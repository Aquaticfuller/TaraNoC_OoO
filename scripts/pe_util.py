#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""What the PEs did inside their blocks: the engine traces of a cluster run against the scheduler's block trace.

A block is "busy" for the scheduler from its start to its completion. The engine traces of TeraMonster's testbench
(build/<name>/redmule_profiling, spatz_profiling: one line per cycle an engine is active) say what the datapath did
in that time. Per cycle of a block, in this order of priority:

  tensor engine (RedMulE)   compute   the FMA array advances (scheduler.reg_enable_o)
                            wait W / X / Y   the array is stalled for an operand stream (a load from L1)
                            wait Z    stalled for the store of results
                            fill      active without computing or stalling (preload, drain)
                            off       the engine is not active: the core sets it up, waits for it, or passes the block on
  vector unit (Spatz)       compute   the vector FPU (VFU) is busy
                            memory    only the load/store unit or the slide unit is busy
                            stall     an instruction cannot issue
                            fill      instructions in flight, no unit busy
                            off       the vector engine is not active: scalar code of the kernel or of the loop

usage: pe_util.py <build dir> <trace file> [--kernel 12] [--offset n] [--json out.json]
       The trace must be that of the last run in the build directory (each run overwrites the engine traces).
       Steps are those of the layer kernel (argument bits 11:8); other kernels are one step.
