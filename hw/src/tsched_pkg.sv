// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Task scheduler: sizes and message types.
//
// Three levels decide where work runs:
//   cluster level   (tsched_backend)     renames task instructions, keeps them in a window until they are
//                                        done, and issues each one to a scheduling domain.
//   domain level    (tsched_domain)      one per 2 x 2 square of mesh groups: cuts a task into blocks and
//                                        hands the blocks to idle PEs, its own first, then its neighbours'.
//   group level     (tsched_group_disp)  one per mesh group: holds the next block per PE class and starts PEs.
//
// A size can be overridden with a define of the same meaning (see below) to build small configurations.

package tsched_pkg;

  // ---------------------------------------------------------------------------------------------
  // Cluster shape
  // ---------------------------------------------------------------------------------------------
  // Scheduling domains per side of the domain mesh. A domain is a 2 x 2 square of mesh groups.
  localparam int unsigned DomPerSide =
`ifdef TSCHED_DOM_PER_SIDE `TSCHED_DOM_PER_SIDE `else 4 `endif;
  localparam int unsigned NumDomains      = DomPerSide * DomPerSide;
  localparam int unsigned GroupsPerDomain = 4;
  // Among equally loaded domains, placement moves on by this many domains after each choice: one to the
  // right and one down on the domain mesh. Consecutive pieces of work then land in domains that are not
  // direct neighbours, so the neighbours that can borrow from them do not overlap. The stride is coprime
  // with the number of domains, so every domain is visited.
  localparam int unsigned PlaceStride     = DomPerSide + 1;
  localparam int unsigned NumGroups       = NumDomains * GroupsPerDomain;
  // PEs of one group. Tensor engines take indices [0, NumTensor), vector units the rest.
  localparam int unsigned NumTensor =
`ifdef TSCHED_NUM_TENSOR `TSCHED_NUM_TENSOR `else 4 `endif;
  localparam int unsigned NumVector =
`ifdef TSCHED_NUM_VECTOR `TSCHED_NUM_VECTOR `else 12 `endif;
  localparam int unsigned NumPes = NumTensor + NumVector;
  // PE classes. A class mask has one bit per class: bit ClsT tensor engines, bit ClsV vector units.
  localparam int unsigned NumCls = 2;
  localparam int unsigned ClsT   = 0;
  localparam int unsigned ClsV   = 1;
  // Tensor engines of one domain.
  localparam int unsigned DomTensor = GroupsPerDomain * NumTensor;
  // Speed hint of a task that both PE classes may run: a block takes about 2^vslow times as long on a vector
  // unit as on a tensor engine. 0: no statement, a block goes to whichever PE is idle. Otherwise the vector
  // units get blocks of the task only while the tensor engines of the domain would need longer for the blocks
  // that wait than one such vector block takes (tsched_domain).
  localparam int unsigned VslowW = 2;
  // With a hint, the vector units also wait while a domain within reach has tensor engines without work
  // (tsched_balance, wanted, and a short time after a block has come back from another domain): a block given
  // to such an engine ends sooner. 0 only to measure what this brings.
  localparam bit          VecHoldNear =
`ifdef TSCHED_VEC_HOLD_NEAR `TSCHED_VEC_HOLD_NEAR `else 1'b1 `endif;

  // ---------------------------------------------------------------------------------------------
  // Memory resources
  // ---------------------------------------------------------------------------------------------
  // The L1 share of a domain is managed in equal slots; a load fills exactly one slot.
  localparam int unsigned SlotsPerDomain =
`ifdef TSCHED_SLOTS_PER_DOMAIN `TSCHED_SLOTS_PER_DOMAIN `else 4 `endif;
  // Stream lanes from L2. A load uses one lane per group of its domain while it streams.
  localparam int unsigned LanesTotal =
