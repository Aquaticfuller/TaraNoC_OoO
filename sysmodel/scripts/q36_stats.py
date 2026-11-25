"""What the Qwen3.6-35B-A3B routing trace looks like at the batch sizes the scheduler sees.

usage: python3 -I scripts/q36_stats.py [json_out]
"""
import json
import os
import sys

import numpy as np

here = os.path.dirname(os.path.abspath(__file__))
D = os.path.join(here, '..', '..', 'moe_study', 'traces', 'q36')
ex = np.load(D + '/experts.npy', mmap_mode='r', allow_pickle=False)
ri = np.load(D + '/req_index.npy', allow_pickle=False)
ph = np.load(D + '/phase.npy', allow_pickle=False)
se = np.load(D + '/session_index.npy', allow_pickle=False)
names = json.load(open(D + '/sessions.json'))['names_by_session_index']
T, L, K = ex.shape
E = 256
b = np.flatnonzero(np.diff(ri)) + 1
runs = list(zip(np.r_[0, b].tolist(), np.r_[b, T].tolist()))
rng = np.random.RandomState(1)
out = {}

# 1. global popularity per layer (every 4th token is enough)
glob = np.zeros((L, E))
sub = np.asarray(ex[::4])
for l in range(L):
    glob[l] = np.bincount(sub[:, l].ravel(), minlength=E)
gtop = np.argsort(-glob, axis=1)[:, :E // 10]
gshare = np.sort(glob, axis=1)[:, ::-1][:, :E // 10].sum(1) / glob.sum(1)
print('global: busiest 10%% of experts carry %.1f%% of activations (mean over layers), min %.1f max %.1f' % (100 * gshare.mean(), 100 * gshare.min(), 100 * gshare.max()))
out['global_top10'] = gshare.round(3).tolist()

# 2. windows of M consecutive prompt tokens
def windows(M, n):
    ok = [(a, z) for a, z in runs if z - a >= M]
    w = []
    for i in range(n):
        a, z = ok[rng.randint(len(ok))]
        o = a + rng.randint(z - a - M + 1)
        w.append((o, np.asarray(ex[o:o + M])))
    return w

print('\nM      requests  experts/layer (min-max over layers)   tokens/expert   share of token-experts on experts with 1 | 2-7 | 8-31 | >=32 tokens   own top10%  global top10%  prev-window top10%')
out['batch'] = []
for M in (1, 4, 16, 64, 256, 1024, 2048, 4096):
    n = 60 if M <= 256 else 30
    W = windows(M, n)
    act = np.zeros((n, L)); sh = np.zeros((n, L, 4)); own = np.zeros((n, L)); gl = np.zeros((n, L)); pv = []
    for i, (o, w) in enumerate(W):
        for l in range(L):
            c = np.bincount(w[:, l].ravel(), minlength=E)
            act[i, l] = (c > 0).sum()
            tot = c.sum()
            sh[i, l] = [c[c == 1].sum() / tot, c[(c >= 2) & (c <= 7)].sum() / tot, c[(c >= 8) & (c <= 31)].sum() / tot, c[c >= 32].sum() / tot]
            own[i, l] = np.sort(c)[::-1][:E // 10].sum() / tot
            gl[i, l] = c[gtop[l]].sum() / tot
        # the window before it in the same request, if there is one
        if o - M >= 0 and ri[o - M] == ri[o]:
            p = np.asarray(ex[o - M:o])
            for l in range(0, L, 4):
                cp = np.bincount(p[:, l].ravel(), minlength=E)
                c = np.bincount(w[:, l].ravel(), minlength=E)
                pv.append(c[np.argsort(-cp)[:E // 10]].sum() / c.sum())
    al = act.mean(0)
    s = sh.mean((0, 1))
    row = dict(M=M, windows=n, experts=round(float(act.mean()), 1), experts_min_layer=round(float(al.min()), 1), experts_max_layer=round(float(al.max()), 1),
               experts_p10=round(float(np.percentile(act, 10)), 1), experts_p90=round(float(np.percentile(act, 90)), 1),
               share=[round(float(x), 3) for x in s], own_top10=round(float(own.mean()), 3), global_top10=round(float(gl.mean()), 3),
               prev_top10=round(float(np.mean(pv)), 3) if pv else None, experts_by_layer=al.round(1).tolist())
    out['batch'].append(row)
    print('%-6d %4d      %6.1f (%5.1f-%5.1f)                   %6.1f          %4.0f%% | %4.0f%% | %4.0f%% | %4.0f%%                         %4.0f%%       %4.0f%%          %s' % (
        M, n, row['experts'], row['experts_min_layer'], row['experts_max_layer'], M * K / row['experts'], 100 * s[0], 100 * s[1], 100 * s[2], 100 * s[3],
        100 * row['own_top10'], 100 * row['global_top10'], '%4.0f%%' % (100 * row['prev_top10']) if pv else '-'))

# 3. by category at 256 tokens
print('\n256-token windows by category: distinct experts per layer, own top-10% share')
out['category'] = []
for ci, nm in enumerate(names):
    ok = [(a, z) for a, z in runs if z - a >= 256 and se[a] == ci]
    if not ok:
        print('  %-12s no request with 256 tokens' % nm)
        continue
    a_, o_ = [], []
    for i in range(30):
        a, z = ok[rng.randint(len(ok))]
        o = a + rng.randint(z - a - 255)
        w = np.asarray(ex[o:o + 256])
        for l in range(L):
            c = np.bincount(w[:, l].ravel(), minlength=E)
            a_.append((c > 0).sum()); o_.append(np.sort(c)[::-1][:E // 10].sum() / c.sum())
    print('  %-12s %3d requests   %.1f experts   %.0f%%' % (nm, len(ok), np.mean(a_), 100 * np.mean(o_)))
    out['category'].append(dict(name=nm, requests=len(ok), experts=round(float(np.mean(a_)), 1), own_top10=round(float(np.mean(o_)), 3)))

# 4. decode: does a response token reuse the experts of the tokens before it (same layer)?
resp = np.flatnonzero((ph[1:] == 1) & (ri[1:] == ri[:-1])) + 1
pick = resp[rng.choice(len(resp), 3000, replace=False)]
print('\ndecode (response tokens): of the 8 experts of a token, how many were used by the previous h tokens in the same layer')
out['decode_reuse'] = []
for h in (1, 4, 16, 64):
    v = []
    for t in pick:
        if t - h < 0 or ri[t - h] != ri[t]:
            continue
        cur = np.asarray(ex[t]); past = np.asarray(ex[t - h:t])
        for l in range(0, L, 4):
            v.append(np.isin(cur[l], past[:, l]).mean())
    print('  h=%-3d %.0f%%   (distinct experts in those h tokens: -)' % (h, 100 * np.mean(v)))
    out['decode_reuse'].append([h, round(float(np.mean(v)), 3)])
if len(sys.argv) > 1:
    json.dump(out, open(sys.argv[1], 'w'))
