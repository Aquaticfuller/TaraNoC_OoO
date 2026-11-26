#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Task programs for the testbench of the task scheduler (hw/tb/tb_tsched.sv).

Two kinds of program
  random  a random program that exercises every instruction and every dependency the testbench checks
  moe     the layers of an MoE model for a batch of tokens, cut exactly as the system model cuts them
          (sysmodel/sysmodel/sim2.py with overlap off): experts busiest first, each a few pieces of
          weights; then the two mixer stages, each behind a TJoin. The same layers are run through the
          system model and its result is written to model.json for comparison.

Files written to the output directory
  prog.txt   one task instruction per line:
             op hd_v hd hs1_v hs1 follow kill hs2_v hs2 cls nblk kern arg len addr
             op: 0 TLoad, 1 TRun, 2 TJoin, 3 TFree; follow: bit 0 follow the stream of hs1, bit 1 chain (follow
             the task of hs2 block by block); cls: bit 0 tensor engines, bit 1 vector units,
             bits 3:2 the speed hint vslow of a task for both (a block takes 2^vslow times as long on a vector unit);
             arg of a TRun is its task index
  tasks.txt  first line: number of run tasks; then per task
             index cls nblk follow need dep  T[0..H-1] V[0..H-1]
             need: tasks 0..need-1 must be done before the task starts; dep: one task that must be done, or -1
             follow: bit 0 the task follows its stream, bit 1 it is chained to task dep (its k-th block starts
             after k blocks of dep are done)
             T, V: cycles of one block on a tensor engine / vector unit at each of the H distances
  hop.txt    first line: groups domains H; then per group, the distance index to each domain
  model.json (moe) what the system model predicts for the same layers

  hint    one or several equal matrix tasks, each on its own load (so each in its own domain), with block times
          as measured on the cluster hardware: for the rule that shares a task between the two PE types
  chain   chains of three kernels over a matrix (tensor engines, vector units, tensor engines), cut into several
          chains of tasks or not, with block times as measured on the cluster hardware

usage
  gen_program.py random <out_dir> [--side 4] [--seed 1] [--pieces 200] [--slots 4]
  gen_program.py hint <out_dir> [--side 2] [--blocks 128] [--tasks 1] [--cls 3] [--hint 2] [--tdur 860] [--vdur 3500]
  gen_program.py chain <out_dir> [--side 2] [--blocks 128] [--tasks 1] [--cut 1] [--order chain] [--home 0]
                 [--follow 0] [--tdur 845] [--sdur 2760]
  gen_program.py moe <out_dir> --kind midfill --n 64 [--regime x1] [--layers 1] [--block 500] [--vec 8]
                 [--seed 11] [--trace <dir>] [--synthetic] [--vslow]
