#!/usr/bin/env python3
"""Resolve the symbols of a task program against the linked PE program.

usage: link_prog.py <prog.txt> <elf> <out dir>

A field of prog.txt may be `@name` or `@name+<bytes>`: the address of symbol `name` in the ELF, plus an offset (for
example the L2 address of the data of a TLoad). Writes <out dir>/prog.txt with numbers only, and prints the
simulator arguments the program needs: +SLOT_BASE=<address of l1_slot> if the PE program reserves L1 slots,
+DMA_MODEL otherwise. On any error nothing is left in <out dir>/prog.txt and the exit status is not zero.
"""
import os
import subprocess
import sys

src, elf, out = sys.argv[1:4]
dst = os.path.join(out, 'prog.txt')
os.makedirs(out, exist_ok=True)
if os.path.exists(dst):
    os.remove(dst)
sym = {}
nm = subprocess.run(['nm', elf], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, check=True)
for line in nm.stdout.splitlines():
    f = line.split()
    if len(f) == 3:
        sym[f[2]] = int(f[0], 16)


def field(t):
    if not t.startswith('@'):
        int(t)                      # a field is a number or a symbol
        return t
    name, _, off = t[1:].partition('+')
    if name not in sym:
        sys.exit('link_prog: %s has no symbol %s' % (elf, name))
    return str(sym[name] + (int(off, 0) if off else 0))


lines = []
for n, line in enumerate(open(src), 1):
    f = line.split()
    if not f:
        continue
    if len(f) != 15:
        sys.exit('link_prog: %s line %d has %d fields, not 15' % (src, n, len(f)))
    lines.append(' '.join(field(t) for t in f))
with open(dst + '.tmp', 'w') as fo:
    fo.write('\n'.join(lines) + '\n')
os.replace(dst + '.tmp', dst)
print('+SLOT_BASE=%x' % sym['l1_slot'] if 'l1_slot' in sym else '+DMA_MODEL')