`ifdef TSCHED_LANES `TSCHED_LANES `else 32 `endif;
  localparam int unsigned LanesPerLoad = GroupsPerDomain;
  // Each group DMA moves its share of a load in this many chunks (a power of two). The chunks that
  // every group of the domain has finished tell the domain how much of the slot can be computed on.
  localparam int unsigned ChunksPerGroup =
`ifdef TSCHED_CHUNKS_PER_GROUP `TSCHED_CHUNKS_PER_GROUP `else 8 `endif;

  // Chunks the DMA engine of one group may have in flight. With one, every chunk pays the latency of a
  // transfer in full; with more, the engine queues the chunks and their transfers overlap. Measured on the
  // cluster hardware, a load of 8 chunks per engine takes 244, 132, 105 and 105 cycles with 1, 2, 4 and 8.
  localparam int unsigned DmaInFlight =
`ifdef TSCHED_DMA_IN_FLIGHT `TSCHED_DMA_IN_FLIGHT `else 4 `endif;

  // ---------------------------------------------------------------------------------------------
  // Cluster level
  // ---------------------------------------------------------------------------------------------
  localparam int unsigned NumArch =  32;   // handle registers a program names
  // Tasks that may use the data of one handle at a time (reference counter width).
  localparam int unsigned RefW    =   4;
  localparam int unsigned NumPhys =
`ifdef TSCHED_NUM_PHYS `TSCHED_NUM_PHYS `else 256 `endif;
  localparam int unsigned WinDepth =
`ifdef TSCHED_WIN_DEPTH `TSCHED_WIN_DEPTH `else 256 `endif;
  localparam int unsigned RunIqDepth =
`ifdef TSCHED_RUN_IQ_DEPTH `TSCHED_RUN_IQ_DEPTH `else 32 `endif;
  localparam int unsigned LoadQDepth =  16;
  // Tasks a domain holds at a time; the cluster level keeps this many credits per domain.
  localparam int unsigned DomTaskDepth =
