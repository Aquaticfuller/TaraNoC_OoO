"""Step-2 experiments: scheduling schemes on the cluster with the L1 interconnect, placement, lanes and two engine
classes. Every scheme gets its own best settings (region size, block size, fetch order, vector threshold).

usage: python3 -I scripts/step2_run.py [json_out] [processes]
"""
import json
import os
import sys
import time
from multiprocessing import Pool

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from sysmodel import HW, PLAN, STATIC, ModelConfig, embedded_sample, mergecast, simulate2, teramonster

here = os.path.dirname(os.path.abspath(__file__))
sample = os.path.join(here, '..', '..', 'moe_study', 'model', 'overlap_embed.json')
model = ModelConfig()
SYSTEMS = {'teramonster': teramonster, 'mergecast': mergecast}
REGIONS = (64, 16, 4, 1)
SW = dict(block_delay=1000.0, stream_delay=1000.0)


def run(job):
    sysname, ideal, M, scheme, kw = job
    system = SYSTEMS[sysname]()
    if ideal:
        system = system.ideal()
    base = {'plan': PLAN, 'static': STATIC}.get(kw.get('policy', 'hw'), HW)
    sc = base.but(**kw)
    t0 = time.time()
    try:
        r = simulate2(system, model, sc, embedded_sample(sample, M))
    except ValueError as e:
        return dict(system=sysname, M=M, scheme=scheme, kw=kw, error=str(e))
    return dict(system=sysname, M=M, scheme=scheme, kw=kw, per_layer=r.per_layer, bound=r.bound_per_layer, stream_util=r.stream_util,
                busy=r.busy, work_share=r.work_share, efficiency=r.efficiency, mean_hops=r.mean_hops, delay_share=r.delay_share,
                fetches=r.fetches_per_layer, pieces=r.pieces_per_layer, blocks=r.blocks_per_layer, passes=r.passes_per_layer,
                plan=r.plan_cycles_per_layer, wall=time.time() - t0)


def grid(sysname, M):
    """(scheme, ideal, settings) for the first round: tensor engines only where the system has them."""
    hetero = sysname == 'teramonster'
    hw_blocks = (500.0, 1000.0, 2000.0, 5000.0) + (() if hetero else (10000.0,))
    sw_blocks = (2000.0, 5000.0, 10000.0, 20000.0, 50000.0)
    # pass_min_frac = 1 means: start the next mixer only when every token is finished (no early passes)
    for b in hw_blocks:
        for o in ('hot', 'mix'):
            for pm in (0.25, 1.0):
                yield 'ideal interconnect, pull', True, dict(min_block_cycles=b, order=o, mixer_spm=False, pass_min_frac=pm)
                for rg in REGIONS:
                    yield ('pull, weights interleaved' if rg == 64 else 'pull + placement'), False, dict(min_block_cycles=b, order=o, region_groups=rg, pass_min_frac=pm)
    for rg in REGIONS:
        for b in sw_blocks:
            for o in ('hot', 'mix'):
                yield ('software plan, interleaved' if rg == 64 else 'software plan + placement'), False, dict(policy='plan', min_block_cycles=b, order=o, region_groups=rg)
                for pm in (0.25, 1.0):
                    yield ('pull, software delays, interleaved' if rg == 64 else 'pull + placement, software delays'), False, dict(min_block_cycles=b, order=o, region_groups=rg, pass_min_frac=pm, **SW)
    yield 'static dense', False, dict(policy='static')


def best_of(rows):
    out = {}
    for r in rows:
        if 'error' in r:
            continue
        k = (r['system'], r['M'], r['scheme'])
        if k not in out or r['per_layer'] < out[k]['per_layer']:
            out[k] = r
    return out


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else None
    procs = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    cases = [('teramonster', M) for M in (1, 16, 64, 256, 1024)] + [('mergecast', M) for M in (1, 16, 64, 256)]
    t0 = time.time()
    jobs = [(s, ideal, M, scheme, kw) for s, M in cases for scheme, ideal, kw in grid(s, M)]
    with Pool(procs) as pool:
        rows = pool.map(run, jobs, chunksize=1)
        best = best_of(rows)
        # second round, heterogeneous system only: let blocks with few tokens run on vector units
        jobs2 = []
        for (s, M, scheme), r in best.items():
            if s != 'teramonster' or scheme in ('static dense', 'ideal interconnect, pull'):
                continue
            for v in (1, 2, 4, 8, 16, 32):
                for b in sorted({r['kw']['min_block_cycles'], 2 * r['kw']['min_block_cycles']}):
                    jobs2.append((s, False, M, scheme + ' + vector units', dict(r['kw'], vec_max_tokens=v, min_block_cycles=b)))
        rows2 = pool.map(run, jobs2, chunksize=1)
        rows += rows2
        best = best_of(rows)
        # third round: the best software plan of each case once more with planning for free
        jobs3 = []
        for s, M in cases:
            c = [r for (a, b, n), r in best.items() if a == s and b == M and n.startswith('software plan')]
            r = min(c, key=lambda r: r['per_layer'])
            jobs3.append((s, False, M, 'best software plan, planning free', dict(r['kw'], plan_cycles_per_block=0.0)))
        rows += pool.map(run, jobs3, chunksize=1)
    best = best_of(rows)
    print('%d runs in %.0f s' % (len(rows), time.time() - t0))
    for s, M in cases:
        ref = min(r['per_layer'] for (a, b, c), r in best.items() if a == s and b == M and c.startswith('pull') and 'software' not in c)
        print('\n%s M=%d' % (s, M))
        for (a, b, scheme), r in sorted(best.items(), key=lambda kv: kv[1]['per_layer']):
            if a != s or b != M:
                continue
            kw = r['kw']
            print('  %-46s %8.0fk %5.2fx | region %2d block %5.0f %-3s pass %.2f vec<=%-2d | stream %3.0f%% hops %.1f | %s' % (
                scheme, r['per_layer'] / 1e3, r['per_layer'] / ref, kw.get('region_groups', 64), kw.get('min_block_cycles', 2000), kw.get('order', '-')[:3],
                kw.get('pass_min_frac', 1.0), kw.get('vec_max_tokens', 0), 100 * r['stream_util'], r['mean_hops'],
                ' '.join('%s busy %.0f%% eff %.0f%% work %.0f%%' % (n[:3], 100 * r['busy'][n], 100 * r['efficiency'][n], 100 * r['work_share'][n]) for n in r['busy'])))
    if out:
        json.dump(dict(rows=rows, best=[dict(r) for r in best.values()]), open(out, 'w'))
