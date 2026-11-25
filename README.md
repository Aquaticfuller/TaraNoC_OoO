# TeraNoC OoO

Hardware task scheduling for a shared-L1 manycore cluster: the back end of the host CPU renames task
instructions, keeps them in a window and issues them to scheduling domains of the cluster, where domain
schedulers cut them into blocks and hand the blocks to idle PEs.

## Layout

| Path | Content |
|---|---|
| `hw/src` | RTL of the task scheduler (`tsched_*`) |
| `hw/tb` | Testbench: the host, the DMA engines and the PEs are models |
| `scripts/gen_program.py` | Task programs for the testbench: random ones, and MoE layers cut as the system model cuts them |
| `sim` | Simulation flow (VCS) |
| `sysmodel` | Event-driven system model of the cluster |
| `arch` | Generator of the architecture figure (draw.io); the figure follows the RTL |
| `syn` | Logic depth and size of the blocks with yosys |

## RTL blocks

| Module | Role |
|---|---|
| `tsched_backend` | Cluster level: rename, window, handle file, load placement, run issue queue, completions, balancer |
| `tsched_rename` | Handle rename and free list, in a map stage and a dispatch stage |
| `tsched_window` | Tasks in program order until they are done |
| `tsched_handle_file` | State and lifetime of handles; releases a handle and its L1 slot when its last user is done |
| `tsched_load_issue` | Loads in program order, each to the least loaded domain that can stream now |
| `tsched_run_iq` | Runs wait for their handles; the oldest ready one goes to the domain that holds its data |
| `tsched_domain` | Domain scheduler: block cutting, stream following, dispatch, join counters; gives blocks to and takes blocks from other domains on command of the cluster level |
| `tsched_balance` | Balancer of the cluster level: moves single blocks from domains with waiting blocks to domains with idle PEs, at most `BalReach` steps apart |
| `tsched_group_disp` | Group dispatcher: next-block register per PE class, PE start and completion |
| `tsched_age_sel`, `tsched_rr_sel`, `tsched_argmin`, `tsched_first_oh`, `tsched_oh_mux` | Selects: oldest first, round robin with a one-hot grant, minimum search, first set bit, one-hot multiplexer |
| `tsched_cluster`, `tsched_top` | Domains, group dispatchers, registered links to the cluster level (no links between domains) |

Sizes are in `hw/src/tsched_pkg.sv`; each can be overridden with a define.

## Packages and dependencies

Dependencies are managed with [Bender](https://github.com/pulp-platform/bender). There are two packages:

| Package | Manifest | Content |
|---|---|---|
| `tsched` | `hw/Bender.yml` | The task scheduler alone. Depends on `common_cells` only. |
| `teranoc_ooo` | `Bender.yml` | The system: `tsched` and the cluster hardware (TeraMonster, package `mempool`). |

TeraMonster and the dependencies it changes are worked on as `bender clone`s in `working_dir/`, each on a
local branch `teranoc-ooo`. The clones are not part of this repository; `Bender.local` points Bender to them.
Until those branches exist on the remotes, the system package can only be built where the clones are.

| Dependency | Remote | Base revision | Local change |
|---|---|---|---|
| `mempool` | liyinrong/TeraNoC, branch `monster-dev` | c76265fac3 | one-domain configuration `config/domain_2x2.mk`; hardware dispatch of the cores (`fsync_shim`); hardware request port of the group DMA engines (`mempool_idma_group`); PE program `tsched_agent` |
| `cluster_icache` | pulp-platform/cluster_icache | 1642961b95 | TeraMonster's change (its `hardware/deps/patches`) |
| `floo_noc` | pulp-platform/FlooNoC | 14c253c996 | same |
| `fpnew` | pulp-platform/cvfpu | 841b19b9fc | same |
| `fractal_sync` | VictorIsachi/fractal_sync | df8e21b7e2 | same |
| `hci` | pulp-platform/hci | a8d8132b7f | same |
| `hwpe-stream` | pulp-platform/hwpe-stream | 05cb830369 | same |
| `ibex` | pulp-platform/ibex | b18f7ef178 | same |
| `idma` | pulp-platform/iDMA | 28a36e5e07 | same |
| `redmule` | liyinrong/redmule | 29fefc29ed | same |
| `register_interface` | pulp-platform/register_interface | d6e1d4cdaa | same |
| `spatz_vpu` | liyinrong/spatz_vpu | 8b46477aa8 | same |
| `tech_cells_generic` | pulp-platform/tech_cells_generic | 3a3de73632 | same |

`.bender.yml` pins the other dependencies on which TeraMonster's packages disagree to the versions of its
lock file, and takes `snitch`, `reqrsp_interface` and `scm` from the folders inside the TeraMonster clone.

## Running the scheduler alone

```sh
cd hw && bender update && cd ../sim
make compile CFG=small DEFS="+define+TSCHED_DOM_PER_SIDE=2"
make regress CFG=small SIDE=2 SLOTS=4 SEEDS=20      # random programs
make compile CFG=full
python3 ../scripts/gen_program.py moe prog/moe64 --kind midfill --n 64 --synthetic
make run CFG=full PROG=prog/moe64
cd ../syn && make depth                              # logic depth and size with yosys
```

`gen_program.py moe` without `--synthetic` needs a routing trace (`--trace <dir>`), which is not part of
this repository.

## Running one domain of cluster hardware

```sh
cd sim
make -f domain.mk setup              # links to the toolchains and to Python 3.12, once
make -f domain.mk hw                 # 2 x 2 groups, 16 tiles, 16 tensor engines, 48 vector units
make -f domain.mk run APP=hello_world
```
