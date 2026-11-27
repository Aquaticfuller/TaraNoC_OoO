#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Task program for the PE agent (tsched_agent): one matrix task Z = X@W + Y on a loaded tile, then its check.

The program, in order
  warm-up     --warm blocks of a counting loop on the tensor engines, then a join the host waits for
  loads       --place loads that only move the placement on, then the load of X (blocks * rows rows of it)
  matrix      one TRun of --blocks blocks of --rows rows each, for the PE types --cls, with speed hint --vslow;
              it follows the load and releases it
  placeholder --spare blocks of a counting loop on the vector units, at the same time (0: none)
  check       blocks of 512 elements that compare the result with the reference, then one block that reports

usage: gemm_prog.py <out dir> [--blocks 32] [--rows 4] [--cls 1] [--vslow 0] [--warm 64] [--place 0] [--spare 0]
       [--shared 0..3]  (with --cls 2 and --blocks = vector units of the domain; blocks * rows = 8 * tiles)
       cls: 1 tensor engines, 2 vector units, 3 both. vslow (cls 3 only): a block takes about 2^vslow times as
       long on a vector unit; 0 gives no hint.
One line of prog.txt: op hd_v hd hs1_v hs1 follow kill hs2_v hs2 cls nblk kern arg len addr (see gen_program.py).
"""
import argparse
import os

COLS = 64               # matrix_N and matrix_P of the PE agent's data
CHECK_ELEMS = 512       # elements one check block compares
LOAD, RUN, JOIN, FREE = 0, 1, 2, 3
K_GEMM, K_SPIN, K_CHECK, K_REPORT = 1, 2, 3, 4

ap = argparse.ArgumentParser()
ap.add_argument('out')
ap.add_argument('--blocks', type=int, default=32)
ap.add_argument('--rows', type=int, default=4)
ap.add_argument('--cls', type=int, default=1, choices=(1, 2, 3))
ap.add_argument('--vslow', type=int, default=0, choices=(0, 1, 2, 3))
ap.add_argument('--warm', type=int, default=64)
ap.add_argument('--place', type=int, default=0)
ap.add_argument('--spare', type=int, default=0)
ap.add_argument('--shared', type=int, choices=(0, 1, 2, 3), help='projection shared by the Spatz units of a group (kernel 15): '
                'one block per vector unit, 8 rows per tile; 1 merges the single words, 2 the bursts, 3 both')
a = ap.parse_args()
assert a.vslow == 0 or a.cls == 3, 'a speed hint needs a task for both PE types'

rows = a.blocks * a.rows
nbytes = rows * COLS * 2
elems = rows * COLS
parts = elems // CHECK_ELEMS
assert nbytes % 16384 == 0 and 1 <= parts <= 64 and elems % CHECK_ELEMS == 0

L = []


def ins(op, hd=None, hs1=None, follow=0, kill=0, hs2=None, cls=0, nblk=0, kern=0, arg=0, length=0, addr='0'):
    L.append(' '.join(str(x) for x in (op, int(hd is not None), hd or 0, int(hs1 is not None), hs1 or 0, follow, kill,
                                       int(hs2 is not None), hs2 or 0, cls, nblk, kern, arg, length, addr)))


if a.warm:
    ins(RUN, hd=7, cls=1, nblk=a.warm, kern=K_SPIN)
    ins(JOIN, hd=8, arg=1)
extra = [11 + i for i in range(a.place)]
for h in extra:
    ins(LOAD, hd=h, length=16384, addr='@l2_X')
ins(LOAD, hd=1, length=nbytes, addr='@l2_X')
ins(RUN, hd=2, hs1=1, follow=1, kill=1, cls=a.cls | (a.vslow << 2), nblk=a.blocks, kern=15 if a.shared is not None else K_GEMM, arg=a.shared if a.shared is not None else a.rows)
for h in extra:
    ins(FREE, hs1=h)
if a.spare:
    ins(RUN, hd=3, cls=2, nblk=a.spare, kern=K_SPIN)
ins(JOIN, hd=4)
ins(RUN, hd=5, hs2=4, cls=1, nblk=parts, kern=K_CHECK, arg=elems)
ins(JOIN, hd=6)
ins(RUN, hd=9, hs2=6, cls=1, nblk=1, kern=K_REPORT, arg=parts | (elems << 8))
ins(JOIN, hd=10)

os.makedirs(a.out, exist_ok=True)
with open(os.path.join(a.out, 'prog.txt'), 'w') as f:
    f.write('\n'.join(L) + '\n')
print('%s: %d instructions; matrix task of %d blocks x %d rows, load of %d bytes, %d check blocks' % (a.out, len(L), a.blocks, a.rows, nbytes, parts))
