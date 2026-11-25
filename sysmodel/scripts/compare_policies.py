"""Step-1 comparison of scheduling schemes on the embedded routing sample (two layers of one traced request).

usage: python3 scripts/compare_policies.py [json_out]
For every scheme the block size (min_block_cycles) is swept and the best is kept, because the right
granularity differs with the dispatch delay.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from sysmodel import HW, PLAN, STATIC, ModelConfig, embedded_sample, mergecast, simulate, teramonster

here = os.path.dirname(os.path.abspath(__file__))
sample = os.path.join(here, '..', '..', 'moe_study', 'model', 'overlap_embed.json')
model = ModelConfig()
BLOCKS = (500.0, 1000.0, 2000.0, 5000.0, 10000.0, 20000.0, 50000.0)


def best(system, layers, variants):
    out = None
    for sc in variants:
        r = simulate(system, model, sc, layers)
        if out is None or r.per_layer < out[0].per_layer:
            out = (r, sc)
    return out


def schemes():
    yield 'static dense', [STATIC]
    yield 'software plan', [PLAN.but(order=o, min_block_cycles=b) for o in ('hot', 'mix') for b in BLOCKS[2:]]
    yield 'pull, software delays', [HW.but(block_delay=1000.0, stream_delay=1000.0, order=o, pass_min_frac=p, min_block_cycles=b)
                                    for o in ('hot', 'mix') for p in (0.25, 0.5) for b in BLOCKS[2:]]
    yield 'pull, hardware delays', [HW.but(order=o, pass_min_frac=p, min_block_cycles=b)
                                    for o in ('hot', 'mix') for p in (0.25, 0.5) for b in BLOCKS[:5]]


rows, t0 = [], time.time()
for system, Ms in ((teramonster(), (1, 16, 64, 256, 1024)), (mergecast(), (1, 16, 64, 256))):
    print('\n=== %s: %d %s engines, %.0f FLOP/cycle, %.0f B/cycle from L2' % (
        system.name, system.n_engines(system.gemm_class), system.gemm_class, system.flop_per_cycle(system.gemm_class), system.l2_bytes_per_cycle))
    print('     M | scheme                  cycles/layer  vs hw | stream  compute  dispatch | best block  blocks/layer  of bound')
    for M in Ms:
        layers = embedded_sample(sample, M)
        res = {name: best(system, layers, v) for name, v in schemes()}
        hw = res['pull, hardware delays'][0].per_layer
        for name, (r, sc) in res.items():
            print('  %4d | %-22s %10.0fk  %5.2fx |  %3.0f%%    %3.0f%%     %4.1f%%  | %7.0f cyc  %10.0f   %5.0f%%' % (
                M, name, r.per_layer / 1e3, r.per_layer / hw, 100 * r.stream_util, 100 * r.compute_util, 100 * r.delay_share,
                sc.min_block_cycles, r.blocks_per_layer, 100 * r.bound_per_layer / r.per_layer))
            rows.append(dict(system=system.name, M=M, scheme=name, per_layer=r.per_layer, vs_hw=r.per_layer / hw, stream_util=r.stream_util,
                             compute_util=r.compute_util, delay_share=r.delay_share, block=sc.min_block_cycles, order=sc.order,
                             blocks=r.blocks_per_layer, bound=r.bound_per_layer))
        print()
print('%.0f s' % (time.time() - t0))
if len(sys.argv) > 1:
    json.dump(rows, open(sys.argv[1], 'w'))
