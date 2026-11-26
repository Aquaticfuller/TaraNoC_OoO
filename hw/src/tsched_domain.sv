// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Domain scheduler: one per scheduling domain (a 2 x 2 square of mesh groups).
//
// Tasks     It holds up to DomTaskDepth tasks from the cluster level. A task is a count of blocks, so
//           cutting is a counter: `next` blocks have been handed out, `elig` may be handed out, `out`
//           are running. A task is done when all its blocks have been handed out and none is running
//           (the join counter).
// Chain     A task can follow another task block by block, in this domain or another: each block of that task
//           that is done makes one block of the follower eligible. The scheduler only counts; which block of
//           the first task a block of the second works on is passed on by the kernels through L1. The domain
//           of the first task sends its progress to the follower through the cluster level.
// Stream    One load at a time. Each group DMA moves its share of the load in ChunksPerGroup chunks; the
//           chunks every group has finished are the progress of the slot. A task that follows the
//           stream gets its blocks eligible in proportion to that progress.
// Dispatch  One block per cycle goes to a next-block register of a group dispatcher. A register with an
//           idle PE behind it is served before a register that only prepares the next block.
//           A next block is prepared behind a busy PE only while that cannot cost time: the backlog of the
//           class is deep, no domain within reach wants blocks of the class, and none is working on blocks
//           of this domain (it will want more when they are done). A prepared block cannot be given away.
//           The decision (which task, for whom) and the block itself are one register stage apart: the
//           counters of the task move with the decision, the fields of the block are read from the
//           task table in the next cycle. A task with a block running stays in the table, so these
//           fields are stable for that read.
//           The decision is built so that everything it needs is prepared in parallel: the flags of the
//           tasks are registers, each tier of requests has its own select with a one-hot grant, and the
//           counters have both outcomes ready. See the comments at each part.
// PE types  A task that both PE classes may run can carry a speed hint (vslow): a block takes about 2^vslow
//           times as long on a vector unit. Vector units then get its blocks only while that pays: the
//           tensor engines that work for the domain (its own, and those that run its blocks elsewhere)
//           would need longer for the blocks that wait than one vector block takes, and no domain within
//           reach has tensor engines without work. No block of such a task is prepared behind a busy
//           vector unit, and while the domain holds such a task its vector units ask no other domain for
//           blocks.
// Balance   The domain tells the cluster level how many groups have an idle PE and nothing to run, and
//           whether it has blocks that no own PE can take now. On a give command of the cluster level it
//           hands one block of its own tasks to another domain; the block travels through the cluster
//           level. It runs blocks it receives from other domains before its own. The completion of such
//           a block returns through the cluster level to the domain of the task, which keeps the join
//           counter. There are no links between domains. L1 is shared: the PE reads the data of the
//           block from the domain named in the block.

