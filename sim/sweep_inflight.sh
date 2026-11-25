#!/bin/sh
# Time of one load on the real DMA engines for several numbers of chunks in flight per engine.
cd "$(dirname "$0")"
for k in "$@"; do
  make -f domain.mk hw BUILD=$PWD/build/dom_k$k DEFS=+define+TSCHED_DMA_IN_FLIGHT=$k > build_k$k.log 2>&1 || { echo "k=$k build failed"; continue; }
  make -f domain.mk run BUILD=$PWD/build/dom_k$k DEFS=+define+TSCHED_DMA_IN_FLIGHT=$k PROG=$PWD/../sys/prog/load ARGS=+TRACE > run_k$k.log 2>&1
  grep -E "\] T |RESULT|PASS|FAIL" build/dom_k$k/transcript > prog/load_trace_k$k.txt
  echo "k=$k $(grep -E 'first_chunk|PASS|FAIL' prog/load_trace_k$k.txt | tr '\n' ' ')"
done
