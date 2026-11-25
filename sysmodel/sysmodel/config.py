"""System and model configurations. Every number carries where it comes from:

  [paper]   stated in the TeraMonster or MergeCast manuscript
  [rtl]     measured in an RTL run of one of the two repositories
  [derived] arithmetic on [paper]/[rtl] numbers
  [assumed] my assumption, to be replaced by a measured or derived value
"""
from dataclasses import dataclass, field, replace


@dataclass(frozen=True)
class EngineClass:
    name: str
    per_group: int          # engines of this class in one group
    flop_per_cycle: float   # FP16 FLOP/cycle of one engine (1 MAC = 2 FLOP)
    # --- step 2: how the engine uses a weight, and which plane of the L1 interconnect feeds it
    rows: int = 1           # tokens that can share one weight element in one pass over the weights
    row_fill: bool = False  # True: a systolic array; rows stay empty when a block has fewer tokens than `rows`
    plane: str = 'ideal'    # 'wide' burst plane | 'word' 32-bit plane | 'ideal' no interconnect limit
    need_overhead: float = 0.0   # vector units: operand bytes besides weights, as a share of the weight bytes


@dataclass(frozen=True)
class WidePlane:
    """Burst plane (512-bit beats). An engine keeps a fixed number of beats in flight, so what it receives per
    cycle is that window divided by the access latency, and the latency grows with the distance to the data."""
    lat0: float = 9.5            # [fit] cycles at 0 hops: paper gives 19 cycles at 1.5 hops and 43 at 5.3 hops
    lat_hop: float = 6.3         # [fit] cycles per hop of mean operand distance (same two points)
    window_bytes: float = 1024.0 # [rtl] 16 outstanding 512-bit beats (rob_depth = 16 in the TeraMonster configuration)
    tensor_window_cycles: float = 27.0   # [fit] a tensor engine runs at full rate up to this latency: 64.1% at 5.25 hops (Fig. 1), 60-65% at 43 cycles (Fig. 5)
    u_max: float = 0.93          # [paper] tensor-engine utilisation with localised data on the 8x8 cluster (92.7%)


@dataclass(frozen=True)
class WordPlane:
    """32-bit word plane as measured on the MergeCast RTL: a core receives a number of weight bytes per cycle that
    falls with the distance to the data."""
    port_bytes: float = 16.0     # [rtl] 4 load ports of 4 B per core: the ceiling for data in the core's own group
    reach: float = 5.5           # [rtl, derived] B/cycle x hops: 2.05-2.5 B/cycle at 2.5 hops (4x4), 0.93-1.17 B/cycle at 5.25 hops (8x8)
    merge: int = 4               # [rtl] cores of a group that share a weight read are served by one request (merge_reqs = 4)


@dataclass(frozen=True)
class SystemConfig:
    name: str
    groups: int                       # groups in the mesh
    engines: tuple                    # EngineClass entries present in every group
    spm_bytes: int                    # shared L1 scratchpad
    l2_ports: int                     # AXI ports to L2 at the cluster boundary
    l2_port_bytes_per_cycle: float    # one port, one beat per cycle
    gemm_class: str                   # engine class that runs GEMM blocks in step 1 of the model
    wide: object = None               # WidePlane, if the system has a burst plane
    word: object = None               # WordPlane, if vector units load weights over the word plane
    l2_efficiency: float = 1.0        # share of the nominal L2 port rate a stream reaches

    @property
    def l2_bytes_per_cycle(self):
        return self.l2_ports * self.l2_port_bytes_per_cycle

    @property
    def side(self):
        k = int(round(self.groups ** 0.5))
        assert k * k == self.groups, 'groups must form a square mesh'
        return k

    def ideal(self):
        """The same system without interconnect and array effects (what step 1 modelled)."""
        return replace(self, engines=tuple(replace(e, plane='ideal', row_fill=False) for e in self.engines), l2_efficiency=1.0)

    def n_engines(self, cls=None):
        return self.groups * sum(e.per_group for e in self.engines if cls in (None, e.name))

    def flop_per_cycle(self, cls=None):
        return self.groups * sum(e.per_group * e.flop_per_cycle for e in self.engines if cls in (None, e.name))


