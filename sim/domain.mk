# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# One scheduling domain of real cluster hardware (TeraMonster, Bender package `mempool`), built with this
# repository as the Bender root. The generation steps and the compile rules are those of TeraMonster's
# own hardware Makefile; this file only calls it with our root, build directory and configuration.
#
#   make -f domain.mk setup            links for the toolchains and for a recent Python (once)
#   make -f domain.mk hw               build the simulator (VCS)
#   make -f domain.mk sw APP=<name>    build a program of software/apps/baremetal
#   make -f domain.mk swclean          remove the built software (needed when CONFIG changes: the runtime
#                                      objects are compiled for one configuration)
#   make -f domain.mk run APP=<name> PROG=<dir>   simulate it under the task scheduler
#
# TeraMonster and the dependencies it changes live in working_dir/ as `bender clone`s with local commits
# (see README).

ROOT    := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
TM      := $(ROOT)/working_dir/mempool
CONFIG  ?= domain_2x2
BUILD   ?= $(ROOT)/sim/build/domain
override BUILD := $(abspath $(BUILD))
APP     ?= tsched_agent
ARGS    ?=
DEFS    ?=
# Domains per side of the scheduler; must match the cluster configuration (1: domain_2x2, 2: cluster_4x4).
SIDE    ?= 1
# The harness ends a run with FAIL after this many cycles without a start or a completion of a block.
TIMEOUT ?= 300000
# The program must print "check PASS" (the programs that compute and check a matrix). CHECK=0: no such line
# is expected (probes, loads without a check).
CHECK   ?= 1
# SW=0: do not rebuild the PE program before a run (several runs at a time, each in its own BUILD, must not
# rebuild it under each other; build it once with `sw` first).
SW      ?= 1
# Toolchains (LLVM, GCC, Bender 0.31 for the software flow) of an existing TeraMonster installation.
TOOLS   ?= /usr/scratch/badile48/msc26f31/teranoc/TeraNoC/install
# The FlooNoC generator needs Python 3.10 or newer with pydantic, networkx, mako, ruamel.yaml and click.
PYTHON3 ?= /usr/bin/python3.12
PYBIN   := $(ROOT)/working_dir/bin

ENV     = PATH=$(PYBIN):$$PATH FLOO_DIR=$$(cd $(ROOT) && bender path floo_noc 2>/dev/null | tail -1)
# The scheduler has one domain here, and the testbench of the cluster hardware gets our harness as its
# external dispatcher.
VLOGAN  := -assert svaext +v2k -override_timescale=1ns/1ps +define+TSCHED_DOM_PER_SIDE=$(SIDE) +define+EXT_DISPATCH=tsched_harness $(DEFS)
# Program of task instructions for the host model (a directory with prog.txt, from scripts/gen_program.py).
# sys/prog/gemm: a warm-up task, one load of a tile into an L1 slot by the DMA engines, one task of eight matrix
# blocks for the tensor engines that follows the load, twelve placeholder blocks for the vector units, then 16
# blocks that check the result and one that reports it. sys/prog/gemm4 is the same for four domains. Before a run, scripts/link_prog.py resolves the symbols of the program (the L2 address of the tile)
# against the PE program and tells where its L1 slots are.
PROG    ?= $(ROOT)/sys/prog/gemm
LINKED  := $(BUILD)/prog
HWMAKE  = $(ENV) $(MAKE) -C $(TM)/hardware config=$(CONFIG) buildpath=$(BUILD) bender="bender -d $(ROOT)" \
          vlogan_args="$(VLOGAN)" vcs_args="+PRELOAD=$(TM)/software/bin/apps/baremetal/$(APP) +DIR=$(LINKED) $$PLUS +TIMEOUT=$(TIMEOUT) -assert nopostproc $(ARGS)"

.PHONY: setup hw sw swclean run

setup:
	mkdir -p $(PYBIN) $(TM)/install
	ln -sfn $(PYTHON3) $(PYBIN)/python3
	for t in llvm riscv-gcc riscv-isa-sim verilator bender; do ln -sfn $(TOOLS)/$$t $(TM)/install/$$t; done

hw:
	$(HWMAKE) compile_vcs_simvopt

