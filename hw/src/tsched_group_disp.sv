// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Group dispatcher: one per mesh group.
//
// It holds one next block per PE class (the next-task register) and starts the first idle PE of that
// class on it. The domain scheduler refills a register only after it has been emptied (pop_o returns
// the credit), so the block link needs no ready.
//
// A PE reports the end of a block with valid/ready. The dispatcher frees the PE at once, so the PE can
// take the next block, and forwards the completion to the domain scheduler, one per cycle. A PE whose
// previous completion has not been forwarded yet holds its next one.

module tsched_group_disp import tsched_pkg::*; (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  // blocks from the domain scheduler
  input  logic                 blk_valid_i,
  input  gblk_t                blk_i,
  output logic  [NumCls-1:0]   pop_o,     // the next-block register of the class was emptied
  output logic  [NumCls-1:0]   idle_o,    // the class has an idle PE
  // completions to the domain scheduler
  output logic                 gdone_valid_o,
  input  logic                 gdone_ready_i,
  output gdone_t               gdone_o,
  output logic                 gdone_cls_o,   // PE class that ran the block
  // PEs: tensor engines first, then vector units. One block bus per class.
  output logic  [NumPes-1:0]   pe_start_o,
  output blk_t  [NumCls-1:0]   pe_blk_o,
  input  logic  [NumPes-1:0]   pe_done_valid_i,
  output logic  [NumPes-1:0]   pe_done_ready_o
);

  // Class of each PE index.
  function automatic logic pe_cls(input int unsigned p);
    return (p < NumTensor) ? 1'(ClsT) : 1'(ClsV);
  endfunction

  logic   [NumCls-1:0] buf_v_d, buf_v_q;
  gblk_t  [NumCls-1:0] buf_q;
  logic   [NumPes-1:0] busy_d, busy_q;
  logic   [NumPes-1:0] pend_d, pend_q;
  gdone_t [NumPes-1:0] run_q, pend_info_q;
  logic   [NumCls-1:0] start;
  logic   [NumPes-1:0] start_oh;
  logic   [NumPes-1:0] done_fire;
  logic   [NumPes-1:0] arb_gnt;

  // -------------------------------------------------------------------------------------------
  // Start: the first idle PE of a class takes the block in that class's register
  // -------------------------------------------------------------------------------------------
  logic [NumCls-1:0][NumPes-1:0] cls_mask, idle_vec, first_idle;
  for (genvar c = 0; c < NumCls; c++) begin : gen_cls
    for (genvar p = 0; p < NumPes; p++) begin : gen_mask
      assign cls_mask[c][p] = pe_cls(p) == 1'(c);
    end
    assign idle_vec[c]   = ~busy_q & cls_mask[c];
    assign first_idle[c] = idle_vec[c] & (~idle_vec[c] + NumPes'(1));
    assign start[c]      = buf_v_q[c] & (|idle_vec[c]);
    assign pe_blk_o[c]   = buf_q[c].b;
  end

  always_comb begin
    start_oh = '0;
    for (int unsigned c = 0; c < NumCls; c++) begin
      if (start[c]) start_oh |= first_idle[c];
    end
  end
  assign pe_start_o = start_oh;

  // -------------------------------------------------------------------------------------------
  // Completions
  // -------------------------------------------------------------------------------------------
  assign pe_done_ready_o = ~pend_q;
  assign done_fire       = pe_done_valid_i & pe_done_ready_o;

  logic [$clog2(NumPes)-1:0] arb_idx;

  rr_arb_tree #(
    .NumIn     (NumPes),
    .DataType  (gdone_t),
    .ExtPrio   (1'b0),
    .AxiVldRdy (1'b1),
    .LockIn    (1'b1),
    .FairArb   (1'b1)
  ) i_done_arb (
    .clk_i,
    .rst_ni,
    .flush_i (1'b0),
    .rr_i    ('0),
    .req_i   (pend_q),
    .gnt_o   (arb_gnt),
    .data_i  (pend_info_q),
    .req_o   (gdone_valid_o),
    .gnt_i   (gdone_ready_i),
    .data_o  (gdone_o),
    .idx_o   (arb_idx)
  );
  assign gdone_cls_o = (32'(arb_idx) >= NumTensor) ? 1'(ClsV) : 1'(ClsT);

  always_comb begin
    buf_v_d = buf_v_q & ~start;
    if (blk_valid_i) buf_v_d[blk_i.b.pcls] = 1'b1;
    busy_d = (busy_q | start_oh) & ~done_fire;
    pend_d = (pend_q & ~arb_gnt) | done_fire;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      buf_v_q <= '0;
      busy_q  <= '0;
      pend_q  <= '0;
      pop_o   <= '0;
      idle_o  <= '0;
    end else begin
      buf_v_q <= buf_v_d;
      busy_q  <= busy_d;
      pend_q  <= pend_d;
      pop_o   <= start;
      for (int unsigned c = 0; c < NumCls; c++) idle_o[c] <= |(~busy_d & cls_mask[c]);
    end
  end

  always_ff @(posedge clk_i) begin
    if (blk_valid_i) buf_q[blk_i.b.pcls] <= blk_i;
    for (int unsigned p = 0; p < NumPes; p++) begin
      if (start_oh[p])  run_q[p]       <= '{bor: buf_q[pe_cls(p)].bor, dom: buf_q[pe_cls(p)].b.dom, tix: buf_q[pe_cls(p)].b.tix};
      if (done_fire[p]) pend_info_q[p] <= run_q[p];
    end
  end

`ifndef TARGET_SYNTHESIS
  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!(blk_valid_i && buf_v_q[blk_i.b.pcls] && !start[blk_i.b.pcls]))
        else $error("[tsched_group_disp] block for a class whose register is full");
      assert ((pe_done_valid_i & ~busy_q) == '0)
        else $error("[tsched_group_disp] completion from a PE that runs no block");
    end
  end
  // pragma translate_on
`endif

endmodule