def teramonster():
    """TeraMonster as evaluated: 8x8 groups, 4 tiles per group, each tile 1 RedMulE + 3 Snitch-Spatz + 1 control core."""
    return SystemConfig(
        name='teramonster',
        groups=64,                                        # [paper] 8x8 mesh
        engines=(EngineClass('tensor', 4, 512.0,          # [paper] 4 tiles/group, RedMulE 256 FP16 MAC/cycle
                             rows=32, row_fill=True,      # [rtl] 8x32 array (redmule_height 8, redmule_width 32): 32 rows share a weight; [derived] rows stay empty below 32 tokens
                             plane='wide'),
                 EngineClass('vector', 12, 16.0,          # [paper] 3 Spatz per tile; [derived] 8 MAC/cycle each from the 71,680 MAC/cycle total
                             rows=8, plane='wide',        # [rtl] up to 8 rows per weight on MergeCast; [assumed] unit-stride bursts over the wide plane
                             need_overhead=0.25)),        # [assumed] activations and results add a quarter to the weight traffic
        spm_bytes=64 << 20,                               # [paper] 64 MiB shared L1
        l2_ports=32, l2_port_bytes_per_cycle=64.0,        # [paper] 32 AXI ports, 512 bit each
        gemm_class='tensor',
        wide=WidePlane(),
        l2_efficiency=0.94)                               # [rtl] 30.1 of 32 beats/cycle on the MergeCast 8x8 AXI mesh


def mergecast():
    """MergeCast scale: 1024 Snitch-Spatz PEs, 16,384 FP16 FLOP/cycle, 64 MiB SPM, 2 KiB/cycle from L2."""
    return SystemConfig(
        name='mergecast',
        groups=64,                                        # [paper] 8x8 groups of 16 PEs
        engines=(EngineClass('vector', 16, 16.0,          # [paper] 16,384 FLOP/cycle over 1024 PEs
                             rows=8, plane='word'),),     # [rtl] KS up to 8 rows per weight; weights arrive over the word plane
        spm_bytes=64 << 20,                               # [paper]
        l2_ports=32, l2_port_bytes_per_cycle=64.0,        # [paper] 2 KiB/cycle in total
        gemm_class='vector',
        word=WordPlane(),
        l2_efficiency=0.94)                               # [rtl] 30.1 of 32 beats/cycle


@dataclass(frozen=True)
class ModelConfig:
    """Shape of the MoE model. Defaults: the traced model, Qwen3.8-Flash-Next."""
    name: str = 'qwen3.8-flash-next'
    experts: int = 512                 # [trace README]
    top_k: int = 10                    # [trace README]
    hidden: int = 2560                 # [trace README]
    expert_width: int = 640            # [trace README]
    weight_bytes: float = 2.0          # FP16 on the stream and in the SPM
    act_bytes_per_token: int = 15 << 10   # [assumed] activations held in the SPM per token
    mixer_rho: float = 0.9             # [assumed] mixer compute per token / expert compute per token
    mixer_phi: float = 0.6             # [assumed] share of the mixer that needs no token order
    mixer_in_expert_eq: float = 5.0    # [assumed] weights of one mixer input pass, in expert fetches
    mixer_out_expert_eq: float = 3.0   # [assumed] weights of the ordered mixer stage, in expert fetches
    shared_experts: int = 0            # experts every token passes through, besides the routed ones

    @property
    def expert_params(self):
        return 3 * self.hidden * self.expert_width          # gate, up, down

    @property
    def expert_bytes(self):
        return self.expert_params * self.weight_bytes

    @property
    def expert_flop_per_token(self):
        return 2.0 * self.expert_params

    @property
    def mixer_flop_per_token(self):
        return self.mixer_rho * self.top_k * self.expert_flop_per_token


