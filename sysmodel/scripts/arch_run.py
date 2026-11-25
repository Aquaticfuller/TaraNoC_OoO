"""Architecture sizing from the workload: the PE mix and the weight bandwidth as free parameters.

The building blocks are the two PEs we have (tensor engine 8x32, 256 MAC/cycle; vector unit, 8 MAC/cycle) on the
burst plane of the L1 interconnect, in 64 groups with 64 MiB of shared L1. Free parameters:
  tensor engines per group   0, 1, 4
  vector units per group     0, 4, 12, 32
  weight stream              FP16 on 32 lanes | 4-bit on 32 lanes | 4-bit on 64 lanes (one lane per group)
Workloads: decode 1, draft 4, sessions 16, midfill 64, midfill 256, prefill 1024 (Qwen3.6 trace).
Organisations: hardware hierarchy and software work stealing, each tuned per point on one batch and four layers,
evaluated on two other batches (same four layers).

usage: python3 -I scripts/arch_run.py <json_out> [processes]
"""
import json
import os
import sys
import time
from dataclasses import replace
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decode_run as dr
import step4_run as s4
from sysmodel import HW, Trace, qwen36, simulate2, teramonster

MIXES = [(t, v) for t in (0, 1, 4) for v in (0, 4, 12, 32) if t or v]
STREAMS = {'fp16, 32 lanes': (2.0, 32), '4-bit, 32 lanes': (0.5, 32), '4-bit, 64 lanes': (0.5, 64)}
WORKLOADS = [('decode', 1), ('draft', 4), ('sessions', 16), ('midfill', 64), ('midfill', 256), ('midfill', 1024)]
ORGS = (s4.S_HW, s4.S_STEAL)
BLOCKS = {s4.S_HW: (250.0, 1000.0), s4.S_STEAL: (2500.0, 5000.0)}
_trace = None


def arch(tensor, vector, lanes):
    tm = teramonster()
    eng = tuple(replace(e, per_group=k) for e, k in zip(tm.engines, (tensor, vector)) if k)
    return replace(tm, name='t%dv%d' % (tensor, vector), engines=eng, l2_ports=lanes, gemm_class=eng[0].name)


def run(job):
    global _trace
    tensor, vector, stream, kind, n, scheme, kw, pos = job
    if _trace is None:
        _trace = Trace(s4.TRACE, 256)
    wb, lanes = STREAMS[stream]
    model = replace(qwen36(), weight_bytes=wb)
    system = arch(tensor, vector, lanes)
    sc = HW.but(**kw).but(hier=s4.HIER[scheme])
    lay = _trace.rows(pos, layers=s4.TUNE_LAYERS, shared=model.shared_experts)
    key = dict(tensor=tensor, vector=vector, stream=stream, kind=kind, n=n, scheme=scheme, kw=kw)
    try:
        r = simulate2(system, model, sc, lay)
    except (ValueError, RuntimeError) as e:
        return dict(key, error=str(e))
    ex = sum(l['experts'] for l in r.layers) / len(r.layers)
    tx = model.expert_bytes / system.l2_bytes_per_cycle
    mac = n * (model.shared_experts + model.top_k) * model.expert_flop_per_token / 2 + n * model.mixer_flop_per_token / 2
    return dict(key, per_layer=r.per_layer, experts=ex, mac=mac,
                stream_floor=(ex + model.mixer_in_expert_eq + model.mixer_out_expert_eq) * tx / system.l2_efficiency,
                stream_util=r.stream_util, busy=r.busy, efficiency=r.efficiency, work_share=r.work_share,
                block_delay=r.block_delay, stream_delay=r.stream_delay, blocks=r.blocks_per_layer)


def grid(tensor, vector, scheme):
    vecs = (0, 8, 32) if tensor and vector else (0,)
    return [dict(min_block_cycles=b, region_groups=rg, pass_min_frac=pm, vec_max_tokens=v)
            for rg in (64, 16, 4, 1) for b in BLOCKS[scheme] for pm in (0.25, 1.0) for v in vecs]


def go(pool, jobs, label):
    t0 = time.time()
    order = sorted(jobs, key=lambda j: -j[4] / (1 + 32 * j[0] + j[1]))
    rows = pool.map(run, order, chunksize=1)
    err = [r for r in rows if 'error' in r]
    print('%s: %d runs in %.0f s, %d errors%s' % (label, len(rows), time.time() - t0, len(err), ': ' + err[0]['error'] if err else ''), flush=True)
    return rows


if __name__ == '__main__':
    out = sys.argv[1]
    procs = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    tr = Trace(s4.TRACE, 256)
    tune_pos = {w: dr.positions(tr, w[0], w[1], 11) for w in WORKLOADS}
    eval_pos = {w: [dr.positions(tr, w[0], w[1], 21 + i) for i in range(2)] for w in WORKLOADS}
    jobs = [(t, v, st, kind, n, org, kw, tune_pos[(kind, n)])
            for t, v in MIXES for st in STREAMS for kind, n in WORKLOADS for org in ORGS for kw in grid(t, v, org)]
    with Pool(procs) as pool:
        rows = go(pool, jobs, 'tuning grid')
        best = {}
        for r in rows:
            if 'error' in r:
                continue
            k = (r['tensor'], r['vector'], r['stream'], r['kind'], r['n'], r['scheme'])
            if k not in best or r['per_layer'] < best[k]['per_layer']:
                best[k] = r
        ev = go(pool, [k + (r['kw'], p) for k, r in best.items() for p in eval_pos[(k[3], k[4])]], 'evaluation')
    json.dump(dict(eval=ev, mixes=MIXES, streams=STREAMS, workloads=WORKLOADS), open(out, 'w'))
    agg = {}
    for r in ev:
        if 'error' not in r:
            agg.setdefault((r['tensor'], r['vector'], r['stream'], r['kind'], r['n'], r['scheme']), []).append(r)
    mean = lambda rs, f: sum(f(r) for r in rs) / len(rs)
    for st in STREAMS:
        for kind, n in WORKLOADS:
            print('\n%s %d, %s: cycles per layer in thousands (hardware) | work stealing / hardware | lanes busy' % (kind, n, st))
            for t, v in MIXES:
                hw, sw = agg.get((t, v, st, kind, n, s4.S_HW)), agg.get((t, v, st, kind, n, s4.S_STEAL))
                if not hw or not sw:
                    continue
                a = mean(hw, lambda r: r['per_layer'])
                print('  tensor %d vector %2d (%5d MAC/cycle)  %9.1f  floor %8.1f | %5.2fx | %3.0f%% | busy %s' % (
                    t, v, 64 * (256 * t + 8 * v), a / 1e3, mean(hw, lambda r: r['stream_floor']) / 1e3, mean(sw, lambda r: r['per_layer']) / a,
                    100 * mean(hw, lambda r: r['stream_util']), ' '.join('%s %.0f%%' % (c, 100 * mean(hw, lambda r: r['busy'][c])) for c in hw[0]['busy'])))
