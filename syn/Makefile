# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Logic depth and size of the scheduler blocks with yosys (no technology library).
#
#   make depth [MODULES="tsched_run_iq ..."] [DEFS="-DTSCHED_DOM_PER_SIDE=2"]
#
# Each block is converted with sv2v and flattened. Two mappings are made:
#   depth  4-input look-up tables, whose mapper minimises depth: the longest path in LUT levels, with
#          the start and end of that path. One LUT level is about two levels of simple gates.
#   size   simple gates (two-input gates, inverters, multiplexers): number of gates and of flip-flops.
# The depth is a unit-delay figure: it ranks paths and blocks, it is not a timing result.

ROOT    := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
BENDER  ?= bender
SV2V    ?= sv2v
YOSYS   ?= yosys-0.35 yosys
BUILD   := $(ROOT)/syn/build
DEFS    ?=
MODULES ?= tsched_rename tsched_window tsched_handle_file tsched_run_iq tsched_load_issue tsched_balance \
           tsched_backend tsched_group_disp tsched_domain

.PHONY: depth clean

depth:
	@mkdir -p $(BUILD)
	@cd $(ROOT) && $(BENDER) script flist -t rtl -t synthesis | grep -E '\.sv$$' \
	  | grep -E '(cf_math_pkg|lzc|rr_arb_tree|fifo_v3|spill_register_flushable|spill_register|tsched_[a-z_0-9]*)\.sv$$' > $(BUILD)/files.f
	@printf '%-20s %6s %8s %8s   %s\n' block levels gates flops 'longest path'
	@for m in $(MODULES); do \
	  $(SV2V) -DSYNTHESIS -DTARGET_SYNTHESIS -DVERILATOR $(DEFS) --exclude=Assert --top=$$m \
	    -I$$(dirname $$(grep cf_math_pkg $(BUILD)/files.f))/../include $$(cat $(BUILD)/files.f) -w $(BUILD)/$$m.v || exit 1; \
	  $(YOSYS) -q -l $(BUILD)/$$m.lut.log -p "read_verilog $(BUILD)/$$m.v; synth -top $$m -flatten -lut 4; ltp -noff" > /dev/null 2>&1 || { tail -5 $(BUILD)/$$m.lut.log; exit 1; }; \
	  $(YOSYS) -q -l $(BUILD)/$$m.gate.log -p "read_verilog $(BUILD)/$$m.v; synth -top $$m -flatten; stat" > /dev/null 2>&1 || { tail -5 $(BUILD)/$$m.gate.log; exit 1; }; \
	  lv=$$(grep -o 'length=[0-9]*' $(BUILD)/$$m.lut.log | cut -d= -f2 | tail -1); \
	  from=$$(grep -A1 'Longest topological path' $(BUILD)/$$m.lut.log | tail -1 | awk '{print $$2,$$3}' | tr -d '\\'); \
	  to=$$(grep -E '^ +(ff|out): ' $(BUILD)/$$m.lut.log | tail -1 | awk '{print $$2,$$3}' | tr -d '\\'); \
	  cells=$$(grep 'Number of cells:' $(BUILD)/$$m.gate.log | tail -1 | awk '{print $$4}'); \
	  ff=$$(tac $(BUILD)/$$m.gate.log | awk '/Number of cells:/ {exit} /DFF/ {s+=$$2} END {print s+0}'); \
	  printf '%-20s %6s %8s %8s   %s -> %s\n' $$m "$$lv" "$$((cells-ff))" "$$ff" "$$from" "$$to"; \
	done

clean:
	rm -rf $(BUILD)
