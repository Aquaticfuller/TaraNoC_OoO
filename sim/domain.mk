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
#   make -f domain.mk run APP=<name> PROG=<dir>   simulate it under the task scheduler
#
# TeraMonster and the dependencies it changes live in working_dir/ as `bender clone`s with local commits
# (see README).

ROOT    := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
TM      := $(ROOT)/working_dir/mempool
CONFIG  ?= domain_2x2
BUILD   ?= $(ROOT)/sim/build/domain
APP     ?= tsched_agent
ARGS    ?=
# Toolchains (LLVM, GCC, Bender 0.31 for the software flow) of an existing TeraMonster installation.
TOOLS   ?= /usr/scratch/badile48/msc26f31/teranoc/TeraNoC/install
# The FlooNoC generator needs Python 3.10 or newer with pydantic, networkx, mako, ruamel.yaml and click.
PYTHON3 ?= /usr/bin/python3.12
PYBIN   := $(ROOT)/working_dir/bin

ENV     = PATH=$(PYBIN):$$PATH FLOO_DIR=$$(cd $(ROOT) && bender path floo_noc 2>/dev/null | tail -1)
# The scheduler has one domain here, and the testbench of the cluster hardware gets our harness as its
# external dispatcher.
VLOGAN  := -assert svaext +v2k -override_timescale=1ns/1ps +define+TSCHED_DOM_PER_SIDE=1 +define+EXT_DISPATCH=tsched_harness
# Program of task instructions for the host model (a directory with prog.txt, from scripts/gen_program.py).
PROG    ?= $(ROOT)/sim/prog/domain_smoke
HWMAKE  = $(ENV) $(MAKE) -C $(TM)/hardware config=$(CONFIG) buildpath=$(BUILD) bender="bender -d $(ROOT)" \
          vlogan_args="$(VLOGAN)" vcs_args="+PRELOAD=$(TM)/software/bin/apps/baremetal/$(APP) +DIR=$(PROG) -assert nopostproc $(ARGS)"

.PHONY: setup hw sw run

setup:
	mkdir -p $(PYBIN) $(TM)/install
	ln -sfn $(PYTHON3) $(PYBIN)/python3
	for t in llvm riscv-gcc riscv-isa-sim verilator bender; do ln -sfn $(TOOLS)/$$t $(TM)/install/$$t; done

hw:
	$(HWMAKE) compile_vcs_simvopt

sw:
	$(ENV) $(MAKE) -C $(TM)/software/apps/baremetal $(APP) config=$(CONFIG) COMPILER=llvm

# The cores never leave their PE loop, so the cluster testbench reports no end of computation; the harness
# ends the run and prints the verdict.
run: sw
	-$(HWMAKE) simcvcs > $(BUILD)/run.log 2>&1
	@grep -E '\[tsched\]' $(BUILD)/transcript; grep -q '\[tsched\] PASS' $(BUILD)/transcript