def qwen36(context=2048):
    """Qwen3.6-35B-A3B, the target model. Shapes from its public config.json (read 2026-11-24): 40 layers, hidden 2048,
    256 routed experts of width 512, top-8, one shared expert of width 512; 30 linear-attention layers (gated delta
    net: 16 key heads and 32 value heads of 128) and 10 full-attention layers (16 heads of 256, 2 key-value heads).

    The mixer numbers are [derived] from those shapes, with the layout of the projection matrices taken from the
    published Qwen3.5 implementation as I remember it [not checked against the checkpoint]. Cross-check: the same
    shapes give 35 B parameters in total and 2.4 B touched per token without embeddings, as the model name says.
      linear layer  order-free: q,k,v,z projections 2048 -> 12288 (25.2 M); ordered: recurrence (3 M FLOP) + output 4096 -> 2048 (8.4 M)
      full layer    order-free: q (with gate) 2048 -> 8192, k and v 2048 -> 512 (18.9 M); ordered: scores over the context + output 4096 -> 2048 (8.4 M)
    One ModelConfig describes every layer, so the mixer is the 30:10 average."""
    e = 3 * 2048 * 512                                   # parameters of one expert
    m_in = (30 * 25.2e6 + 10 * 18.9e6) / 40              # order-free mixer parameters
    m_out = 8.4e6                                        # ordered stage: output projection
    f_in = 2.0 * m_in
    f_out = 2.0 * m_out + 0.75 * 3.1e6 + 0.25 * 16384.0 * context   # + recurrence (linear), + scores over `context` tokens (full)
    kv = 0.25 * context * 2048.0 / 2.0                   # key-value cache of a full layer, 2 KiB per context token, in FP16 parameters
    return ModelConfig(name='qwen3.6-35b-a3b', experts=256, top_k=8, hidden=2048, expert_width=512,
                       act_bytes_per_token=12 << 10,     # [assumed] three hidden vectors per token, as for the other model
                       mixer_rho=(f_in + f_out) / (8 * 2.0 * e), mixer_phi=f_in / (f_in + f_out),
                       mixer_in_expert_eq=m_in / e, mixer_out_expert_eq=(m_out + kv) / e, shared_experts=1)


@dataclass(frozen=True)
class SchedConfig:
    """Scheduling scheme. In step 1 the two delays are inputs; later steps derive them."""
    policy: str = 'hw'                 # 'hw' pull scheduler | 'plan' plan-once software | 'static' pinned experts
    block_delay: float = 100.0         # [assumed] cycles from "engine idle" to "block running"
    stream_delay: float = 100.0        # [assumed] cycles from "stream free" to "next job streaming"
    plan_cycles_per_block: float = 0.0 # [assumed] software planning cost, paid once before the first fetch
    order: str = 'hot'                 # fetch order: 'hot' busiest first | 'mix' busiest while compute is hungry, else least busy | 'index'
    overlap: bool = True               # start the next mixer on finished tokens before the last expert is done
    pass_min_frac: float = 0.25        # finished-token share that triggers a mixer input pass
    min_block_cycles: float = 2000.0   # no block shorter than this on a nominal engine; an expert is cut into at most one block per engine
    blocks_per_engine: float = 4.0     # a mixer pass is cut into at most this many blocks per engine
    plan_blocks_per_group: float = 8.0 # target pieces per group in a software plan
    tile_following: bool = True        # blocks of an expert become ready as its weights arrive
    parallel_fetches: int = 1          # concurrent stream jobs sharing the L2 ports
    speed_spread: float = 0.0          # engines run at 1/(1+spread*U[0,1]) of nominal speed (step 1 only)
    seed: int = 1
    # --- step 2 (sim2): where weights are placed and which engine class runs a block
    region_groups: int = 64            # weights of one piece are interleaved over an aligned square of this many groups (1, 4, 16, 64)
    slots_per_region: float = 2.0      # a piece is at most 1/slots of a region's free capacity, so a region can stream one piece while it computes another
    vec_max_tokens: int = 0            # blocks with at most this many tokens may run on vector units (0: tensor engines only, when the system has them)
    mixer_spm: bool = True             # mixer weights occupy SPM until their blocks are done (step 1 did not count them)
    plan_cores: int = 1                # cores that share the software planning work
    fixed_block_cycles: float = 0.0    # > 0: the program fixes the task length; every piece is cut into blocks of this many cycles (pull schemes)
    cross_region: bool = True          # False: a block only runs on engines of the region that holds its weights (no pull across regions)
    window_tasks: int = 0              # > 0: pieces retire in issue order and at most this many may be issued and not yet retired (a reorder buffer for tasks)
    steer: str = 'home'                # where a piece is computed: 'home' in the region that holds its weights | 'soft' the cluster level picks the region
                                       # that finishes it first (queue there + run time at that distance); the weights stay where they were loaded
    # --- step 3 (sim2): who decides. With a Hierarchy the two delays above are not used; they come out of the model.
    hier: object = None

    def but(self, **kw):
        return replace(self, **kw)


