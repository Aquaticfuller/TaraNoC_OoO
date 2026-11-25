"""Regression: the discrete model against the fluid model on the same routing sample.

usage: python3 scripts/regress_fluid.py [ref/fluid_ref.json] [../moe_study/model/overlap_embed.json]
The two models share policy and parameters; they differ in that this one runs whole blocks on single engines.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from sysmodel import ModelConfig, SchedConfig, embedded_sample, mergecast, simulate, teramonster

here = os.path.dirname(os.path.abspath(__file__))
ref = json.load(open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, '..', 'ref', 'fluid_ref.json')))
sample = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, '..', '..', 'moe_study', 'model', 'overlap_embed.json')
systems = {'teramonster': teramonster(), 'mergecast': mergecast()}
model = ModelConfig()
worst, t0 = 0.0, time.time()
print('%-11s %5s %-4s %-7s %5s | %10s %10s %6s | util stream/compute fluid -> discrete | blocks' % ('system', 'M', 'ord', 'overlap', 'delay', 'fluid', 'discrete', 'ratio'))
for r in ref:
    layers = embedded_sample(sample, r['M'])
    if r['cluster'] == 'mergecast' and r['M'] > 256:
        continue
    sc = SchedConfig(policy='hw', block_delay=0.0, min_block_cycles=500.0, stream_delay=float(r['gap']), order=r['order'], overlap=r['overlap'],
                     pass_min_frac=max(1, round(r['M'] / 4)) / r['M'])
    res = simulate(systems[r['cluster']], model, sc, layers)
    ratio = res.per_layer / r['per_layer']
    worst = max(worst, abs(ratio - 1))
    print('%-11s %5d %-4s %-7s %5d | %9.0fk %9.0fk %6.3f |   %3.0f%%/%3.0f%% -> %3.0f%%/%3.0f%%   | %6.0f' % (
        r['cluster'], r['M'], r['order'], 'yes' if r['overlap'] else 'no', r['gap'], r['per_layer'] / 1e3, res.per_layer / 1e3, ratio,
        100 * r['stream_util'], 100 * r['compute_util'], 100 * res.stream_util, 100 * res.compute_util, res.blocks_per_layer))
print('largest deviation from the fluid model: %.1f%%   (%.0f s)' % (100 * worst, time.time() - t0))
