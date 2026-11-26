#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Per step of the layer (kernel 12 of the PE agent): blocks, first start, last end and block times from a trace.

usage: layer_times.py <trace file> [--side 1]
Prints one line per step and, last, the mean block times as a list for gen_program.py layer --durs.
"""
import argparse
import json
import os
import subprocess
import sys

NAMES = ['norm1', 'qkv', 'pack', 'score', 'softmax', 'pv', 'wo', 'norm2', 'gu', 'silu', 'wd']
ap = argparse.ArgumentParser()
ap.add_argument('trace')
ap.add_argument('--side', type=int, default=1)
a = ap.parse_args()
out = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'trace_blocks.py'), a.trace, '--kernel', '12',
                      '--side', str(a.side)], stdout=subprocess.PIPE, universal_newlines=True, check=True).stdout
d = json.loads(out)
durs = []
print('span %d cycles' % d['span'])
for s, name in enumerate(NAMES):
    v = [b for b in d['blocks'] if (b[9] >> 8) & 0xf == s]
    if not v:
        continue
    t = sorted(b[1] - b[0] for b in v)
    durs.append(sum(t) // len(t))
    print('%2d %-8s %3d blocks  start %6d  end %6d  block min %5d mean %5d max %5d  domains %s' % (
        s, name, len(v), min(b[0] for b in v), max(b[1] for b in v), t[0], durs[-1], t[-1], sorted(set(b[3] for b in v))))
print('--durs ' + ','.join(map(str, durs)))