"""
import argparse
import collections
import json
import os
import re

NAMES = ['norm1', 'qkv', 'pack', 'score', 'softmax', 'pv', 'wo', 'norm2', 'gu', 'silu', 'wd']
TB = ['compute', 'wait W', 'wait X', 'wait Y', 'wait Z', 'fill', 'off']
VB = ['compute', 'memory', 'stall', 'fill', 'off']
NUM_T, VEC_PER_TILE = 4, 3

ap = argparse.ArgumentParser()
ap.add_argument('build')
ap.add_argument('trace')
ap.add_argument('--kernel', type=int, default=12)
ap.add_argument('--offset', type=int, help='cycles the engine traces are ahead of the block trace (found from the traces if not given)')
ap.add_argument('--json')
a = ap.parse_args()

# ------------------------------------------------------------------ blocks of the kernel, from the scheduler's trace
start = re.compile(r'\[tsched\] T (\d+) start (tensor|vector) group (\d+) pe (\d+) kernel (\d+) block (\d+) of (\d+) domain \d+ data \d+(?: arg (\d+))?')
done = re.compile(r'\[tsched\] T (\d+) done (tensor|vector) group (\d+) pe (\d+)')
run, blocks = {}, []            # blocks: (start, end, class, group, pe, step)
for line in open(a.trace, errors='replace'):
    m = start.search(line)
    if m:
        t, cls, g, p, k, _, _, arg = m.groups()
        run[(int(g), int(p))] = (int(t), cls, int(k), int(arg or 0))
        continue
    m = done.search(line)
    if m:
        key = (int(m.group(3)), int(m.group(4)))
        if key in run:
            t0, cls, k, arg = run.pop(key)
            if k == a.kernel:
                blocks.append((t0, int(m.group(1)), cls, key[0], key[1], (arg >> 8) & 0xf if k == 12 else 0))
assert blocks, 'no block of kernel %d in the trace' % a.kernel


# ------------------------------------------------------------------ engine traces: cycle -> bucket, per PE
def tensor_rows(g, t):
    d = {}
    f = os.path.join(a.build, 'redmule_profiling', 'redmule_g%d_t%d.log' % (g, t))
    for line in open(f):
        if line[0] != 'C':
            continue
        v = line.split()
        sched, reg_en, stall, sw, sx, sy = int(v[3]), v[4] == '1', v[5] == '1', v[6] == '1', v[7] == '1', v[8] == '1'
        if reg_en:
            b = 0
        elif stall:
            b = 1 if (sched == 2 and sw) else 2 if (sched == 2 and sx) else 3 if (sched == 2 and sy) else 4
        else:
            b = 5
        d[int(v[1])] = b
    return d


def vector_rows(g, t, c):
    d = {}
    f = os.path.join(a.build, 'spatz_profiling', 'spatz_g%d_t%d_c%d.log' % (g, t, c))
    for line in open(f):
        if line[0] != 'C':
            continue
        v = line.split()
        d[int(v[1])] = 0 if v[5] == '1' else 1 if (v[7] == '1' or v[9] == '1') else 2 if v[3] == '1' else 3
    return d


# The scheduler numbers the groups row by row, the testbench's engine traces column by column: x and y swap.
SIDE = int(round((len(os.listdir(os.path.join(a.build, 'redmule_profiling'))) / NUM_T) ** 0.5))


def tb_group(g):
    return (g % SIDE) * SIDE + g // SIDE


cache = {}


def rows(cls, g, p):
    key = (cls, g, p)
    if key not in cache:
        g = tb_group(g)
        cache[key] = tensor_rows(g, p) if cls == 'tensor' else vector_rows(g, (p - NUM_T) // VEC_PER_TILE, 1 + (p - NUM_T) % VEC_PER_TILE)
    return cache[key]


# The harness counts cycles from its own reset, the engine traces from that of the testbench. A tensor engine first
# becomes active a few cycles after the start of the first tensor block on its tile: the smallest such distance over
# all tiles is the offset (a few cycles too large, which is the time a core needs to set the engine up).
first = {}
for b in sorted(blocks):
    if b[2] == 'tensor':
        first.setdefault((b[3], b[4]), b[0])
if a.offset is not None:
    off = a.offset
elif first:
    off = min(min(rows('tensor', g, p)) - t0 for (g, p), t0 in first.items()) - 12   # 12: set-up of the engine by its core
else:
    # No block on a tensor engine: the same with the vector units, whose first vector instruction comes later in a
    # block than an engine's start; the offset is then some tens of cycles too large (give --offset to fix it).
    for b in sorted(blocks):
        first.setdefault((b[3], b[4]), b[0])
    off = min(min(c for c in rows('vector', g, p) if c >= 0) - t0 for (g, p), t0 in first.items() if rows('vector', g, p))


def count(sel):
    acc = collections.Counter()
    tot = 0
    for b in sel:
        r = rows(b[2], b[3], b[4])
        n = 6 if b[2] == 'tensor' else 4
        for c in range(b[0] + off, b[1] + off):
            acc[r.get(c, n)] += 1
        tot += b[1] - b[0]
    return acc, tot


def line(label, sel):
    out = {}
    for cls, names in (('tensor', TB), ('vector', VB)):
        v = [b for b in sel if b[2] == cls]
        if not v:
            continue
        acc, tot = count(v)
        out[cls] = dict(blocks=len(v), cycles=tot, mean=tot / len(v), share={n: acc[i] / tot for i, n in enumerate(names)})
        print('%-12s %-6s %4d blocks, mean %5d cycles:  %s' % (label, cls, len(v), tot / len(v),
              '  '.join('%s %4.1f%%' % (n, 100 * acc[i] / tot) for i, n in enumerate(names))))
    return out


t0, t1 = min(b[0] for b in blocks), max(b[1] for b in blocks)
print('%d blocks of kernel %d, cycles %d to %d (%d); engine traces are %d cycles ahead' % (len(blocks), a.kernel, t0, t1, t1 - t0, off))
res = dict(span=t1 - t0, offset=off, steps=[], total=None)
for s in sorted(set(b[5] for b in blocks)):
    r = line('%2d %s' % (s, NAMES[s]) if a.kernel == 12 else 'kernel', [b for b in blocks if b[5] == s])
    res['steps'].append(dict(step=s, name=NAMES[s] if a.kernel == 12 else 'kernel', **r))
print()
res['total'] = line('all blocks', blocks)

# Over the whole run of the kernel and all PEs that ran a block of it: how much of the time the scheduler had a block on
# a PE, and how much of the time its datapath computed.
print()
res['pes'] = {}
for cls in ('tensor', 'vector'):
    v = [b for b in blocks if b[2] == cls]
    if not v:
        continue
    pes = len(set((b[3], b[4]) for b in v))
    groups = len(set(b[3] for b in blocks))
    allpes = groups * (NUM_T if cls == 'tensor' else NUM_T * VEC_PER_TILE)
    acc, tot = count(v)
    res['pes'][cls] = dict(pes=allpes, used=pes, busy=tot / (allpes * (t1 - t0)), compute=acc[0] / (allpes * (t1 - t0)))
    print('%s: %d PEs in the groups that ran blocks (%d ran one). Over the %d cycles: a block on the PE %.1f%% of the time, datapath computing %.1f%%' % (
        cls, allpes, pes, t1 - t0, 100 * tot / (allpes * (t1 - t0)), 100 * acc[0] / (allpes * (t1 - t0))))
if a.json:
    json.dump(res, open(a.json, 'w'), indent=1)