sw:
	$(ENV) $(MAKE) -C $(TM)/software/apps/baremetal $(APP) config=$(CONFIG) COMPILER=llvm

swclean:
	$(ENV) $(MAKE) -C $(TM)/software/apps/baremetal clean config=$(CONFIG) > /dev/null

# The cores never leave their PE loop, so the cluster testbench reports no end of computation; the harness
# ends the run and prints the verdict.
run: $(if $(filter 1,$(SW)),sw)
	mkdir -p $(BUILD) && rm -f $(BUILD)/transcript $(BUILD)/run.log
	@PLUS=$$($(PYBIN)/python3 $(ROOT)/scripts/link_prog.py $(PROG)/prog.txt $(TM)/software/bin/apps/baremetal/$(APP) $(LINKED)) \
	  || { echo "verdict: FAIL (the program could not be linked)"; exit 1; }; \
	  echo "simulating $(PROG) with $$PLUS"; \
	  $(HWMAKE) simcvcs > $(BUILD)/run.log 2>&1 || true
	@test -f $(BUILD)/transcript || { echo "no transcript: the simulation did not run, see $(BUILD)/run.log"; exit 1; }
	@grep -E '^\[tsched\] (RESULT|PASS|FAIL|DMA)|^\[tsched\] [0-9]+ instr|\[UART\]' $(BUILD)/transcript; \
	  grep -q '\[tsched\] PASS' $(BUILD)/transcript || { echo "verdict: FAIL (no PASS of the harness)"; exit 1; }; \
	  ! grep -q 'check FAIL' $(BUILD)/transcript || { echo "verdict: FAIL (the result check failed)"; exit 1; }; \
	  ! grep -q -E '^Error|Offending|\[tsched_[a-z_]+( [0-9]+)?\]|\[mempool_idma_group\]|Missed wake-up' $(BUILD)/transcript || { echo "verdict: FAIL (assertion or lost wake-up messages in the transcript)"; exit 1; }; \
	  test "$(CHECK)" = 0 || grep -q 'check PASS' $(BUILD)/transcript || { echo "verdict: FAIL (no check PASS line)"; exit 1; }; \
	  if test "$(CHECK)" = 0; then echo "verdict: PASS (no result check in this program)"; else echo "verdict: PASS (result check passed)"; fi

# ---------------------------------------------------------------- QuestaSim, for looking at waveforms
#   make -f domain.mk hwq  CONFIG=.. SIDE=.. BUILD=build/<name> DEFS=..            compile (own BUILD, not one of VCS)
#   make -f domain.mk gui  CONFIG=.. SIDE=.. BUILD=build/<name> DEFS=.. PROG=..    open the GUI with the waves of DO
#   make -f domain.mk simq ...                                                    the same run without GUI
# The GUI stops at time 0 with the waves added: type `run 70us` (or `run -a`) in its console.
QUESTA  ?= questa-2025.3-dz
DO      ?= $(ROOT)/sim/wave_mcast.do
VLOG    := -suppress vlog-2583 -suppress vlog-13314 -suppress vlog-13233 -work work -timescale 1ns/1ps \
           +define+TSCHED_DOM_PER_SIDE=$(SIDE) +define+EXT_DISPATCH=tsched_harness $(DEFS)
QSIM    = cd $(BUILD) && $(QUESTA) vsim -voptargs=+acc -sv_lib work-dpi/mempool_dpi -work work -suppress vsim-12070 \
          +PRELOAD=$(TM)/software/bin/apps/baremetal/$(APP) +DIR=$(LINKED) $$PLUS +TIMEOUT=$(TIMEOUT) $(ARGS) work.mempool_tb

.PHONY: hwq gui simq
hwq:
	$(HWMAKE) vlog_args="$(VLOG)" compile

gui simq: $(if $(filter 1,$(SW)),sw)
	@PLUS=$$($(PYBIN)/python3 $(ROOT)/scripts/link_prog.py $(PROG)/prog.txt $(TM)/software/bin/apps/baremetal/$(APP) $(LINKED)) \
	  || { echo "the program could not be linked"; exit 1; }; \
	  $(if $(filter gui,$@),$(QSIM) -do $(DO),$(QSIM) -c -do $(DO) -do "run -a; quit -f")
