"""Step 4: the scheduler organisations of step 3 on the Qwen3.6-35B-A3B routing trace.

Settings (region size, block size, early mixer passes, fetch order, vector threshold) are tuned per scheme on one
window and four layers, then every scheme is evaluated with its tuned settings on other windows at full depth
(40 layers). Prefill windows are consecutive prompt tokens of one request; the 1-token case uses response tokens.

usage: python3 -I scripts/step4_run.py <json_out> [processes] [eval windows]
"""
import json
import os
import sys
import time
from multiprocessing import Pool

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from sysmodel import (HIER_HW, HIER_SW_PLAN, HIER_SW_PULL, HIER_SW_STEAL, HW, PLAN, STATIC, Trace, mergecast, qwen36, simulate2, teramonster)

here = os.path.dirname(os.path.abspath(__file__))
TRACE = os.path.join(here, '..', '..', 'moe_study', 'traces', 'q36')
SYSTEMS = {'teramonster': teramonster, 'mergecast': mergecast}
TUNE_LAYERS = (1, 9, 20, 33)
CASES = [('teramonster', M) for M in (1, 16, 64, 256, 1024, 2048)] + [('mergecast', M) for M in (1, 16, 64, 256)]
REGIONS, PASS = (64, 16, 4, 1), (0.25, 1.0)

S_HW = 'hardware: cluster scheduler + group dispatchers'
S_HW64 = 'hardware: weights over the whole cluster'
S_CEN = 'hardware: one central scheduler'
S_STEAL = 'software: work stealing'
S_NOTRACK = 'software: work stealing, no progress tracking'
S_PLAN = 'software: plan once, per-group lists'
S_PLANFREE = 'software: plan once, planning free'
S_QUEUE = 'software: one shared queue'
S_STATIC = 'static pinning'
HIER = {S_HW: HIER_HW, S_HW64: HIER_HW, S_CEN: HIER_HW.but(central=True), S_STEAL: HIER_SW_STEAL, S_NOTRACK: HIER_SW_STEAL,
        S_PLAN: HIER_SW_PLAN, S_PLANFREE: HIER_SW_PLAN, S_QUEUE: HIER_SW_PULL, S_STATIC: HIER_SW_PLAN}
_trace = None


def run(job):
    global _trace
    sysname, M, scheme, kw, hier_kw, start, layers, tag = job
    if _trace is None:
        _trace = Trace(TRACE, 256)
    model = qwen36()
    base = {'plan': PLAN, 'static': STATIC}.get(kw.get('policy', 'hw'), HW)
    hier = HIER[scheme.split(' | ')[0]] if not scheme.startswith('sweep') else (HIER_HW.but(central=True) if 'central' in scheme else HIER_HW)
    if hier_kw:
        hier = hier.but(**hier_kw)
    sc = base.but(**kw).but(hier=hier)
    lay = _trace.window(start, M, layers=layers, shared=model.shared_experts)
    t0 = time.time()
    try:
        r = simulate2(SYSTEMS[sysname](), model, sc, lay)
    except (ValueError, RuntimeError) as e:
        return dict(system=sysname, M=M, scheme=scheme, kw=kw, tag=tag, start=start, error=str(e))
    return dict(system=sysname, M=M, scheme=scheme, kw=kw, hier_kw=hier_kw, tag=tag, start=start, n_layers=len(lay), per_layer=r.per_layer,
                bound=r.bound_per_layer, layer_cycles=[round(l['t1'] - l['t0']) for l in r.layers], layer_experts=[l['experts'] for l in r.layers],
                block_delay=r.block_delay, stream_delay=r.stream_delay, dispatch_busy=r.dispatch_busy, sched_busy=r.sched_busy,
                stream_util=r.stream_util, busy=r.busy, efficiency=r.efficiency, work_share=r.work_share, mean_hops=r.mean_hops,
                blocks=r.blocks_per_layer, pieces=r.pieces_per_layer, plan=r.plan_cycles_per_layer, wall=time.time() - t0)


