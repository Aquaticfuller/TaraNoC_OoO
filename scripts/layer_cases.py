#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""The transformer layer of gen_program.py layer on the scheduler alone: step after step against chained, for one
or several layers at a time. Prints the cycles of each case and writes them to a JSON file.

usage: layer_cases.py <out.json> --durs d0,...,d10 [--blocks 64] [--work <dir>]
       Cases: one domain (build `one`) with 1 layer; 2 x 2 domains (build `small`) with 1, 2 and 4 layers.
       Per case: step after step, chained, chained with the projections open to both PE types, and a lower bound.
       durs: cycles of one block of each step, from scripts/layer_times.py on a trace of the cluster hardware.
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(HERE, '..', 'sim')
TENSOR = (1, 3, 5, 6, 8, 10)        # steps on tensor engines

ap = argparse.ArgumentParser()
ap.add_argument('out')
ap.add_argument('--durs', required=True)
ap.add_argument('--blocks', type=int, default=64)
ap.add_argument('--work', default=os.path.join(SIM, 'prog', 'layer_cases'))
a = ap.parse_args()
durs = [int(x) for x in a.durs.split(',')]


def run(cfg, side, layers, follow, both=0):
    d = os.path.join(a.work, '%s_l%d_f%d_b%d' % (cfg, layers, follow, both))
    subprocess.run([sys.executable, '-I', os.path.join(HERE, 'gen_program.py'), 'layer', d, '--side', str(side), '--blocks', str(a.blocks),
                    '--tasks', str(layers), '--follow', str(follow), '--both', str(both), '--durs', a.durs], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['make', '-C', SIM, 'run', 'CFG=' + cfg, 'DEFS=+define+TSCHED_DOM_PER_SIDE=%d' % side, 'PROG=' + d],
                   stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    log = open(os.path.join(d, 'sim_%s.log' % cfg), errors='replace').read()
    m = re.search(r'RESULT cycles=(\d+) instructions=\d+ tasks=\d+ tasks_done=\d+ errors=(\d+)', log)
    assert m and '[tb] PASS' in log and m.group(2) == '0', 'failed: ' + d
    return int(m.group(1))


res = dict(blocks=a.blocks, durs=durs, cases=[])
for cfg, side, layers in (('one', 1, 1), ('small', 2, 1), ('small', 2, 2), ('small', 2, 4)):
    dom = side * side
    # Shortest possible: the tensor engines never idle (16 per domain), or one block through all eleven steps.
    bound = max(layers * a.blocks * sum(durs[s] for s in TENSOR) // (16 * dom), sum(durs))
    # both: chained, and the projections may also run on vector units (4 times slower there, speed hint 2)
    c = dict(domains=dom, layers=layers, whole=run(cfg, side, layers, 0), chained=run(cfg, side, layers, 1),
             both=run(cfg, side, layers, 1, 1), bound=bound)
    res['cases'].append(c)
    print('%d domain(s), %d layer(s): step after step %6d, chained %6d (%.0f%% shorter), projections on both PE types %6d, bound %6d' % (
        dom, layers, c['whole'], c['chained'], 100 * (1 - c['chained'] / c['whole']), c['both'], bound), flush=True)
json.dump(res, open(a.out, 'w'), indent=1)
