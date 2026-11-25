# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# RTL simulation of the task scheduler alone (package `tsched` in hw/) with VCS.
#
#   make compile CFG=<name> DEFS="+define+..."   build sim/build/<name>/simv
#   make run     CFG=<name> PROG=<dir> [ARGS=..] run one program, log in <dir>/sim_<name>.log
#   make clean                                   remove every build directory
#
# CFG names a build: one set of defines (sizes of tsched_pkg, testbench switches). Examples
#   make compile CFG=full
#   make compile CFG=small DEFS="+define+TSCHED_DOM_PER_SIDE=2"
#   make compile CFG=bound DEFS="+define+TB_NO_LEND"

ROOT    := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
BENDER  ?= bender
VCS     ?= vcs-2025.06
CFG     ?= full
DEFS    ?=
PROG    ?=
ARGS    ?=
# A run that goes wrong must not fill the disk: the log is cut at this many bytes.
LOG_MAX ?= 20000000
BUILD   := $(ROOT)/sim/build/$(CFG)

VLOGAN_ARGS := -assert svaext +v2k -override_timescale=1ns/1ps -nc $(DEFS)

.PHONY: compile run clean

compile: $(BUILD)/simv

$(BUILD)/simv: $(wildcard $(ROOT)/hw/src/*.sv) $(wildcard $(ROOT)/hw/tb/*.sv) $(ROOT)/hw/Bender.yml
	mkdir -p $(BUILD)
	cd $(ROOT)/hw && $(BENDER) script vcs --vlogan-bin="$(VCS) vlogan" --vlog-arg="$(VLOGAN_ARGS)" -t rtl -t test > $(BUILD)/compile.sh
	cd $(BUILD) && bash compile.sh > compile.log 2>&1 || (tail -30 compile.log; false)
	cd $(BUILD) && $(VCS) vcs -full64 -nc tb_tsched -assert disable_cover -o simv > elab.log 2>&1 || (tail -30 elab.log; false)

run: $(BUILD)/simv
	@test -n "$(PROG)" || (echo "PROG=<directory with prog.txt> is required"; false)
	cd $(BUILD) && ./simv -nc -no_save -assert global_finish_maxfail=20 +DIR=$(abspath $(PROG)) $(ARGS) 2>&1 \
	  | head -c $(LOG_MAX) > $(abspath $(PROG))/sim_$(CFG).log; \
	  grep -E 'RESULT|PASS|FAIL|ERROR|rror' $(abspath $(PROG))/sim_$(CFG).log | head -40

# Random regression: SEEDS programs of PIECES instructions each for the build CFG. SIDE (domains per side)
# and SLOTS (slots per domain) must match the defines of that build. Every seed reuses one directory;
# a failing seed is copied next to it.
SEEDS  ?= 20
PIECES ?= 300
SIDE   ?= 4
SLOTS  ?= 4
RDIR   := $(ROOT)/sim/prog/regress_$(CFG)
.PHONY: regress
regress: $(BUILD)/simv
	@pass=0; fail=0; for s in $$(seq 1 $(SEEDS)); do \
	  python3 -I $(ROOT)/scripts/gen_program.py random $(RDIR) --side $(SIDE) --slots $(SLOTS) --seed $$s --pieces $(PIECES) > /dev/null; \
	  (cd $(BUILD) && ./simv -nc -no_save -assert global_finish_maxfail=20 +DIR=$(RDIR) $(ARGS) 2>&1 | head -c $(LOG_MAX) > $(RDIR)/sim.log); \
	  if grep -q '\[tb\] PASS' $(RDIR)/sim.log && ! grep -q -E 'ERROR|Error' $(RDIR)/sim.log; then pass=$$((pass+1)); \
	  else fail=$$((fail+1)); cp -r $(RDIR) $(RDIR)_fail_$$s; echo "seed $$s FAILED: $(RDIR)_fail_$$s/sim.log"; fi; \
	done; echo "regress $(CFG): $$pass passed, $$fail failed"; test $$fail -eq 0

clean:
	rm -rf $(ROOT)/sim/build
