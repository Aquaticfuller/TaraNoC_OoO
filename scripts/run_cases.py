#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""RTL against the system model on MoE layers from the routing trace.

For every case the layer is cut into a task program (gen_program.py moe), run through the system model
and through the RTL testbench, once with blocks free to run in neighbour domains and once bound to the
domain that holds their weights. One simulation runs at a time.

usage: run_cases.py <json_out> [case ...]      case = kind:n:regime, default: the list below
       EXTRA_DEFS="+define+..." in the environment adds defines to both builds (separate build directories)
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
SIM = os.path.join(ROOT, 'sim')
CASES = ['decode:1:x4', 'sessions:16:x4', 'midfill:64:x4', 'midfill:64:x1', 'midfill:256:x1', 'midfill:1024:x1']
SLOTS = 2
EXTRA = os.environ.get('EXTRA_DEFS', '')
TAG = ('_' + ''.join(c if c.isalnum() else '_' for c in EXTRA.replace('+define+', ''))).rstrip('_') if EXTRA else ''
BUILDS = {False: ('full_s2' + TAG, ('+define+TSCHED_SLOTS_PER_DOMAIN=%d ' % SLOTS) + EXTRA),
          True: ('full_s2_bound' + TAG, ('+define+TSCHED_SLOTS_PER_DOMAIN=%d +define+TB_NO_LEND ' % SLOTS) + EXTRA)}


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True, **kw).stdout


def run_case(case, layers='9', block=500, vec=8):
    kind, n, regime = case.split(':')
    out = {}
    for bound, (cfg, defs) in BUILDS.items():
        d = os.path.join(SIM, 'prog', '%s_%s_%s%s' % (kind, n, regime, '_bound' if bound else ''))
        sh('python3 -I %s/gen_program.py moe %s --kind %s --n %s --regime %s --layers %s --block %d --vec %d --slots %d %s'
           % (HERE, d, kind, n, regime, layers, block, vec, SLOTS, '--bound' if bound else ''))
        m = json.load(open(os.path.join(d, 'model.json')))
        sh('make compile CFG=%s DEFS="%s"' % (cfg, defs), cwd=SIM)
        sh('make run CFG=%s PROG=%s ARGS="+LANE_BPC100=%d"' % (cfg, d, m['lane_bpc100']), cwd=SIM)
        log = open(os.path.join(d, 'sim_%s.log' % cfg)).read()
        res = dict(re.findall(r'(\w+)=([\d.]+)', ' '.join(l for l in log.splitlines() if 'RESULT' in l)))
        res = {k: float(v) for k, v in res.items()}
        res['pass'] = '[tb] PASS' in log and 'Error' not in log
        res['phases'] = [int(x) for x in re.findall(r'PHASE tasks_done=\d+ cycle=(\d+)', log)]
        out['bound' if bound else 'lend'] = dict(model=dict(cycles=m['cycles'], phases=[p[2] for p in m['phases']], pieces=m['pieces'],
                                                            blocks=m['blocks'], stream_util=m['stream_util'], window=m['window']),
                                                 rtl=res)
    return out


if __name__ == '__main__':
    path = sys.argv[1]
    cases = sys.argv[2:] or CASES
    rows = {}
    print('%-18s %10s %10s %7s   %10s %10s %7s   %s' % ('case', 'model', 'RTL', 'ratio', 'model bnd', 'RTL bnd', 'ratio', 'window max / issue queue max / pass'))
    for c in cases:
        r = rows[c] = run_case(c)
        a, b = r['lend'], r['bound']
        print('%-18s %10.0f %10.0f %7.3f   %10.0f %10.0f %7.3f   %d / %d / %s' % (
            c, a['model']['cycles'], a['rtl']['cycles'], a['rtl']['cycles'] / a['model']['cycles'],
            b['model']['cycles'], b['rtl']['cycles'], b['rtl']['cycles'] / b['model']['cycles'],
            a['rtl']['win_max'], a['rtl']['riq_max'], a['rtl']['pass'] and b['rtl']['pass']), flush=True)
        json.dump(rows, open(path, 'w'), indent=1)