def weight(job):
    s, M = job[0], job[1]
    return -(M ** 0.5) * (4 if s == 'mergecast' else 1) * (len(job[6]) if job[6] else 40)


def best_of(rows, out=None):
    out = {} if out is None else out
    for r in rows:
        if 'error' in r:
            continue
        k = (r['system'], r['M'], r['scheme'])
        if k not in out or r['per_layer'] < out[k]['per_layer']:
            out[k] = r
    return out


def go(pool, jobs, label):
    t0 = time.time()
    rows = pool.map(run, sorted(jobs, key=weight), chunksize=1)
    err = [r for r in rows if 'error' in r]
    print('%s: %d runs in %.0f s, %d errors%s' % (label, len(rows), time.time() - t0, len(err), ': ' + err[0]['error'] if err else ''), flush=True)
    return rows


def sweep_jobs(tuned, J):
    """What the hardware has to achieve: service time of a hand-over (group dispatchers, and one central server) and
    of a stream decision. Each organisation starts from its own tuned settings; the block size is re-tuned per point."""
    jobs = []
    for s, M in (('teramonster', 256), ('teramonster', 1024), ('mergecast', 64)):
        hw, cen = tuned[(s, M, S_HW)], tuned[(s, M, S_CEN)]
        for d in (2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0, 256.0, 512.0, 1024.0):
            for b in (500.0, 2000.0, 5000.0, 20000.0):
                jobs.append(J(s, M, 'sweep: group dispatchers', dict(hw, min_block_cycles=b), dict(dispatch_cycles=d), d))
            for b in (2000.0, 5000.0, 20000.0, 50000.0, 200000.0):
                jobs.append(J(s, M, 'sweep: one central scheduler', dict(cen, min_block_cycles=b), dict(dispatch_cycles=d), d))
        for d in (16.0, 64.0, 256.0, 1024.0, 4096.0):
            for b in (500.0, 1000.0, 2500.0):
                jobs.append(J(s, M, 'sweep: stream decision', dict(hw, min_block_cycles=b), dict(sched_cycles=d), d))
    return jobs


