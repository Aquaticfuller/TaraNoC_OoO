#!/usr/bin/env python3
"""Resolve the symbols of a task program against the linked PE program.

usage: link_prog.py <prog.txt> <elf> <out dir>

A field of prog.txt may be `@name`: the address of symbol `name` in the ELF (for example the L2 address of the
data of a TLoad). Writes <out dir>/prog.txt with numbers only, and prints the simulator arguments the program
needs: +SLOT_BASE=<address of l1_slot> if the PE program reserves L1 slots, +DMA_MODEL otherwise.
"""
import os
import subprocess
import sys

src, elf, out = sys.argv[1:4]
sym = {}
for line in subprocess.run(['nm', elf], capture_output=True, text=True, check=True).stdout.splitlines():
    f = line.split()
    if len(f) == 3:
        sym[f[2]] = int(f[0], 16)
os.makedirs(out, exist_ok=True)
with open(src) as fi, open(os.path.join(out, 'prog.txt'), 'w') as fo:
    for line in fi:
        fo.write(' '.join(str(sym[t[1:]]) if t.startswith('@') else t for t in line.split()) + '\n')
print('+SLOT_BASE=%x' % sym['l1_slot'] if 'l1_slot' in sym else '+DMA_MODEL')
