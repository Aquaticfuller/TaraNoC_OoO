#!/bin/bash
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Gate and flip-flop counts of blocks of the cluster hardware (one TeraMonster tile and what is in it), with the
# flow of syn/Makefile (sv2v, then yosys `synth -top <m> -flatten; stat`), to compare the scheduler with.
#
# usage: scripts/ref_sizes.sh prep                      file lists and the tile converted to Verilog (syn/build/ref)
#        scripts/ref_sizes.sh list                      names of the elaborated modules (to pick <module> from)
#        scripts/ref_sizes.sh synth <module> <tag> [0]  one block, with the parameters the tile gives it; a line in
#                                                       syn/build/ref/results.txt. Last argument 0: the tile
#                                                       without its tensor engine (RedMulE = 0).
# Needs sim/build/c4/compilevcs.sh (written by `make -f domain.mk hw CONFIG=cluster_4x4`): files, include
# directories and defines of the cluster are taken from it.
#
# What differs from the scheduler's flow, and why:
#  - Sources are not changed; three copies in the build directory are: mempool_tile.sv with RedMulE = 1 as its
#    default (the group sets it per tile), axi_pkg.sv without a typedef inside a function (sv2v cannot parse
#    it), mempool.svh with struct ports kept as structs when VERILATOR is defined.
#  - The converted Verilog is edited for what yosys 0.35 cannot read (fix()): left-over assertions and
#    simulation tasks, references through the inlined interfaces of RedMulE, one loop with a signal as bound.
#  - `unique casez` on the instruction word (Snitch, Spatz decoder) gets (* parallel_case *): sv2v drops `unique`,
#    and without it yosys' proc_mux does not finish these decoders in hours.
#  - tc_sram (the L1 banks of a tile) is a black box: memory macros are not counted.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
R=$ROOT/syn/build/ref
VCS=$ROOT/sim/build/c4/compilevcs.sh
YOSYS=${YOSYS:-yosys-0.35 yosys}
mkdir -p $R/incp/mempool

fix() {  # <file.v>
  sed -i -E '/^\s*assert \(.*\) else \$(fatal|error|warning|display)\(.*\);\s*$/d' $1
  sed -i -E '/^\s*assert property \(/,/^\s*\) ;\s*$/d' $1
  sed -i -E 's/= \{<< 1\{(.*)\}\};$/= \1;/' $1                           # ECC modules, not elaborated
  sed -i -E 's/sv2v_cast_144\((\w+)\[143-:144\]\)\[/\1[/g' $1            # part select of a cast
  sed -i 's|for (i = 0; i <= z_height; i = i + 1)$|for (i = 0; i < D; i = i + 1) if (i <= z_height)|' $1
  sed -i -E '/^\s*\$timeformat\(.*\);\s*$/d' $1
  sed -i -E 's/^(\s*)\$(warning|error|fatal|info)\(.*\);\s*$/\1;/' $1
  sed -i 's|^module tc_sram ($|(* blackbox *) module tc_sram (|' $1
  sed -i -E 's/^(\s*)casez \((inst_data_i\)|decoder_req_i\[)/\1(* parallel_case *) casez (\2/' $1
  python3 - $1 <<'EOF'
import re, sys
f, top = sys.argv[1], 'mempool_tile'
s = open(f).read()
i = s.index('\nmodule %s (' % top)
head, body = s[:i], s[i:]
body = re.sub(r'[A-Za-z_][\w.\[\]]*\.(hci_package_iomsb|hwpe_stream_package_iomsb)\(', r'\1(', body)
body = re.sub(r'\b%s\.(?=[A-Za-z_])' % top, '', body)
j = body.index(');') + 2
fn = ''.join("\n\tfunction automatic [31:0] %s;\n\t\tinput reg [31:0] width;\n\t\t%s = (width != 32'd0 ? $unsigned(width - 1) : 32'd0);\n\tendfunction" % (n, n)
             for n in ('hci_package_iomsb', 'hwpe_stream_package_iomsb'))
open(f, 'w').write(head + body[:j] + fn + body[j:])
EOF
}