module tsched_domain import tsched_pkg::*; #(
  parameter int unsigned DomId   = 0,
  parameter bit          BalEn   = 1'b1,    // take part in the balancing by the cluster level
  parameter int unsigned LendMin = 1        // eligible blocks a task must have left to give one away
) (
  input  logic                                    clk_i,
  input  logic                                    rst_ni,
  // cluster level
  input  logic                                    run_valid_i,
  input  run_req_t                                run_i,
  input  logic                                    reg_valid_i,    // the task in entry run_i.ptix has a follower
  input  logic                                    load_valid_i,
  input  load_req_t                               load_i,
  output logic                                    done_valid_o,
  input  logic                                    done_ready_i,
  output done_t                                   done_o,
  // DMA engines, one per group
  output logic     [GroupsPerDomain-1:0]          dma_valid_o,
  input  logic     [GroupsPerDomain-1:0]          dma_ready_i,
  output dma_req_t [GroupsPerDomain-1:0]          dma_o,
  input  logic     [GroupsPerDomain-1:0]          dma_done_i,
  // group dispatchers
  output logic     [GroupsPerDomain-1:0]          blk_valid_o,
  output gblk_t    [GroupsPerDomain-1:0]          blk_o,
  input  logic     [GroupsPerDomain-1:0][NumCls-1:0] pop_i,
  input  logic     [GroupsPerDomain-1:0][NumCls-1:0] idle_i,
  input  logic     [GroupsPerDomain-1:0]          gdone_valid_i,
  output logic     [GroupsPerDomain-1:0]          gdone_ready_o,
  input  gdone_t   [GroupsPerDomain-1:0]          gdone_i,
  input  logic     [GroupsPerDomain-1:0]          gdone_cls_i,    // PE class that ran the block
  // balancing by the cluster level
  output rep_t                                    rep_o,          // idle PEs without work, blocks to give
  input  logic                                    give_valid_i,   // hand one block to another domain
  input  give_t                                   give_i,
  output logic                                    rblk_valid_o,   // the answer, two cycles after the command
  output rblk_t                                   rblk_o,
  input  logic                                    bblk_valid_i,   // a block of another domain to run here
  input  blk_t                                    bblk_i,
  output logic                                    bpop_valid_o,   // such a block left the queue for a group
  output logic                                    bpop_cls_o,
  input  logic [NumCls-1:0]                       wanted_i,       // a domain within reach wants the class
  input  logic                                    ret_valid_i,    // a block given away is done
  input  ret_t                                    ret_i
);

  localparam int unsigned G     = GroupsPerDomain;
  localparam int unsigned T     = DomTaskDepth;
  localparam int unsigned C     = ChunksPerGroup;
  localparam int unsigned TickW = ChunkW + 1;
  // Chunks in flight per group DMA engine: never more than a load has, so that the count fits TickW bits.
  localparam int unsigned InFlight = (DmaInFlight < C) ? ((DmaInFlight > 0) ? DmaInFlight : 1) : C;
  localparam int unsigned DecW  = $clog2(G + 2);

  // -------------------------------------------------------------------------------------------
  // Stream: one load at a time
  // -------------------------------------------------------------------------------------------
  logic                    ld_active_d, ld_active_q;
  wid_t                    ld_wid_q;
  slot_t                   ld_slot_q;
  len_t                    ld_clen_q;
  addr_t                   ld_addr_q;
  len_t  [G-1:0]           ld_off_q;      // offset in the load of the next chunk of each group
  logic  [G-1:0]           ld_full_d, ld_full_q;   // the engine of the group has DmaInFlight chunks in flight
  logic  [G-1:0][TickW-1:0] ld_issued_d, ld_issued_q, ld_cdone_d, ld_cdone_q;
  logic  [TickW-1:0]       ld_prog_d, ld_prog_q;
  logic  [G-1:0]           dma_fire;
  logic                    ld_fin;
  logic                    ld_take;       // the completion of the load moves to the output register

  for (genvar g = 0; g < G; g++) begin : gen_dma
    assign dma_valid_o[g] = ld_active_q & ~ld_full_q[g] & (ld_issued_q[g] != TickW'(C));
    assign dma_o[g]       = '{slot: ld_slot_q, chunk: ld_issued_q[g][ChunkW-1:0], len: ld_clen_q, off: ld_off_q[g], addr: ld_addr_q};
    assign dma_fire[g]    = dma_valid_o[g] & dma_ready_i[g];
  end

  always_comb begin
    ld_active_d = ld_active_q;
    ld_issued_d = ld_issued_q;
    ld_cdone_d  = ld_cdone_q;
    for (int unsigned g = 0; g < G; g++) begin
      if (dma_fire[g])   ld_issued_d[g] = ld_issued_q[g] + TickW'(1);
      if (dma_done_i[g]) ld_cdone_d[g]  = ld_cdone_q[g] + TickW'(1);
    end
    // Progress of the slot: chunks that every group has finished.
    ld_prog_d = ld_cdone_d[0];
    for (int unsigned g = 1; g < G; g++) begin
      if (ld_cdone_d[g] < ld_prog_d) ld_prog_d = ld_cdone_d[g];
    end
    if (ld_take) ld_active_d = 1'b0;
    if (load_valid_i) begin
      ld_active_d = 1'b1;
      ld_issued_d = '0;
      ld_cdone_d  = '0;
      ld_prog_d   = '0;
    end
    for (int unsigned g = 0; g < G; g++) ld_full_d[g] = (ld_issued_d[g] - ld_cdone_d[g]) == TickW'(InFlight);
  end

  always_comb begin
    ld_fin = ld_active_q;
    for (int unsigned g = 0; g < G; g++) ld_fin &= ld_cdone_q[g] == TickW'(C);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ld_active_q <= 1'b0;
      ld_full_q   <= '0;
      ld_issued_q <= '0;
      ld_cdone_q  <= '0;
      ld_prog_q   <= '0;
    end else begin
      ld_active_q <= ld_active_d;
      ld_full_q   <= ld_full_d;
      ld_issued_q <= ld_issued_d;
      ld_cdone_q  <= ld_cdone_d;
      ld_prog_q   <= ld_prog_d;
    end
  end

  always_ff @(posedge clk_i) begin
    if (load_valid_i) begin
      ld_wid_q  <= load_i.wid;
      ld_slot_q <= load_i.slot;
      ld_clen_q <= load_i.len >> (GrpW + ChunkW);
      ld_addr_q <= load_i.addr;
      ld_off_q  <= '0;
    end else begin
      // A chunk spans all groups of the domain: the next one starts G chunk lengths further.
      for (int unsigned g = 0; g < G; g++) begin
        if (dma_fire[g]) ld_off_q[g] <= ld_off_q[g] + LenW'(ld_clen_q << GrpW);
      end
    end
  end

  // -------------------------------------------------------------------------------------------
  // Task table
  // -------------------------------------------------------------------------------------------
  logic  [T-1:0]             t_valid_d, t_valid_q;
  wid_t  [T-1:0]             t_wid_q;
  cls_t  [T-1:0]             t_cls_q;
  vslow_t [T-1:0]            t_vslow_q;
  logic  [T-1:0]             t_vok_d, t_vok_q;       // vector units may take blocks of the task
  logic  [T-1:0]             t_hv_d, t_hv_q;         // ... and the task has a speed hint
  nblk_t [T-1:0]             t_nblk_q;
  nblk_t [T-1:0]             t_next_d, t_next_q;     // blocks handed out
  nblk_t [T-1:0]             t_left_d, t_left_q;     // blocks that may be handed out and have not been
  nblk_t [T-1:0]             t_out_d, t_out_q;       // blocks running
  logic  [T-1:0]             t_avail_d, t_avail_q;   // t_left is not zero
  logic  [T-1:0]             t_spare_d, t_spare_q;   // t_left is at least LendMin
  nblk_t [T-1:0]             t_inc_d, t_inc_q;       // blocks that became eligible, added to t_left next
  logic  [T-1:0]             t_follow_q, t_slot_v_q;
  slot_t [T-1:0]             t_slot_q;
  logic  [T-1:0][TickW-1:0]  t_ticks_d, t_ticks_q;   // progress steps already turned into eligible blocks
  logic  [T-1:0][ChunkW-1:0] t_acc_d, t_acc_q;
  kern_t [T-1:0]             t_kern_q;
  arg_t  [T-1:0]             t_arg_q;

  logic  [T-1:0]             ins_oh;
  tix_t                      ins_idx;
  logic  [T-1:0]             t_fin;
  logic  [T-1:0]             cut_oh;                 // the task a block is cut from this cycle
  logic  [T-1:0][DecW-1:0]   t_dec_d, t_dec_q;       // completions per task, subtracted from t_out next
  logic  [T-1:0]             t_take;                 // the completion of the task moves to the output register

  // The cluster level names the entry a task takes.
  assign ins_idx = run_i.tix;
  always_comb begin
    ins_oh = '0;
    ins_oh[ins_idx] = run_valid_i;
  end

  // Chained tasks. A task can be followed block by block by one other task, in this domain or another
  // (t_rf, with the domain and entry of the follower). What the follower has been told so far is counted
  // per task (t_sent); the blocks done are the blocks handed out minus those running. The difference is sent
  // as progress messages through the completion path, up to 2^ProgW - 1 blocks per message; the cluster
  // level forwards them, and the follower gets that many eligible blocks.
  // One task at a time is served, in three steps, so that the subtraction is shared and starts at registers:
  //   idle  pick a task that has news for its follower (t_dirty: a block was done, or the follower is new)
  //   calc  owed = handed out - running - sent, from the counters of that task
  //   send  one message with min(owed, 2^ProgW - 1) blocks; nothing if owed is zero
  // A task stays marked if more was owed than one message carries, or if a block was done after the counters
  // were read. It leaves the table only when it is not marked.
  // The follower is registered when it is issued (reg_valid_i, with the task link's payload). A registration
  // that finds its task gone (it finished while the follower was on its way) is answered with one message
  // "all done" (gone). The entry cannot hold a later task yet: the cluster level gives it out again only to a
  // task issued after the follower.
  logic  [T-1:0]             t_rf_d, t_rf_q;
  dom_t  [T-1:0]             t_rfd_q;
  tix_t  [T-1:0]             t_rft_q;
  nblk_t [T-1:0]             t_sent_q;
  logic  [T-1:0]             t_dirty_d, t_dirty_q;
  logic  [T-1:0]             reg_oh;
  logic                      reg_hit, reg_gone;
  logic  [T-1:0]             gone_d, gone_q;
  dom_t  [T-1:0]             gone_dom_q;
  tix_t  [T-1:0]             gone_tix_q;
  logic  [T-1:0]             gone_oh;
  logic                      prog_take, gone_take;

  typedef enum logic [1:0] {PsIdle, PsCalc, PsSend} ps_e;
  ps_e                       ps_d, ps_q;
  logic  [T-1:0]             ps_cand, ps_first, ps_oh_d, ps_oh_q;
  nblk_t                     ps_owe_d, ps_owe_q;      // blocks owed to the follower of the task being served
  logic                      ps_new_d, ps_new_q;      // a block of that task was done after its counters were read
  logic                      ps_dec;                  // ... in this cycle
  logic                      ps_more, ps_fin;
  logic  [ProgW-1:0]         prog_n;
  nblk_t                     ps_sent_new;

  always_comb begin
    reg_oh = '0;
    reg_oh[run_i.ptix] = 1'b1;
  end
  assign reg_hit  = reg_valid_i &  (t_valid_q[run_i.ptix] & ~t_take[run_i.ptix]);
  assign reg_gone = reg_valid_i & ~(t_valid_q[run_i.ptix] & ~t_take[run_i.ptix]);

  assign ps_cand = t_valid_q & t_rf_q & t_dirty_q;
  for (genvar t = 0; t < T; t++) begin : gen_prog
    assign ps_first[t] = ps_cand[t] & ~(|(ps_cand & T'((32'd1 << t) - 32'd1)));
    assign gone_oh[t]  = gone_q[t]  & ~(|(gone_q  & T'((32'd1 << t) - 32'd1)));
  end

  assign ps_more = ps_owe_q > nblk_t'(2**ProgW - 1);
  assign prog_n  = ps_more ? '1 : ps_owe_q[ProgW-1:0];
  // The served task is done with: its message was taken, or there was nothing to tell.
  assign ps_fin  = (ps_q == PsSend) & (prog_take | (ps_owe_q == '0));

  always_comb begin
    nblk_t nx, ou, se;
    nx     = '0;
    ou     = '0;
    se     = '0;
    ps_dec = 1'b0;
    for (int unsigned t = 0; t < T; t++) begin
      nx     |= {NblkW{ps_oh_q[t]}} & t_next_q[t];
      ou     |= {NblkW{ps_oh_q[t]}} & t_out_q[t];
      se     |= {NblkW{ps_oh_q[t]}} & t_sent_q[t];
      ps_dec |= ps_oh_q[t] & (t_dec_q[t] != '0);
    end
    ps_sent_new = se + nblk_t'(prog_n);
    ps_d     = ps_q;
    ps_oh_d  = ps_oh_q;
    ps_owe_d = ps_owe_q;
    ps_new_d = ps_new_q | ps_dec;
    unique case (ps_q)
      PsIdle: if (|ps_cand) begin
        ps_d    = PsCalc;
        ps_oh_d = ps_first;
      end
      PsCalc: begin
        // The counters hold the completions of the earlier cycles; one that is subtracted in this cycle or
        // later (t_dec_q) is noted in ps_new.
        ps_owe_d = nx - ou - se;
        ps_new_d = ps_dec;
        ps_d     = PsSend;
      end
      PsSend: if (ps_fin) ps_d = PsIdle;
      default: ps_d = PsIdle;
    endcase
    for (int unsigned t = 0; t < T; t++) begin
      t_rf_d[t]    = t_rf_q[t] & ~t_take[t];
      // Marked again by every block that is done; the mark is taken off only when all that was done up to
      // the reading of the counters has been sent and nothing was done since.
      t_dirty_d[t] = (t_dirty_q[t] & ~(ps_fin & ps_oh_q[t] & ~ps_more & ~ps_new_q))
                   | (t_rf_q[t] & (t_dec_q[t] != '0));
      if (reg_hit && reg_oh[t]) begin
        t_rf_d[t]    = 1'b1;
        t_dirty_d[t] = 1'b1;
      end
      if (ins_oh[t]) begin
        t_rf_d[t]    = 1'b0;
        t_dirty_d[t] = 1'b0;
      end
      gone_d[t] = (gone_q[t] & ~(gone_take & gone_oh[t])) | (reg_gone & reg_oh[t]);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      t_rf_q    <= '0;
      t_dirty_q <= '0;
      gone_q    <= '0;
      ps_q      <= PsIdle;
    end else begin
      t_rf_q    <= t_rf_d;
      t_dirty_q <= t_dirty_d;
      gone_q    <= gone_d;
      ps_q      <= ps_d;
    end
  end

  always_ff @(posedge clk_i) begin
    ps_oh_q  <= ps_oh_d;
    ps_owe_q <= ps_owe_d;
    ps_new_q <= ps_new_d;
    for (int unsigned t = 0; t < T; t++) begin
      if (prog_take && ps_oh_q[t]) t_sent_q[t] <= ps_sent_new;
    end
    if (reg_hit) begin
      t_rfd_q[run_i.ptix]  <= run_i.fdom;
      t_rft_q[run_i.ptix]  <= run_i.tix;
      t_sent_q[run_i.ptix] <= '0;
    end
    if (reg_gone) begin
      gone_dom_q[run_i.ptix] <= run_i.fdom;
      gone_tix_q[run_i.ptix] <= run_i.tix;
    end
  end

  for (genvar t = 0; t < T; t++) begin : gen_task
    assign t_fin[t] = t_valid_q[t] & (t_next_q[t] == t_nblk_q[t]) & (t_out_q[t] == '0) & ~(t_rf_q[t] & t_dirty_q[t]);
  end

  // The decision of this cycle (cut_oh) is the last signal to arrive. Both outcomes of every counter and
  // flag are prepared from registers, so the decision only selects between them. For the same reason
  // the eligible blocks (t_inc) and the completions (t_dec) are added one cycle after they are found.
  always_comb begin
    t_valid_d = t_valid_q & ~t_take;
    t_ticks_d = t_ticks_q;
    t_acc_d   = t_acc_q;
    for (int unsigned t = 0; t < T; t++) begin
      logic [TickW-1:0] target;
      logic [NblkW:0]   sum;
      nblk_t            left_a, out_m;
      // Progress of the slot the task reads: the load in flight if it fills that slot, else complete.
      target = (ld_active_q && (ld_slot_q == t_slot_q[t])) ? ld_prog_q : TickW'(C);
      sum    = (NblkW+1)'(t_acc_q[t]) + (NblkW+1)'(t_nblk_q[t]);
      // One progress step per cycle: eligible = floor(steps * nblk / C), kept exact by the remainder in acc.
      t_inc_d[t] = '0;
      if (t_valid_q[t] && t_follow_q[t] && (t_ticks_q[t] < target)) begin
        t_ticks_d[t] = t_ticks_q[t] + TickW'(1);
        t_inc_d[t]   = nblk_t'(sum >> ChunkW);
        t_acc_d[t]   = sum[ChunkW-1:0];
      end
      // A chained task: the progress of the task it follows (it follows no stream at the same time).
      if (ret_valid_i && ret_i.prog && (ret_i.tix == tix_t'(t))) t_inc_d[t] = ret_i.all ? t_nblk_q[t] : nblk_t'(ret_i.n);
      left_a = t_left_q[t] + t_inc_q[t];
      out_m  = t_out_q[t] - nblk_t'(t_dec_q[t]);
      if (cut_oh[t]) begin
        t_next_d[t]  = t_next_q[t] + nblk_t'(1);
        t_left_d[t]  = left_a - nblk_t'(1);
        t_out_d[t]   = out_m + nblk_t'(1);
        t_avail_d[t] = left_a != nblk_t'(1);
        t_spare_d[t] = {1'b0, left_a} >= (NblkW+1)'(LendMin + 1);
      end else begin
        t_next_d[t]  = t_next_q[t];
        t_left_d[t]  = left_a;
        t_out_d[t]   = out_m;
        t_avail_d[t] = t_valid_q[t] & (left_a != '0);
        t_spare_d[t] = t_valid_q[t] & ({1'b0, left_a} >= (NblkW+1)'(LendMin));
      end
      if (ins_oh[t]) begin
        t_valid_d[t] = 1'b1;
        t_next_d[t]  = '0;
        t_out_d[t]   = '0;
        t_ticks_d[t] = '0;
        t_acc_d[t]   = '0;
        // A task that follows a stream or a task starts with no eligible block.
        t_left_d[t]  = ((run_i.follow & run_i.slot_v) | run_i.ftask) ? '0 : run_i.nblk;
        t_avail_d[t] = ~((run_i.follow & run_i.slot_v) | run_i.ftask);
        t_spare_d[t] = ~((run_i.follow & run_i.slot_v) | run_i.ftask) & ({1'b0, run_i.nblk} >= (NblkW+1)'(LendMin));
      end
    end
  end

  // Tensor backlog: the blocks not handed out yet of the tasks that tensor engines may run. Two counters that
  // wrap, the blocks that arrived with tasks and the blocks handed out, and their difference one cycle later.
  // So the decision of the cycle only steps a counter, and the wide additions start at registers.
  logic [BlkCntW-1:0]      tb_in_d, tb_in_q, tb_out_d, tb_out_q, tb_q;
  logic [T-1:0]            t_ten;
  logic [2**VslowW-1:0]    tb_over;      // the backlog exceeds what the tensor engines finish in 2^k - 1 block times
  logic                    v_near;       // a tensor engine within reach is, or is about to be, without work

  for (genvar t = 0; t < T; t++) begin : gen_ten
    assign t_ten[t] = t_cls_q[t][ClsT];
  end
  logic cut_ten;       // the block cut this cycle is of a task that tensor engines may run (set with cut_oh)
  assign tb_in_d  = tb_in_q + ((run_valid_i && run_i.cls[ClsT]) ? BlkCntW'(run_i.nblk) : '0);
  assign tb_out_d = cut_ten ? tb_out_q + BlkCntW'(1) : tb_out_q;

  // Per class, whether the backlog is deep: more blocks than the PEs of the class in this domain run in two
  // rounds. Only then is a next block prepared behind a busy PE. For the tensor engines this is the backlog
  // counted above; for the vector units it is enough to ask whether one task has that many eligible blocks
  // (a vector block is long, so preparing the next one early saves little).
  // A block prepared can no longer be given away or go to another group, and with a short backlog it may be
  // one of the last: a PE of another group or domain that becomes idle a moment later would have run it a
  // whole block sooner. (Measured on one domain of the cluster hardware: without this, single blocks of a
  // 128-block task were left for a round of their own.)
  localparam int unsigned DeepT = 2 * DomTensor;
  localparam int unsigned DeepV = 2 * GroupsPerDomain * NumVector;
  logic [T-1:0]            t_vdeep;
  logic [NumCls-1:0]       deep_q;
  for (genvar t = 0; t < T; t++) begin : gen_vec
    assign t_vdeep[t] = t_valid_q[t] & t_cls_q[t][ClsV] & (t_left_q[t] >= nblk_t'(DeepV));
  end

  // A task that names both classes with a hint keeps its blocks off the vector units unless the backlog
  // is large enough (tb_over, below) and no tensor engine within reach is without work (a block there ends
  // sooner than on a vector unit here). The flag is a register, read by the candidate logic in place of the
  // class bit; it follows the backlog a few cycles late.
  always_comb begin
    for (int unsigned t = 0; t < T; t++) begin
      t_vok_d[t] = t_cls_q[t][ClsV] & (~t_cls_q[t][ClsT] | (t_vslow_q[t] == '0)
                                       | (tb_over[t_vslow_q[t]] & ~v_near));
      // A new task with a hint starts with the vector units held; its fields are in the table next cycle.
      t_hv_d[t] = t_vok_d[t] & t_cls_q[t][ClsT] & (t_vslow_q[t] != '0);
      if (ins_oh[t]) begin
        t_vok_d[t] = run_i.cls[ClsV] & (~run_i.cls[ClsT] | (run_i.vslow == '0));
        t_hv_d[t]  = 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      t_valid_q <= '0;
      t_avail_q <= '0;
      t_spare_q <= '0;
      t_inc_q   <= '0;
      t_dec_q   <= '0;
      t_vok_q   <= '0;
      t_hv_q    <= '0;
      tb_q      <= '0;
      tb_in_q   <= '0;
      tb_out_q  <= '0;
      deep_q    <= '0;
    end else begin
      t_valid_q <= t_valid_d;
      t_avail_q <= t_avail_d;
      t_spare_q <= t_spare_d;
      t_inc_q   <= t_inc_d;
      t_dec_q   <= t_dec_d;
      t_vok_q   <= t_vok_d;
      t_hv_q    <= t_hv_d;
      tb_q      <= tb_in_q - tb_out_q;
      tb_in_q   <= tb_in_d;
      tb_out_q  <= tb_out_d;
      deep_q    <= {|t_vdeep, tb_q >= BlkCntW'(DeepT)};
    end
  end

  always_ff @(posedge clk_i) begin
    t_next_q  <= t_next_d;
    t_left_q  <= t_left_d;
    t_out_q   <= t_out_d;
    t_ticks_q <= t_ticks_d;
    t_acc_q   <= t_acc_d;
    if (run_valid_i) begin
      t_wid_q[ins_idx]    <= run_i.wid;
      t_cls_q[ins_idx]    <= run_i.cls;
      t_vslow_q[ins_idx]  <= run_i.vslow;
      t_nblk_q[ins_idx]   <= run_i.nblk;
      t_follow_q[ins_idx] <= run_i.follow & run_i.slot_v;
      t_slot_v_q[ins_idx] <= run_i.slot_v;
      t_slot_q[ins_idx]   <= run_i.slot;
      t_kern_q[ins_idx]   <= run_i.kern;
      t_arg_q[ins_idx]    <= run_i.arg;
    end
  end

  // -------------------------------------------------------------------------------------------
  // Candidates: the oldest task with a block for a class, for own PEs and for lending
  // -------------------------------------------------------------------------------------------
  logic [2*NumCls-1:0][T-1:0] sel_req, sel_gnt;
  logic [NumCls-1:0]          has_own, has_lend;

  // A PE class first takes the tasks that only it can run, then the tasks it shares with the other
  // class; within each, the oldest. This keeps tensor engines off blocks that vector units can do
  // while work is waiting that needs a tensor engine.
  for (genvar c = 0; c < NumCls; c++) begin : gen_cand
    logic [T-1:0] own_excl, own_any, lend_excl, lend_any;
    for (genvar t = 0; t < T; t++) begin : gen_t
      assign own_any[t]   = t_avail_q[t] & ((c == ClsV) ? t_vok_q[t] : t_cls_q[t][c]);
      assign own_excl[t]  = own_any[t] & (t_cls_q[t] == (cls_t'(1) << c));
      assign lend_any[t]  = own_any[t] & t_spare_q[t];
      assign lend_excl[t] = own_excl[t] & t_spare_q[t];
    end
    assign sel_req[c]        = (|own_excl)  ? own_excl  : own_any;
    assign sel_req[NumCls+c] = (|lend_excl) ? lend_excl : lend_any;
    assign has_own[c]        = |own_any;
    assign has_lend[c]       = |lend_any;
  end

  tsched_age_sel #(
    .N      (T),
    .NumSel (2 * NumCls)
  ) i_age (
    .clk_i,
    .rst_ni,
    .push_i    (run_valid_i),
    .push_oh_i (ins_oh),
    .valid_i   (t_valid_q),
    .req_i     (sel_req),
    .gnt_o     (sel_gnt)
  );

  // -------------------------------------------------------------------------------------------
  // Requesters
  // -------------------------------------------------------------------------------------------
  // gcred_q[g][c]: the next-block register of class c in group g is empty and no block is on its way.
  logic [G-1:0][NumCls-1:0] gcred_d, gcred_q;
  logic [G-1:0][NumCls-1:0] urg, pre;
  for (genvar g = 0; g < G; g++) begin : gen_grp_req
    assign urg[g] = gcred_q[g] & idle_i[g];
    assign pre[g] = gcred_q[g] & ~idle_i[g];
  end

  // The decision taken in the previous cycle.
  logic         d_v_q;          // a decision was taken
  logic         d_give_q;       // it answers a give command (also when there was no block to give)
  logic         d_bor_q;        // it passes a block of another domain on to a group
  logic [G-1:0] d_goh_q;        // group that gets the block, one-hot
  logic         d_cls_q;
  dom_t         d_rcv_q;        // give: the domain that receives the block
  logic [T-1:0] d_oh_q;         // task the block is cut from, one-hot; zero for a block of another domain
  blk_t         d_bblk_q;       // the block of another domain

  // Blocks of other domains wait in a short queue until a next-block register of their class is empty.
  // The cluster level sends a block only while it holds a credit for this queue.
  logic bor_empty, bor_full, bor_pop;
  blk_t bor_head;

  fifo_v3 #(
    .FALL_THROUGH (1'b0),
    .DEPTH        (BorDepth),
    .dtype        (blk_t)
  ) i_bor (
    .clk_i,
    .rst_ni,
    .flush_i    (1'b0),
    .testmode_i (1'b0),
    .full_o     (bor_full),
    .empty_o    (bor_empty),
    .usage_o    (/* unused */),
    .data_i     (bblk_i),
    .push_i     (bblk_valid_i),
    .data_o     (bor_head),
    .pop_i      (bor_pop)
  );

  // Two tiers of own requests: registers with an idle PE, registers that prepare the next block. Each
  // tier has its own round-robin select; both run in parallel and the tier is chosen last.
  localparam int unsigned NumOwn = G * NumCls;

  logic [NumOwn-1:0] r_urg, r_pre, g_urg, g_pre;

  // A task with a speed hint has a block that vector units may take.
  logic v_nopre;
  assign v_nopre = |(t_avail_q & t_hv_q);
  logic              any_urg, any_pre;
  logic              sel_g, sel_b, sel_u, sel_p;

  // A domain that took blocks of a class from here is busy with them and wants more when they are done, often
  // just after the PEs of this domain have taken their next blocks. Blocks prepared here in between would wait
  // behind busy PEs for a whole block while PEs of that domain are idle. So a class also counts as wanted while
  // blocks of it are away (away_nz, below) and for a few cycles after one has come back (rhold): then the PE
  // that ran it is idle and its want is on its way. A domain whose neighbours have work of their own gives
  // nothing away and prepares its next blocks as before.
  logic [NumCls-1:0] away_nz_q;
  logic [NumCls-1:0] wanted;
  logic              ret_recent;
  for (genvar c = 0; c < NumCls; c++) begin : gen_wanted
    assign wanted[c] = BalEn & BalHold & (wanted_i[c] | away_nz_q[c] | ret_recent);
  end

  for (genvar g = 0; g < G; g++) begin : gen_r_own
    for (genvar c = 0; c < NumCls; c++) begin : gen_c
      assign r_urg[g * NumCls + c] = urg[g][c] & has_own[c];
      // No block is prepared in advance for a class another domain wants: it could not be given away. Nor
      // while the backlog of the class is short (deep, above).
      // Nor for a vector unit while a task with a speed hint could supply it: a block parked behind a busy
      // vector unit starts a whole vector block later, and the hint says a tensor engine is faster.
      assign r_pre[g * NumCls + c] = pre[g][c] & has_own[c] & ~wanted[c] & deep_q[c]
                                   & ~((c == ClsV) & v_nopre);
    end
  end

  tsched_rr_sel #(.N (NumOwn)) i_sel_urg (
    .clk_i,
    .rst_ni,
    .req_i  (r_urg),
    .take_i (sel_u),
    .any_o  (any_urg),
    .gnt_o  (g_urg)
  );

  tsched_rr_sel #(.N (NumOwn)) i_sel_pre (
    .clk_i,
    .rst_ni,
    .req_i  (r_pre),
    .take_i (sel_p),
    .any_o  (any_pre),
    .gnt_o  (g_pre)
  );

  // A block of another domain: the group that takes it is the first with an idle PE of its class, else
  // the first with an empty register.
  logic [NumCls-1:0][G-1:0] b_pick;
  logic [NumCls-1:0]        b_room;
  logic                     b_any, b_cls;
  logic [G-1:0]             b_goh;

  always_comb begin
    for (int unsigned c = 0; c < NumCls; c++) begin
      logic [G-1:0] u, e, u_first, e_first;
      for (int unsigned g = 0; g < G; g++) begin
        u[g] = urg[g][c];
        e[g] = gcred_q[g][c];
      end
      for (int unsigned g = 0; g < G; g++) begin
        u_first[g] = u[g] & ~(|(u & G'((32'd1 << g) - 32'd1)));
        e_first[g] = e[g] & ~(|(e & G'((32'd1 << g) - 32'd1)));
      end
      b_pick[c] = (|u) ? u_first : e_first;
      b_room[c] = |e;
    end
  end
  assign b_cls = bor_head.pcls;
  assign b_any = ~bor_empty & b_room[b_cls];
  assign b_goh = b_pick[b_cls];

  // One decision per cycle, in this order:
  //   give  a give command of the cluster level: one block of the oldest task that can spare one leaves
  //         for another domain. It goes first so that the answer returns after a fixed number of cycles.
  //   b     a block of another domain goes to a group (it was asked for because own tasks had nothing)
  //   u     an own block for a register with an idle PE
  //   p     an own block for a register that prepares the next block
  logic [T-1:0] k_give;
  assign k_give = (BalEn && has_lend[give_i.cls]) ? sel_gnt[NumCls + 32'(give_i.cls)] : '0;

  assign sel_g   = give_valid_i;
  assign sel_b   = ~sel_g & b_any;
  assign sel_u   = ~sel_g & ~b_any & any_urg;
  assign sel_p   = ~sel_g & ~b_any & ~any_urg & any_pre;
  assign bor_pop = sel_b;

  // Per tier: the class of the winner and the task its block is cut from (the grants are one-hot).
  logic [NumCls-1:0] c_urg, c_pre;
  logic [T-1:0]      k_urg, k_pre;
  always_comb begin
    c_urg = '0;
    c_pre = '0;
    for (int unsigned c = 0; c < NumCls; c++) begin
      for (int unsigned g = 0; g < G; g++) begin
        c_urg[c] |= g_urg[g * NumCls + c];
        c_pre[c] |= g_pre[g * NumCls + c];
      end
    end
    k_urg = '0;
    k_pre = '0;
    for (int unsigned c = 0; c < NumCls; c++) begin
      k_urg |= {T{c_urg[c]}} & sel_gnt[c];
      k_pre |= {T{c_pre[c]}} & sel_gnt[c];
    end
  end

  assign cut_oh = ({T{sel_g}} & k_give) | ({T{sel_u}} & k_urg) | ({T{sel_p}} & k_pre);
  // The same choice, reduced per tier in parallel, so that the backlog counter sees it as early as the tasks do.
  assign cut_ten = (sel_g & (|(k_give & t_ten))) | (sel_u & (|(k_urg & t_ten))) | (sel_p & (|(k_pre & t_ten)));

  // -------------------------------------------------------------------------------------------
  // Speed hint: how long the tensor engines need for the backlog
  // -------------------------------------------------------------------------------------------
  // eng: the tensor engines that work on tasks of this domain, its own and one per block that a tensor engine of
  // another domain runs (given away for that class and not back yet). awayv: the same count for vector units.
  // With a hint 2^k, a vector unit takes a block only while the backlog
  // exceeds what these engines finish in 2^k - 1 block times: they are busy for up to one block time more, so
  // they need up to 1 + backlog / eng, and the vector unit needs 2^k. When a block has come back, the vector
  // units also wait a few cycles: the engine that ran it is idle, and the news that it wants another block
  // (wanted_i) is still on its way.
  localparam int unsigned ThrW    = BlkCntW + VslowW + 1;
  localparam int unsigned RetHold = 15;
  logic [BlkCntW-1:0]                  eng_d, eng_q, awayv_d, awayv_q;
  logic [NumCls-1:0]                   give_c, ret_c;
  logic [2**VslowW-1:1][ThrW-1:0]      thr_d, thr_q;
  logic [3:0]                          rhold_d, rhold_q;
  logic                                give_ok;

  assign give_ok = d_v_q & d_give_q & (|d_oh_q);
  assign v_near  = BalEn & VecHoldNear & (wanted_i[ClsT] | (rhold_q != '0));
  assign ret_recent = rhold_q != '0;
  for (genvar c = 0; c < NumCls; c++) begin : gen_away
    assign give_c[c] = give_ok & (d_cls_q == 1'(c));
    assign ret_c[c]  = ret_valid_i & ~ret_i.prog & (ret_i.cls == 1'(c));
  end

  always_comb begin
    eng_d   = eng_q;
    awayv_d = awayv_q;
    if (give_c[ClsT] && !ret_c[ClsT]) eng_d   = eng_q + BlkCntW'(1);
    if (!give_c[ClsT] && ret_c[ClsT]) eng_d   = eng_q - BlkCntW'(1);
    if (give_c[ClsV] && !ret_c[ClsV]) awayv_d = awayv_q + BlkCntW'(1);
    if (!give_c[ClsV] && ret_c[ClsV]) awayv_d = awayv_q - BlkCntW'(1);
    rhold_d = rhold_q;
    if (rhold_q != '0) rhold_d = rhold_q - 4'd1;
    if (ret_valid_i && !ret_i.prog) rhold_d = 4'(RetHold);
    tb_over[0] = 1'b1;
    for (int unsigned k = 1; k < 2**VslowW; k++) begin
      thr_d[k]   = ThrW'(eng_q) * ThrW'((1 << k) - 1);
      tb_over[k] = ThrW'(tb_q) > thr_q[k];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      eng_q     <= BlkCntW'(DomTensor);
      awayv_q   <= '0;
      away_nz_q <= '0;
      rhold_q   <= '0;
      for (int unsigned k = 1; k < 2**VslowW; k++) thr_q[k] <= ThrW'(DomTensor * ((1 << k) - 1));
    end else begin
      eng_q     <= eng_d;
      awayv_q   <= awayv_d;
      away_nz_q <= {awayv_d != '0, eng_d != BlkCntW'(DomTensor)};
      rhold_q   <= rhold_d;
      thr_q   <= thr_d;
    end
  end

  // The next-block register that gets a block, one-hot over group and class.
  logic [G-1:0][NumCls-1:0] send_oh;
  logic [G-1:0]             send_goh;
  logic                     send_cls;
  always_comb begin
    for (int unsigned g = 0; g < G; g++) begin
      for (int unsigned c = 0; c < NumCls; c++) begin
        send_oh[g][c] = (sel_b & b_goh[g] & (b_cls == 1'(c)))
                      | (sel_u & g_urg[g * NumCls + c])
                      | (sel_p & g_pre[g * NumCls + c]);
      end
      send_goh[g] = |send_oh[g];
    end
    send_cls = (sel_g & give_i.cls) | (sel_b & b_cls) | (sel_u & c_urg[NumCls-1]) | (sel_p & c_pre[NumCls-1]);
  end

  // -------------------------------------------------------------------------------------------
  // Block outputs
  // -------------------------------------------------------------------------------------------
  // The block of the previous cycle's decision, read from the task table. The counter of the task has
  // moved on by one since the decision, so the index of the block is that counter minus one.
  blk_t  asm_blk;
  gblk_t out_blk;
  nblk_t asm_next;
  always_comb begin
    asm_blk  = '0;
    asm_next = '0;
    for (int unsigned t = 0; t < T; t++) begin
      if (d_oh_q[t]) begin
        asm_blk.kern   = t_kern_q[t];
        asm_blk.arg    = t_arg_q[t];
        asm_blk.nblk   = t_nblk_q[t];
        asm_blk.slot_v = t_slot_v_q[t];
        asm_blk.slot   = t_slot_q[t];
        asm_blk.tix    = tix_t'(t);
        asm_next       = t_next_q[t];
      end
    end
    asm_blk.bidx = asm_next - nblk_t'(1);
    asm_blk.dom  = dom_t'(DomId);
    asm_blk.pcls = d_cls_q;
  end
  assign out_blk = d_bor_q ? '{bor: 1'b1, b: d_bblk_q} : '{bor: 1'b0, b: asm_blk};

  assign gcred_d = (gcred_q | pop_i) & ~send_oh;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      d_v_q        <= 1'b0;
      d_give_q     <= 1'b0;
      blk_valid_o  <= '0;
      rblk_valid_o <= 1'b0;
      bpop_valid_o <= 1'b0;
      gcred_q      <= '1;
    end else begin
      d_v_q        <= sel_g | sel_b | sel_u | sel_p;
      d_give_q     <= sel_g;
      blk_valid_o  <= {G{d_v_q & ~d_give_q}} & d_goh_q;
      rblk_valid_o <= d_v_q & d_give_q;
      bpop_valid_o <= sel_b;
      gcred_q      <= gcred_d;
    end
  end

  always_ff @(posedge clk_i) begin
    d_bor_q <= sel_b;
    d_goh_q <= send_goh;
    d_cls_q <= send_cls;
    d_oh_q  <= cut_oh;
    if (sel_g) d_rcv_q  <= give_i.rcv;
    if (sel_b) d_bblk_q <= bor_head;
    bpop_cls_o <= b_cls;
    for (int unsigned g = 0; g < G; g++) begin
      if (d_v_q && !d_give_q && d_goh_q[g]) blk_o[g] <= out_blk;
    end
    if (d_v_q && d_give_q) rblk_o <= '{ok: |d_oh_q, rcv: d_rcv_q, b: asm_blk};
  end

  // -------------------------------------------------------------------------------------------
  // Report to the cluster level
  // -------------------------------------------------------------------------------------------
  // want: groups with an idle PE of the class, an empty register, and no own block for that class.
  //       Vector units do not ask for blocks while the domain holds a task with a speed hint: it keeps them
  //       free on purpose, or will need them itself, and a block of another domain would wait behind them.
  // give: a task can spare a block for the class and no own register with an idle PE waits for one.
  rep_t rep_d;
  logic has_hint;
  always_comb begin
    has_hint = 1'b0;
    for (int unsigned t = 0; t < T; t++) has_hint |= t_valid_q[t] & t_cls_q[t][ClsT] & t_cls_q[t][ClsV] & (t_vslow_q[t] != '0);
  end
  always_comb begin
    rep_d = '0;
    for (int unsigned c = 0; c < NumCls; c++) begin
      if (BalEn && !has_own[c] && !((c == ClsV) && has_hint)) begin
        for (int unsigned g = 0; g < G; g++) rep_d.want[c] += WantW'(urg[g][c]);
      end
      rep_d.give[c] = BalEn & has_lend[c] & ~any_urg;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rep_o <= '0;
    end else begin
      rep_o <= rep_d;
    end
  end

  // -------------------------------------------------------------------------------------------
  // Completions of blocks
  // -------------------------------------------------------------------------------------------
  // A completion of an own block is always taken. A completion of a block of another domain needs the
  // return register, from which it leaves to the cluster level; among the groups the lowest wins.
  logic         ret_v_d, ret_v_q;
  dom_t         ret_dom_q;
  tix_t         ret_tix_q;
  logic         ret_cls_q;
  logic         ret_take;       // the return moves to the output register
  logic         ret_free;
  logic [G-1:0] ret_want, ret_first;

  assign ret_free = ~ret_v_q | ret_take;

  always_comb begin
    for (int unsigned g = 0; g < G; g++) begin
      ret_want[g] = gdone_valid_i[g] & gdone_i[g].bor;
    end
    for (int unsigned g = 0; g < G; g++) begin
      ret_first[g]     = ret_want[g] & ~(|(ret_want & G'((32'd1 << g) - 32'd1)));
      gdone_ready_o[g] = ~gdone_i[g].bor | (ret_first[g] & ret_free);
    end
    ret_v_d = (ret_v_q & ~ret_take) | ((|ret_want) & ret_free);
  end

  always_comb begin
    for (int unsigned t = 0; t < T; t++) begin
      t_dec_d[t] = DecW'(ret_valid_i & ~ret_i.prog & (ret_i.tix == tix_t'(t)));
      for (int unsigned g = 0; g < G; g++) begin
        t_dec_d[t] += DecW'(gdone_valid_i[g] & ~gdone_i[g].bor & (gdone_i[g].tix == tix_t'(t)));
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ret_v_q <= 1'b0;
    end else begin
      ret_v_q <= ret_v_d;
    end
  end

  always_ff @(posedge clk_i) begin
    if ((|ret_want) && ret_free) begin
      for (int unsigned g = 0; g < G; g++) begin
        if (ret_first[g]) begin
          ret_dom_q <= gdone_i[g].dom;
          ret_tix_q <= gdone_i[g].tix;
          ret_cls_q <= gdone_cls_i[g];
        end
      end
    end
  end

  // -------------------------------------------------------------------------------------------
  // Completions to the cluster level: the load first, then the answer to a late registration, a block run
  // for another domain, progress for a follower, and the lowest finished task
  // -------------------------------------------------------------------------------------------
  logic  done_v_d, done_v_q;
  done_t done_d, done_q;
  logic  done_can, done_load;

  assign done_valid_o = done_v_q;
  assign done_o       = done_q;
  assign done_can     = ~done_v_q | done_ready_i;
  assign done_load    = done_can & ld_fin;
  assign ld_take      = done_load;
  assign gone_take    = done_can & ~ld_fin & (|gone_q);
  assign ret_take     = done_can & ~ld_fin & ~(|gone_q) & ret_v_q;
  assign prog_take    = done_can & ~ld_fin & ~(|gone_q) & ~ret_v_q & (ps_q == PsSend) & (ps_owe_q != '0);

  always_comb begin
    t_take   = '0;
    done_v_d = done_v_q & ~done_ready_i;
    done_d   = done_q;
    if (done_load) begin
      done_v_d = 1'b1;
      done_d   = '{wid: ld_wid_q, is_load: 1'b1, is_ret: 1'b0, nblk: '0, dom: '0, tix: '0};
    end else if (gone_take) begin
      done_v_d = 1'b1;
      done_d   = '{wid: '0, is_load: 1'b0, is_ret: 1'b1, nblk: nblk_t'(3'b110), dom: '0, tix: '0};   // all, prog
      for (int unsigned t = 0; t < T; t++) begin
        done_d.dom |= {DomW{gone_oh[t]}} & gone_dom_q[t];
        done_d.tix |= {TixW{gone_oh[t]}} & gone_tix_q[t];
      end
    end else if (ret_take) begin
      done_v_d = 1'b1;
      done_d   = '{wid: '0, is_load: 1'b0, is_ret: 1'b1, nblk: nblk_t'(ret_cls_q), dom: ret_dom_q, tix: ret_tix_q};
    end else if (prog_take) begin
      done_v_d = 1'b1;
      done_d   = '{wid: '0, is_load: 1'b0, is_ret: 1'b1, nblk: nblk_t'({prog_n, 3'b010}), dom: '0, tix: '0};   // n, prog
      for (int unsigned t = 0; t < T; t++) begin
        done_d.dom |= {DomW{ps_oh_q[t]}} & t_rfd_q[t];
        done_d.tix |= {TixW{ps_oh_q[t]}} & t_rft_q[t];
      end
    end else if (done_can) begin
      for (int t = T - 1; t >= 0; t--) begin
        if (t_fin[t]) begin
          t_take    = '0;
          t_take[t] = 1'b1;
          done_v_d  = 1'b1;
          done_d    = '{wid: t_wid_q[t], is_load: 1'b0, is_ret: 1'b0, nblk: t_nblk_q[t], dom: '0, tix: tix_t'(t)};
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      done_v_q <= 1'b0;
    end else begin
      done_v_q <= done_v_d;
    end
  end

  always_ff @(posedge clk_i) begin
    done_q <= done_d;
  end

`ifndef TARGET_SYNTHESIS
  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!(run_valid_i && t_valid_q[ins_idx])) else $error("[tsched_domain %0d] task for entry %0d, which is in use", DomId, ins_idx);
      assert (!(ret_valid_i && ret_i.prog && !t_valid_q[ret_i.tix]))
        else $error("[tsched_domain %0d] progress for entry %0d, which holds no task", DomId, ret_i.tix);
      assert (!(reg_gone && gone_q[run_i.ptix] && !(gone_take && gone_oh[run_i.ptix])))
        else $error("[tsched_domain %0d] two late registrations for entry %0d", DomId, run_i.ptix);
      assert (!(reg_hit && t_rf_q[run_i.ptix]))
        else $error("[tsched_domain %0d] entry %0d gets a second follower", DomId, run_i.ptix);
      assert (!(load_valid_i && ld_active_q && !ld_take))
        else $error("[tsched_domain %0d] load while a load is streaming", DomId);
      for (int unsigned g = 0; g < G; g++) assert (!(dma_done_i[g] && (ld_issued_q[g] == ld_cdone_q[g]))) else $error("[tsched_domain %0d] DMA completion without a chunk", DomId);
      assert (!(ret_c[ClsT] && !give_c[ClsT] && (eng_q == BlkCntW'(DomTensor))))
        else $error("[tsched_domain %0d] a block came back from a tensor engine that was not away", DomId);
      assert (!(ret_c[ClsV] && !give_c[ClsV] && (awayv_q == '0)))
        else $error("[tsched_domain %0d] a block came back from a vector unit that was not away", DomId);
      assert (cut_ten == (|(cut_oh & t_ten))) else $error("[tsched_domain %0d] backlog counter out of step", DomId);
      assert ($onehot0(cut_oh)) else $error("[tsched_domain %0d] block cut from two tasks", DomId);
      assert ($onehot0(send_oh)) else $error("[tsched_domain %0d] block sent to two registers", DomId);
      assert ((send_oh & ~gcred_q) == '0) else $error("[tsched_domain %0d] block sent to a full register", DomId);
      assert (!(sel_u | sel_p) || (|cut_oh)) else $error("[tsched_domain %0d] decision without a task", DomId);
      assert (!(bblk_valid_i && bor_full)) else $error("[tsched_domain %0d] block of another domain without room", DomId);
      assert (!(bblk_valid_i && (bblk_i.dom == dom_t'(DomId))))
        else $error("[tsched_domain %0d] own block returned as a block of another domain", DomId);
      for (int unsigned t = 0; t < T; t++) begin
        assert (!(t_valid_q[t] && (32'(t_dec_q[t]) > 32'(t_out_q[t]))))
          else $error("[tsched_domain %0d] task %0d: more completions than blocks running", DomId, t);
        assert (!(t_valid_q[t] && t_cls_q[t][ClsT] && (32'(BlkCntW'(tb_in_q - tb_out_q)) < 32'(t_nblk_q[t] - t_next_q[t]))))
          else $error("[tsched_domain %0d] task %0d: tensor backlog below the blocks the task has left", DomId, t);
        assert (!(t_valid_q[t] && (32'(t_next_q[t]) + 32'(t_left_q[t]) + 32'(t_inc_q[t]) > 32'(t_nblk_q[t]))))
          else $error("[tsched_domain %0d] task %0d: more blocks eligible than it has", DomId, t);
        assert (!(cut_oh[t] && !t_avail_q[t]))
          else $error("[tsched_domain %0d] task %0d: block cut without an eligible one", DomId, t);
        assert (!(ret_valid_i && (ret_i.tix == tix_t'(t)) && !t_valid_q[t]))
          else $error("[tsched_domain %0d] completion of a given block for task %0d, which is not in the table", DomId, t);
      end
    end
  end
  // pragma translate_on
`endif

endmodule
