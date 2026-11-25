"""Decode and midfill on the Qwen3.6 trace: what the cluster waits for, and when short tasks matter.

Workloads (all from the routing trace, one batch per layer step):
  decode 1      one response token of one request
  draft k       k consecutive response tokens of one request (multi-token prediction, or verifying k drafted tokens)
  sessions n    one response token from each of n different requests (concurrent sessions or agents)
  midfill m     m consecutive prompt tokens of one request (an added prompt or a tool result on an existing context)

Stream regimes: the same workload with the weight stream 1x, 4x and 16x faster per parameter.
  x1    FP16 weights on the stream and in L1 (as in step 4)
  x4    4-bit weights on the stream and in L1, expanded at the engine [assumed: no cost in engine rate]
  x16   4-bit weights and four times the L2 port rate [hypothetical: shows the compute-limited end]

Each organisation is tuned per workload and regime on one batch and four layers (region size, block size, early
mixer passes, vector threshold), then evaluated on other batches at all 40 layers.

usage: python3 -I scripts/decode_run.py <json_out> [processes] [eval batches]
"""
import json
import os
import sys
import time
from dataclasses import replace
from multiprocessing import Pool

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import step4_run as s4
from sysmodel import HW, PLAN, Trace, qwen36, simulate2

WORKLOADS = [('decode', 1), ('draft', 4), ('draft', 8), ('sessions', 4), ('sessions', 16), ('sessions', 64),
             ('midfill', 16), ('midfill', 64), ('midfill', 256)]
REGIMES = {'x1': (2.0, 1.0), 'x4': (0.5, 1.0), 'x16': (0.5, 4.0)}      # weight bytes per parameter, L2 port rate factor
ORGS = (s4.S_HW, s4.S_CEN, s4.S_STEAL, s4.S_PLAN, s4.S_QUEUE)
BLOCKS = {s4.S_HW: (125.0, 250.0, 500.0, 1000.0, 2500.0), s4.S_CEN: (500.0, 2000.0, 5000.0, 20000.0),
          s4.S_STEAL: (1000.0, 2500.0, 5000.0, 12500.0), s4.S_PLAN: (2500.0, 5000.0, 12500.0, 50000.0),
          s4.S_QUEUE: (5000.0, 20000.0, 100000.0)}
_trace = None


def positions(tr, kind, n, seed):
    """Token positions of one batch."""
    if kind == 'sessions':
        rng = np.random.RandomState(seed)
        resp = [np.flatnonzero(tr.phase[a:z] == 1) + a for a, z in tr.requests]
        resp = [r for r in resp if len(r)]
        pick = rng.permutation(len(resp))[:n]
        return [int(resp[i][rng.randint(len(resp[i]))]) for i in pick]
    start = tr.starts(n, 1, seed=seed, phase=0 if kind == 'midfill' else 1)[0]
    return list(range(start, start + n))


def run(job):
    global _trace
    sysname, kind, n, regime, scheme, kw, pos, layers, context = job
    if _trace is None:
        _trace = Trace(s4.TRACE, 256)
    wb, rate = REGIMES[regime]
    model = replace(qwen36(context), weight_bytes=wb)
    system = s4.SYSTEMS[sysname]()
    system = replace(system, l2_port_bytes_per_cycle=system.l2_port_bytes_per_cycle * rate)
    base = PLAN if kw.get('policy') == 'plan' else HW
    sc = base.but(**kw).but(hier=s4.HIER[scheme])
    lay = _trace.rows(pos, layers=layers, shared=model.shared_experts)
    key = dict(system=sysname, kind=kind, n=n, regime=regime, scheme=scheme, kw=kw, context=context)
    try:
        r = simulate2(system, model, sc, lay)
    except (ValueError, RuntimeError) as e:
        return dict(key, error=str(e))
    ex = [l['experts'] for l in r.layers]
    tx = model.expert_bytes / system.l2_bytes_per_cycle
    return dict(key, per_layer=r.per_layer, experts=sum(ex) / len(ex),
                stream_floor=(sum(ex) / len(ex) + model.mixer_in_expert_eq + model.mixer_out_expert_eq) * tx / system.l2_efficiency,
                stream_util=r.stream_util, busy=r.busy, efficiency=r.efficiency, work_share=r.work_share, block_delay=r.block_delay,
                stream_delay=r.stream_delay, blocks=r.blocks_per_layer, pieces=r.pieces_per_layer, plan=r.plan_cycles_per_layer,
                mean_hops=r.mean_hops, layer_cycles=[round(l['t1'] - l['t0']) for l in r.layers] if layers is None else None)


def grid(sysname, scheme):
    vecs = (0, 2, 8, 32) if sysname == 'teramonster' else (0,)
    out = []
    for rg in (64, 16, 4, 1):
        for b in BLOCKS[scheme]:
            for v in vecs:
                if scheme == s4.S_PLAN:
                    out.append(dict(policy='plan', min_block_cycles=b, region_groups=rg, plan_cores=1, vec_max_tokens=v))
                else:
                    for pm in (0.25, 1.0):
                        out.append(dict(min_block_cycles=b, region_groups=rg, pass_min_frac=pm, vec_max_tokens=v))
    return out