`ifdef TSCHED_DOM_TASK_DEPTH `TSCHED_DOM_TASK_DEPTH `else 4 `endif;

  // ---------------------------------------------------------------------------------------------
  // Field widths
  // ---------------------------------------------------------------------------------------------
  function automatic int unsigned idx_w(input int unsigned n);
    return (n > 1) ? $clog2(n) : 1;
  endfunction

  localparam int unsigned DomW   = idx_w(NumDomains);
  localparam int unsigned GrpW   = idx_w(GroupsPerDomain);
  localparam int unsigned SlotW  = idx_w(SlotsPerDomain);
  localparam int unsigned ArchW  = idx_w(NumArch);
  localparam int unsigned PhysW  = idx_w(NumPhys);
  localparam int unsigned WidW   = idx_w(WinDepth);
  localparam int unsigned TixW   = idx_w(DomTaskDepth);
  localparam int unsigned ChunkW = $clog2(ChunksPerGroup);
  localparam int unsigned NblkW  = 10;   // blocks of one task
  localparam int unsigned KernW  =  8;   // kernel a PE runs
  localparam int unsigned ArgW   = 32;   // argument record of the kernel, opaque to the scheduler
  localparam int unsigned LenW   = 24;   // bytes of one load
  localparam int unsigned AddrW  = 40;   // L2 address
  // Blocks a domain can have received and not finished.
  localparam int unsigned BlkCntW = NblkW + $clog2(DomTaskDepth + 1);

  typedef logic [DomW-1:0]   dom_t;
  typedef logic [SlotW-1:0]  slot_t;
  typedef logic [ArchW-1:0]  arch_t;
  typedef logic [PhysW-1:0]  phys_t;
  typedef logic [WidW-1:0]   wid_t;
  typedef logic [TixW-1:0]   tix_t;
  typedef logic [NblkW-1:0]  nblk_t;
  typedef logic [KernW-1:0]  kern_t;
  typedef logic [ArgW-1:0]   arg_t;
  typedef logic [LenW-1:0]   len_t;
  typedef logic [AddrW-1:0]  addr_t;
  typedef logic [NumCls-1:0] cls_t;
  typedef logic [VslowW-1:0] vslow_t;

  // ---------------------------------------------------------------------------------------------
  // Task instructions (host to cluster level), in program order and no longer speculative
  // ---------------------------------------------------------------------------------------------
  typedef enum logic [1:0] {
    TLoad = 2'd0,   // hd <- stream `len` bytes from L2 address `addr` into a free L1 slot
    TRun  = 2'd1,   // hd <- run `nblk` blocks of kernel `kern` on the data of hs1, after hs2 is done
    TJoin = 2'd2,   // hd <- done once every older task is done
    TFree = 2'd3    // release hs1 and its slot
  } top_e;

  typedef struct packed {
    top_e  op;
    logic  hd_v;     // the task defines handle hd
    arch_t hd;
    logic  hs1_v;    // TRun: data handle (weights); TFree: the handle to release
    arch_t hs1;
    logic  follow;   // TRun: blocks may start while hs1 is still streaming, in the order the data arrives
    logic  kill;     // TRun: last use of hs1, release it when this task retires
    logic  hs2_v;    // TRun: handle that must be done before the task starts
    arch_t hs2;
    cls_t  cls;      // TRun: PE classes that may run the blocks
    vslow_t vslow;   // TRun, both classes: log2 of how much longer a block takes on a vector unit; 0: no hint
    nblk_t nblk;     // TRun: number of blocks, at least 1
    kern_t kern;
    arg_t  arg;
    len_t  len;      // TLoad: bytes, a multiple of GroupsPerDomain * ChunksPerGroup
    addr_t addr;     // TLoad
  } tinstr_t;

  // ---------------------------------------------------------------------------------------------
  // Cluster level <-> domain
  // ---------------------------------------------------------------------------------------------
  typedef struct packed {
    wid_t  wid;
    cls_t  cls;
    vslow_t vslow;
    nblk_t nblk;
    logic  slot_v;   // the task has data in a slot of this domain
    logic  follow;   // blocks become eligible as that slot fills
    slot_t slot;
    kern_t kern;
    arg_t  arg;
  } run_req_t;

  typedef struct packed {
    wid_t  wid;
    slot_t slot;
    len_t  len;
    addr_t addr;
  } load_req_t;

  // A completion from a domain: a load, a task, or one block that the domain ran for another domain.
  typedef struct packed {
    wid_t  wid;
    logic  is_load;
    logic  is_ret;   // a block of domain `dom`, task index `tix` there, is done
    nblk_t nblk;     // run: blocks of the finished task
    dom_t  dom;
    tix_t  tix;
  } done_t;

  // ---------------------------------------------------------------------------------------------
  // Domain <-> group dispatcher, domain <-> domain
  // ---------------------------------------------------------------------------------------------
  // One block of a task, as a PE receives it.
  typedef struct packed {
    kern_t kern;
    arg_t  arg;
    nblk_t bidx;     // which block of the task
    nblk_t nblk;     // blocks of the task
    dom_t  dom;      // domain that holds the task and its data
    logic  slot_v;
    slot_t slot;
    tix_t  tix;      // task index in that domain, returned when the block is done
    logic  pcls;     // PE class the block was cut for (ClsT or ClsV)
  } blk_t;

  // A block as a group dispatcher gets it. `bor`: the block belongs to a task of another domain (b.dom),
  // which must be told when it is done.
  typedef struct packed {
    logic bor;
    blk_t b;
  } gblk_t;

  typedef struct packed {
    logic bor;
    dom_t dom;       // domain that holds the task
    tix_t tix;       // task index in that domain
  } gdone_t;

  // ---------------------------------------------------------------------------------------------
  // Balancing by the cluster level
  // ---------------------------------------------------------------------------------------------
  // A domain reports, per PE class, how many of its groups have an idle PE and nothing to run (want) and
  // whether it has blocks that no own PE can take now (give). The cluster level tells a domain that
  // gives to hand one block to a domain that wants, at most BalReach steps away on the domain mesh. The
  // block travels through the cluster level; there are no links between domains.
  localparam int unsigned BalReach =
