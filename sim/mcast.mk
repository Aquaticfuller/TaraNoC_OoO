# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Unit test of a merge slice (package `mcast`) with VCS.
#
#   make -f mcast.mk compile CFG=<name> DEFS="+define+TB_NUM_REQ=2 +define+TB_DATAW=32"
#   make -f mcast.mk run     CFG=<name> ARGS="+SEED=3 +REPEAT=2"
#
# A new set of DEFS needs a new CFG name: the build is not redone when only DEFS change.

ROOT    := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
BENDER  ?= bender
VCS     ?= vcs-2025.06
CFG     ?= mc4
DEFS    ?=
ARGS    ?=
LOG_MAX ?= 20000000
BUILD   := $(ROOT)/sim/build/mcast_$(CFG)

.PHONY: compile run
compile: $(BUILD)/simv

$(BUILD)/simv: $(wildcard $(ROOT)/mcast/src/*.sv) $(wildcard $(ROOT)/mcast/tb/*.sv)
	mkdir -p $(BUILD)
	cd $(ROOT)/mcast && $(BENDER) script vcs --vlogan-bin="$(VCS) vlogan" \
	  --vlog-arg="-assert svaext +v2k -override_timescale=1ns/1ps -nc $(DEFS)" -t rtl -t test > $(BUILD)/compile.sh
	cd $(BUILD) && bash compile.sh > compile.log 2>&1 || (tail -30 compile.log; false)
	cd $(BUILD) && $(VCS) vcs -full64 -nc tb_mcast_slice -assert disable_cover -o simv > elab.log 2>&1 || (tail -30 elab.log; false)

run: $(BUILD)/simv
	cd $(BUILD) && ./simv -nc -no_save -assert global_finish_maxfail=20 $(ARGS) 2>&1 | head -c $(LOG_MAX) > run.log; \
	  grep -E 'RESULT|PASS|FAIL|rror' run.log | head -20
