"""What does it cost to bind work to FU groups? The cluster-level scheduler (here: the CPU backend) places every piece
of weights in one region; a region is the "FU group" (1, 4 or 16 mesh groups, i.e. 64, 16 or 4 issue ports).

  free        the current design: region size tuned, idle engines pull the nearest ready block from any region
  pull        regions of the given size, idle engines may still pull across regions
  bound       regions of the given size, a block only runs inside the region that holds its weights
  bound+fence as bound, and the next mixer starts only when every expert of the layer is done (a join in program order)

Hardware hierarchy in all cases. Tuned on one batch (block size, early passes, vector threshold), evaluated on two
other batches; layers 1, 9, 20, 33.

usage: python3 -I scripts/fugroup_run.py <json_out> [processes]
"""
import json
import os
import sys
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decode_run as dr
import step4_run as s4
from sysmodel import Trace

CASES = [('teramonster', 'midfill', 64, 'x1'), ('teramonster', 'midfill', 256, 'x1'), ('teramonster', 'midfill', 1024, 'x1'),
         ('mergecast', 'midfill', 64, 'x1'), ('mergecast', 'midfill', 256, 'x1'),
         ('teramonster', 'decode', 1, 'x4'), ('teramonster', 'sessions', 16, 'x4'), ('teramonster', 'midfill', 64, 'x4')]


def variants(sysname):
    vecs = (0, 8, 32) if sysname == 'teramonster' else (0,)
    base = [dict(min_block_cycles=b, pass_min_frac=pm, vec_max_tokens=v) for b in (125.0, 500.0, 2500.0) for pm in (0.25, 1.0) for v in vecs]
    out = [('free', dict(k, region_groups=rg)) for k in base for rg in (64, 16, 4, 1)]
    for rg in (16, 4, 1):
        out += [('pull %d' % rg, dict(k, region_groups=rg)) for k in base]
        out += [('bound %d' % rg, dict(k, region_groups=rg, cross_region=False)) for k in base]
        out += [('bound+fence %d' % rg, dict(k, region_groups=rg, cross_region=False, overlap=False)) for k in base if k['pass_min_frac'] == 1.0]
    return out


def run(job):
    name, j = job
    r = dr.run(j)
    r['variant'] = name
    return r


if __name__ == '__main__':
    out = sys.argv[1]
    procs = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    tr = Trace(s4.TRACE, 256)
    pos = {c: [dr.positions(tr, c[1], c[2], sd) for sd in (11, 21, 22)] for c in CASES}
    jobs = [(name, (c[0], c[1], c[2], c[3], s4.S_HW, kw, pos[c][0], s4.TUNE_LAYERS, 2048)) for c in CASES for name, kw in variants(c[0])]
    jobs.sort(key=lambda j: -j[1][2] * (4 if j[1][0] == 'mergecast' else 1))
    with Pool(procs) as pool:
        rows = pool.map(run, jobs, chunksize=1)
        best = {}
        for r in rows:
            if 'error' in r:
                continue
            k = (r['system'], r['kind'], r['n'], r['regime'], r['variant'])
            if k not in best or r['per_layer'] < best[k]['per_layer']:
                best[k] = r
        ev = pool.map(run, [(k[4], (k[0], k[1], k[2], k[3], s4.S_HW, r['kw'], p, s4.TUNE_LAYERS, 2048)) for k, r in best.items()
                            for p in pos[(k[0], k[1], k[2], k[3])][1:]], chunksize=1)
    json.dump(dict(eval=ev, errors=sum('error' in r for r in rows)), open(out, 'w'))
    agg = {}
    for r in ev:
        if 'error' not in r:
            agg.setdefault((r['system'], r['kind'], r['n'], r['regime'], r['variant']), []).append(r)
    m = lambda rs, f: sum(f(r) for r in rs) / len(rs)
    print('tuning errors', sum('error' in r for r in rows), 'eval errors', sum('error' in r for r in ev))
    names = ['free'] + ['%s %d' % (a, rg) for rg in (16, 4, 1) for a in ('pull', 'bound', 'bound+fence')]
    print('%-34s' % 'time per layer / free' + ''.join('%15s' % n for n in names))
    for c in CASES:
        ref = m(agg[c + ('free',)], lambda r: r['per_layer'])
        line = '%-34s' % ('%s %s %d %s (rg %d)' % (c[0][:5], c[1], c[2], c[3], agg[c + ('free',)][0]['kw']['region_groups']))
        for n in names:
            rs = agg.get(c + (n,))
            line += '%15s' % ('%.2f' % (m(rs, lambda r: r['per_layer']) / ref) if rs else '-')
        print(line)
