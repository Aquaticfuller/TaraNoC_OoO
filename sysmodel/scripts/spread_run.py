#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Over how many groups should one piece of weights be spread in L1?

Every piece (what one TLoad brings) is interleaved over an aligned square of `spread` mesh groups: 1, 4, 16 or all
64. The spread sets how many DMA engines and stream lanes copy the piece (one per group, at most all 32 lanes) and
how far the PEs that compute on it are from it. Scheduling is left free on purpose (an idle PE takes the nearest
ready block from anywhere), so that the result shows the effect of the data layout alone; `bound` (a block runs only
in the region of its weights) is the other extreme.

A second question: with the spread kept at 4 groups, does cutting the weights into smaller pieces do the same?
A piece is at most 1/`slots` of the L1 of its region (2 in the rest of the study); more slots give more, smaller
pieces, each still copied by the 4 engines of its region, so more of them stream at the same time.

The six workloads and all other settings are those of scripts/balance_run.py (plus decode with 16-bit weights).

usage: python3 -I sysmodel/scripts/spread_run.py <json_out> [processes]
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

CASES = ['decode:1:x4', 'decode:1:x1', 'sessions:16:x4', 'midfill:64:x4', 'midfill:64:x1', 'midfill:256:x1', 'midfill:1024:x1']
LAYERS = (9, 3, 30)
SEEDS = (11, 21)
SPREADS = (1, 4, 16, 64)
POLICIES = ('free', 'bound')
SLOTS = (2.0, 4.0, 8.0, 16.0, 32.0)      # pieces per region, for the spread of 4


def run(job):
    case, layer, seed, spread, policy, slots, pos = job
    kind, n, regime = case.split(':')
    wb, rate = dr.REGIMES[regime]
    model = replace(qwen36(2048), weight_bytes=wb)
    system = s4.SYSTEMS['teramonster']()
    system = replace(system, l2_port_bytes_per_cycle=system.l2_port_bytes_per_cycle * rate)
    sc = HW.but(hier=HIER_HW, region_groups=spread, overlap=False, pass_min_frac=1.0, min_block_cycles=500.0, vec_max_tokens=8,
                cross_region=policy == 'free', slots_per_region=slots)
    tr = Trace(s4.TRACE, model.experts)
    layers = tr.rows(pos, layers=[layer], shared=model.shared_experts)
    sim = MeshSim(system, model, sc)
    r = sim.run(layers)
    return dict(case=case, layer=layer, seed=seed, spread=spread, policy=policy, slots=slots, cycles=r.cycles, mean_hops=r.mean_hops,
                stream_util=r.stream_util, busy=r.busy, pieces=r.pieces_per_layer, piece_bytes=sim.piece_bytes,
                piece_lanes=sim.piece_lanes, stream_delay=r.stream_delay)


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
                for spread in SPREADS:
                    for policy in POLICIES:
                        jobs.append((case, layer, seed, spread, policy, 2.0, pos))
                for slots in SLOTS[1:]:
                    jobs.append((case, layer, seed, 4, 'free', slots, pos))
    jobs.sort(key=lambda j: -int(j[0].split(':')[1]))
    with Pool(procs) as pool:
        rows = pool.map(run, jobs, chunksize=1)
    json.dump(rows, open(out, 'w'), indent=1)
    agg = {}
    small = {}
    for r in rows:
        if r['slots'] == 2.0:
            agg.setdefault((r['case'], r['spread'], r['policy']), []).append(r)
        if r['spread'] == 4 and r['policy'] == 'free':
            small.setdefault((r['case'], r['slots']), []).append(r)
    mean = lambda rs, k: sum(r[k] for r in rs) / len(rs)
    for policy in POLICIES:
        print('time per layer relative to a spread of 4 groups (%s), mean of %d layers x %d token sets' % (policy, len(LAYERS), len(SEEDS)))
        print('%-18s' % 'case' + ''.join('%10d' % s for s in SPREADS) + '   cycles at 4')
        for case in CASES:
            ref = agg[(case, 4, policy)]
            print('%-18s' % case + ''.join('%10.3f' % (sum(a['cycles'] / b['cycles'] for a, b in zip(agg[(case, s, policy)], ref)) / len(ref))
                                           for s in SPREADS) + '%14.0f' % mean(ref, 'cycles'))
    for key, title, fmt in (('stream_util', 'share of the lane time in use (free)', '%10.2f'), ('mean_hops', 'mean hops between a PE and its weights (free)', '%10.2f'),
                            ('pieces', 'pieces per layer (free)', '%10.0f'), ('piece_bytes', 'bytes of a piece (free)', '%10.0f'),
                            ('piece_lanes', 'lanes of a piece (free)', '%10.0f')):
        print(title)
        for case in CASES:
            print('%-18s' % case + ''.join(fmt % mean(agg[(case, s, 'free')], key) for s in SPREADS))
    print('share of tensor-engine time in use (free)')
    for case in CASES:
        print('%-18s' % case + ''.join('%10.2f' % (sum(list(r['busy'].values())[0] for r in agg[(case, s, 'free')]) / len(agg[(case, s, 'free')])) for s in SPREADS))
    print('spread of 4 groups, smaller pieces: time per layer relative to 2 pieces per region (free)')
    print('%-18s' % 'pieces per region' + ''.join('%10d' % x for x in SLOTS) + '   best spread above')
    for case in CASES:
        ref = small[(case, 2.0)]
        best = min(sum(a['cycles'] / b['cycles'] for a, b in zip(agg[(case, sp, 'free')], ref)) / len(ref) for sp in SPREADS)
        print('%-18s' % case + ''.join('%10.3f' % (sum(a['cycles'] / b['cycles'] for a, b in zip(small[(case, x)], ref)) / len(ref)) for x in SLOTS) + '%14.3f' % best)
    for key, title, fmt in (('stream_util', 'share of the lane time in use', '%10.2f'), ('pieces', 'pieces per layer', '%10.0f'), ('mean_hops', 'mean hops between a PE and its weights', '%10.2f')):
        print(title)
        for case in CASES:
            print('%-18s' % case + ''.join(fmt % mean(small[(case, x)], key) for x in SLOTS))
