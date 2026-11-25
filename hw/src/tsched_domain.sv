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
  logic  [T-1:0]            t_valid_d, t_valid_q;
  wid_t  [T-1:0]            t_wid_q;
  cls_t  [T-1:0]            t_cls_q;
  nblk_t [T-1:0]            t_nblk_q;
  nblk_t [T-1:0]            t_next_d, t_next_q;     // blocks handed out
  nblk_t [T-1:0]            t_elig_d, t_elig_q;     // blocks that may be handed out
  nblk_t [T-1:0]            t_out_d, t_out_q;       // blocks running
  logic  [T-1:0]            t_follow_q, t_slot_v_q;
  slot_t [T-1:0]            t_slot_q;
  logic  [T-1:0][TickW-1:0] t_ticks_d, t_ticks_q;   // progress steps already turned into eligible blocks
  logic  [T-1:0][ChunkW-1:0] t_acc_d, t_acc_q;
  kern_t [T-1:0]            t_kern_q;
  arg_t  [T-1:0]            t_arg_q;

  logic  [T-1:0]            ins_oh;
  tix_t                     ins_idx;
  logic                     ins_none;
  logic  [T-1:0]            avail, spare, t_fin;
  logic  [T-1:0]            cut_oh;                 // the task a block is cut from this cycle
  logic  [T-1:0][DecW-1:0]  t_dec;                  // completions per task this cycle
  logic  [T-1:0]            t_take;                 // the completion of the task moves to the output register

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
    logic [NblkW:0] left;
    assign left     = {1'b0, t_elig_q[t]} - {1'b0, t_next_q[t]};
    assign avail[t] = t_valid_q[t] & (t_next_q[t] != t_elig_q[t]);
    assign spare[t] = t_valid_q[t] & (left >= (NblkW+1)'(LendMin));
    assign t_fin[t] = t_valid_q[t] & (t_next_q[t] == t_nblk_q[t]) & (t_out_q[t] == '0);
  end

  always_comb begin
    t_valid_d = t_valid_q & ~t_take;
    t_next_d  = t_next_q;
    t_elig_d  = t_elig_q;
    t_out_d   = t_out_q;
    t_ticks_d = t_ticks_q;
    t_acc_d   = t_acc_q;
    for (int unsigned t = 0; t < T; t++) begin
      logic [TickW-1:0] target;
      logic [NblkW:0]   sum;
      // Progress of the slot the task reads: the load in flight if it fills that slot, else complete.
      target = (ld_active_q && (ld_slot_q == t_slot_q[t])) ? ld_prog_q : TickW'(C);
      sum    = (NblkW+1)'(t_acc_q[t]) + (NblkW+1)'(t_nblk_q[t]);
      // One progress step per cycle: elig = floor(steps * nblk / C), kept exact by the remainder in acc.
      if (t_valid_q[t] && t_follow_q[t] && (t_ticks_q[t] < target)) begin
        t_ticks_d[t] = t_ticks_q[t] + TickW'(1);
        t_elig_d[t]  = t_elig_q[t] + nblk_t'(sum >> ChunkW);
        t_acc_d[t]   = sum[ChunkW-1:0];
      end
      if (cut_oh[t]) t_next_d[t] = t_next_q[t] + nblk_t'(1);
      t_out_d[t] = t_out_q[t] + nblk_t'(cut_oh[t]) - nblk_t'(t_dec[t]);
      if (ins_oh[t]) begin
        t_valid_d[t] = 1'b1;
        t_next_d[t]  = '0;
        t_out_d[t]   = '0;
        t_ticks_d[t] = '0;
        t_acc_d[t]   = '0;
        t_elig_d[t]  = (run_i.follow & run_i.slot_v) ? '0 : run_i.nblk;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      t_valid_q <= '0;
    end else begin
      t_valid_q <= t_valid_d;
    end
  end

  always_ff @(posedge clk_i) begin
    t_next_q  <= t_next_d;
    t_elig_q  <= t_elig_d;
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

  for (genvar c = 0; c < NumCls; c++) begin : gen_cand
    for (genvar t = 0; t < T; t++) begin : gen_t
      assign sel_req[c][t]        = avail[t] & t_cls_q[t][c];
      assign sel_req[NumCls+c][t] = avail[t] & t_cls_q[t][c] & spare[t];
    end
    assign has_own[c]  = |sel_req[c];
    assign has_lend[c] = |sel_req[NumCls+c];
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

  // A lent block waits in a register per direction.
  logic [NumDir-1:0] lend_v_d, lend_v_q;
  blk_t [NumDir-1:0] lend_q;
  logic [NumDir-1:0] lend_free;
  assign lend_free      = ~lend_v_q | nb_blk_ready_i;
  assign nb_blk_valid_o = lend_v_q;
  assign nb_blk_o       = lend_q;

  // Three tiers: own registers with an idle PE, neighbours, own registers that prepare the next block.
  localparam int unsigned NumOwn = G * NumCls;
  localparam int unsigned NumNb  = NumDir * NumCls;
  localparam int unsigned NumReq = 2 * NumOwn + NumNb;
  localparam int unsigned ReqW   = $clog2(NumReq);

  logic [NumOwn-1:0] r_urg, r_pre;
  logic [NumNb-1:0]  r_nb;
  logic [NumReq-1:0] r_all, r_gnt;
  logic              r_valid;
  logic [ReqW-1:0]   r_idx;

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

  // Borrowed blocks go first: they are only requested when the own tasks had nothing for that class.
  logic [NumDir-1:0] b_can;
  logic              b_any;
  logic [1:0]        b_dir;
  logic              b_cls;
  logic [GrpW-1:0]   b_grp;
  always_comb begin
    b_any = 1'b0;
    b_dir = '0;
    for (int unsigned d = 0; d < NumDir; d++) begin
      logic any_cred;
      any_cred = 1'b0;
      for (int unsigned g = 0; g < G; g++) any_cred |= gcred_q[g][nb_blk_i[d].pcls];
      b_can[d] = nb_blk_valid_i[d] & any_cred;
    end
    for (int d = NumDir - 1; d >= 0; d--) begin
      if (b_can[d]) begin
        b_any = 1'b1;
        b_dir = 2'(d);
      end
    end
    b_cls = nb_blk_i[b_dir].pcls;
    b_grp = '0;
    for (int g = G - 1; g >= 0; g--) if (gcred_q[g][b_cls]) b_grp = GrpW'(g);
    for (int g = G - 1; g >= 0; g--) if (urg[g][b_cls])     b_grp = GrpW'(g);
  end
  for (genvar d = 0; d < NumDir; d++) begin : gen_b_ready
    assign nb_blk_ready_o[d] = b_any & (b_dir == 2'(d));
  end

  always_comb begin
    r_all = '0;
    if (!b_any) begin
      if (|r_urg)     r_all[NumOwn-1:0]                  = r_urg;
      else if (|r_nb) r_all[NumOwn+NumNb-1:NumOwn]       = r_nb;
      else            r_all[NumReq-1:NumOwn+NumNb]       = r_pre;
    end
  end

  rr_arb_tree #(
    .NumIn     (NumReq),
    .DataWidth (1),
    .ExtPrio   (1'b0),
    .AxiVldRdy (1'b1),
    .LockIn    (1'b0),
    .FairArb   (1'b1)
  ) i_req_arb (
    .clk_i,
    .rst_ni,
    .flush_i (1'b0),
    .rr_i    ('0),
    .req_i   (r_all),
    .gnt_o   (r_gnt),
    .data_i  ('0),
    .req_o   (r_valid),
    .gnt_i   (1'b1),
    .data_o  (/* unused */),
    .idx_o   (r_idx)
  );

  // Decode the winner.
  logic            w_nb;                 // the block is lent
  logic            w_cls;
  logic [GrpW-1:0] w_grp;
  logic [1:0]      w_dir;
  always_comb begin
    logic [ReqW-1:0] rel;
    w_nb  = (r_idx >= ReqW'(NumOwn)) && (r_idx < ReqW'(NumOwn + NumNb));
    rel   = w_nb ? (r_idx - ReqW'(NumOwn)) : ((r_idx < ReqW'(NumOwn)) ? r_idx : (r_idx - ReqW'(NumOwn + NumNb)));
    w_cls = rel[0];
    w_grp = GrpW'(rel >> 1);
    w_dir = 2'(rel >> 1);
  end

  // The block cut for the winner. The grant of the age select is one-hot.
  blk_t cut_blk;
  always_comb begin
    logic [T-1:0] oh;
    oh      = w_nb ? sel_gnt[NumCls + 32'(w_cls)] : sel_gnt[32'(w_cls)];
    cut_oh  = r_valid ? oh : '0;
    cut_blk = '0;
    for (int unsigned t = 0; t < T; t++) begin
      if (oh[t]) begin
        cut_blk.kern   = t_kern_q[t];
        cut_blk.arg    = t_arg_q[t];
        cut_blk.bidx   = t_next_q[t];
        cut_blk.nblk   = t_nblk_q[t];
        cut_blk.slot_v = t_slot_v_q[t];
        cut_blk.slot   = t_slot_q[t];
        cut_blk.tix    = tix_t'(t);
      end
    end
    cut_blk.dom  = dom_t'(DomId);
    cut_blk.pcls = w_cls;
  end

  // -------------------------------------------------------------------------------------------
  // Block outputs
  // -------------------------------------------------------------------------------------------
  logic  [G-1:0] blk_valid_d;
  gblk_t         blk_own, blk_bor;
  logic          send_own, send_bor;
  logic  [GrpW-1:0] send_grp;
  logic          send_cls;

  assign send_bor = b_any;
  assign send_own = r_valid & ~w_nb;
  assign blk_own  = '{owner: '0, b: cut_blk};
  assign blk_bor  = '{owner: owner_t'(3'd1 + 3'(b_dir)), b: nb_blk_i[b_dir]};
  assign send_grp = send_bor ? b_grp : w_grp;
  assign send_cls = send_bor ? b_cls : w_cls;

  always_comb begin
    blk_valid_d = '0;
    gcred_d     = gcred_q | pop_i;
    lend_v_d    = lend_v_q & ~nb_blk_ready_i;
    if (send_bor || send_own) begin
      blk_valid_d[send_grp]       = 1'b1;
      gcred_d[send_grp][send_cls] = 1'b0;
    end
    if (r_valid && w_nb) lend_v_d[w_dir] = 1'b1;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      blk_valid_o <= '0;
      gcred_q     <= '1;
      lend_v_q    <= '0;
    end else begin
      blk_valid_o <= blk_valid_d;
      gcred_q     <= gcred_d;
      lend_v_q    <= lend_v_d;
    end
  end

  always_ff @(posedge clk_i) begin
    if (send_bor || send_own) blk_o[send_grp] <= send_bor ? blk_bor : blk_own;
    if (r_valid && w_nb)      lend_q[w_dir]   <= cut_blk;
  end

  // -------------------------------------------------------------------------------------------
  // Borrowing: ask one neighbour at a time, the next one every four cycles
  // -------------------------------------------------------------------------------------------
  logic [NumCls-1:0] starve;
  logic [1:0]        ask_dir_q;
  logic [1:0]        ask_cnt_q;

  always_comb begin
    for (int unsigned c = 0; c < NumCls; c++) begin
      starve[c] = ~has_own[c];
      begin
        logic any_urg;
        any_urg = 1'b0;
        for (int unsigned g = 0; g < G; g++) any_urg |= urg[g][c];
        starve[c] &= any_urg;
      end
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
  logic [G-1:0]      gdone_fire, gdone_self;

  assign nb_ret_valid_o = ret_v_q;
  assign nb_ret_o       = ret_q;

  always_comb begin
    logic [NumDir-1:0] taken;
    ret_v_d = ret_v_q & ~nb_ret_ready_i;
    ret_d   = ret_q;
    taken   = '0;
    for (int unsigned g = 0; g < G; g++) begin
      logic [1:0] dir;
      dir            = 2'(gdone_i[g].owner - owner_t'(1));
      gdone_self[g]  = gdone_i[g].owner == '0;
      // A completion of a borrowed block needs the return register of its direction; the lowest group wins.
      gdone_ready_o[g] = gdone_self[g] | ((~ret_v_q[dir] | nb_ret_ready_i[dir]) & ~taken[dir]);
      gdone_fire[g]    = gdone_valid_i[g] & gdone_ready_o[g];
      if (gdone_fire[g] && !gdone_self[g]) begin
        taken[dir]   = 1'b1;
        ret_v_d[dir] = 1'b1;
        ret_d[dir]   = gdone_i[g].tix;
      end
    end
  end

  always_comb begin
    for (int unsigned t = 0; t < T; t++) begin
      t_dec[t] = '0;
      for (int unsigned g = 0; g < G; g++) begin
        t_dec[t] += DecW'(gdone_fire[g] & gdone_self[g] & (gdone_i[g].tix == tix_t'(t)));
      end
      for (int unsigned d = 0; d < NumDir; d++) begin
        t_dec[t] += DecW'(nb_ret_valid_i[d] & (nb_ret_i[d] == tix_t'(t)));
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
      for (int unsigned t = 0; t < T; t++) begin
        assert (!(t_valid_q[t] && (32'(t_dec[t]) > 32'(t_out_q[t]) + 32'(cut_oh[t]))))
          else $error("[tsched_domain %0d] task %0d: more completions than blocks running", DomId, t);
      end
    end
  end
  // pragma translate_on
`endif

endmodule