def go(pool, jobs, label):
    t0 = time.time()
    order = sorted(jobs, key=lambda j: -j[2] * (4 if j[0] == 'mergecast' else 1) * (40 if j[7] is None else len(j[7])))
    rows = pool.map(run, order, chunksize=1)
    err = [r for r in rows if 'error' in r]
    print('%s: %d runs in %.0f s, %d errors%s' % (label, len(rows), time.time() - t0, len(err), ': ' + err[0]['error'] if err else ''), flush=True)
    return rows


if __name__ == '__main__':
    out = sys.argv[1]
    procs = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    n_eval = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    tr = Trace(s4.TRACE, 256)
    tune_pos = {w: positions(tr, w[0], w[1], 11) for w in WORKLOADS}
    eval_pos = {w: [positions(tr, w[0], w[1], 21 + i) for i in range(n_eval)] for w in WORKLOADS}
    jobs = [(s, kind, n, reg, org, kw, tune_pos[(kind, n)], s4.TUNE_LAYERS, 2048)
            for s in ('teramonster', 'mergecast') for kind, n in WORKLOADS for reg in REGIMES for org in ORGS for kw in grid(s, org)]
    with Pool(procs) as pool:
        rows = go(pool, jobs, 'tuning grid')
        best = {}
        for r in rows:
            if 'error' in r:
                continue
            k = (r['system'], r['kind'], r['n'], r['regime'], r['scheme'])
            if k not in best or r['per_layer'] < best[k]['per_layer']:
                best[k] = r
        jobs = [(k[0], k[1], k[2], k[3], k[4], r['kw'], p, None, 2048) for k, r in best.items() for p in eval_pos[(k[1], k[2])]]
        # sensitivity: a long context (16,384 tokens) with the settings tuned at 2,048
        jobs += [(k[0], k[1], k[2], k[3], k[4], r['kw'], p, None, 16384) for k, r in best.items()
                 if k[4] in (s4.S_HW, s4.S_STEAL) and k[3] in ('x1', 'x4') for p in eval_pos[(k[1], k[2])][:2]]
        ev = go(pool, jobs, 'evaluation')
    json.dump(dict(tuned=[dict(system=k[0], kind=k[1], n=k[2], regime=k[3], scheme=k[4], kw=r['kw']) for k, r in best.items()], eval=ev,
                   workloads=WORKLOADS, regimes=REGIMES), open(out, 'w'))
    agg = {}
    for r in ev:
        if 'error' not in r:
            agg.setdefault((r['system'], r['kind'], r['n'], r['regime'], r['scheme'], r['context']), []).append(r)
    mean = lambda rs, f: sum(f(r) for r in rs) / len(rs)
    for s in ('teramonster', 'mergecast'):
        for kind, n in WORKLOADS:
            for reg in REGIMES:
                hw = agg.get((s, kind, n, reg, s4.S_HW, 2048))
                if not hw:
                    continue
                ref = mean(hw, lambda r: r['per_layer'])
                print('\n%s %s %d, stream %s: hardware %.1fk cycles/layer (%.1fk per token), stream floor %.1fk, lanes %.0f%% busy, %.0f experts' % (
                    s, kind, n, reg, ref / 1e3, ref / n / 1e3, mean(hw, lambda r: r['stream_floor']) / 1e3, 100 * mean(hw, lambda r: r['stream_util']),
                    mean(hw, lambda r: r['experts'])))
                for org in ORGS:
                    rs = agg.get((s, kind, n, reg, org, 2048))
                    if not rs:
                        continue
                    kw = rs[0]['kw']
                    print('  %-48s %5.2fx | region %2d block %6.0f pass %.2f vec<=%-2d | blocks %5.0f block delay %6.0f stream delay %6.0f | lanes %3.0f%% | busy %s' % (
                        org, mean(rs, lambda r: r['per_layer']) / ref, kw.get('region_groups', 64), kw.get('min_block_cycles', 2000), kw.get('pass_min_frac', 1.0),
                        kw.get('vec_max_tokens', 0), mean(rs, lambda r: r['blocks']), mean(rs, lambda r: r['block_delay']), mean(rs, lambda r: r['stream_delay']),
                        100 * mean(rs, lambda r: r['stream_util']), ' '.join('%s %.0f%%' % (c, 100 * mean(rs, lambda r: r['busy'][c])) for c in rs[0]['busy'])))
                for org in (s4.S_HW, s4.S_STEAL):
                    rs = agg.get((s, kind, n, reg, org, 16384))
                    if rs:
                        print('  %-48s %5.2fx   (context 16,384)' % (org, mean(rs, lambda r: r['per_layer']) / ref))