`ifdef TSCHED_BAL_REACH `TSCHED_BAL_REACH `else 2 `endif;
  // Blocks of other domains that a domain can hold before a next-block register takes them. Two entries:
  // with four, one of three workloads was 2.4% faster, for about 2,000 more gates per domain scheduler.
  localparam int unsigned BorDepth =
`ifdef TSCHED_BOR_DEPTH `TSCHED_BOR_DEPTH `else 2 `endif;
  localparam int unsigned WantW    = $clog2(GroupsPerDomain + 1);
  // A domain does not fill next-block registers in advance for a class that a domain within reach wants
  // (tsched_balance, wanted). 0 only to measure what the rule brings.
  localparam bit          BalHold  =
`ifdef TSCHED_BAL_HOLD `TSCHED_BAL_HOLD `else 1'b1 `endif;

  typedef struct packed {
    logic [NumCls-1:0][WantW-1:0] want;
    logic [NumCls-1:0]            give;
  } rep_t;

  // Give command: hand one block for PE class `cls` to domain `rcv`.
  typedef struct packed {
    logic cls;
    dom_t rcv;
  } give_t;

  // Answer to a give command; ok is low when the domain had no block to give.
  typedef struct packed {
    logic ok;
    dom_t rcv;
    blk_t b;
  } rblk_t;

  // One chunk of a load, to the DMA engine of a group. A load is laid out in rows that run across the
  // groups of the domain, so that a prefix of the load is a prefix in every group. Chunk `chunk` covers the
  // bytes [off, off + GroupsPerDomain * len) of the load; a group moves its `len` bytes of them. Where
  // these bytes are in L2 and in the slot is for the DMA engine's side to work out from `addr` and `off`.
  typedef struct packed {
    slot_t             slot;
    logic [ChunkW-1:0] chunk;
    len_t              len;
    len_t              off;
    addr_t             addr;    // L2 address of the load
  } dma_req_t;

  // ---------------------------------------------------------------------------------------------
  // Inside the cluster level
  // ---------------------------------------------------------------------------------------------
  // What the window keeps of a task.
  typedef struct packed {
    logic  is_join;
    logic  pd_v;
    phys_t pd;       // handle the task defines
    logic  s1_v;
    phys_t s1;       // data handle the task holds a reference on until it is done
  } win_alloc_t;

  // A renamed load waiting for a domain.
  typedef struct packed {
    wid_t  wid;
    phys_t pd;
    len_t  len;
    addr_t addr;
  } loadq_t;

  // A renamed run entering the issue queue.
  typedef struct packed {
    wid_t  wid;
    logic  s1_v;
    phys_t s1;
    logic  follow;
    logic  s2_v;
    phys_t s2;
    cls_t  cls;
    vslow_t vslow;
    nblk_t nblk;
    kern_t kern;
    arg_t  arg;
  } riq_push_t;

  // State of a handle, as the handle file returns it.
  typedef struct packed {
    logic  placed;   // has a domain and a slot (set when its load is issued)
    logic  done;
    dom_t  dom;
    slot_t slot;
  } hstate_t;

  // ---------------------------------------------------------------------------------------------
  // Wake-up buses of the cluster level
  // ---------------------------------------------------------------------------------------------
  // A load was issued: its handle now has a domain and a slot.
  typedef struct packed {
    logic  v;
    phys_t tag;
    dom_t  dom;
    slot_t slot;
  } wake_place_t;

  // A task finished: its handle is done.
  typedef struct packed {
    logic  v;
    phys_t tag;
  } wake_done_t;

endpackage
