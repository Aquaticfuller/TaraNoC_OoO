#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""How fine must a chain of kernels be cut? Runs gen_program.py chain over a range of cuts on the scheduler alone.

A chain is three stages over one matrix (tensor engines, vector units, tensor engines); block b of a stage needs
block b of the stage before. The program cuts the matrix into `cut` chains of three tasks. Per case the script
prints the cycles of the whole program and writes them to a JSON file.

usage: chain_cases.py <out.json> [--cfg small] [--side 2] [--blocks 128] [--tdur 845] [--sdur 2760]
                      [--cuts 1,2,4,8,16,32] [--work <dir>] [--defs "+define+..."]
       cfg/side: a build of sim/Makefile and its domains per side (small: 2 x 2 domains)
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(HERE, '..', 'sim')

ap = argparse.ArgumentParser()
ap.add_argument('out')
ap.add_argument('--cfg', default='small')
ap.add_argument('--side', type=int, default=2)
ap.add_argument('--blocks', type=int, default=128)
ap.add_argument('--tdur', type=int, default=845)
ap.add_argument('--sdur', type=int, default=2760)
ap.add_argument('--cuts', default='1,2,4,8,16,32')
ap.add_argument('--work', default=os.path.join(SIM, 'prog', 'chain_cases'))
ap.add_argument('--defs', default=None)
ap.add_argument('--args', default='', help='further arguments of gen_program.py chain (e.g. "--follow 1")')
a = ap.parse_args()
defs = a.defs if a.defs is not None else '+define+TSCHED_DOM_PER_SIDE=%d' % a.side
cuts = [int(c) for c in a.cuts.split(',')]
dom = a.side * a.side


def run(tasks, cut, order, home, extra=''):
    d = os.path.join(a.work, 't%d_c%d_%s_h%d%s' % (tasks, cut, order, home, re.sub(r'\W', '', extra)))
    cmd = [sys.executable, '-I', os.path.join(HERE, 'gen_program.py'), 'chain', d, '--side', str(a.side), '--blocks', str(a.blocks),
           '--tasks', str(tasks), '--cut', str(cut), '--order', order, '--home', str(home), '--tdur', str(a.tdur),
           '--sdur', str(a.sdur)] + (a.args + ' ' + extra).split()
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    r = subprocess.run(['make', '-C', SIM, 'run', 'CFG=' + a.cfg, 'DEFS=' + defs, 'PROG=' + d], stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True)
    log = open(os.path.join(d, 'sim_%s.log' % a.cfg), errors='replace').read()
    m = re.search(r'RESULT cycles=(\d+) instructions=(\d+) tasks=(\d+) tasks_done=(\d+) errors=(\d+)', log)
    ok = bool(m) and '[tb] PASS' in log and m.group(5) == '0'
    b = re.search(r'RESULT busy_tensor=(\d+) busy_vector=(\d+)', log)
    w = re.search(r'RESULT win_max=(\d+) win_mean=([\d.]+) riq_max=(\d+)', log)
    aw = re.search(r'away_tensor=(\d+) away_vector=(\d+)', log)
    if not ok:
        print('FAILED: %s\n%s' % (d, r.stdout[-600:]))
        return None
    return dict(cycles=int(m.group(1)), instr=int(m.group(2)), busy_t=int(b.group(1)), busy_v=int(b.group(2)),
                win_max=int(w.group(1)), riq_max=int(w.group(3)), away_t=int(aw.group(1)), away_v=int(aw.group(2)))


res = dict(blocks=a.blocks, tdur=a.tdur, sdur=a.sdur, side=a.side, cuts=cuts, panels=[])
for name, tasks in (('One matrix, the other domains idle', 1), ('A matrix in every domain', dom)):
    panel = dict(name=name, tasks=tasks, rows=[])
    for order, home in (('chain', 0), ('chain', 1), ('stage', 0)):
        row = dict(order=order, home=home, cases=[])
        for cut in cuts:
            if order == 'stage' and 3 * cut * tasks > 20:
                row['cases'].append(None)
                continue
            c = run(tasks, cut, order, home)
            row['cases'].append(c)
            print('%-36s %-5s home %d cut %3d: %s' % (name, order, home, cut, c and c['cycles']), flush=True)
        panel['rows'].append(row)
    res['panels'].append(panel)
json.dump(res, open(a.out, 'w'), indent=1)
