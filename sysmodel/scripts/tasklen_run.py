"""Second workload of step 4: the same data flow, but the program fixes the task length.

In the MoE runs every scheme chooses its own block size. A general workload does not allow that: a task is as long as
the program made it. Here every piece of work is cut into tasks of a given length and the scheduler organisations are
compared at that length. Data flow, placement and engines are those of the Qwen3.6 layer (two layers of the tuning
window), so the only thing that changes is how often a decision is needed.

usage: python3 -I scripts/tasklen_run.py ref/step4.json <json_out> [processes]
"""
import json
import os
import sys
import time
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import step4_run as s4

LAYERS = (9, 20)
LENGTHS = (64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0, 32000.0)
CASES = (('teramonster', 1024), ('teramonster', 256), ('mergecast', 64))
ORGS = (s4.S_HW, s4.S_CEN, s4.S_STEAL, s4.S_QUEUE)

if __name__ == '__main__':
    d = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    procs = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    tuned = {(t['system'], t['M'], t['scheme']): t['kw'] for t in d['tuned']}
    jobs = []
    for s, M in CASES:
        for org in ORGS:
            kw = tuned[(s, M, org)]
            for rg in sorted({kw.get('region_groups', 64), 1, 4, 16}):
                for L in LENGTHS:
                    if s == 'mergecast' and L < 125:
                        continue
                    jobs.append((s, M, org, dict(kw, region_groups=rg, fixed_block_cycles=L), None, d['tune_starts'][str(M)], LAYERS, L))
    t0 = time.time()
    with Pool(procs) as pool:
        rows = pool.map(s4.run, sorted(jobs, key=lambda j: j[7]), chunksize=1)
    print('%d runs in %.0f s' % (len(rows), time.time() - t0))
    best = {}
    for r in rows:
        if 'error' in r:
            print('error', r['system'], r['M'], r['scheme'], r['tag'], r['error'])
            continue
        k = (r['system'], r['M'], r['scheme'], r['tag'])
        if k not in best or r['per_layer'] < best[k]['per_layer']:
            best[k] = r
    for s, M in CASES:
        ref = min(r['per_layer'] for k, r in best.items() if k[:3] == (s, M, s4.S_HW))
        print('\n%s M=%d   time per layer relative to the hardware hierarchy at its best task length (%.0fk cycles)' % (s, M, ref / 1e3))
        print('  %-48s' % 'task length' + ''.join('%8.0f' % L for L in LENGTHS))
        for org in ORGS:
            print('  %-48s' % org + ''.join(('%8.2f' % (best[(s, M, org, L)]['per_layer'] / ref)) if (s, M, org, L) in best else '       -' for L in LENGTHS))
        print('  %-48s' % 'best software / hardware at the same length' + ''.join(
            ('%8.2f' % (min(best[(s, M, o, L)]['per_layer'] for o in (s4.S_STEAL, s4.S_QUEUE)) / best[(s, M, s4.S_HW, L)]['per_layer'])) if (s, M, s4.S_HW, L) in best else '       -' for L in LENGTHS))
    json.dump(dict(rows=rows, best=list(best.values()), lengths=LENGTHS, layers=LAYERS), open(out, 'w'))
