// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Load queue and placement: renamed TLoad tasks leave in program order, each to the domain that has the
// least work among the domains that can take a load now. Work is counted in two parts, compared in this
// order: loads placed in the domain whose first task has not been issued yet (work that is still to
// come, for example weights fetched ahead of a join), then blocks received and not finished.
//
// A domain can take a load when its DMA engines are idle and it has a free slot; the cluster as a whole
// needs LanesPerLoad free stream lanes. These resources are counted here, so the links to the domains
// carry no back-pressure: a load is sent only when the domain is known to be able to start it.
//
// The choice of the domain comes from a two-stage minimum search and is two cycles old. It is used only
// if the chosen domain can still take a load; after an issue the stale choice names a domain that is now
// busy, so the queue pauses for the two cycles the search needs to catch up.

module tsched_load_issue import tsched_pkg::*; (
  input  logic                                clk_i,
  input  logic                                rst_ni,
  // from rename
  output logic                                ready_o,
  input  logic                                push_i,
  input  loadq_t                              push_data_i,
  // blocks each domain has received and not finished
  input  logic [NumDomains-1:0][BlkCntW-1:0]  blk_out_i,
  // a load finished in domain load_done_dom_i
  input  logic                                load_done_i,
  input  dom_t                                load_done_dom_i,
  // placed data of a domain got its first task, or was released without one
  input  logic  [1:0]                         unused_dec_valid_i,
  input  dom_t  [1:0]                         unused_dec_dom_i,
  // a slot was released
  input  logic                                slot_free_valid_i,
  input  dom_t                                slot_free_dom_i,
  input  slot_t                               slot_free_i,
  // issue, registered
  output logic [NumDomains-1:0]               load_valid_o,
  output load_req_t                           load_o,
  output wake_place_t                         place_o
);

  localparam int unsigned LaneW = $clog2(LanesTotal + 1);
  localparam int unsigned PendW = $clog2(SlotsPerDomain + 1);
  localparam int unsigned KeyW  = PendW + BlkCntW + DomW;

  logic   q_valid, q_empty, q_full, q_pop;
  loadq_t q_head;

  fifo_v3 #(
    .FALL_THROUGH (1'b0),
    .DEPTH        (LoadQDepth),
    .dtype        (loadq_t)
  ) i_fifo (
    .clk_i,
    .rst_ni,
    .flush_i    (1'b0),
    .testmode_i (1'b0),
    .full_o     (q_full),
    .empty_o    (q_empty),
    .usage_o    (/* unused */),
    .data_i     (push_data_i),
    .push_i     (push_i),
    .data_o     (q_head),
    .pop_i      (q_pop)
  );
  assign ready_o = ~q_full;
  assign q_valid = ~q_empty;

  // -------------------------------------------------------------------------------------------
  // Resources
  // -------------------------------------------------------------------------------------------
  logic [LaneW-1:0]                           lanes_d, lanes_q;
  logic [NumDomains-1:0]                      dma_busy_d, dma_busy_q;
  logic [NumDomains-1:0][SlotsPerDomain-1:0]  slot_free_d, slot_free_q;
  dom_t                                       rot_d, rot_q;
  logic [NumDomains-1:0][PendW-1:0]           pend_d, pend_q;

  logic [NumDomains-1:0]           elig;
  logic [NumDomains-1:0][KeyW-1:0] key;
  logic                            best_v;
  dom_t                            best;
  logic                            issue;
  slot_t                           slot;
  logic                            slot_none;
  logic                            place_v_q;
  phys_t                           place_tag_q;
  dom_t                            place_dom_q;
  slot_t                           place_slot_q;

  assign place_o = '{v: place_v_q, tag: place_tag_q, dom: place_dom_q, slot: place_slot_q};

  for (genvar d = 0; d < NumDomains; d++) begin : gen_key
    assign elig[d] = ~dma_busy_q[d] & (|slot_free_q[d]);
    // Least outstanding work first; equal work goes to the domain after the one served last.
    assign key[d]  = {pend_q[d], blk_out_i[d], dom_t'(DomW'(d) - rot_q)};
  end

  tsched_argmin #(
    .N    (NumDomains),
    .KeyW (KeyW)
  ) i_best (
    .clk_i,
    .rst_ni,
    .valid_i (elig),
    .key_i   (key),
    .valid_o (best_v),
    .idx_o   (best)
  );

  lzc #(
    .WIDTH (SlotsPerDomain),
    .MODE  (1'b0)
  ) i_lzc_slot (
    .in_i    (slot_free_q[best]),
    .cnt_o   (slot),
    .empty_o (slot_none)
  );

  assign issue = q_valid & best_v & elig[best] & (lanes_q >= LaneW'(LanesPerLoad));
  assign q_pop = issue;

  always_comb begin
    lanes_d     = lanes_q;
    dma_busy_d  = dma_busy_q;
    slot_free_d = slot_free_q;
    rot_d       = rot_q;
    if (slot_free_valid_i) slot_free_d[slot_free_dom_i][slot_free_i] = 1'b1;
    if (load_done_i) dma_busy_d[load_done_dom_i] = 1'b0;
    if (issue) begin
      dma_busy_d[best]        = 1'b1;
      slot_free_d[best][slot] = 1'b0;
      rot_d                   = best + dom_t'(PlaceStride);
    end
    lanes_d = lanes_q + (load_done_i ? LaneW'(LanesPerLoad) : '0) - (issue ? LaneW'(LanesPerLoad) : '0);
    for (int unsigned d = 0; d < NumDomains; d++) begin
      pend_d[d] = pend_q[d] + PendW'(issue & (best == dom_t'(d)))
                - PendW'(unused_dec_valid_i[0] & (unused_dec_dom_i[0] == dom_t'(d)))
                - PendW'(unused_dec_valid_i[1] & (unused_dec_dom_i[1] == dom_t'(d)));
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lanes_q      <= LaneW'(LanesTotal);
      dma_busy_q   <= '0;
      slot_free_q  <= '1;
      rot_q        <= '0;
      pend_q       <= '0;
      load_valid_o <= '0;
      place_v_q    <= 1'b0;
    end else begin
      lanes_q      <= lanes_d;
      dma_busy_q   <= dma_busy_d;
      slot_free_q  <= slot_free_d;
      rot_q        <= rot_d;
      pend_q       <= pend_d;
      load_valid_o <= '0;
      load_valid_o[best] <= issue;
      place_v_q    <= issue;
    end
  end

  always_ff @(posedge clk_i) begin
    if (issue) begin
      load_o       <= '{wid: q_head.wid, slot: slot, len: q_head.len, addr: q_head.addr};
      place_tag_q  <= q_head.pd;
      place_dom_q  <= best;
      place_slot_q <= slot;
    end
  end

`ifndef TARGET_SYNTHESIS
  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!(push_i && q_full)) else $error("[tsched_load_issue] push into a full queue");
      assert (!(issue && slot_none)) else $error("[tsched_load_issue] issue without a free slot");
      if (slot_free_valid_i) begin
        assert (!slot_free_q[slot_free_dom_i][slot_free_i])
          else $error("[tsched_load_issue] slot %0d of domain %0d released twice", slot_free_i, slot_free_dom_i);
      end
    end
  end
  // pragma translate_on
`endif

endmodule
