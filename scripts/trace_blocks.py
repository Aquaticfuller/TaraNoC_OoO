#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Blocks of one or several kernels from a harness trace (simulation argument +TRACE), as JSON.

usage: trace_blocks.py <transcript or trace file> [--kernel 1[,9,10]] [--side 2]
       side: scheduling domains per side of the build (the groups of the trace are numbered row by row)
Prints {"t0": cycle of the first start, "span": cycles from the first start to the last end,
        "blocks": [[start - t0, end - t0, class (0 tensor, 1 vector), domain the block ran in, home domain,
                    group, PE in the group, index of the block, kernel, argument of the task], ...]}
       The index is that of the block in its task; a matrix task of the PE agent names the blocks before its first
       one in bits 23:8 of the argument (0 in traces written before the argument was printed).
"""
import argparse
import json
import re

ap = argparse.ArgumentParser()
ap.add_argument('trace')
ap.add_argument('--kernel', default='1')
ap.add_argument('--side', type=int, default=2)
a = ap.parse_args()
kernels = {int(k) for k in a.kernel.split(',')}

start = re.compile(r'\[tsched\] T (\d+) start (tensor|vector) group (\d+) pe (\d+) kernel (\d+) block (\d+) of (\d+) domain \d+ data (\d+)(?: arg (\d+))?')
done = re.compile(r'\[tsched\] T (\d+) done (tensor|vector) group (\d+) pe (\d+)')
run, blocks = {}, []


def dom_of_group(g):
    return ((g // (2 * a.side)) // 2) * a.side + (g % (2 * a.side)) // 2


for line in open(a.trace, errors='replace'):
    m = start.search(line)
    if m:
        t, c, g, p, k, b, n, d, arg = m.groups()
        run[(c, int(g), int(p))] = (int(t), int(k), int(d), int(b), int(arg or 0))
        continue
    m = done.search(line)
    if m:
        t, c, g, p = m.groups()
        s = run.pop((c, int(g), int(p)), None)
        if s and s[1] in kernels:
            blocks.append([s[0], int(t), 0 if c == 'tensor' else 1, dom_of_group(int(g)), s[2], int(g), int(p), s[3], s[1], s[4]])
t0 = min(b[0] for b in blocks)
blocks.sort()
print(json.dumps({'t0': t0, 'span': max(b[1] for b in blocks) - t0,
                  'blocks': [[b[0] - t0, b[1] - t0] + b[2:] for b in blocks]}))
