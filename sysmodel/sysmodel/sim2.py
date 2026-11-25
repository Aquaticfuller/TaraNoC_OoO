"""Step 2 of the system model: the flat model of sim.py plus the L1 interconnect, data placement, the L2 lanes and
two engine classes. Same unit of simulation (expert phase of layer l, then or overlapped with the mixer of l+1).

What is new compared with sim.py
  pieces    a stream job (an expert, a mixer pass) is cut into pieces. A piece is interleaved over one region of
            the mesh (1, 4, 16 or all groups) and occupies that region's banks until its blocks are done.
  lanes     the L2 ports are lanes of one beat per cycle. A piece uses one lane per group of its region (each
            group has one DMA engine), at most all lanes, so local pieces stream slowly but many at a time.
  distance  a block runs slower the further its engine is from the piece's region (mesh.slow_factor).
  rows      a tensor engine leaves array rows empty when a block has fewer tokens than rows.
  classes   blocks with few tokens may run on vector units; tensor engines take any block.

Schemes
  hw      idle engines pull the nearest ready block; the stream places each piece in the least loaded region.
  plan    one plan after the router: pieces assigned to regions and groups (largest first, knowing how fast each
          group is for each region), every group follows its list, barrier before the mixer.
  static  experts pinned to groups by index, weights interleaved over the whole cluster.
"""
import heapq
import math
from collections import deque
from dataclasses import dataclass, field

from .mesh import Mesh, slow_factor


class _Job:
    __slots__ = ('kind', 'id', 'tok', 'n', 'flops', 'left', 'small', 'pieces')

    def __init__(self, kind, n, flops, eid=-1, tok=None):
        self.kind, self.id, self.tok, self.n, self.flops = kind, eid, tok, n, flops
        self.left, self.small, self.pieces = 0, False, None


class _Piece:
    __slots__ = ('job', 'bytes', 'flops', 'seq', 'region', 'blocks', 'left', 'counted', 'widx', 't_issue', 'exec')

    def __init__(self, job, nbytes, flops, seq):
        self.job, self.bytes, self.flops, self.seq = job, nbytes, flops, seq
        self.region, self.blocks, self.left, self.counted = -1, None, 0, False


class _Block:
    __slots__ = ('piece', 'flops', 'group', 'cls', 'load')

    def __init__(self, piece, flops, group=-1, cls=-1):
        self.piece, self.flops, self.group, self.cls, self.load = piece, flops, group, cls, 0.0


@dataclass
class Result2:
    cycles: float
    per_layer: float
    bound_per_layer: float
    stream_util: float            # share of lane-cycles that carried data
    busy: dict = field(default_factory=dict)        # per engine class: share of engine-cycles running a block
    work_share: dict = field(default_factory=dict)  # per engine class: share of all FLOP
    efficiency: dict = field(default_factory=dict)  # per engine class: FLOP done / (busy cycles x nominal rate)
    mean_hops: float = 0.0        # FLOP-weighted distance between engine and weights
    delay_share: float = 0.0
    fetches_per_layer: float = 0.0
    pieces_per_layer: float = 0.0
    passes_per_layer: float = 0.0
    blocks_per_layer: float = 0.0
    plan_cycles_per_layer: float = 0.0
    block_delay: float = 0.0      # mean cycles from "engine idle and block chosen" to "block running"
    stream_delay: float = 0.0     # mean cycles from "piece chosen" to "piece streaming"
    dispatch_busy: float = 0.0    # share of time the dispatch servers are busy (step 3)
    sched_busy: float = 0.0       # share of time the cluster scheduler is busy (step 3)
    layers: list = field(default_factory=list)
    window: dict = field(default_factory=dict)      # tasks (pieces) issued and not yet retired in order: mean, max; piece lifetimes


