"""How large must the task window be? Tasks (pieces: one load from L2 plus the compute on it) retire in issue order,
as in a reorder buffer, and at most W of them may be issued and not yet retired.

FU groups of 4 mesh groups (16 ports), hardware decision times, settings from ref/fugroup.json ("bound 4": blocks stay
in their FU group; "pull 4": idle engines may pull across FU groups). Evaluated on two batches, layers 1, 9, 20, 33.

usage: python3 -I scripts/window_run.py ref/fugroup.json <json_out> [processes]
"""
import json
import os
import sys
from dataclasses import replace
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decode_run as dr
import fugroup_run as fg
import step4_run as s4
from sysmodel import HW, Trace, qwen36, simulate2

WINDOWS = (0, 256, 128, 64, 48, 32, 24, 16, 8)
_trace = None


def run(job):
    global _trace
    sysname, kind, n, regime, variant, kw, pos, W = job
    if _trace is None:
        _trace = Trace(s4.TRACE, 256)
    wb, rate = dr.REGIMES[regime]
    model = replace(qwen36(), weight_bytes=wb)
    system = s4.SYSTEMS[sysname]()
    system = replace(system, l2_port_bytes_per_cycle=system.l2_port_bytes_per_cycle * rate)
    sc = HW.but(**kw).but(hier=s4.HIER[s4.S_HW], window_tasks=W)
    r = simulate2(system, model, sc, _trace.rows(pos, layers=s4.TUNE_LAYERS, shared=model.shared_experts))
    return dict(system=sysname, kind=kind, n=n, regime=regime, variant=variant, W=W, per_layer=r.per_layer, window=r.window,
                pieces=r.pieces_per_layer, blocks=r.blocks_per_layer)


if __name__ == '__main__':
    d = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    procs = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    kws = {}
    for r in d['eval']:
        if 'error' not in r and r['variant'] in ('bound 4', 'pull 4'):
            kws[(r['system'], r['kind'], r['n'], r['regime'], r['variant'])] = r['kw']
    tr = Trace(s4.TRACE, 256)
    jobs = [k + (kw, dr.positions(tr, k[1], k[2], sd), W) for k, kw in kws.items() for sd in (21, 22) for W in WINDOWS]
    jobs.sort(key=lambda j: -j[2] * (4 if j[0] == 'mergecast' else 1))
    with Pool(procs) as pool:
        rows = pool.map(run, jobs, chunksize=1)
    json.dump(dict(rows=rows), open(out, 'w'))
    agg = {}
    for r in rows:
        agg.setdefault((r['system'], r['kind'], r['n'], r['regime'], r['variant'], r['W']), []).append(r)
    m = lambda rs, f: sum(f(r) for r in rs) / len(rs)
    for variant in ('bound 4', 'pull 4'):
        print('\n%s: time per layer relative to an unlimited window' % variant)
        print('%-30s %9s %7s %7s %9s %9s |' % ('case', 'tasks/lay', 'in fl.', 'max', 'life mean', 'life max') + ''.join('%7d' % W for W in WINDOWS[1:]))
        for c in fg.CASES:
            ref = agg[c + (variant, 0)]
            t0 = m(ref, lambda r: r['per_layer'])
            print('%-30s %9.0f %7.1f %7.0f %9.0f %9.0f |' % ('%s %s %d %s' % (c[0][:5], c[1], c[2], c[3]), m(ref, lambda r: r['window']['tasks_per_layer']),
                  m(ref, lambda r: r['window']['mean']), max(r['window']['max'] for r in ref), m(ref, lambda r: r['window']['life_mean']), max(r['window']['life_max'] for r in ref))
                  + ''.join('%7.2f' % (m(agg[c + (variant, W)], lambda r: r['per_layer']) / t0) for W in WINDOWS[1:]))
