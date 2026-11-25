"""Step-3 experiments: the scheduling decisions are made by servers with a service time, so the block and stream
delays are outputs. Starts from the best step-2 settings of each scheme (ref/step2.json).

usage: python3 -I scripts/step3_run.py ref/step2.json [json_out] [processes]
"""
import json
import os
import sys
import time
from multiprocessing import Pool

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from sysmodel import HIER_HW, HIER_SW_PLAN, HIER_SW_PULL, HIER_SW_STEAL, HW, PLAN, ModelConfig, embedded_sample, mergecast, simulate2, teramonster

here = os.path.dirname(os.path.abspath(__file__))
sample = os.path.join(here, '..', '..', 'moe_study', 'model', 'overlap_embed.json')
model = ModelConfig()
SYSTEMS = {'teramonster': teramonster, 'mergecast': mergecast}


def run(job):
    sysname, M, scheme, kw, hier, tag = job
    sc = (PLAN if kw.get('policy') == 'plan' else HW).but(**kw).but(hier=hier)
    t0 = time.time()
    r = simulate2(SYSTEMS[sysname](), model, sc, embedded_sample(sample, M))
    return dict(system=sysname, M=M, scheme=scheme, tag=tag, kw=kw, hier=dict(hier.__dict__), per_layer=r.per_layer, block_delay=r.block_delay,
                stream_delay=r.stream_delay, dispatch_busy=r.dispatch_busy, sched_busy=r.sched_busy, blocks=r.blocks_per_layer,
                pieces=r.pieces_per_layer, stream_util=r.stream_util, busy=r.busy, efficiency=r.efficiency, plan=r.plan_cycles_per_layer,
                wall=time.time() - t0)


def best_of(rows):
    out = {}
    for r in rows:
        k = (r['system'], r['M'], r['scheme'], json.dumps(r['tag']))
        if k not in out or r['per_layer'] < out[k]['per_layer']:
            out[k] = r
    return out


if __name__ == '__main__':
    step2 = {(r['system'], r['M'], r['scheme']): r for r in json.load(open(sys.argv[1]))['best']}
    out = sys.argv[2] if len(sys.argv) > 2 else None
    procs = int(sys.argv[3]) if len(sys.argv) > 3 else 12

    def pick(s, M, *names):
        c = [step2[(s, M, n)] for n in names if (s, M, n) in step2]
        return min(c, key=lambda r: r['per_layer'])['kw']

    cases = [('teramonster', M) for M in (16, 64, 256, 1024)] + [('mergecast', M) for M in (16, 64, 256)]
    R, PM = (64, 16, 4, 1), (0.25, 1.0)
    jobs = []
    for s, M in cases:
        hw = pick(s, M, 'pull + placement', 'pull + placement + vector units', 'pull, weights interleaved', 'pull, weights interleaved + vector units')
        sw = pick(s, M, 'software plan + placement', 'software plan + placement + vector units', 'software plan, interleaved', 'software plan, interleaved + vector units')
        swp = pick(s, M, 'pull + placement, software delays', 'pull + placement, software delays + vector units', 'pull, software delays, interleaved')
        for rg in R:
            for pm in PM:
                for b in (250.0, 500.0, 1000.0, 2000.0, 5000.0):
                    jobs.append((s, M, 'hardware: cluster scheduler + group dispatchers', dict(hw, min_block_cycles=b, region_groups=rg, pass_min_frac=pm), HIER_HW, None))
                for b in (1000.0, 2000.0, 5000.0, 20000.0):
                    jobs.append((s, M, 'hardware: one central scheduler', dict(hw, min_block_cycles=b, region_groups=rg, pass_min_frac=pm), HIER_HW.but(central=True), None))
                    jobs.append((s, M, 'software: work stealing', dict(swp, min_block_cycles=b * 2.5, region_groups=rg, pass_min_frac=pm), HIER_SW_STEAL, None))
                    jobs.append((s, M, 'software: work stealing, no progress tracking', dict(swp, min_block_cycles=b * 2.5, region_groups=rg, pass_min_frac=pm, tile_following=False), HIER_SW_STEAL, None))
                for b in (5000.0, 20000.0, 50000.0, 200000.0):
                    jobs.append((s, M, 'software: one shared queue', dict(swp, min_block_cycles=b, region_groups=rg, pass_min_frac=pm), HIER_SW_PULL, None))
            for b in (2500.0, 5000.0, 12500.0, 50000.0):
                jobs.append((s, M, 'software: plan once, per-group lists', dict(sw, min_block_cycles=b, region_groups=rg, plan_cores=1), HIER_SW_PLAN, None))
                jobs.append((s, M, 'software: plan once, planning free', dict(sw, min_block_cycles=b, region_groups=rg, plan_cycles_per_block=0.0), HIER_SW_PLAN, None))
    t0 = time.time()
    with Pool(procs) as pool:
        rows = pool.map(run, jobs, chunksize=1)
        best = best_of(rows)
        # what the hardware has to achieve: service time of a hand-over (with group dispatchers and with one central
        # server) and of a stream decision, starting from the best hardware settings of the case
        jobs = []
        for s, M in (('teramonster', 64), ('teramonster', 1024), ('mergecast', 64)):
            hw = best[(s, M, 'hardware: cluster scheduler + group dispatchers', 'null')]['kw']
            for d in (2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0, 256.0, 512.0, 1024.0):
                for b in (500.0, 2000.0, 5000.0, 20000.0):
                    jobs.append((s, M, 'sweep: group dispatchers', dict(hw, min_block_cycles=b), HIER_HW.but(dispatch_cycles=d), d))
                    jobs.append((s, M, 'sweep: one central scheduler', dict(hw, min_block_cycles=b), HIER_HW.but(dispatch_cycles=d, central=True), d))
            for d in (16.0, 64.0, 256.0, 1024.0, 4096.0):
                for b in (500.0, 1000.0, 2000.0):
                    jobs.append((s, M, 'sweep: stream decision', dict(hw, min_block_cycles=b), HIER_HW.but(sched_cycles=d), d))
        rows += pool.map(run, jobs, chunksize=1)
    best = best_of(rows)
    print('%d runs in %.0f s' % (len(rows), time.time() - t0))
    for s, M in cases:
        ref = best[(s, M, 'hardware: cluster scheduler + group dispatchers', 'null')]['per_layer']
        print('\n%s M=%d' % (s, M))
        for (a, b, scheme, tag), r in sorted(best.items(), key=lambda kv: (kv[0][2].startswith('sweep'), kv[0][2], kv[1]['tag'] or 0)):
            if a != s or b != M:
                continue
            print('  %-48s %6s %8.0fk %5.2fx | block %6.0f | block delay %7.0f stream delay %6.0f | dispatch busy %3.0f%% scheduler busy %3.0f%%' % (
                scheme, '' if r['tag'] is None else '%g' % r['tag'], r['per_layer'] / 1e3, r['per_layer'] / ref, r['kw']['min_block_cycles'],
                r['block_delay'], r['stream_delay'], 100 * r['dispatch_busy'], 100 * r['sched_busy']) + ' region %d pass %.2f' % (r['kw'].get('region_groups', 64), r['kw'].get('pass_min_frac', 1.0)))
    if out:
        json.dump(dict(rows=rows, best=list(best.values())), open(out, 'w'))
