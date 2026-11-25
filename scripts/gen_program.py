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
             op: 0 TLoad, 1 TRun, 2 TJoin, 3 TFree; cls: bit 0 tensor engines, bit 1 vector units;
             arg of a TRun is its task index
  tasks.txt  first line: number of run tasks; then per task
             index cls nblk follow need dep  T[0..H-1] V[0..H-1]
             need: tasks 0..need-1 must be done before the task starts; dep: one task that must be done, or -1
             T, V: cycles of one block on a tensor engine / vector unit at each of the H distances
  hop.txt    first line: groups domains H; then per group, the distance index to each domain
  model.json (moe) what the system model predicts for the same layers

usage
  gen_program.py random <out_dir> [--side 4] [--seed 1] [--pieces 200] [--slots 4]
  gen_program.py moe <out_dir> --kind midfill --n 64 [--regime x1] [--layers 1] [--block 500] [--vec 8]
                 [--seed 11] [--trace <dir>] [--synthetic]
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
CHUNK = 32          # GroupsPerDomain * ChunksPerGroup: a load is a multiple of this


class Program:
    def __init__(self):
        self.instr, self.tasks, self.addr = [], [], 0x1000

    def load(self, hd, nbytes):
        nbytes = max(CHUNK, int(math.ceil(nbytes / CHUNK)) * CHUNK)
        assert nbytes < (1 << 24), 'a load must fit the 24-bit length field'
        self.instr.append((LOAD, 1, hd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, nbytes, self.addr))
        self.addr += nbytes

    def run(self, cls, nblk, dur_t, dur_v, hs1=None, follow=False, kill=False, hs2=None, hd=None, need=0, dep=-1):
        t = len(self.tasks)
        assert 1 <= nblk <= 255
        self.tasks.append((t, cls, nblk, int(bool(follow and hs1 is not None)), need, dep, dur_t, dur_v))
        self.instr.append((RUN, int(hd is not None), hd or 0, int(hs1 is not None), hs1 or 0, int(follow), int(kill),
                           int(hs2 is not None), hs2 or 0, cls, nblk, 0, t, 0, 0))
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
            hd = None
            if rng.random() < 0.3:
                hd = rng.randrange(16, 24)
                joins.pop(hd, None)
            t = p.run(rng.choice((CLS_T, CLS_V, CLS_ANY, CLS_ANY)), rng.choice((1, 1, 2, 3, 5, 8, 13, 40)), dur(), dur(), hd=hd, **kw)
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
            nb = min(255, max(1, min(kmax, int(math.ceil(T / sc.min_block_cycles)))))
            dur = [[max(1, int(math.ceil(pf / nb / sim.rate[ci] * slow_factor(sim.cls[ci], system, n, h)))) for h in hops] for ci in (ct, cv)]
            p.load(1, nbytes / k)
            p.run(CLS_ANY if small else CLS_T, nb, dur[0], dur[1], hs1=1, follow=True, kill=True, hs2=hs2, need=need)

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

    r = simulate2(system, model, sc, layers)
    json.dump(dict(cycles=r.cycles, per_layer=r.per_layer, pieces=r.pieces_per_layer, blocks=r.blocks_per_layer,
                   stream_util=r.stream_util, busy=r.busy, work_share=r.work_share, mean_hops=r.mean_hops,
                   block_delay=r.block_delay, stream_delay=r.stream_delay, window=r.window,
                   args=vars(a), lane_bpc100=int(round(system.l2_port_bytes_per_cycle * system.l2_efficiency * 100))),
              open(os.path.join(a.out, 'model.json'), 'w'), indent=1)
    print('moe: %d layers, %d instructions, %d run tasks; model %.0f cycles' % (len(layers), len(p.instr), len(p.tasks), r.cycles))


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=('random', 'moe'))
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
    a = ap.parse_args()
    (gen_random if a.mode == 'random' else gen_moe)(a)
