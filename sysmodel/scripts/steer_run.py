"""Soft steering by the cluster level (the CPU): each piece of weights is loaded where there is room, and its compute
is given to the domain (region of 4 mesh groups, one task port) that finishes it first: the home domain unless another
one is enough less loaded to make up for the distance. Compared with the results of fugroup_run.py on the same batches:

  bound        compute only in the home domain
  soft         the CPU may send the whole task to another domain; no pulling of blocks between domains
  pull         compute queued at home; idle engines of other domains pull single blocks (nearest first, no cost check)
  soft + pull  both

usage: python3 -I scripts/steer_run.py ref/fugroup.json <json_out> [processes]
"""
import json
import os
import sys
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decode_run as dr
import fugroup_run as fg
import step4_run as s4
from sysmodel import Trace


def variants(sysname, rg):
    vecs = (0, 8, 32) if sysname == 'teramonster' else (0,)
    base = [dict(min_block_cycles=b, pass_min_frac=pm, vec_max_tokens=v, region_groups=rg) for b in (125.0, 500.0, 2500.0) for pm in (0.25, 1.0) for v in vecs]
    return [('soft %d' % rg, dict(k, steer='soft', cross_region=False)) for k in base] + [('soft+pull %d' % rg, dict(k, steer='soft')) for k in base]


if __name__ == '__main__':
    old = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    procs = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    tr = Trace(s4.TRACE, 256)
    pos = {c: [dr.positions(tr, c[1], c[2], sd) for sd in (11, 21, 22)] for c in fg.CASES}
    jobs = [(name, (c[0], c[1], c[2], c[3], s4.S_HW, kw, pos[c][0], s4.TUNE_LAYERS, 2048)) for c in fg.CASES for rg in (4, 16) for name, kw in variants(c[0], rg)]
    jobs.sort(key=lambda j: -j[1][2] * (4 if j[1][0] == 'mergecast' else 1))
    with Pool(procs) as pool:
        rows = pool.map(fg.run, jobs, chunksize=1)
        best = {}
        for r in rows:
            if 'error' in r:
                continue
            k = (r['system'], r['kind'], r['n'], r['regime'], r['variant'])
            if k not in best or r['per_layer'] < best[k]['per_layer']:
                best[k] = r
        ev = pool.map(fg.run, [(k[4], (k[0], k[1], k[2], k[3], s4.S_HW, r['kw'], p, s4.TUNE_LAYERS, 2048)) for k, r in best.items()
                               for p in pos[(k[0], k[1], k[2], k[3])][1:]], chunksize=1)
    json.dump(dict(eval=ev), open(out, 'w'))
    agg = {}
    for r in old['eval'] + ev:
        if 'error' not in r:
            agg.setdefault((r['system'], r['kind'], r['n'], r['regime'], r['variant']), []).append(r)
    m = lambda rs, f: sum(f(r) for r in rs) / len(rs)
    print('errors', sum('error' in r for r in rows + ev))
    names = ['free'] + ['%s %d' % (a, rg) for rg in (4, 16) for a in ('bound', 'soft', 'pull', 'soft+pull')]
    print('%-30s' % 'time per layer / free' + ''.join('%14s' % n for n in names) + '   hops: bound4 soft4 pull4')
    for c in fg.CASES:
        ref = m(agg[c + ('free',)], lambda r: r['per_layer'])
        line = '%-30s' % ('%s %s %d %s' % (c[0][:5], c[1], c[2], c[3]))
        for n in names:
            rs = agg.get(c + (n,))
            line += '%14s' % ('%.2f' % (m(rs, lambda r: r['per_layer']) / ref) if rs else '-')
        line += '   ' + ' '.join('%.2f' % m(agg[c + (n,)], lambda r: r['mean_hops']) for n in ('bound 4', 'soft 4', 'pull 4'))
        print(line)