@dataclass(frozen=True)
class Hierarchy:
    """Step 3: the servers that make scheduling decisions and how long one decision keeps a server busy.
    A decision waits while its server is busy, so block and stream delays depend on the load."""
    name: str
    dispatch_servers_per_group: int    # servers that hand blocks to the engines of one group
    dispatch_cycles: float             # one hand-over: choose the block, program the engine
    launch_cycles: float               # engine start-up after the hand-over
    steal_cycles: float = 0.0          # extra when the block comes from another region's queue
    steal_hop_cycles: float = 0.0      # ... per hop to that region
    central: bool = False              # True: one server for the whole cluster hands out every block
    sched_cycles: float = 0.0          # one stream decision: choose piece and region, launch the DMA
    stream_local: bool = False         # True: stream decisions are served by the dispatch servers of the target region
    done_cycles_per_token: float = 0.0 # counter updates when an expert completes, per token of that expert
    issue_cycles_per_route: float = 0.0  # building the layer's task table, per (token, expert) entry
    issue_cores: int = 1               # cores that share that work

    def but(self, **kw):
        return replace(self, **kw)


# Hardware hierarchy. Every number is [assumed]: a target for the design, to be replaced by RTL.
HIER_HW = Hierarchy('hardware', dispatch_servers_per_group=1, dispatch_cycles=8.0, launch_cycles=16.0,
                    steal_cycles=8.0, steal_hop_cycles=2.0, sched_cycles=16.0, done_cycles_per_token=0.25,
                    issue_cycles_per_route=0.25)
# Software on the control cores, one per tile [paper]. A cluster-wide software barrier costs about 790 cycles
# [paper: 11x the 72-cycle hardware barrier]; the per-decision costs below are [assumed] from that scale.
HIER_SW_PLAN = Hierarchy('software, per-group lists', dispatch_servers_per_group=4, dispatch_cycles=300.0, launch_cycles=16.0,
                         sched_cycles=300.0, stream_local=True, done_cycles_per_token=0.0,
                         issue_cycles_per_route=20.0, issue_cores=64)
HIER_SW_PULL = Hierarchy('software, shared queue', dispatch_servers_per_group=4, dispatch_cycles=300.0, launch_cycles=16.0,
                         central=True, sched_cycles=300.0, done_cycles_per_token=20.0,
                         issue_cycles_per_route=20.0, issue_cores=64)
# Work stealing on the control cores: each serves its own group, taking from another region costs a remote queue
# operation; stream decisions and token counters on one core.
HIER_SW_STEAL = HIER_SW_PLAN.but(name='software, work stealing', steal_cycles=700.0, steal_hop_cycles=10.0, stream_local=False,
                                 done_cycles_per_token=20.0)

HW = SchedConfig(policy='hw')
PLAN = SchedConfig(policy='plan', block_delay=1000.0, stream_delay=1000.0, plan_cycles_per_block=100.0, overlap=False)
STATIC = SchedConfig(policy='static', block_delay=1000.0, stream_delay=1000.0, order='index', overlap=False)