"""
import argparse
import json
import math
import os
import random
import sys
from dataclasses import replace

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'sysmodel'))
sys.path.insert(0, os.path.join(HERE, '..', 'sysmodel', 'scripts'))

from sysmodel.mesh import Mesh, slow_factor                      # noqa: E402

LOAD, RUN, JOIN, FREE = 0, 1, 2, 3
CLS_T, CLS_V, CLS_ANY = 1, 2, 3
CHUNK = 128         # a load is a multiple of GroupsPerDomain * ChunksPerGroup; this covers up to 32 chunks
NBLK_MAX = 1023     # blocks of one task (NblkW in tsched_pkg)


class Program:
    def __init__(self):
        self.instr, self.tasks, self.addr = [], [], 0x1000

    def load(self, hd, nbytes):
        nbytes = max(CHUNK, int(math.ceil(nbytes / CHUNK)) * CHUNK)
        assert nbytes < (1 << 24), 'a load must fit the 24-bit length field'
        self.instr.append((LOAD, 1, hd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, nbytes, self.addr))
        self.addr += nbytes

    def run(self, cls, nblk, dur_t, dur_v, hs1=None, follow=False, kill=False, hs2=None, hd=None, need=0, dep=-1, vslow=0,
            chain=False):
        t = len(self.tasks)
        assert 1 <= nblk <= NBLK_MAX and 0 <= vslow <= 3 and (vslow == 0 or cls == CLS_ANY)
        chain = bool(chain and hs2 is not None)
        assert not chain or (dep >= 0 and self.tasks[dep][2] == nblk), 'a chained task has as many blocks as the task it follows'
        self.tasks.append((t, cls, nblk, int(bool(follow and hs1 is not None and not chain)) | (2 if chain else 0), need, dep, dur_t, dur_v))
        self.instr.append((RUN, int(hd is not None), hd or 0, int(hs1 is not None), hs1 or 0, int(follow) | (2 if chain else 0), int(kill),
                           int(hs2 is not None), hs2 or 0, cls | (vslow << 2), nblk, 0, t, 0, 0))
        return t

    def join(self, hd):
        self.instr.append((JOIN, 1, hd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    def free(self, hs):
        self.instr.append((FREE, 0, 0, 1, hs, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    def write(self, out, mesh, hops):
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, 'prog.txt'), 'w') as f:
            for i in self.instr:
                f.write(' '.join(str(x) for x in i) + '\n')
        with open(os.path.join(out, 'tasks.txt'), 'w') as f:
            f.write('%d\n' % len(self.tasks))
            for t, cls, nblk, follow, need, dep, dt, dv in self.tasks:
                f.write('%d %d %d %d %d %d  %s  %s\n' % (t, cls, nblk, follow, need, dep, ' '.join(map(str, dt)), ' '.join(map(str, dv))))
        idx = {h: i for i, h in enumerate(hops)}
        with open(os.path.join(out, 'hop.txt'), 'w') as f:
            f.write('%d %d %d\n' % (mesh.G, mesh.R, len(hops)))
            for g in range(mesh.G):
                f.write(' '.join(str(idx[mesh.hop[g][r]]) for r in range(mesh.R)) + '\n')


def hop_values(mesh):
    return sorted({mesh.hop[g][r] for g in range(mesh.G) for r in range(mesh.R)})


# --------------------------------------------------------------------------------------------- random
def gen_random(a):
    rng = random.Random(a.seed)
    mesh = Mesh(2 * a.side, 4)
    hops = hop_values(mesh)
    p = Program()
    total_slots = mesh.R * a.slots
    max_live = max(1, min(6, total_slots - 1))    # loads whose mapping has not ended: must stay below the slots
    live = []                                     # arch handles that hold a load
    free_arch = list(range(1, 9))
    producer = {}                                 # arch handle -> run task that defines it
    joins = {}                                    # arch handle -> number of run tasks before that join
    def dur():
        b = rng.randint(20, 300)
        return [max(1, int(b * (1 + 0.15 * i))) for i in range(len(hops))]

    for _ in range(a.pieces):
        r = rng.random()
        if r < 0.45 and len(live) < max_live and free_arch:
            h = free_arch.pop(rng.randrange(len(free_arch)))
            p.load(h, rng.choice((1, 2, 4, 8, 16)) * 1024)
            live.append(h)
        elif r < 0.85:
            kw = {}
            if live and rng.random() < 0.8:
                h = rng.choice(live)
                kw.update(hs1=h, follow=rng.random() < 0.7)
                if rng.random() < 0.5:
                    kw['kill'] = True
                    live.remove(h)
                    free_arch.append(h)
            c = rng.random()
            if joins and c < 0.3:
                h2 = rng.choice(list(joins))
                kw.update(hs2=h2, need=joins[h2])
            elif producer and c < 0.6:
                h2 = rng.choice(list(producer))
                kw.update(hs2=h2, dep=producer[h2])
            nblk = rng.choice((1, 1, 2, 3, 5, 8, 13, 40, 90))
            if 'dep' in kw and rng.random() < 0.6:
                # Chained to the task of hs2: as many blocks as that task.
                kw['chain'] = True
                nblk = p.tasks[kw['dep']][2]
            hd = None
            if rng.random() < (0.6 if kw.get('chain') else 0.3):
                hd = rng.randrange(16, 24)
                joins.pop(hd, None)
            c = rng.choice((CLS_T, CLS_V, CLS_ANY, CLS_ANY))
            t = p.run(c, nblk, dur(), dur(), hd=hd,
                      vslow=rng.choice((0, 1, 1, 2, 3)) if c == CLS_ANY else 0, **kw)
            if hd is not None:
                producer[hd] = t
        elif r < 0.92:
            hd = rng.randrange(16, 24)
            producer.pop(hd, None)
            p.join(hd)
            joins[hd] = len(p.tasks)
        elif live:
            h = live.pop(rng.randrange(len(live)))
            free_arch.append(h)
            p.free(h)
    for h in live:
        p.free(h)
    p.join(31)
    p.write(a.out, mesh, hops)
    print('random: %d instructions, %d run tasks, %d domains' % (len(p.instr), len(p.tasks), mesh.R))


# --------------------------------------------------------------------------------------------- hint
def gen_hint(a):
    mesh = Mesh(2 * a.side, 4)
    hops = hop_values(mesh)
    p = Program()
    # A block that runs in another domain was about 5% slower on the hardware. hops[0] is the distance inside the
    # domain of the data.
    dt = [a.tdur if h == hops[0] else int(a.tdur * 1.05) for h in hops]
    dv = [a.vdur if h == hops[0] else int(a.vdur * 1.05) for h in hops]
    for i in range(a.tasks):
        p.load(1 + i, a.blocks * 512)
        p.run(a.cls, a.blocks, dt, dv, hs1=1 + i, follow=True, kill=True, vslow=a.hint if a.cls == CLS_ANY else 0)
    p.join(31)
    p.write(a.out, mesh, hops)
    print('hint: %d tasks of %d blocks, cls %d, hint %d' % (a.tasks, a.blocks, a.cls, a.hint))


# --------------------------------------------------------------------------------------------- chain
def gen_chain(a):
    """Chains of three kernels over one matrix each: tensor engines, vector units, tensor engines.

    Block b of a stage needs block b of the stage before. A task can only wait for a whole task, so a chain of
    --blocks blocks is cut into --cut chains of blocks/cut blocks (see scripts/chain_prog.py, which writes the
    same program for the cluster hardware). With --follow 1 the stages are chained instead (the chain flag): the
    scheduler releases the k-th block of a stage when k blocks of the stage before are done.
    """
    mesh = Mesh(2 * a.side, 4)
    hops = hop_values(mesh)
    p = Program()
    far = lambda d: [d if h == hops[0] else int(d * 1.05) for h in hops]
    dt, ds = far(a.tdur), far(a.sdur)
    per = a.blocks // a.cut
    assert a.blocks % a.cut == 0
    for i in range(a.tasks):
        h = 1 + i
        p.load(h, a.blocks * 512)
        prev = [None] * a.cut
        order = [(c, s) for c in range(a.cut) for s in range(3)] if a.order == 'chain' else \
                [(c, s) for s in range(3) for c in range(a.cut)]
        if a.order == 'stage':
            assert 3 * a.cut * a.tasks <= 20, 'not enough handle registers for this cut in stage order'
        for c, s in order:
            hd = (20 + s) if a.order == 'chain' else (10 + 3 * (i * a.cut + c) + s)
            data = h if (s == 0 or a.home) else None
            prev[c] = p.run(CLS_V if s == 1 else CLS_T, per, dt, ds, hs1=data, hd=hd,
                            hs2=None if s == 0 else hd - 1, dep=-1 if s == 0 else prev[c], chain=bool(a.follow))
        p.free(h)
    p.join(31)
    p.write(a.out, mesh, hops)
    print('chain: %d matrices, %d blocks each, cut into %d chains, %s order' % (a.tasks, a.blocks, a.cut, a.order))


# --------------------------------------------------------------------------------------------- moe
def gen_moe(a):
    import numpy as np
    import decode_run as dr
    import step4_run as s4
    from sysmodel import Trace, simulate2
    from sysmodel.config import HW, HIER_HW, qwen36
    from sysmodel.sim2 import MeshSim
    from sysmodel.workload import LayerRouting

    wb, rate = dr.REGIMES[a.regime]
    model = replace(qwen36(a.context), weight_bytes=wb)
    system = s4.SYSTEMS[a.system]()
    system = replace(system, l2_port_bytes_per_cycle=system.l2_port_bytes_per_cycle * rate)
    sc = HW.but(hier=HIER_HW, region_groups=4, overlap=False, pass_min_frac=1.0, min_block_cycles=float(a.block),
                vec_max_tokens=a.vec, cross_region=not a.bound, slots_per_region=float(a.slots))
    layer_ids = [int(x) for x in a.layers.split(',')]
    if a.synthetic:
        rng = np.random.RandomState(a.seed)
        w = 1.0 / np.arange(1, model.experts + 1) ** 0.8
        ids = np.stack([rng.choice(model.experts, size=model.top_k, replace=False, p=w / w.sum()) for _ in range(a.n)])
        ids = np.concatenate([ids, np.full((a.n, model.shared_experts), model.experts)], axis=1)
        layers = [LayerRouting(ids.astype(np.int64), model.experts + model.shared_experts) for _ in layer_ids]
    else:
        tr = Trace(a.trace or s4.TRACE, model.experts)
        layers = tr.rows(dr.positions(tr, a.kind, a.n, a.seed), layers=layer_ids, shared=model.shared_experts)

    sim = MeshSim(system, model, sc)
    mesh = sim.mesh
    hops = hop_values(mesh)
    names = [c.name for c in sim.cls]
    ct, cv = names.index('tensor'), names.index('vector')
    p = Program()

    def piece_tasks(kind, n, small, flops, nbytes, piece_bytes, hs2, need):
        k = max(1, int(math.ceil(nbytes / piece_bytes - 1e-9)))
        for _ in range(k):
            pf = flops / k
            c = sim.vec if small else sim.main
            T = pf / sim.rate[c] * sim.slow_in(c, n)
            kmax = sim.n_eng[c] if kind == 'x' else max(1, int(sim.n_eng[c] * sc.blocks_per_engine / k))
            nb = min(NBLK_MAX, max(1, min(kmax, int(math.ceil(T / sc.min_block_cycles)))))
            dur = [[max(1, int(math.ceil(pf / nb / sim.rate[ci] * slow_factor(sim.cls[ci], system, n, h)))) for h in hops] for ci in (ct, cv)]
            p.load(1, nbytes / k)
            # The hint a program would give: how much longer a block takes on a vector unit, as a power of two.
            vs = min(3, max(0, int(round(math.log2(dur[1][0] / dur[0][0]))))) if (small and a.vslow) else 0
            p.run(CLS_ANY if small else CLS_T, nb, dur[0], dur[1], hs1=1, follow=True, kill=True, hs2=hs2, need=need, vslow=vs)

    prev = None                                   # the join that ends the previous layer
    for routing in layers:
        M = routing.tokens
        free = system.spm_bytes - M * model.act_bytes_per_token
        piece_bytes = min(model.expert_bytes, free / mesh.R / sc.slots_per_region)
        small = lambda n: sim.vec >= 0 and n <= sc.vec_max_tokens
        ex = sorted(((len(t), e) for e, t in routing.lists().items()), key=lambda x: (-x[0], x[1]))
        base = len(p.tasks)
        for n, _ in ex:
            piece_tasks('x', n, small(n), n * model.expert_flop_per_token, model.expert_bytes, piece_bytes, prev, base)
        p.join(2)
        need = len(p.tasks)
        piece_tasks('in', M, small(M), M * model.mixer_phi * model.mixer_flop_per_token,
                    model.mixer_in_expert_eq * model.expert_bytes, piece_bytes, 2, need)
        p.join(3)
        need = len(p.tasks)
        piece_tasks('out', M, small(M), M * (1.0 - model.mixer_phi) * model.mixer_flop_per_token,
                    model.mixer_out_expert_eq * model.expert_bytes, piece_bytes, 3, need)
        p.join(4)
        prev = 4
    p.write(a.out, mesh, hops)

    class Probe(MeshSim):
        """The model run, with the cycle at which each phase of a layer ends."""
        phases = []

        def on_block_done(self, c, g, b):
            super().on_block_done(c, g, b)
            ph = self.__dict__.setdefault('ph', {})
            if ph.get('layer') != self.li:
                ph.clear()
                ph['layer'] = self.li
            if 'experts' not in ph and self.xdone == len(self.experts):
                ph['experts'] = self.t
                Probe.phases.append(('experts', self.li, round(self.t)))
            if 'mixer_in' not in ph and self.out_started:
                ph['mixer_in'] = self.t
                Probe.phases.append(('mixer_in', self.li, round(self.t)))

    r = Probe(system, model, sc).run(layers)
    json.dump(dict(cycles=r.cycles, phases=Probe.phases, per_layer=r.per_layer, pieces=r.pieces_per_layer, blocks=r.blocks_per_layer,
                   stream_util=r.stream_util, busy=r.busy, work_share=r.work_share, mean_hops=r.mean_hops,
                   block_delay=r.block_delay, stream_delay=r.stream_delay, window=r.window,
                   args=vars(a), lane_bpc100=int(round(system.l2_port_bytes_per_cycle * system.l2_efficiency * 100))),
              open(os.path.join(a.out, 'model.json'), 'w'), indent=1)
    print('moe: %d layers, %d instructions, %d run tasks; model %.0f cycles, phases %s' % (len(layers), len(p.instr), len(p.tasks), r.cycles, Probe.phases))


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=('random', 'moe', 'hint', 'chain'))
    ap.add_argument('out')
    ap.add_argument('--side', type=int, default=4, help='domains per side (random)')
    ap.add_argument('--seed', type=int, default=11)
    ap.add_argument('--pieces', type=int, default=200)
    ap.add_argument('--slots', type=int, default=2, help='L1 slots per domain')
    ap.add_argument('--system', default='teramonster')
    ap.add_argument('--kind', default='midfill')
    ap.add_argument('--n', type=int, default=64)
    ap.add_argument('--regime', default='x1')
    ap.add_argument('--layers', default='9')
    ap.add_argument('--context', type=int, default=2048)
    ap.add_argument('--block', type=float, default=500.0, help='shortest block in cycles')
    ap.add_argument('--vec', type=int, default=8, help='tasks with at most this many tokens may run on vector units')
    ap.add_argument('--bound', action='store_true', help='model: blocks only run in the domain that holds their weights')
    ap.add_argument('--trace', default=None)
    ap.add_argument('--synthetic', action='store_true', help='draw the routing from a Zipf law instead of the trace')
    ap.add_argument('--vslow', action='store_true', help='moe: give the tasks for both PE types their speed hint')
    ap.add_argument('--blocks', type=int, default=128, help='hint: blocks of a task')
    ap.add_argument('--tasks', type=int, default=1, help='hint: tasks, each with its own load')
    ap.add_argument('--cls', type=int, default=3, help='hint: PE types of the tasks (1 tensor, 2 vector, 3 both)')
    ap.add_argument('--hint', type=int, default=2, help='hint: speed hint of the tasks (cls 3)')
    ap.add_argument('--tdur', type=int, default=860, help='hint: cycles of a block on a tensor engine')
    ap.add_argument('--vdur', type=int, default=3500, help='hint: cycles of a block on a vector unit')
    ap.add_argument('--sdur', type=int, default=2760, help='chain: cycles of a block of the vector stage')
    ap.add_argument('--cut', type=int, default=1, help='chain: chains of tasks the matrix is cut into')
    ap.add_argument('--order', default='chain', choices=('chain', 'stage'), help='chain: program order of the tasks')
    ap.add_argument('--home', type=int, default=0, help='chain: 1 issues every stage to the domain of the load')
    ap.add_argument('--follow', type=int, default=0, help='chain: 1 sets the chain flag of stages 2 and 3')
    a = ap.parse_args()
    {'random': gen_random, 'moe': gen_moe, 'hint': gen_hint, 'chain': gen_chain}[a.mode](a)
