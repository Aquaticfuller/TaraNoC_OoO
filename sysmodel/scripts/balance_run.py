#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Who balances the work between scheduling domains: the domains among themselves, or the cluster level.

A task runs where its weights were loaded. When one domain has more ready blocks than idle PEs and another has
idle PEs, the blocks can move in different ways. L1 is shared in every variant: a PE reads the weights from the
domain that holds them, at the speed the distance allows.

  bound        no balancing: a block only runs in the domain that holds its weights
  any          an idle PE takes the nearest ready block of any domain (the reference of the system model)
  nb <h>       lending between domains: as `any`, but only between domains at most h steps apart on the 4 x 4
               domain mesh (h = 1 is what the RTL does)
  central      the cluster level balances: a domain with idle PEs and nothing to run is noticed by the cluster
               level, which `delay` cycles later takes a range of ready blocks from another domain at most
               `reach` steps away (the nearest one with a backlog, or the one with the largest backlog) and
               hands it to the idle domain. The range has `grain` blocks per idle PE; blocks that find no idle
               PE wait in the receiving domain and cannot move again.

The six workloads and all other settings are those of scripts/run_cases.py (one MoE layer, 2 slots per domain).

usage: python3 -I sysmodel/scripts/balance_run.py <json_out> [processes]
"""
import json
import os
import sys
from dataclasses import replace
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..'))
import decode_run as dr
import step4_run as s4
from sysmodel import Trace
from sysmodel.config import HW, HIER_HW, qwen36
from sysmodel.sim2 import MeshSim

CASES = ['decode:1:x4', 'sessions:16:x4', 'midfill:64:x4', 'midfill:64:x1', 'midfill:256:x1', 'midfill:1024:x1']
LAYERS = (9, 3, 30)
SEEDS = (11, 21)
VARIANTS = [
    ('bound', dict(policy='bound')),
    ('any', dict(policy='any')),
    ('nb 1', dict(policy='nb', reach=1)),
    ('nb 2', dict(policy='nb', reach=2)),
    ('cen r1 d16', dict(policy='central', reach=1, delay=16.0)),
    ('cen r2 d16', dict(policy='central', reach=2, delay=16.0)),
    ('cen r2 d64', dict(policy='central', reach=2, delay=64.0)),
    ('cen r2 d256', dict(policy='central', reach=2, delay=256.0)),
    ('cen r2 d16 g2', dict(policy='central', reach=2, delay=16.0, grain=2.0)),
    ('cen r2 most', dict(policy='central', reach=2, delay=16.0, donor='most')),
    ('cen any d16', dict(policy='central', reach=99, delay=16.0)),
    ('cen any most', dict(policy='central', reach=99, delay=16.0, donor='most')),
]


class BalSim(MeshSim):
    policy, reach, delay, grain, donor = 'any', 99, 16.0, 1.0, 'near'

    def __init__(self, system, model, sched):
        super().__init__(system, model, sched)
        s = int(round(self.R ** 0.5))
        self.rdist = [[abs(a % s - b % s) + abs(a // s - b // s) for b in range(self.R)] for a in range(self.R)]
        self.req = set()
        self.n_handout = self.n_moved = self.n_parked = 0

    # ------------------------------------------------------------ lending with a reach
    def on_ready(self, b):
        if self.policy == 'central' and b.group < 0:
            job, home = b.piece.job, b.piece.exec
            if job.small and self.idle_tot[self.vec] and not any(self.idle[self.vec][g] for g in self.mesh.members[home]):
                # A block that vector units can run does not take a tensor engine at home while a vector unit
                # within reach is idle (the same preference the lending variants have): it waits for the hand-out.
                rd = self.rdist[home]
                if any(rd[self.mesh.region_of[g]] <= self.reach for g in self.idle_groups[self.vec]):
                    p = (0 if job.kind == 'x' else 2) + 1
                    self.rq[p][home].append(b)
                    self.ne[p].add(home)
                    self._central_kick()
                    return
        if self.policy != 'nb' or b.group >= 0:
            super().on_ready(b)
            if self.policy == 'central':
                self._central_kick()
            return
        job = b.piece.job
        r, home = b.piece.region, b.piece.exec
        hop, reg, rd = self.mesh.hop, self.mesh.region_of, self.rdist[home]
        for c in ((self.vec, self.main) if job.small else (self.main,)):
            if self.idle_tot[c]:
                cand = [g for g in self.idle_groups[c] if rd[reg[g]] <= self.reach]
                if not cand:
                    continue
                self._start(c, min(cand, key=lambda g: (hop[g][r], g)), b)
                return
        p = (0 if job.kind == 'x' else 2) + (1 if job.small else 0)
        self.rq[p][home].append(b)
        self.ne[p].add(home)

    def _feed(self, c, g):
        if self.policy != 'nb':
            super()._feed(c, g)
            if self.policy == 'central':
                self._central_kick()
            return
        idle = self.idle[c]
        pq = self.pq[c][g]
        hop, rd = self.mesh.hop[g], self.rdist[self.mesh.region_of[g]]
        while idle[g]:
            if pq:
                self._start(c, g, pq.popleft())
                continue
            b = None
            for p in self.take[c]:
                cand = [r for r in self.ne[p] if rd[r] <= self.reach]
                if not cand:
                    continue
                r = min(cand, key=lambda r: (hop[r], r))
                dq = self.rq[p][r]
                b = dq.popleft()
                if not dq:
                    self.ne[p].discard(r)
                break
            if b is None:
                return
            self._start(c, g, b)

    # ------------------------------------------------------------ balancing by the cluster level
    def _central_kick(self):
        for c in range(self.nc):
            take = self.take[c]
            if not take or not self.idle_tot[c] or not any(self.ne[p] for p in take):
                continue
            for r in {self.mesh.region_of[g] for g in self.idle_groups[c]}:
                if (r, c) in self.req:
                    continue
                if any(r2 != r and self.rdist[r][r2] <= self.reach for p in take for r2 in self.ne[p]):
                    self.req.add((r, c))
                    self.at(self.t + self.delay, self._handout, r, c)

    def _handout(self, r, c):
        self.req.discard((r, c))
        groups = [g for g in self.mesh.members[r] if self.idle[c][g]]
        n_idle = sum(self.idle[c][g] for g in groups)
        if not n_idle:
            return
        k = max(1, int(round(n_idle * self.grain)))
        moved = []
        for p in self.take[c]:
            while len(moved) < k:
                cand = [r2 for r2 in self.ne[p] if r2 != r and self.rdist[r][r2] <= self.reach]
                if not cand:
                    break
                if self.donor == 'most':
                    d = max(cand, key=lambda r2: (len(self.rq[p][r2]), -self.rdist[r][r2], -r2))
                else:
                    d = min(cand, key=lambda r2: (self.rdist[r][r2], -len(self.rq[p][r2]), r2))
                dq = self.rq[p][d]
                for _ in range(min(k - len(moved), len(dq))):
                    moved.append(dq.popleft())
                if not dq:
                    self.ne[p].discard(d)
            if len(moved) >= k:
                break
        if not moved:
            return
        self.n_handout += 1
        self.n_moved += len(moved)
        mem = self.mesh.members[r]
        i = 0
        for b in moved:
            g = next((g for g in mem if self.idle[c][g]), None)
            if g is not None:
                b.group, b.cls = g, c           # handed over by the cluster level: an ordinary local dispatch
                self._start(c, g, b)
            else:
                g = mem[i % len(mem)]
                i += 1
                b.group, b.cls = g, c
                self.pq[c][g].append(b)
                self.n_parked += 1
        self._central_kick()


def run(job):
    case, layer, seed, name, kw, pos = job
    kind, n, regime = case.split(':')
    wb, rate = dr.REGIMES[regime]
    model = replace(qwen36(2048), weight_bytes=wb)
    system = s4.SYSTEMS['teramonster']()
    system = replace(system, l2_port_bytes_per_cycle=system.l2_port_bytes_per_cycle * rate)
    sc = HW.but(hier=HIER_HW, region_groups=4, overlap=False, pass_min_frac=1.0, min_block_cycles=500.0, vec_max_tokens=8,
                cross_region=kw['policy'] in ('any', 'nb'), slots_per_region=2.0)
    tr = Trace(s4.TRACE, model.experts)
    layers = tr.rows(pos, layers=[layer], shared=model.shared_experts)
    sim = type('Sim', (BalSim,), kw)(system, model, sc)
    r = sim.run(layers)
    return dict(case=case, layer=layer, seed=seed, variant=name, cycles=r.cycles, mean_hops=r.mean_hops, busy=r.busy,
                handouts=sim.n_handout, moved=sim.n_moved, parked=sim.n_parked, blocks=r.blocks_per_layer)


if __name__ == '__main__':
    out = sys.argv[1]
    procs = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    tr = Trace(s4.TRACE, 256)
    jobs = []
    for case in CASES:
        kind, n, _ = case.split(':')
        for seed in SEEDS:
            pos = dr.positions(tr, kind, int(n), seed)
            for layer in LAYERS:
                for name, kw in VARIANTS + [('check: nb 99', dict(policy='nb', reach=99))]:
                    jobs.append((case, layer, seed, name, kw, pos))
    jobs.sort(key=lambda j: -int(j[0].split(':')[1]))
    with Pool(procs) as pool:
        rows = pool.map(run, jobs, chunksize=1)
    json.dump(rows, open(out, 'w'), indent=1)
    agg = {}
    for r in rows:
        agg.setdefault((r['case'], r['variant']), []).append(r)
    bad = [k for k in agg if k[1] == 'check: nb 99' and any(abs(a['cycles'] - b['cycles']) > 0.5 for a, b in zip(agg[k], agg[(k[0], 'any')]))]
    print('self-check (lending with unlimited reach equals `any`):', 'FAILED %s' % bad if bad else 'ok')
    names = [n for n, _ in VARIANTS]
    print('time per layer relative to `any`, mean of %d layers x %d token sets' % (len(LAYERS), len(SEEDS)))
    print('%-18s' % 'case' + ''.join('%17s' % n for n in names))
    for case in CASES:
        ref = agg[(case, 'any')]
        line = '%-18s' % case
        for n in names:
            rs = agg[(case, n)]
            line += '%17.3f' % (sum(a['cycles'] / b['cycles'] for a, b in zip(rs, ref)) / len(rs))
        print(line)
    print('worst single run relative to `any`')
    for case in CASES:
        ref = agg[(case, 'any')]
        print('%-18s' % case + ''.join('%17.3f' % max(a['cycles'] / b['cycles'] for a, b in zip(agg[(case, n)], ref)) for n in names))
    print('mean hops between a PE and its weights')
    for case in CASES:
        print('%-18s' % case + ''.join('%17.2f' % (sum(a['mean_hops'] for a in agg[(case, n)]) / len(agg[(case, n)])) for n in names))
