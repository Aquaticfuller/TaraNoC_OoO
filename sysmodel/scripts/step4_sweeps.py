"""Redo only the service-time sweeps of step 4 from the tuned settings stored in a step-4 result file.

usage: python3 -I scripts/step4_sweeps.py ref/step4.json [processes]
"""
import json
import os
import sys
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import step4_run as s4

if __name__ == '__main__':
    path = sys.argv[1]
    procs = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    d = json.load(open(path))
    tuned = {(t['system'], t['M'], t['scheme']): t['kw'] for t in d['tuned']}
    J = lambda s, M, scheme, kw, hk=None, tag=None: (s, M, scheme, kw, hk, d['tune_starts'][str(M)], s4.TUNE_LAYERS, tag)
    with Pool(procs) as pool:
        d['sweeps'] = s4.go(pool, s4.sweep_jobs(tuned, J), 'service-time sweeps')
    json.dump(d, open(path, 'w'))
