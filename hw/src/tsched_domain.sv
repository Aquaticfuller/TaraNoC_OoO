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
// Lending   A domain whose idle PEs find no block asks one neighbour at a time. A neighbour hands out a
//           block of its own tasks when none of its own idle PEs can take it. The completion of a lent
//           block returns to the lender, which keeps the join counter.

module tsched_domain import tsched_pkg::*; #(
  parameter int unsigned       DomId   = 0,
  parameter logic [NumDir-1:0] NbMask  = '1,      // directions in which a neighbour exists
  parameter bit                LendEn  = 1'b1,
  parameter int unsigned       LendMin = 1        // eligible blocks a task must have left to lend one
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
  // neighbours
  output logic     [NumDir-1:0][NumCls-1:0]       nb_want_o,       // this domain asks for a block
  input  logic     [NumDir-1:0][NumCls-1:0]       nb_want_i,
  output logic     [NumDir-1:0]                   nb_blk_valid_o,  // blocks lent
  input  logic     [NumDir-1:0]                   nb_blk_ready_i,
  output blk_t     [NumDir-1:0]                   nb_blk_o,
  input  logic     [NumDir-1:0]                   nb_blk_valid_i,  // blocks borrowed
  output logic     [NumDir-1:0]                   nb_blk_ready_o,
  input  blk_t     [NumDir-1:0]                   nb_blk_i,
  output logic     [NumDir-1:0]                   nb_ret_valid_o,  // completions of borrowed blocks
  input  logic     [NumDir-1:0]                   nb_ret_ready_i,
  output tix_t     [NumDir-1:0]                   nb_ret_o,
  input  logic     [NumDir-1:0]                   nb_ret_valid_i,  // completions of lent blocks, always taken
  input  tix_t     [NumDir-1:0]                   nb_ret_i
);

  localparam int unsigned G     = GroupsPerDomain;
  localparam int unsigned T     = DomTaskDepth;
  localparam int unsigned C     = ChunksPerGroup;
  localparam int unsigned TickW = ChunkW + 1;
  localparam int unsigned DecW  = $clog2(G + NumDir + 1);

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
  logic              d_v_q;          // a block was decided
  logic              d_bor_q;        // it is a borrowed block, passed on to a group
  logic              d_nb_q;         // it is lent to a neighbour
  logic [G-1:0]      d_goh_q;        // group that gets it, one-hot
  logic              d_cls_q;
  logic [NumDir-1:0] d_doh_q;        // direction it is lent to or was borrowed from, one-hot
  logic [T-1:0]      d_oh_q;         // task it is cut from, one-hot
  blk_t              d_bblk_q;       // the borrowed block

  // A lent block waits in a register per direction. A new block is decided for a direction only when
  // that register is empty and no block is on its way into it. The ready of the neighbour is not used
  // here, so no path runs from one domain's decision through the neighbour into the next decision.
  logic [NumDir-1:0] lend_v_d, lend_v_q;
  blk_t [NumDir-1:0] lend_q;
  logic [NumDir-1:0] lend_free;
  assign lend_free      = ~lend_v_q & ~({NumDir{d_v_q & d_nb_q}} & d_doh_q);
  assign nb_blk_valid_o = lend_v_q;
  assign nb_blk_o       = lend_q;

  // Three tiers of requests: own registers with an idle PE, neighbours, own registers that prepare the
  // next block. Each tier has its own round-robin select; all three run in parallel and the tier is
  // chosen last.
  localparam int unsigned NumOwn = G * NumCls;
  localparam int unsigned NumNb  = NumDir * NumCls;

  logic [NumOwn-1:0] r_urg, r_pre, g_urg, g_pre;
  logic [NumNb-1:0]  r_nb, g_nb;
  logic              any_urg, any_nb, any_pre;
  logic              sel_b, sel_u, sel_n, sel_p;

  for (genvar g = 0; g < G; g++) begin : gen_r_own
    for (genvar c = 0; c < NumCls; c++) begin : gen_c
      assign r_urg[g * NumCls + c] = urg[g][c] & has_own[c];
      assign r_pre[g * NumCls + c] = pre[g][c] & has_own[c];
    end
  end
  for (genvar d = 0; d < NumDir; d++) begin : gen_r_nb
    for (genvar c = 0; c < NumCls; c++) begin : gen_c
      assign r_nb[d * NumCls + c] = LendEn & NbMask[d] & nb_want_i[d][c] & has_lend[c] & lend_free[d];
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

  tsched_rr_sel #(.N (NumNb)) i_sel_nb (
    .clk_i,
    .rst_ni,
    .req_i  (r_nb),
    .take_i (sel_n),
    .any_o  (any_nb),
    .gnt_o  (g_nb)
  );

  tsched_rr_sel #(.N (NumOwn)) i_sel_pre (
    .clk_i,
    .rst_ni,
    .req_i  (r_pre),
    .take_i (sel_p),
    .any_o  (any_pre),
    .gnt_o  (g_pre)
  );

  // Borrowed blocks go first: they are only requested when the own tasks had nothing for that class.
  // Per class, the group that takes one: the first with an idle PE, else the first empty register.
  logic [NumCls-1:0][G-1:0] b_pick;
  logic [NumCls-1:0]        b_room;
  logic [NumDir-1:0]        b_can, b_doh;
  logic                     b_cls;
  logic [G-1:0]             b_goh;
  blk_t                     b_blk;

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
    for (int unsigned d = 0; d < NumDir; d++) begin
      b_can[d] = nb_blk_valid_i[d] & b_room[nb_blk_i[d].pcls];
    end
    b_cls = 1'b0;
    b_blk = '0;
    for (int unsigned d = 0; d < NumDir; d++) begin
      b_doh[d] = b_can[d] & ~(|(b_can & NumDir'((32'd1 << d) - 32'd1)));
      b_cls   |= b_doh[d] & nb_blk_i[d].pcls;
      b_blk   |= {$bits(blk_t){b_doh[d]}} & nb_blk_i[d];
    end
    b_goh = b_pick[b_cls];
  end

  assign sel_b          = |b_can;
  assign sel_u          = ~sel_b & any_urg;
  assign sel_n          = ~sel_b & ~any_urg & any_nb;
  assign sel_p          = ~sel_b & ~any_urg & ~any_nb & any_pre;
  assign nb_blk_ready_o = b_doh;

  // Per tier: the class of the winner and the task its block is cut from (the grants are one-hot).
  logic [NumCls-1:0] c_urg, c_nb, c_pre;
  logic [T-1:0]      k_urg, k_nb, k_pre;
  logic [NumDir-1:0] n_doh;
  always_comb begin
    c_urg = '0;
    c_nb  = '0;
    c_pre = '0;
    n_doh = '0;
    for (int unsigned c = 0; c < NumCls; c++) begin
      for (int unsigned g = 0; g < G; g++) begin
        c_urg[c] |= g_urg[g * NumCls + c];
        c_pre[c] |= g_pre[g * NumCls + c];
      end
      for (int unsigned d = 0; d < NumDir; d++) begin
        c_nb[c]  |= g_nb[d * NumCls + c];
        n_doh[d] |= g_nb[d * NumCls + c];
      end
    end
    k_urg = '0;
    k_nb  = '0;
    k_pre = '0;
    for (int unsigned c = 0; c < NumCls; c++) begin
      k_urg |= {T{c_urg[c]}} & sel_gnt[c];
      k_pre |= {T{c_pre[c]}} & sel_gnt[c];
      k_nb  |= {T{c_nb[c]}}  & sel_gnt[NumCls + c];
    end
  end

  assign cut_oh = ({T{sel_u}} & k_urg) | ({T{sel_n}} & k_nb) | ({T{sel_p}} & k_pre);

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
    send_cls = (sel_b & b_cls) | (sel_u & c_urg[NumCls-1]) | (sel_n & c_nb[NumCls-1]) | (sel_p & c_pre[NumCls-1]);
  end

  // -------------------------------------------------------------------------------------------
  // Block outputs
  // -------------------------------------------------------------------------------------------
  // The block of the previous cycle's decision, read from the task table. The counter of the task has
  // moved on by one since the decision, so the index of the block is that counter minus one.
  blk_t   asm_blk;
  gblk_t  out_blk;
  nblk_t  asm_next;
  owner_t d_owner;
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
    d_owner = '0;
    for (int unsigned d = 0; d < NumDir; d++) begin
      if (d_doh_q[d]) d_owner = owner_t'(d + 1);
    end
  end
  assign out_blk = d_bor_q ? '{owner: d_owner, b: d_bblk_q} : '{owner: '0, b: asm_blk};

  assign gcred_d  = (gcred_q | pop_i) & ~send_oh;
  assign lend_v_d = (lend_v_q & ~nb_blk_ready_i) | ({NumDir{d_v_q & d_nb_q}} & d_doh_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      d_v_q       <= 1'b0;
      d_nb_q      <= 1'b0;
      blk_valid_o <= '0;
      gcred_q     <= '1;
      lend_v_q    <= '0;
    end else begin
      d_v_q       <= sel_b | sel_u | sel_n | sel_p;
      d_nb_q      <= sel_n;
      blk_valid_o <= {G{d_v_q & ~d_nb_q}} & d_goh_q;
      gcred_q     <= gcred_d;
      lend_v_q    <= lend_v_d;
    end
  end

  always_ff @(posedge clk_i) begin
    d_bor_q <= sel_b;
    d_goh_q <= send_goh;
    d_cls_q <= send_cls;
    d_doh_q <= sel_b ? b_doh : n_doh;
    d_oh_q  <= cut_oh;
    if (sel_b) d_bblk_q <= b_blk;
    for (int unsigned g = 0; g < G; g++) begin
      if (d_v_q && !d_nb_q && d_goh_q[g]) blk_o[g] <= out_blk;
    end
    for (int unsigned d = 0; d < NumDir; d++) begin
      if (d_v_q && d_nb_q && d_doh_q[d]) lend_q[d] <= asm_blk;
    end
  end

  // -------------------------------------------------------------------------------------------
  // Borrowing: ask one neighbour at a time, the next one every four cycles
  // -------------------------------------------------------------------------------------------
  logic [NumCls-1:0] starve;
  logic [1:0]        ask_dir_q;
  logic [1:0]        ask_cnt_q;

  always_comb begin
    for (int unsigned c = 0; c < NumCls; c++) begin
      logic idle_c;
      idle_c = 1'b0;
      for (int unsigned g = 0; g < G; g++) idle_c |= urg[g][c];
      starve[c] = ~has_own[c] & idle_c;
    end
  end

  function automatic logic [1:0] next_dir(input logic [1:0] d);
    logic [1:0] n;
    n = d;
    for (int unsigned k = NumDir; k >= 1; k--) begin
      if (NbMask[2'(d + 2'(k))]) n = 2'(d + 2'(k));
    end
    return n;
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ask_dir_q <= '0;
      ask_cnt_q <= '0;
      nb_want_o <= '0;
    end else begin
      ask_cnt_q <= (|starve) ? ask_cnt_q + 2'd1 : '0;
      if (ask_cnt_q == 2'd3) ask_dir_q <= next_dir(ask_dir_q);
      for (int unsigned d = 0; d < NumDir; d++) begin
        nb_want_o[d] <= (LendEn && NbMask[d] && (ask_dir_q == 2'(d))) ? starve : '0;
      end
    end
  end

  // -------------------------------------------------------------------------------------------
  // Completions of blocks
  // -------------------------------------------------------------------------------------------
  logic [NumDir-1:0] ret_v_d, ret_v_q;
  tix_t [NumDir-1:0] ret_d, ret_q;
  logic [G-1:0]      gdone_self;
  logic [G-1:0][NumDir-1:0] ret_want;   // a completion of a borrowed block, by the direction it returns to
  logic [NumDir-1:0] ret_free;

  assign nb_ret_valid_o = ret_v_q;
  assign nb_ret_o       = ret_q;
  assign ret_free       = ~ret_v_q | nb_ret_ready_i;

  // A completion of an own block is always taken. A completion of a borrowed block needs the return
  // register of its direction; among the groups that want one register the lowest wins. Who wins does
  // not depend on whether the register is free, so the two are found in parallel.
  always_comb begin
    ret_v_d = ret_v_q & ~nb_ret_ready_i;
    ret_d   = ret_q;
    for (int unsigned g = 0; g < G; g++) begin
      gdone_self[g] = gdone_i[g].owner == '0;
      for (int unsigned d = 0; d < NumDir; d++) begin
        ret_want[g][d] = gdone_valid_i[g] & (gdone_i[g].owner == owner_t'(d + 1));
      end
    end
    for (int unsigned g = 0; g < G; g++) begin
      logic [NumDir-1:0] first;
      first = ret_want[g];
      for (int unsigned k = 0; k < g; k++) first &= ~ret_want[k];
      gdone_ready_o[g] = gdone_self[g] | (|(first & ret_free));
    end
    // The return registers: per direction a one-hot choice of the group.
    for (int unsigned d = 0; d < NumDir; d++) begin
      logic any;
      tix_t tix;
      any = 1'b0;
      tix = '0;
      for (int unsigned g = 0; g < G; g++) begin
        logic first;
        first = ret_want[g][d];
        for (int unsigned k = 0; k < g; k++) first &= ~ret_want[k][d];
        any |= first;
        tix |= {TixW{first}} & gdone_i[g].tix;
      end
      if (any && ret_free[d]) begin
        ret_v_d[d] = 1'b1;
        ret_d[d]   = tix;
      end
    end
  end

  always_comb begin
    for (int unsigned t = 0; t < T; t++) begin
      t_dec_d[t] = '0;
      for (int unsigned g = 0; g < G; g++) begin
        t_dec_d[t] += DecW'(gdone_valid_i[g] & gdone_self[g] & (gdone_i[g].tix == tix_t'(t)));
      end
      for (int unsigned d = 0; d < NumDir; d++) begin
        t_dec_d[t] += DecW'(nb_ret_valid_i[d] & (nb_ret_i[d] == tix_t'(t)));
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ret_v_q <= '0;
    end else begin
      ret_v_q <= ret_v_d;
    end
  end

  always_ff @(posedge clk_i) begin
    ret_q <= ret_d;
  end

  // -------------------------------------------------------------------------------------------
  // Completions to the cluster level: the load first, then the lowest finished task
  // -------------------------------------------------------------------------------------------
  logic  done_v_d, done_v_q;
  done_t done_d, done_q;
  logic  done_load;

  assign done_valid_o = done_v_q;
  assign done_o       = done_q;

  always_comb begin
    done_load = (~done_v_q | done_ready_i) & ld_fin;
    ld_take   = done_load;
    t_take    = '0;
    done_v_d  = done_v_q & ~done_ready_i;
    done_d    = done_q;
    if (done_load) begin
      done_v_d = 1'b1;
      done_d   = '{wid: ld_wid_q, is_load: 1'b1, nblk: '0};
    end else if (~done_v_q | done_ready_i) begin
      for (int t = T - 1; t >= 0; t--) begin
        if (t_fin[t]) begin
          t_take   = '0;
          t_take[t] = 1'b1;
          done_v_d = 1'b1;
          done_d   = '{wid: t_wid_q[t], is_load: 1'b0, nblk: t_nblk_q[t]};
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
      assert ((sel_u | sel_n | sel_p) == (|cut_oh)) else $error("[tsched_domain %0d] decision without a task", DomId);
      for (int unsigned t = 0; t < T; t++) begin
        assert (!(t_valid_q[t] && (32'(t_dec_q[t]) > 32'(t_out_q[t]))))
          else $error("[tsched_domain %0d] task %0d: more completions than blocks running", DomId, t);
        assert (!(cut_oh[t] && !t_avail_q[t]))
          else $error("[tsched_domain %0d] task %0d: block cut without an eligible one", DomId, t);
      end
    end
  end
  // pragma translate_on
`endif

endmodule
