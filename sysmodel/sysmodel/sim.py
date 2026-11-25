"""Event-driven, task-level model of MoE layers on a shared-L1 cluster. Step 1: flat scheduler.

One simulated unit is the expert phase of layer l followed by (or overlapped with) the mixer of layer l+1,
the same unit as the fluid model in moe_study/model/overlap_model.js, but with discrete blocks on discrete
engines. Time is in cycles.

Resources
  engines   the GEMM-capable engines of the system; each runs one block at a time
  stream    the L2 ports, shared by `parallel_fetches` concurrent stream jobs
  SPM       bytes; an expert holds its weights from the start of its fetch until its last block is done

Work
  expert e      one stream job of expert_bytes, and n_e * expert_flop_per_token FLOP cut into blocks
  mixer pass    one stream job of mixer_in weights, and phi * mixer FLOP for the tokens in the pass
  ordered part  one stream job of mixer_out weights, and (1 - phi) * mixer FLOP for all tokens
"""
import heapq
import math
import random
from collections import deque
from dataclasses import dataclass, field


class _Expert:
    __slots__ = ('id', 'tok', 'n', 'flops', 'blocks', 'left', 'state', 'rank')

    def __init__(self, eid, tok, flops):
        self.id, self.tok, self.n, self.flops = eid, tok, len(tok), flops
        self.blocks, self.left, self.state, self.rank = [], 0, 'waiting', 0


class _Block:
    __slots__ = ('kind', 'flops', 'owner', 'group', 'ready', 'started')

    def __init__(self, kind, flops, owner=None, group=-1):
        self.kind, self.flops, self.owner, self.group = kind, flops, owner, group
        self.ready, self.started = False, False


@dataclass
class Result:
    cycles: float
    per_layer: float
    bound_per_layer: float
    stream_util: float
    compute_util: float
    delay_share: float
    fetches_per_layer: float
    passes_per_layer: float
    blocks_per_layer: float
    layers: list = field(default_factory=list)
    stream_jobs: list = field(default_factory=list)
    compute_bins: dict = field(default_factory=dict)


