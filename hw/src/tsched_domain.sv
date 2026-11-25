// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Domain scheduler: one per scheduling domain (a 2 x 2 square of mesh groups).
//
// Tasks     It holds up to DomTaskDepth tasks from the cluster level. A task is a count of blocks, so
//           cutting is a counter: `next` blocks have been handed out, `elig` may be handed out, `out`
//           are running. A task is done when all its blocks have been handed out and none is running
//           (the join counter).
// Stream    One load at a time. Each group DMA moves its share of the load in ChunksPerGroup chunks; the
//           chunks every group has finished are the progress of the slot. A task that follows the
//           stream gets its blocks eligible in proportion to that progress.
// Dispatch  One block per cycle goes to a next-block register of a group dispatcher. A register with an
//           idle PE behind it is served before a register that only prepares the next block.
//           The decision (which task, for whom) and the block itself are one register stage apart: the
//           counters of the task move with the decision, the fields of the block are read from the
//           task table in the next cycle. A task with a block running stays in the table, so these
//           fields are stable for that read.
//           The decision is built so that everything it needs is prepared in parallel: the flags of the
//           tasks are registers, each tier of requests has its own select with a one-hot grant, and the
//           counters have both outcomes ready. See the comments at each part.
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
  input  logic                                    ret_valid_i,    // a block given away is done
  input  tix_t                                    ret_tix_i
);

  localparam int unsigned G     = GroupsPerDomain;
  localparam int unsigned T     = DomTaskDepth;
  localparam int unsigned C     = ChunksPerGroup;
  localparam int unsigned TickW = ChunkW + 1;
  localparam int unsigned DecW  = $clog2(G + 2);

  // -------------------------------------------------------------------------------------------
  // Stream: one load at a time
  // -------------------------------------------------------------------------------------------
  logic                    ld_active_d, ld_active_q;
  wid_t                    ld_wid_q;
  slot_t                   ld_slot_q;
  len_t                    ld_clen_q;
  addr_t [G-1:0]           ld_ptr_q;
  logic  [G-1:0]           ld_busy_d, ld_busy_q;
  logic  [G-1:0][TickW-1:0] ld_issued_d, ld_issued_q, ld_cdone_d, ld_cdone_q;
  logic  [TickW-1:0]       ld_prog_d, ld_prog_q;
  logic  [G-1:0]           dma_fire;
  logic                    ld_fin;
  logic                    ld_take;       // the completion of the load moves to the output register

  for (genvar g = 0; g < G; g++) begin : gen_dma
    assign dma_valid_o[g] = ld_active_q & ~ld_busy_q[g] & (ld_issued_q[g] != TickW'(C));
    assign dma_o[g]       = '{slot: ld_slot_q, chunk: ld_issued_q[g][ChunkW-1:0], len: ld_clen_q, addr: ld_ptr_q[g]};
    assign dma_fire[g]    = dma_valid_o[g] & dma_ready_i[g];
  end

  always_comb begin
    ld_active_d = ld_active_q;
    ld_busy_d   = (ld_busy_q | dma_fire) & ~dma_done_i;
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
      ld_busy_d   = '0;
      ld_issued_d = '0;
      ld_cdone_d  = '0;
      ld_prog_d   = '0;
    end
  end

  always_comb begin
    ld_fin = ld_active_q;
    for (int unsigned g = 0; g < G; g++) ld_fin &= ld_cdone_q[g] == TickW'(C);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ld_active_q <= 1'b0;
      ld_busy_q   <= '0;
      ld_issued_q <= '0;
      ld_cdone_q  <= '0;
      ld_prog_q   <= '0;
    end else begin
      ld_active_q <= ld_active_d;
      ld_busy_q   <= ld_busy_d;
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
      // Group g streams the g-th quarter of the load.
      for (int unsigned g = 0; g < G; g++) ld_ptr_q[g] <= load_i.addr + AddrW'(g) * AddrW'(load_i.len >> GrpW);
    end else begin
      for (int unsigned g = 0; g < G; g++) begin
        if (dma_fire[g]) ld_ptr_q[g] <= ld_ptr_q[g] + AddrW'(ld_clen_q);
      end
    end
  end

  // -------------------------------------------------------------------------------------------
  // Task table
  // -------------------------------------------------------------------------------------------
  logic  [T-1:0]             t_valid_d, t_valid_q;
  wid_t  [T-1:0]             t_wid_q;
  cls_t  [T-1:0]             t_cls_q;
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
  logic                      ins_none;
  logic  [T-1:0]             t_fin;
  logic  [T-1:0]             cut_oh;                 // the task a block is cut from this cycle
  logic  [T-1:0][DecW-1:0]   t_dec_d, t_dec_q;       // completions per task, subtracted from t_out next
  logic  [T-1:0]             t_take;                 // the completion of the task moves to the output register

  lzc #(
    .WIDTH (T),
    .MODE  (1'b0)
  ) i_lzc_ins (
    .in_i    (~t_valid_q),
    .cnt_o   (ins_idx),
    .empty_o (ins_none)
  );

  always_comb begin
    ins_oh = '0;
    ins_oh[ins_idx] = run_valid_i;
  end

  for (genvar t = 0; t < T; t++) begin : gen_task
    assign t_fin[t] = t_valid_q[t] & (t_next_q[t] == t_nblk_q[t]) & (t_out_q[t] == '0);
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
        // A task that follows a stream starts with no eligible block.
        t_left_d[t]  = (run_i.follow & run_i.slot_v) ? '0 : run_i.nblk;
        t_avail_d[t] = ~(run_i.follow & run_i.slot_v);
        t_spare_d[t] = ~(run_i.follow & run_i.slot_v) & ({1'b0, run_i.nblk} >= (NblkW+1)'(LendMin));
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
    end else begin
      t_valid_q <= t_valid_d;
      t_avail_q <= t_avail_d;
      t_spare_q <= t_spare_d;
      t_inc_q   <= t_inc_d;
      t_dec_q   <= t_dec_d;
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
      assign own_any[t]   = t_avail_q[t] & t_cls_q[t][c];
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
  logic              any_urg, any_pre;
  logic              sel_g, sel_b, sel_u, sel_p;

  for (genvar g = 0; g < G; g++) begin : gen_r_own
    for (genvar c = 0; c < NumCls; c++) begin : gen_c
      assign r_urg[g * NumCls + c] = urg[g][c] & has_own[c];
      assign r_pre[g * NumCls + c] = pre[g][c] & has_own[c];
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
  // give: a task can spare a block for the class and no own register with an idle PE waits for one.
  rep_t rep_d;
  always_comb begin
    rep_d = '0;
    for (int unsigned c = 0; c < NumCls; c++) begin
      if (BalEn && !has_own[c]) begin
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
      t_dec_d[t] = DecW'(ret_valid_i & (ret_tix_i == tix_t'(t)));
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
        end
      end
    end
  end

  // -------------------------------------------------------------------------------------------
  // Completions to the cluster level: the load first, then a block run for another domain, then the
  // lowest finished task
  // -------------------------------------------------------------------------------------------
  logic  done_v_d, done_v_q;
  done_t done_d, done_q;
  logic  done_can, done_load;

  assign done_valid_o = done_v_q;
  assign done_o       = done_q;
  assign done_can     = ~done_v_q | done_ready_i;
  assign done_load    = done_can & ld_fin;
  assign ld_take      = done_load;
  assign ret_take     = done_can & ~ld_fin & ret_v_q;

  always_comb begin
    t_take   = '0;
    done_v_d = done_v_q & ~done_ready_i;
    done_d   = done_q;
    if (done_load) begin
      done_v_d = 1'b1;
      done_d   = '{wid: ld_wid_q, is_load: 1'b1, is_ret: 1'b0, nblk: '0, dom: '0, tix: '0};
    end else if (ret_take) begin
      done_v_d = 1'b1;
      done_d   = '{wid: '0, is_load: 1'b0, is_ret: 1'b1, nblk: '0, dom: ret_dom_q, tix: ret_tix_q};
    end else if (done_can) begin
      for (int t = T - 1; t >= 0; t--) begin
        if (t_fin[t]) begin
          t_take    = '0;
          t_take[t] = 1'b1;
          done_v_d  = 1'b1;
          done_d    = '{wid: t_wid_q[t], is_load: 1'b0, is_ret: 1'b0, nblk: t_nblk_q[t], dom: '0, tix: '0};
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
      assert (!(run_valid_i && ins_none)) else $error("[tsched_domain %0d] task without a free entry", DomId);
      assert (!(load_valid_i && ld_active_q && !ld_take))
        else $error("[tsched_domain %0d] load while a load is streaming", DomId);
      assert ((dma_done_i & ~ld_busy_q) == '0) else $error("[tsched_domain %0d] DMA completion without a chunk", DomId);
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
        assert (!(cut_oh[t] && !t_avail_q[t]))
          else $error("[tsched_domain %0d] task %0d: block cut without an eligible one", DomId, t);
        assert (!(ret_valid_i && (ret_tix_i == tix_t'(t)) && !t_valid_q[t]))
          else $error("[tsched_domain %0d] completion of a given block for task %0d, which is not in the table", DomId, t);
      end
    end
  end
  // pragma translate_on
`endif

endmodule
