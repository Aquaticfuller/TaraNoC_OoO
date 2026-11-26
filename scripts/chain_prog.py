#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Task program for the PE agent (tsched_agent): a chain of three kernels over one matrix, then its check.

  stage 1  Z  = X@W + Y          a projection, on the tensor engines            (kernel 1)
  stage 2  P  = softmax(Z)       row by row, on the vector units, over stage 1  (kernel 9)
  stage 3  Z2 = P@W + Y          a second projection, on the tensor engines     (kernel 10)

Block b of every stage works on the same rows, so block b of a stage needs only block b of the stage before.
Three ways to say that:

  --cut 1   three tasks of --blocks blocks; each stage waits for the whole stage before (hs2)
  --cut C   C chains of three tasks of blocks/C blocks each; a stage of one chain waits for the stage before of
            the same chain only
  --follow 1  stages 2 and 3 carry the chain flag: the scheduler releases their k-th block when k blocks of the
            stage before are done. The kernels pass on which blocks those were (lists in L1, see the PE agent):
            stage 1 leaves its block in list 1, stage 2 takes from list 1 and leaves in list 2, stage 3 takes
            from list 2. Can be combined with --cut.

  --order chain  the tasks of one chain follow each other in the program (stage 1, 2, 3 of chain 0, then chain 1 ...)
  --order stage  all tasks of stage 1 first, then all of stage 2, then all of stage 3

usage: chain_prog.py <out dir> [--blocks 128] [--rows 4] [--cut 1] [--follow 0] [--order chain] [--warm 64] [--home 0]
                     [--wload 0]
       --wload 1: stage 3 has weights of its own: a second TLoad brings W into a slot, which the scheduler
       places where it finds room (another domain when there are several), and stage 3 names it as its data
       --home 1: stages 2 and 3 name the load as their data too, so they are issued to the domain of stage 1
One line of prog.txt: op hd_v hd hs1_v hs1 follow kill hs2_v hs2 cls nblk kern arg len addr (see gen_program.py);
the follow field is 2 for a chained task.
"""
import argparse
import os

COLS = 64               # matrix_N and matrix_P of the PE agent's data
CHECK_ELEMS = 512       # elements one check block compares
LOAD, RUN, JOIN, FREE = 0, 1, 2, 3
K_GEMM, K_SPIN, K_REPORT, K_SOFTMAX, K_GEMM2, K_CHECK2 = 1, 2, 4, 9, 10, 11
CLS_T, CLS_V = 1, 2

ap = argparse.ArgumentParser()
ap.add_argument('out')
ap.add_argument('--blocks', type=int, default=128)
ap.add_argument('--rows', type=int, default=4)
ap.add_argument('--cut', type=int, default=1)
ap.add_argument('--order', default='chain', choices=('chain', 'stage'))
ap.add_argument('--warm', type=int, default=64)
ap.add_argument('--home', type=int, default=0, choices=(0, 1))
ap.add_argument('--follow', type=int, default=0, choices=(0, 1))
ap.add_argument('--wload', type=int, default=0, choices=(0, 1))
a = ap.parse_args()

rows = a.blocks * a.rows
nbytes = rows * COLS * 2
elems = rows * COLS
parts = elems // CHECK_ELEMS
per = a.blocks // a.cut
assert a.blocks % a.cut == 0 and a.rows < 256 and a.blocks < 65536
assert nbytes % 16384 == 0 and 1 <= parts <= 64 and elems % CHECK_ELEMS == 0

L = []


def ins(op, hd=None, hs1=None, follow=0, kill=0, hs2=None, cls=0, nblk=0, kern=0, arg=0, length=0, addr='0'):
    L.append(' '.join(str(x) for x in (op, int(hd is not None), hd or 0, int(hs1 is not None), hs1 or 0, follow, kill,
                                       int(hs2 is not None), hs2 or 0, cls, nblk, kern, arg, length, addr)))


H_LOAD, H_W = 1, 2
# Handles of the three stages of a chain. With --order chain the next chain defines the same three again (the
# scheduler renames them); with --order stage every chain needs its own.
if a.order == 'chain':
    hnd = [(20, 21, 22)] * a.cut
else:
    assert 3 * a.cut <= 20, 'not enough handle registers for this cut in stage order'
    hnd = [(12 + 3 * c, 13 + 3 * c, 14 + 3 * c) for c in range(a.cut)]


def stage(c, s):
    arg = a.rows | ((c * per) << 8)
    h = hnd[c]
    data = H_LOAD if (s == 0 or a.home) else None
    if s == 2 and a.wload:
        data = H_W
    f = 2 * a.follow                    # the chain flag, in the follow field
    take, leave = (lambda n: (n << 24) * a.follow), (lambda n: (n << 26) * a.follow)
    if s == 0:
        ins(RUN, hd=h[0], hs1=H_LOAD, cls=CLS_T, nblk=per, kern=K_GEMM, arg=arg | leave(1))
    elif s == 1:
        ins(RUN, hd=h[1], hs1=data, follow=f, hs2=h[0], cls=CLS_V, nblk=per, kern=K_SOFTMAX, arg=arg | take(1) | leave(2))
    else:
        ins(RUN, hd=h[2], hs1=data, follow=f, hs2=h[1], cls=CLS_T, nblk=per, kern=K_GEMM2, arg=arg | take(2))


if a.warm:
    ins(RUN, hd=7, cls=CLS_T, nblk=a.warm, kern=K_SPIN)
    ins(JOIN, hd=8, arg=1)
ins(LOAD, hd=H_LOAD, length=nbytes, addr='@l2_X')
if a.wload:
    ins(LOAD, hd=H_W, length=16384, addr='@l2_W')      # W is 8 KiB; a load is a multiple of 16 KiB
if a.order == 'chain':
    for c in range(a.cut):
        for s in range(3):
            stage(c, s)
else:
    for s in range(3):
        for c in range(a.cut):
            stage(c, s)
ins(JOIN, hd=4)
ins(FREE, hs1=H_LOAD)
if a.wload:
    ins(FREE, hs1=H_W)
ins(RUN, hd=5, hs2=4, cls=CLS_T, nblk=parts, kern=K_CHECK2, arg=elems)
ins(JOIN, hd=6)
ins(RUN, hd=9, hs2=6, cls=CLS_T, nblk=1, kern=K_REPORT, arg=parts | (elems << 8))
ins(JOIN, hd=10)

os.makedirs(a.out, exist_ok=True)
with open(os.path.join(a.out, 'prog.txt'), 'w') as f:
    f.write('\n'.join(L) + '\n')
print('%s: %d instructions; %d chain(s) of 3 tasks x %d blocks x %d rows, load of %d bytes, %d check blocks'
      % (a.out, len(L), a.cut, per, a.rows, nbytes, parts))
