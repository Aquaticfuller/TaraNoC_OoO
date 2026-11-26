#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Task program for the PE agent (tsched_agent): one transformer layer, one task per step, then its check.

  step        PE class  data (a load)   computes, row by row unless noted
  0  norm1    vector    X               N1 = rmsnorm(X)
  1  qkv      tensor    Wqkv            QKV = N1 @ [Wq | Wk | Wv]
  2  pack     vector                    Q, V as matrices of their own, K transposed
  3  score    tensor                    S = Q @ K^T          row r needs every row of K
  4  softmax  vector                    P = softmax(S), causal mask
  5  pv       tensor                    O = P @ V            row r needs every row of V
  6  wo       tensor    Wo              A = X + O @ Wo
  7  norm2    vector                    N2 = rmsnorm(A)
  8  gu       tensor    Wgu             GU = N2 @ [Wg | Wu]
  9  silu     vector                    M = silu(G) * U
  10 wd       tensor    Wd              Y = A + M @ Wd

Every step is one task of --blocks blocks of 128 / blocks tokens. Two ways to order them:

  --chain 0   each step waits for the whole step before (order dependency on its task)
  --chain 1   each step follows the step before block by block (chain flag), except step 3: it reads all of K, so
              it waits for the whole of step 2. The kernels pass on which block is ready through one list per step.

  --loads 1   X and the four weight matrices are loads (TLoad) into L1 slots chosen by the scheduler; the task of
              a step names its load as its data. X is released after step 0, so one domain with four slots is enough.
  --check     buffers to compare with their references after the layer: any of N1,QKV,P,O,A,N2,GU,M,Y (default Y);
              S, the scores, only with --steps 4, since the softmax works in place

usage: layer_prog.py <out dir> [--blocks 64] [--chain 0] [--check Y] [--warm 64] [--steps 11]
One line of prog.txt: op hd_v hd hs1_v hs1 follow kill hs2_v hs2 cls nblk kern arg len addr (see gen_program.py);
the follow field is 2 for a chained task.
"""
import argparse
import os

T, D, F = 128, 64, 128              # layer_T, layer_D, layer_F of the PE agent's data
LOAD, RUN, JOIN, FREE = 0, 1, 2, 3
K_SPIN, K_LAYER, K_LCHECK, K_LREPORT = 2, 12, 13, 14
CLS_T, CLS_V = 1, 2
STEPS = [('norm1', CLS_V, 'X'), ('qkv', CLS_T, 'Wqkv'), ('pack', CLS_V, None), ('score', CLS_T, None),
         ('softmax', CLS_V, None), ('pv', CLS_T, None), ('wo', CLS_T, 'Wo'), ('norm2', CLS_V, None),
         ('gu', CLS_T, 'Wgu'), ('silu', CLS_V, None), ('wd', CLS_T, 'Wd')]
WHOLE = {3}                         # steps that need the whole step before, chained or not
# load: (handle, L2 symbol, bytes rounded up to the 16 KiB a load is made of)
LOADS = {'X': (1, '@l2_LX', 16384), 'Wqkv': (2, '@l2_LWqkv', 32768), 'Wo': (3, '@l2_LWo', 16384),
         'Wgu': (4, '@l2_LWgu', 32768), 'Wd': (5, '@l2_LWd', 16384)}
CHECKS = {'N1': (0, T * D), 'QKV': (1, T * 3 * D), 'P': (2, T * T), 'O': (3, T * D), 'A': (4, T * D), 'N2': (5, T * D),
          'GU': (6, T * 2 * F), 'M': (7, T * F), 'Y': (8, T * D), 'S': (9, T * T)}

ap = argparse.ArgumentParser()
ap.add_argument('out')
ap.add_argument('--blocks', type=int, default=64)
ap.add_argument('--chain', type=int, default=0, choices=(0, 1))
ap.add_argument('--check', default='Y')
ap.add_argument('--warm', type=int, default=64)
ap.add_argument('--steps', type=int, default=len(STEPS), help='run only the first steps (S can be checked after 4)')
a = ap.parse_args()
assert T % a.blocks == 0
rows = T // a.blocks

L = []


def ins(op, hd=None, hs1=None, follow=0, kill=0, hs2=None, cls=0, nblk=0, kern=0, arg=0, length=0, addr='0'):
    L.append(' '.join(str(x) for x in (op, int(hd is not None), hd or 0, int(hs1 is not None), hs1 or 0, follow, kill,
                                       int(hs2 is not None), hs2 or 0, cls, nblk, kern, arg, length, addr)))


if a.warm:
    ins(RUN, hd=7, cls=CLS_T, nblk=a.warm, kern=K_SPIN)
    ins(JOIN, hd=8, arg=1)
H0 = 10                             # handle of step s: H0 + s
ins(LOAD, hd=LOADS['X'][0], length=LOADS['X'][2], addr=LOADS['X'][1])
for s, (name, cls, data) in enumerate(STEPS[:a.steps]):
    if data and data != 'X':
        ins(LOAD, hd=LOADS[data][0], length=LOADS[data][2], addr=LOADS[data][1])
    chained = a.chain and s > 0 and s not in WHOLE
    leaves = a.chain and s + 1 < a.steps and (s + 1) not in WHOLE
    arg = rows | (s << 8) | (int(chained) << 12) | (int(leaves) << 13) | ((s - 1 if chained else 0) << 16)
    ins(RUN, hd=H0 + s, hs1=LOADS[data][0] if data else None, follow=2 if chained else 0, hs2=H0 + s - 1 if s else None,
        cls=cls, nblk=a.blocks, kern=K_LAYER, arg=arg)
    if data:
        ins(FREE, hs1=LOADS[data][0])       # released when the task that uses it is done
ins(JOIN, hd=6)
h, prev = 22, 6
for name in a.check.split(','):
    # One check after the other: the check blocks leave their counts in one set of places.
    cid, elems = CHECKS[name]
    parts = min(64, elems // 512)
    ins(RUN, hd=h, hs2=prev, cls=CLS_T, nblk=parts, kern=K_LCHECK, arg=cid)
    ins(JOIN, hd=h + 1)
    ins(RUN, hd=h + 2, hs2=h + 1, cls=CLS_T, nblk=1, kern=K_LREPORT, arg=parts | (cid << 8))
    ins(JOIN, hd=h + 3)
    prev = h + 3
    h = 22 if h == 26 else 26           # two sets of handles in turn; the scheduler renames them

os.makedirs(a.out, exist_ok=True)
with open(os.path.join(a.out, 'prog.txt'), 'w') as f:
    f.write('\n'.join(L) + '\n')
print('%s: %d instructions; %d steps x %d blocks x %d rows, %s; checks: %s'
      % (a.out, len(L), a.steps, a.blocks, rows, 'chained' if a.chain else 'each step waits for the step before', a.check))