if __name__ == '__main__':
    out = sys.argv[1]
    procs = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    n_eval = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    tr = Trace(TRACE, 256)
    tune = {M: tr.starts(M, 1, seed=11, phase=1 if M == 1 else 0)[0] for M in (1, 16, 64, 256, 1024, 2048)}
    evals = {M: tr.starts(M, n_eval, seed=21, phase=1 if M == 1 else 0) for M in (1, 16, 64, 256, 1024, 2048)}
    J = lambda s, M, scheme, kw, hk=None, tag=None: (s, M, scheme, kw, hk, tune[M], TUNE_LAYERS, tag)
    jobs = []
    for s, M in CASES:
        for rg in REGIONS:
            for pm in PASS:
                for b in (500.0, 1000.0, 2500.0):
                    jobs.append(J(s, M, S_HW64 if rg == 64 else S_HW, dict(min_block_cycles=b, region_groups=rg, pass_min_frac=pm)))
                for b in (2000.0, 5000.0, 20000.0):
                    jobs.append(J(s, M, S_CEN, dict(min_block_cycles=b, region_groups=rg, pass_min_frac=pm)))
                for b in (2500.0, 5000.0, 12500.0):
                    jobs.append(J(s, M, S_STEAL, dict(min_block_cycles=b, region_groups=rg, pass_min_frac=pm)))
                for b in (5000.0, 20000.0, 100000.0):
                    jobs.append(J(s, M, S_QUEUE, dict(min_block_cycles=b, region_groups=rg, pass_min_frac=pm)))
            for b in (2500.0, 5000.0, 12500.0, 50000.0):
                jobs.append(J(s, M, S_PLAN, dict(policy='plan', min_block_cycles=b, region_groups=rg, plan_cores=1)))
        jobs.append(J(s, M, S_STATIC, dict(policy='static')))
    with Pool(procs) as pool:
        rows = go(pool, jobs, 'tuning grid')
        best = best_of(rows)
        # second round: fetch order, vector units (heterogeneous system), and the variants that inherit settings
        jobs = []
        for s, M in CASES:
            for scheme in (S_HW, S_HW64, S_STEAL, S_CEN):
                jobs.append(J(s, M, scheme, dict(best[(s, M, scheme)]['kw'], order='mix')))
        rows2 = go(pool, jobs, 'fetch order')
        rows += rows2
        best = best_of(rows2, best)
        jobs = []
        for s, M in CASES:
            if s == 'teramonster':
                for scheme in (S_HW, S_STEAL):
                    for v in (2, 8, 32):
                        jobs.append(J(s, M, scheme, dict(best[(s, M, scheme)]['kw'], vec_max_tokens=v)))
        rows2 = go(pool, jobs, 'vector units')
        rows += rows2
        best = best_of(rows2, best)
        tuned = {k: r['kw'] for k, r in best.items()}
        for s, M in CASES:
            tuned[(s, M, S_NOTRACK)] = dict(tuned[(s, M, S_STEAL)], tile_following=False)
            tuned[(s, M, S_PLANFREE)] = dict(tuned[(s, M, S_PLAN)], plan_cycles_per_block=0.0)
        # evaluation at full depth on windows that were not used for tuning
        jobs = [(s, M, scheme, kw, None, st, None, None) for (s, M, scheme), kw in tuned.items() for st in evals[M]]
        ev = go(pool, jobs, 'evaluation')
        # service-time sweeps, on the tuning window
        jobs = sweep_jobs(tuned, J)
        sw = go(pool, jobs, 'service-time sweeps')
    json.dump(dict(tune_rows=rows, tuned=[dict(system=k[0], M=k[1], scheme=k[2], kw=v) for k, v in tuned.items()], eval=ev, sweeps=sw,
                   tune_starts=tune, eval_starts=evals, tune_layers=TUNE_LAYERS), open(out, 'w'))
    # summary
    agg = {}
    for r in ev:
        if 'error' not in r:
            agg.setdefault((r['system'], r['M'], r['scheme']), []).append(r)
    for s, M in CASES:
        ref = sum(r['per_layer'] for r in agg[(s, M, S_HW)]) / len(agg[(s, M, S_HW)])
        print('\n%s M=%d   (hardware reference %.0fk cycles/layer, bound %.0fk)' % (s, M, ref / 1e3, sum(r['bound'] for r in agg[(s, M, S_HW)]) / len(agg[(s, M, S_HW)]) / 1e3))
        for (a, b, scheme), rs in sorted(agg.items(), key=lambda kv: sum(r['per_layer'] for r in kv[1]) / len(kv[1])):
            if a != s or b != M:
                continue
            t = [r['per_layer'] for r in rs]
            kw = rs[0]['kw']
            print('  %-48s %5.2fx (%4.2f-%4.2f) | region %2d block %6.0f pass %.2f %-3s vec<=%-2d | block delay %6.0f stream delay %6.0f | stream %3.0f%%' % (
                scheme, sum(t) / len(t) / ref, min(x / y['per_layer'] for x, y in zip(t, agg[(s, M, S_HW)])), max(x / y['per_layer'] for x, y in zip(t, agg[(s, M, S_HW)])),
                kw.get('region_groups', 64), kw.get('min_block_cycles', 2000), kw.get('pass_min_frac', 1.0), kw.get('order', 'hot')[:3], kw.get('vec_max_tokens', 0),
                sum(r['block_delay'] for r in rs) / len(rs), sum(r['stream_delay'] for r in rs) / len(rs), 100 * sum(r['stream_util'] for r in rs) / len(rs)))