class LayerSim:
    def __init__(self, system, model, sched, trace_bin=None):
        self.sys, self.mod, self.sc = system, model, sched
        rng = random.Random(sched.seed)
        cls = next(e for e in system.engines if e.name == system.gemm_class)
        self.per_group = cls.per_group
        self.n_eng = system.groups * cls.per_group
        self.rate_nom = cls.flop_per_cycle
        self.rate = [cls.flop_per_cycle / (1.0 + sched.speed_spread * rng.random()) for _ in range(self.n_eng)]
        self.total_rate = self.n_eng * cls.flop_per_cycle
        self.lane_rate = system.l2_bytes_per_cycle / sched.parallel_fetches
        self.tx = model.expert_bytes / system.l2_bytes_per_cycle      # cycles to fetch one expert over all ports
        self.list_mode = sched.policy in ('plan', 'static')
        self.trace_bin = trace_bin
        self.t = 0.0
        self.q, self.seq = [], 0
        self.idle = [deque(range(g * self.per_group, (g + 1) * self.per_group)) for g in range(system.groups)]
        self.idle_groups = set(range(system.groups))
        self.n_idle = self.n_eng
        self.stream_busy = self.compute_busy = self.delay_cycles = 0.0
        self.n_fetch = self.n_pass = self.n_blocks = 0
        self.stream_jobs, self.bins, self.layer_log = [], {}, []
        self.bound = 0.0

    # ---------------------------------------------------------------- events
    def at(self, t, fn, *a):
        self.seq += 1
        heapq.heappush(self.q, (t, self.seq, fn, a))

    def run(self, layers):
        for li, routing in enumerate(layers):
            self.start_layer(li, routing)
            while not self.layer_done:
                if not self.q:
                    raise RuntimeError('deadlock in layer %d at cycle %.0f' % (li, self.t))
                t, _, fn, a = heapq.heappop(self.q)
                self.t = t
                fn(*a)
            self.layer_log.append({'layer': li, 't0': self.t0, 't1': self.t, 'experts': len(self.experts), 'passes': self.layer_passes})
        n, T = len(layers), self.t
        return Result(cycles=T, per_layer=T / n, bound_per_layer=self.bound / n,
                      stream_util=self.stream_busy / (T * self.sc.parallel_fetches) * 1.0 if T else 0.0,
                      compute_util=self.compute_busy / (T * self.n_eng) if T else 0.0,
                      delay_share=self.delay_cycles / (T * self.n_eng) if T else 0.0,
                      fetches_per_layer=self.n_fetch / n, passes_per_layer=self.n_pass / n, blocks_per_layer=self.n_blocks / n,
                      layers=self.layer_log, stream_jobs=self.stream_jobs, compute_bins=self.bins)

    # ---------------------------------------------------------------- layer set-up
    def start_layer(self, li, routing):
        mod, sc, sy = self.mod, self.sc, self.sys
        self.li, self.t0, self.layer_done, self.layer_passes = li, self.t, False, 0
        M = self.M = routing.tokens
        fx = mod.expert_flop_per_token
        self.experts = [_Expert(e, tok.tolist(), len(tok) * fx) for e, tok in routing.lists().items()]
        hot = sorted(self.experts, key=lambda x: (-x.n, x.id))
        for i, x in enumerate(hot):
            x.rank = i
        self.order = sorted(self.experts, key=lambda x: x.id) if sc.order == 'index' else hot
        self.lo, self.hi = 0, len(self.order) - 1
        self.pending = [routing.ids.shape[1]] * M
        self.fin_unpassed = self.passed = self.xdone = 0
        self.pass_min = max(1, int(round(sc.pass_min_frac * M)))
        self.passes_open = 0
        self._pass_left = 0
        self.out_started, self.out_left = False, 0
        self.spm_free = sy.spm_bytes - M * mod.act_bytes_per_token
        if self.spm_free < 2 * mod.expert_bytes:
            raise ValueError('SPM too small for %d tokens: fewer than two experts fit' % M)
        self.resident_flops = 0.0
        self.lanes_free = sc.parallel_fetches
        self.ready_x, self.ready_m = deque(), deque()
        total_x = M * routing.ids.shape[1] * fx
        total_m = M * mod.mixer_flop_per_token
        self.min_flops = sc.min_block_cycles * self.rate_nom
        self.bound += max((total_x + total_m) / self.total_rate,
                          (len(self.experts) + mod.mixer_in_expert_eq + mod.mixer_out_expert_eq) * self.tx)
        plan_time = 0.0
        if self.list_mode:
            G = sy.groups
            self.gready = [deque() for _ in range(G)]
            if sc.policy == 'static':
                pieces = [(x, x.flops, x.id % G) for x in self.experts]
            else:
                # a piece is what one group is given of one expert: about total/(G*pieces per group), but small enough
                # that a group drains it in one fetch time, so that cold experts do not block the SPM
                grp_rate = self.per_group * self.rate_nom
                target = max(min(total_x / (G * sc.plan_blocks_per_group), grp_rate * self.tx), grp_rate * sc.min_block_cycles)
                raw = []
                for x in hot:
                    k = max(1, min(G, int(math.ceil(x.flops / target))))
                    raw.extend((x, x.flops / k) for _ in range(k))
                load = [(0.0, g) for g in range(G)]
                heapq.heapify(load)
                pieces = []
                for x, f in sorted(raw, key=lambda p: -p[1]):
                    l, g = heapq.heappop(load)
                    pieces.append((x, f, g))
                    heapq.heappush(load, (l + f, g))
                plan_time = sc.plan_cycles_per_block * len(raw)
            for x, f, g in pieces:
                for _ in range(self.per_group):
                    b = _Block('x', f / self.per_group, x, g)
                    x.blocks.append(b)
            for x in self.experts:
                x.left = len(x.blocks)
        self.at(self.t + plan_time, self.kick_stream)

    # ---------------------------------------------------------------- weight stream
    def kick_stream(self):
        mod, sc = self.mod, self.sc
        while self.lanes_free > 0:
            all_x = self.xdone == len(self.experts)
            if self.fin_unpassed > 0 and (all_x or (sc.overlap and self.fin_unpassed >= self.pass_min)):
                n = self.fin_unpassed
                self.fin_unpassed = 0
                self.passed += n
                self.n_pass += 1
                self.layer_passes += 1
                work = n * mod.mixer_phi * mod.mixer_flop_per_token
                blocks = self._cut('in', work)
                self.passes_open += 1
                self._pass_left += len(blocks)
                self._stream_job('in', mod.mixer_in_expert_eq * mod.expert_bytes if work > 0 else 0.0, blocks)
                if not blocks:
                    self.passes_open -= 1
            elif self.lo <= self.hi and self.spm_free >= mod.expert_bytes:
                if sc.order == 'mix' and self.resident_flops / self.total_rate >= self.tx:
                    x = self.order[self.hi]
                    self.hi -= 1
                else:
                    x = self.order[self.lo]
                    self.lo += 1
                self.spm_free -= mod.expert_bytes
                self.resident_flops += x.flops
                x.state = 'fetching'
                self.n_fetch += 1
                if not self.list_mode:
                    # as many blocks as there are engines, so the whole cluster can drain a resident expert,
                    # but no block shorter than min_block_cycles
                    k = max(1, min(self.n_eng, int(math.ceil(x.flops / self.min_flops))))
                    x.blocks = [_Block('x', x.flops / k, x) for _ in range(k)]
                    x.left = k
                self.n_blocks += len(x.blocks)
                self._stream_job('x', mod.expert_bytes, x.blocks)
            elif all_x and self.passed == self.M and self.passes_open == 0 and not self.out_started:
                self.out_started = True
                work = self.M * (1.0 - mod.mixer_phi) * mod.mixer_flop_per_token
                blocks = self._cut('out', work)
                self.out_left = len(blocks)
                self._stream_job('out', mod.mixer_out_expert_eq * mod.expert_bytes if work > 0 else 0.0, blocks)
                if not blocks:
                    self.layer_done = True
            else:
                break

    def _cut(self, kind, work):
        if work <= 0:
            return []
        k = max(1, min(int(self.n_eng * self.sc.blocks_per_engine), int(math.ceil(work / self.min_flops))))
        self.n_blocks += k
        return [_Block(kind, work / k) for _ in range(k)]

    def _stream_job(self, kind, nbytes, blocks):
        if nbytes <= 0:
            for b in blocks:
                self.at(self.t, self.on_ready, b)
            return
        self.lanes_free -= 1
        s = self.t + self.sc.stream_delay
        d = nbytes / self.lane_rate
        self.stream_busy += d
        if self.trace_bin:
            self.stream_jobs.append((kind, s, s + d, self.li))
        nb = len(blocks)
        for j, b in enumerate(blocks):
            self.at(s + (d * (j + 1) / nb if self.sc.tile_following else d), self.on_ready, b)
        self.at(s + d, self.on_stream_done)

    def on_stream_done(self):
        self.lanes_free += 1
        self.kick_stream()

    # ---------------------------------------------------------------- engines
    def on_ready(self, b):
        b.ready = True
        if b.kind != 'x':
            self.ready_m.append(b)
        elif not self.list_mode:
            self.ready_x.append(b)
        else:
            self.gready[b.group].append(b)      # a group runs its own blocks in the order they become ready
            self.dispatch(b.group)
            return
        self.dispatch()

    def dispatch(self, g=None):
        if self.n_idle == 0:
            return
        if self.list_mode and g is not None:
            q = self.gready[g]
            while q and self.idle[g]:
                self._start(g, q.popleft())
        while self.n_idle and (self.ready_x or self.ready_m):
            g = next(iter(self.idle_groups))
            self._start(g, self.ready_x.popleft() if self.ready_x else self.ready_m.popleft())

    def _start(self, g, b):
        e = self.idle[g].popleft()
        if not self.idle[g]:
            self.idle_groups.discard(g)
        self.n_idle -= 1
        b.started = True
        d = b.flops / self.rate[e]
        s = self.t + self.sc.block_delay
        self.compute_busy += d
        self.delay_cycles += self.sc.block_delay
        if self.trace_bin:
            w, i = self.trace_bin, int(s // self.trace_bin)
            k = 0 if b.kind == 'x' else 1
            a, end = s, s + d
            while a < end:
                nxt = min(end, (i + 1) * w)
                self.bins.setdefault(i, [0.0, 0.0])[k] += nxt - a
                a, i = nxt, i + 1
        self.at(s + d, self.on_block_done, e, g, b)

    def on_block_done(self, e, g, b):
        self.idle[g].append(e)
        self.idle_groups.add(g)
        self.n_idle += 1
        if b.kind == 'x':
            x = b.owner
            self.resident_flops -= b.flops
            x.left -= 1
            if x.left == 0:
                x.state = 'done'
                self.xdone += 1
                self.spm_free += self.mod.expert_bytes
                pend = self.pending
                for t in x.tok:
                    pend[t] -= 1
                    if pend[t] == 0:
                        self.fin_unpassed += 1
                self.kick_stream()
        elif b.kind == 'in':
            self._pass_left -= 1
            if self._pass_left == 0:
                self.passes_open = 0
                self.kick_stream()
        else:
            self.out_left -= 1
            if self.out_left == 0:
                self.layer_done = True
        self.dispatch(g)


def simulate(system, model, sched, layers, trace_bin=None):
    """Run the layers one after the other and return a Result."""
    return LayerSim(system, model, sched, trace_bin).run(layers)