class MeshSim:
    def __init__(self, system, model, sched):
        self.sys, self.mod, self.sc = system, model, sched
        self.static = sched.policy == 'static'
        self.list_mode = sched.policy in ('plan', 'static')
        self.mesh = Mesh(system.side, 64 if self.static else sched.region_groups)
        self.G, self.R = self.mesh.G, self.mesh.R
        self.cls = list(system.engines)
        self.nc = len(self.cls)
        self.rate = [c.flop_per_cycle for c in self.cls]
        self.per_group = [c.per_group for c in self.cls]
        self.n_eng = [c.per_group * self.G for c in self.cls]
        tens = [i for i, c in enumerate(self.cls) if c.row_fill or c.name == 'tensor']
        self.main = tens[0] if tens else 0
        vec = [i for i in range(self.nc) if i != self.main]
        self.vec = vec[0] if (vec and tens and sched.vec_max_tokens > 0) else -1
        # queue priorities: 0 expert block, 1 expert block with few tokens, 2 mixer block, 3 mixer block with few tokens
        self.take = [()] * self.nc
        self.take[self.main] = (0, 1, 2, 3)
        if self.vec >= 0:
            self.take[self.vec] = (1, 3)
        self.lanes = system.l2_ports
        self.lane_rate = system.l2_port_bytes_per_cycle * system.l2_efficiency
        self.piece_lanes = min(self.mesh.per_region, self.lanes)
        self.tx = model.expert_bytes / system.l2_bytes_per_cycle
        self.t, self.q, self.seq = 0.0, [], 0
        self.idle = [[c.per_group] * self.G for c in self.cls]
        self.idle_tot = list(self.n_eng)
        self.idle_groups = [set(range(self.G)) for _ in self.cls]
        self.stream_busy = self.delay_cycles = self.bound = self.plan_total = 0.0
        self.busy = [0.0] * self.nc
        self.work = [0.0] * self.nc
        self.hops = 0.0
        self.n_fetch = self.n_pass = self.n_blocks = self.n_pieces = 0
        self.layer_log = []
        self._slow = {}
        # tasks in issue order (a piece = one task of the cluster level): head = oldest not yet retired
        self.win_issued = self.win_head = self.win_max = 0
        self.win_done = set()
        self.win_sum = self.life_sum = self.life_max = 0.0
        # step 3: decision servers; each entry is the cycle at which that server is free again
        self.h = h = sched.hier
        self.n_started = 0
        self.sdelay = self.disp_work = self.sched_work = 0.0
        if h is not None:
            self.disp = [[0.0] * h.dispatch_servers_per_group for _ in range(self.G)]
            self.central = [0.0]
            self.sched_free = 0.0

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
        tot = sum(self.work) or 1.0
        name = [c.name for c in self.cls]
        return Result2(
            cycles=T, per_layer=T / n, bound_per_layer=self.bound / n,
            stream_util=self.stream_busy / (T * self.lanes) if T else 0.0,
            busy={name[i]: self.busy[i] / (T * self.n_eng[i]) for i in range(self.nc)},
            work_share={name[i]: self.work[i] / tot for i in range(self.nc)},
            efficiency={name[i]: (self.work[i] / (self.busy[i] * self.rate[i]) if self.busy[i] else 0.0) for i in range(self.nc)},
            mean_hops=self.hops / tot, delay_share=self.delay_cycles / (T * sum(self.n_eng)) if T else 0.0,
            fetches_per_layer=self.n_fetch / n, pieces_per_layer=self.n_pieces / n, passes_per_layer=self.n_pass / n,
            blocks_per_layer=self.n_blocks / n, plan_cycles_per_layer=self.plan_total / n,
            block_delay=self.delay_cycles / max(1, self.n_started), stream_delay=self.sdelay / max(1, self.n_pieces),
            dispatch_busy=(self.disp_work / (T * (1 if self.h.central else self.G * self.h.dispatch_servers_per_group)) if self.h and T else 0.0),
            sched_busy=self.sched_work / T if self.h and T else 0.0, layers=self.layer_log,
            window=dict(mean=self.win_sum / max(1, self.win_issued), max=self.win_max, tasks_per_layer=self.win_issued / n,
                        life_mean=self.life_sum / max(1, self.win_issued), life_max=self.life_max))

    def slow(self, c, n, g, r):
        key = (c, n, g, r)
        v = self._slow.get(key)
        if v is None:
            v = self._slow[key] = slow_factor(self.cls[c], self.sys, n, self.mesh.hop[g][r])
        return v

    def slow_rr(self, c, n, r2, r):
        """Slow factor of class c for engines of region r2 working on weights held by region r (mean distance)."""
        key = (c, n, r2, r, 'rr')
        v = self._slow.get(key)
        if v is None:
            m = self.mesh.members[r2]
            v = self._slow[key] = slow_factor(self.cls[c], self.sys, n, sum(self.mesh.hop[g][r] for g in m) / len(m))
        return v

    def slow_in(self, c, n):
        key = (c, n)
        v = self._slow.get(key)
        if v is None:
            v = self._slow[key] = slow_factor(self.cls[c], self.sys, n, self.mesh.hop_inside)
        return v

    # ---------------------------------------------------------------- layer set-up
    def start_layer(self, li, routing):
        mod, sc, sy = self.mod, self.sc, self.sys
        self.li, self.t0, self.layer_done, self.layer_passes = li, self.t, False, 0
        M = self.M = routing.tokens
        fx = mod.expert_flop_per_token
        self.experts = [_Job('x', len(tok), len(tok) * fx, e, tok.tolist()) for e, tok in routing.lists().items()]
        for x in self.experts:
            x.small = self.vec >= 0 and x.n <= sc.vec_max_tokens
        hot = sorted(self.experts, key=lambda x: (-x.n, x.id))
        self.order = sorted(self.experts, key=lambda x: x.id) if sc.order == 'index' else hot
        self.lo, self.hi = 0, len(self.order) - 1
        self.pending = [routing.ids.shape[1]] * M
        self.fin_unpassed = self.passed = self.xdone = 0
        self.pass_min = max(1, int(round(sc.pass_min_frac * M)))
        self.in_open, self.out_started = 0, False
        free = sy.spm_bytes - M * mod.act_bytes_per_token
        if free < 2 * mod.expert_bytes:
            raise ValueError('SPM too small for %d tokens: fewer than two experts fit' % M)
        self.rcap = free / self.R
        self.rfree = [self.rcap] * self.R
        self.rbusy = [False] * self.R
        self.rload = [0.0] * self.R
        self.rot = 0
        self.piece_bytes = min(mod.expert_bytes, self.rcap / sc.slots_per_region)
        self.resident_flops = 0.0
        self.lanes_free = self.lanes
        self.mixq, self.xq = deque(), deque()
        self.rq = [[deque() for _ in range(self.R)] for _ in range(4)]
        self.ne = [set() for _ in range(4)]
        self.pq = [[deque() for _ in range(self.G)] for _ in self.cls]
        self.pseq = 0
        total_x = M * routing.ids.shape[1] * fx
        total_m = M * mod.mixer_flop_per_token
        gemm_rate = sum(self.n_eng[c] * self.rate[c] for c in range(self.nc) if c == self.main or c == self.vec)
        self.bound += max((total_x + total_m) / gemm_rate,
                          (len(self.experts) + mod.mixer_in_expert_eq + mod.mixer_out_expert_eq) * self.tx)
        plan_time = 0.0
        if self.list_mode:
            plan_time = self._plan(hot, total_x)
        if self.h is not None:
            plan_time += M * routing.ids.shape[1] * self.h.issue_cycles_per_route / self.h.issue_cores
        self.plan_total += plan_time
        self.at(self.t + plan_time, self.kick_stream)

    def _pieces(self, job, nbytes):
        k = max(1, int(math.ceil(nbytes / self.piece_bytes - 1e-9)))
        job.left = k
        job.pieces = []
        for _ in range(k):
            self.pseq += 1
            job.pieces.append(_Piece(job, nbytes / k, job.flops / k, self.pseq))
        return job.pieces

    def _pref(self, job):
        return self.vec if job.small else self.main

    def _plan(self, hot, total_x):
        """Software plan (or the static pinning): every expert block gets its group before the first fetch."""
        sc, G, mesh = self.sc, self.G, self.mesh
        self.rlist = [deque() for _ in range(self.R)]
        if self.static:
            for x in self.order:
                p = self._pieces(x, self.mod.expert_bytes)[0]
                p.region, c, g = 0, self.main, x.id % G
                p.blocks = [_Block(p, p.flops / self.per_group[c], g, c) for _ in range(self.per_group[c])]
                self.rlist[0].append(p)
            return 0.0
        pieces = [p for x in self.order for p in self._pieces(x, self.mod.expert_bytes)]
        # 1. pieces to regions, largest first, per engine class
        rl = [[0.0] * self.R for _ in self.cls]
        cost = lambda p: p.flops / self.rate[self._pref(p.job)] * self.slow_in(self._pref(p.job), p.job.n)
        for p in sorted(pieces, key=lambda p: -cost(p)):
            c = self._pref(p.job)
            r = min(range(self.R), key=lambda r: rl[c][r])
            p.region = r
            rl[c][r] += cost(p)
        # 2. each piece to one or more groups of its region, largest first, with the speed of each group for that region
        #    The planner knows how fast an engine class is for a given token count, so it cuts in time, not in FLOP:
        #    a share is what one group finishes in about one fetch time, and no shorter than min_block_cycles.
        gl = [[0.0] * G for _ in self.cls]
        subs = []
        alone = lambda p: cost(p) / self.per_group[self._pref(p.job)]      # cycles for one group on its own
        total = [sum(alone(p) for p in pieces if self._pref(p.job) == c) for c in range(self.nc)]
        for p in pieces:
            c = self._pref(p.job)
            target = max(min(total[c] / (G * sc.plan_blocks_per_group), self.tx), sc.min_block_cycles)
            k = max(1, min(mesh.per_region, int(math.ceil(alone(p) / target))))
            p.blocks = []
            subs.extend((p, p.flops / k) for _ in range(k))
        for p, f in sorted(subs, key=lambda s: -s[1]):
            c, r = self._pref(p.job), p.region
            t = lambda g: f / (self.per_group[c] * self.rate[c]) * self.slow(c, p.job.n, g, r)
            g = min(mesh.members[r], key=lambda g: gl[c][g] + t(g))
            gl[c][g] += t(g)
            p.blocks.extend(_Block(p, f / self.per_group[c], g, c) for _ in range(self.per_group[c]))
        for p in pieces:
            self.rlist[p.region].append(p)
        return sc.plan_cycles_per_block * len(subs) / sc.plan_cores

    # ---------------------------------------------------------------- weight stream
    def kick_stream(self):
        if self.list_mode and self.xdone < len(self.experts):
            self._kick_lists()
        while True:
            p = self._peek()
            if p is None:
                return
            if self.sc.window_tasks and self.win_issued - self.win_head >= self.sc.window_tasks:
                return
            r = self._place(p)
            if r < 0:
                return
            (self.mixq if p.job.kind != 'x' else self.xq).popleft()
            self._start_piece(p, r)

    def _kick_lists(self):
        heads = sorted((self.rlist[r][0].seq, r) for r in range(self.R) if self.rlist[r] and not self.rbusy[r])
        for _, r in heads:
            if self.lanes_free < self.piece_lanes:
                return
            p = self.rlist[r][0]
            if self.rfree[r] + 1e-6 < p.bytes:
                continue
            self.rlist[r].popleft()
            self._start_piece(p, r)

    def _peek(self):
        mod, sc = self.mod, self.sc
        while True:
            if self.mixq:
                return self.mixq[0]
            all_x = self.xdone == len(self.experts)
            if self.fin_unpassed > 0 and (all_x or (sc.overlap and self.fin_unpassed >= self.pass_min)):
                n = self.fin_unpassed
                self.fin_unpassed = 0
                self.passed += n
                self.n_pass += 1
                self.layer_passes += 1
                work = n * mod.mixer_phi * mod.mixer_flop_per_token
                if work > 0:
                    j = _Job('in', n, work)
                    j.small = self.vec >= 0 and n <= sc.vec_max_tokens
                    self.in_open += 1
                    self.mixq.extend(self._pieces(j, mod.mixer_in_expert_eq * mod.expert_bytes))
                continue
            if not self.list_mode:
                if self.xq:
                    return self.xq[0]
                if self.lo <= self.hi and max(self.rfree) + 1e-6 >= self.piece_bytes:
                    if sc.order == 'mix' and self.resident_flops / (self.n_eng[self.main] * self.rate[self.main]) >= self.tx:
                        x = self.order[self.hi]
                        self.hi -= 1
                    else:
                        x = self.order[self.lo]
                        self.lo += 1
                    self.xq.extend(self._pieces(x, mod.expert_bytes))
                    continue
            if all_x and self.passed == self.M and self.in_open == 0 and not self.out_started:
                self.out_started = True
                work = self.M * (1.0 - mod.mixer_phi) * mod.mixer_flop_per_token
                if work <= 0:
                    self.layer_done = True
                    return None
                j = _Job('out', self.M, work)
                j.small = self.vec >= 0 and self.M <= sc.vec_max_tokens
                self.mixq.extend(self._pieces(j, mod.mixer_out_expert_eq * mod.expert_bytes))
                continue
            return None

    def _place(self, p):
        """Region for a piece that is not in a plan: the least loaded region that has a free DMA and room."""
        if p.bytes > 0 and self.lanes_free < self.piece_lanes:
            return -1
        counted = p.job.kind == 'x' or self.sc.mixer_spm
        best, bl = -1, 0.0
        R = self.R
        for i in range(R):
            r = (self.rot + i) % R
            if p.bytes > 0 and (self.rbusy[r] or (counted and self.rfree[r] + 1e-6 < p.bytes)):
                continue
            if best < 0 or self.rload[r] < bl:
                best, bl = r, self.rload[r]
        if best >= 0:
            self.rot = (best + 1) % R
        return best

    def _start_piece(self, p, r):
        sc = self.sc
        job = p.job
        p.region = p.exec = r
        p.widx, p.t_issue = self.win_issued, self.t
        self.win_issued += 1
        occ = self.win_issued - self.win_head
        self.win_sum += occ
        self.win_max = max(self.win_max, occ)
        if p.seq == job.pieces[0].seq and job.kind == 'x':
            self.n_fetch += 1
            self.resident_flops += job.flops
        self.n_pieces += 1
        if p.blocks is None:
            c = self._pref(job)
            T = p.flops / self.rate[c] * self.slow_in(c, job.n)
            kmax = self.n_eng[c] if job.kind == 'x' else max(1, int(self.n_eng[c] * sc.blocks_per_engine / len(job.pieces)))
            k = max(1, min(kmax, int(math.ceil(T / sc.min_block_cycles))))
            if sc.fixed_block_cycles > 0:
                k = max(1, int(round(T / sc.fixed_block_cycles)))
            if sc.steer == 'soft' and self.R > 1:
                # task-level steering: run the piece in the region that finishes it first; its weights stay in r
                best = None
                for r2 in range(self.R):
                    t2 = p.flops / self.rate[c] * self.slow_rr(c, job.n, r2, r)
                    if best is None or self.rload[r2] + t2 < best[0]:
                        best = (self.rload[r2] + t2, r2, t2)
                p.exec, T = best[1], best[2]
            p.blocks = [_Block(p, p.flops / k) for _ in range(k)]
            for b in p.blocks:
                b.load = T / k
            self.rload[p.exec] += T
        p.left = len(p.blocks)
        self.n_blocks += p.left
        if p.bytes <= 0:
            for b in p.blocks:
                self.at(self.t, self.on_ready, b)
            return
        p.counted = job.kind == 'x' or sc.mixer_spm
        if p.counted:
            self.rfree[r] -= p.bytes
        self.rbusy[r] = True
        self.lanes_free -= self.piece_lanes
        s = self.t + (sc.stream_delay if self.h is None else self._stream_decision(r))
        self.sdelay += s - self.t
        d = p.bytes / (self.piece_lanes * self.lane_rate)
        self.stream_busy += d * self.piece_lanes
        nb = len(p.blocks)
        for j, b in enumerate(p.blocks):
            self.at(s + (d * (j + 1) / nb if sc.tile_following else d), self.on_ready, b)
        self.at(s + d, self.on_stream_done, r)

    def _stream_decision(self, r):
        h = self.h
        if h.stream_local:
            self.disp_work += h.sched_cycles
            srv = self.disp[self.mesh.members[r][0]]
            i = min(range(len(srv)), key=srv.__getitem__)
            srv[i] = max(self.t, srv[i]) + h.sched_cycles
            return srv[i] - self.t
        self.sched_work += h.sched_cycles
        self.sched_free = max(self.t, self.sched_free) + h.sched_cycles
        return self.sched_free - self.t

    def _dispatch(self, g, b):
        h = self.h
        svc = h.dispatch_cycles
        r = b.piece.exec
        if b.group < 0 and self.mesh.region_of[g] != r:
            svc += h.steal_cycles + h.steal_hop_cycles * self.mesh.hop[g][r]
        srv = self.central if h.central else self.disp[g]
        i = min(range(len(srv)), key=srv.__getitem__) if len(srv) > 1 else 0
        srv[i] = max(self.t, srv[i]) + svc
        self.disp_work += svc
        return srv[i] + h.launch_cycles - self.t

    def on_stream_done(self, r):
        self.rbusy[r] = False
        self.lanes_free += self.piece_lanes
        self.kick_stream()

    # ---------------------------------------------------------------- engines
    def on_ready(self, b):
        if b.group >= 0:
            c, g = b.cls, b.group
            if self.idle[c][g]:
                self._start(c, g, b)
            else:
                self.pq[c][g].append(b)
            return
        job = b.piece.job
        r = b.piece.region
        for c in ((self.vec, self.main) if job.small else (self.main,)):
            if self.idle_tot[c]:
                ig = self.idle_groups[c]
                if not self.sc.cross_region:
                    own = [g for g in self.mesh.members[b.piece.exec] if self.idle[c][g]]
                    if not own:
                        continue
                    self._start(c, own[0], b)
                    return
                if len(ig) <= 8:
                    hop = self.mesh.hop
                    g = min(ig, key=lambda g: (hop[g][r], g))
                else:
                    idle = self.idle[c]
                    g = next(g for g in self.mesh.groups_near[r] if idle[g])
                self._start(c, g, b)
                return
        p = (0 if job.kind == 'x' else 2) + (1 if job.small else 0)
        self.rq[p][b.piece.exec].append(b)
        self.ne[p].add(b.piece.exec)

    def _feed(self, c, g):
        """An engine of class c in group g is idle: its own list first, then the nearest ready block it may take."""
        idle = self.idle[c]
        pq = self.pq[c][g]
        while idle[g]:
            if pq:
                self._start(c, g, pq.popleft())
                continue
            b = None
            for p in self.take[c]:
                ne = self.ne[p]
                if not ne:
                    continue
                if not self.sc.cross_region:
                    r = self.mesh.region_of[g]
                    if r not in ne:
                        continue
                    dq = self.rq[p][r]
                    b = dq.popleft()
                    if not dq:
                        ne.discard(r)
                    break
                if len(ne) <= 8:
                    hop = self.mesh.hop[g]
                    r = min(ne, key=lambda r: (hop[r], r))
                else:
                    r = next(r for r in self.mesh.regions_near[g] if r in ne)
                dq = self.rq[p][r]
                b = dq.popleft()
                if not dq:
                    ne.discard(r)
                break
            if b is None:
                return
            self._start(c, g, b)

    def _start(self, c, g, b):
        self.idle[c][g] -= 1
        self.idle_tot[c] -= 1
        if not self.idle[c][g]:
            self.idle_groups[c].discard(g)
        job = b.piece.job
        r = b.piece.region
        d = b.flops / self.rate[c] * self.slow(c, job.n, g, r)
        self.busy[c] += d
        self.work[c] += b.flops
        self.hops += b.flops * self.mesh.hop[g][r]
        delay = self.sc.block_delay if self.h is None else self._dispatch(g, b)
        self.n_started += 1
        self.delay_cycles += delay
        self.at(self.t + delay + d, self.on_block_done, c, g, b)

    def on_block_done(self, c, g, b):
        self.idle[c][g] += 1
        self.idle_tot[c] += 1
        self.idle_groups[c].add(g)
        p = b.piece
        job = p.job
        self.rload[p.exec] -= b.load
        if job.kind == 'x':
            self.resident_flops -= b.flops
        p.left -= 1
        if p.left == 0:
            kick = bool(self.sc.window_tasks)
            life = self.t - p.t_issue
            self.life_sum += life
            self.life_max = max(self.life_max, life)
            self.win_done.add(p.widx)
            while self.win_head in self.win_done:
                self.win_done.discard(self.win_head)
                self.win_head += 1
            if p.counted:
                self.rfree[p.region] += p.bytes
                kick = True
            job.left -= 1
            if job.left == 0:
                kick = True
                if job.kind == 'x':
                    self.xdone += 1
                    if self.h is not None and self.h.done_cycles_per_token:
                        w = job.n * self.h.done_cycles_per_token
                        self.sched_free = max(self.t, self.sched_free) + w
                        self.sched_work += w
                    pend = self.pending
                    for t in job.tok:
                        pend[t] -= 1
                        if pend[t] == 0:
                            self.fin_unpassed += 1
                elif job.kind == 'in':
                    self.in_open -= 1
                else:
                    self.layer_done = True
            if kick:
                self.kick_stream()
        self._feed(c, g)


def simulate2(system, model, sched, layers):
    """Run the layers one after the other with the step-2 model and return a Result2."""
    return MeshSim(system, model, sched).run(layers)