case "$1" in
prep)
  test -f $VCS || { echo "missing $VCS"; exit 1; }
  grep -o '"\$ROOT[^"]*\.s\?v"' $VCS | tr -d '"' | sed "s|\$ROOT|$ROOT|" \
    | grep -v -E 'hardware/tb/|common_verification|cv32e40|/sys/tb/|/sys/src/|/hw/src/tsched|/hw/tb/|dram_rtl_sim|l2_tcdm_hybrid_interco' \
    | grep -v -E 'HMR_wrap|pad_functional|apb_test|axi_chan_compare|axi_sim_mem|axi_test|reqrsp_test|periph_to_reg|hci_ecc_interconnect' \
    | grep -v -E 'mempool_group|cluster_floonoc_wrapper|mempool_system|ctrl_registers|mempool_idma_group|axi_hier_interco|axi_L2_interleaver|bootrom\.sv' \
    | awk '!s[$0]++' > $R/all.f
  (echo "-I$R/incp"; grep -o '+incdir+[^"]*' $VCS | sort -u | sed "s|+incdir+\$ROOT|-I$ROOT|") > $R/inc.f
  (grep -o '"+define+[^"]*"' $VCS | tr -d '"' | sort -u | grep -v -E 'TARGET_SIMULATION|TARGET_VCS|TARGET_MEMPOOL_VSIM|PROFILING|SNITCH_TRACE|TARGET_RTL' \
    | sed 's|+define+|-D|'; echo -DPOSTLAYOUT) > $R/def.f
  printf '`ifndef MEMPOOL_SVH_\n`define MEMPOOL_SVH_\n`define STRUCT_PORT(struct_t) struct_t\n`define STRUCT_VECT(struct_t, dim) struct_t dim\n`endif\n' > $R/incp/mempool/mempool.svh
  A=$(grep '/src/axi_pkg.sv$' $R/all.f)
  sed -e '/typedef shortint unsigned SU;/d' -e "s/SU'(/16'(/g" $A > $R/axi_pkg_p.sv
  T=$ROOT/working_dir/mempool/hardware/src/mempool_tile.sv
  sed "s|RedMulE      = 1.b0|RedMulE      = 1'b1|" $T > $R/mempool_tile_rm.sv
  sed -e "s|^$A\$|$R/axi_pkg_p.sv|" -e "s|^$T\$|$R/mempool_tile_rm.sv|" $R/all.f > $R/files1.f
  sed -e "s|^$A\$|$R/axi_pkg_p.sv|" $R/all.f > $R/files0.f
  for k in 1 0; do
    sv2v -DSYNTHESIS -DTARGET_SYNTHESIS -DVERILATOR $(tr '\n' ' ' < $R/def.f) --exclude=Assert --top=mempool_tile \
      $(tr '\n' ' ' < $R/inc.f) $(tr '\n' ' ' < $R/files$k.f) -w $R/tile$k.v > $R/sv2v$k.log 2>&1 || { grep -v Warning $R/sv2v$k.log | tail -5; exit 1; }
    fix $R/tile$k.v
  done
  ls -la $R/tile1.v $R/tile0.v ;;
list)
  $YOSYS -q -l $R/list.log -p "read_verilog -defer $R/tile1.v; hierarchy -top mempool_tile; ls" > /dev/null 2>&1
  awk '/modules:$/{f=1;next} f&&NF==1{print $1}' $R/list.log ;;
synth)
  m=$2; tag=$3; v=$R/tile${4:-1}.v
  timeout ${TMO:-14400} $YOSYS -q -l $R/$tag.gate.log -p "read_verilog -defer $v; hierarchy -top mempool_tile; synth -top $m -flatten; stat" > /dev/null 2>&1 || true
  cells=$(grep 'Number of cells:' $R/$tag.gate.log | tail -1 | awk '{print $4}')
  ff=$(tac $R/$tag.gate.log | awk '/Number of cells:/ {exit} /DFF/ {s+=$2} END {print s+0}')
  other=$(tac $R/$tag.gate.log | awk '/Number of cells:/ {exit} /tc_sram|DLATCH/ {printf "%s=%s ", $1, $2}')
  echo "$tag cells=$cells flops=$ff gates=$((cells-ff)) (gates include: $other) $(grep -m1 ERROR $R/$tag.gate.log | cut -c1-160)" | tee -a $R/results.txt ;;
*)
  sed -n '6,24p' "$0" ;;
esac
