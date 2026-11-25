// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Cluster side of the task scheduler: the domain schedulers on their mesh, and the group dispatchers.
//
// Numbering
//   domain d   = dy * DomPerSide + dx
//   group      = gy * (2 * DomPerSide) + gx on the group mesh; group j of domain d sits at
//                gx = 2 * dx + j % 2, gy = 2 * dy + j / 2
//   direction  0 north (dy - 1), 1 east (dx + 1), 2 south (dy + 1), 3 west (dx - 1)

module tsched_cluster import tsched_pkg::*; #(
  parameter bit          LendEn  = 1'b1,
  parameter int unsigned LendMin = 1
) (
  input  logic                                clk_i,
  input  logic                                rst_ni,
  // cluster level, per domain
  input  logic      [NumDomains-1:0]          run_valid_i,
  input  run_req_t  [NumDomains-1:0]          run_i,
  input  logic      [NumDomains-1:0]          load_valid_i,
  input  load_req_t [NumDomains-1:0]          load_i,
  output logic      [NumDomains-1:0]          done_valid_o,
  input  logic      [NumDomains-1:0]          done_ready_i,
  output done_t     [NumDomains-1:0]          done_o,
  // DMA engines, per group
  output logic      [NumGroups-1:0]           dma_valid_o,
  input  logic      [NumGroups-1:0]           dma_ready_i,
  output dma_req_t  [NumGroups-1:0]           dma_o,
  input  logic      [NumGroups-1:0]           dma_done_i,
  // PEs, per group
  output logic      [NumGroups-1:0][NumPes-1:0] pe_start_o,
  output blk_t      [NumGroups-1:0][NumCls-1:0] pe_blk_o,
  input  logic      [NumGroups-1:0][NumPes-1:0] pe_done_valid_i,
  output logic      [NumGroups-1:0][NumPes-1:0] pe_done_ready_o
);

  localparam int unsigned S = DomPerSide;

  // Mesh index of group j of domain d.
  function automatic int unsigned group_of(input int unsigned d, input int unsigned j);
    return (2 * (d / S) + j / 2) * (2 * S) + 2 * (d % S) + j % 2;
  endfunction

  // Neighbour of domain d in direction k, or -1.
  function automatic int nb_of(input int unsigned d, input int unsigned k);
    int x, y;
    x = d % S;
    y = d / S;
    unique case (k)
      0:       y = y - 1;
      1:       x = x + 1;
      2:       y = y + 1;
      default: x = x - 1;
    endcase
    return ((x < 0) || (y < 0) || (x >= S) || (y >= S)) ? -1 : y * S + x;
  endfunction

  function automatic logic [NumDir-1:0] nb_mask(input int unsigned d);
    logic [NumDir-1:0] m;
    for (int unsigned k = 0; k < NumDir; k++) m[k] = nb_of(d, k) >= 0;
    return m;
  endfunction

  logic [NumDomains-1:0][NumDir-1:0][NumCls-1:0] want_out, want_in;
  logic [NumDomains-1:0][NumDir-1:0]             lend_valid, lend_ready, bor_valid, bor_ready;
  blk_t [NumDomains-1:0][NumDir-1:0]             lend_blk, bor_blk;
  logic [NumDomains-1:0][NumDir-1:0]             ret_out_valid, ret_in_valid;
  tix_t [NumDomains-1:0][NumDir-1:0]             ret_out, ret_in;

  for (genvar d = 0; d < NumDomains; d++) begin : gen_domain
    logic   [GroupsPerDomain-1:0]             blk_valid;
    gblk_t  [GroupsPerDomain-1:0]             blk;
    logic   [GroupsPerDomain-1:0][NumCls-1:0] pop, idle;
    logic   [GroupsPerDomain-1:0]             gdone_valid, gdone_ready;
    gdone_t [GroupsPerDomain-1:0]             gdone;
    logic   [GroupsPerDomain-1:0]             dma_valid, dma_ready, dma_done;
    dma_req_t [GroupsPerDomain-1:0]           dma;

    // Direction k of this domain meets direction k ^ 2 of the neighbour.
    for (genvar k = 0; k < NumDir; k++) begin : gen_nb
      if (nb_of(d, k) >= 0) begin : gen_link
        localparam int unsigned N = nb_of(d, k);
        assign want_in[d][k]      = want_out[N][k ^ 2];
        assign bor_valid[d][k]    = lend_valid[N][k ^ 2];
        assign bor_blk[d][k]      = lend_blk[N][k ^ 2];
        assign lend_ready[d][k]   = bor_ready[N][k ^ 2];
        assign ret_in_valid[d][k] = ret_out_valid[N][k ^ 2];
        assign ret_in[d][k]       = ret_out[N][k ^ 2];
      end else begin : gen_edge
        assign want_in[d][k]      = '0;
        assign bor_valid[d][k]    = 1'b0;
        assign bor_blk[d][k]      = '0;
        assign lend_ready[d][k]   = 1'b1;
        assign ret_in_valid[d][k] = 1'b0;
        assign ret_in[d][k]       = '0;
      end
    end

    tsched_domain #(
      .DomId   (d),
      .NbMask  (nb_mask(d)),
      .LendEn  (LendEn),
      .LendMin (LendMin)
    ) i_domain (
      .clk_i,
      .rst_ni,
      .run_valid_i    (run_valid_i[d]),
      .run_i          (run_i[d]),
      .load_valid_i   (load_valid_i[d]),
      .load_i         (load_i[d]),
      .done_valid_o   (done_valid_o[d]),
      .done_ready_i   (done_ready_i[d]),
      .done_o         (done_o[d]),
      .dma_valid_o    (dma_valid),
      .dma_ready_i    (dma_ready),
      .dma_o          (dma),
      .dma_done_i     (dma_done),
      .blk_valid_o    (blk_valid),
      .blk_o          (blk),
      .pop_i          (pop),
      .idle_i         (idle),
      .gdone_valid_i  (gdone_valid),
      .gdone_ready_o  (gdone_ready),
      .gdone_i        (gdone),
      .nb_want_o      (want_out[d]),
      .nb_want_i      (want_in[d]),
      .nb_blk_valid_o (lend_valid[d]),
      .nb_blk_ready_i (lend_ready[d]),
      .nb_blk_o       (lend_blk[d]),
      .nb_blk_valid_i (bor_valid[d]),
      .nb_blk_ready_o (bor_ready[d]),
      .nb_blk_i       (bor_blk[d]),
      .nb_ret_valid_o (ret_out_valid[d]),
      .nb_ret_ready_i ('1),
      .nb_ret_o       (ret_out[d]),
      .nb_ret_valid_i (ret_in_valid[d]),
      .nb_ret_i       (ret_in[d])
    );

    for (genvar j = 0; j < GroupsPerDomain; j++) begin : gen_group
      localparam int unsigned Gm = group_of(d, j);

      assign dma_valid_o[Gm] = dma_valid[j];
      assign dma_o[Gm]       = dma[j];
      assign dma_ready[j]    = dma_ready_i[Gm];
      assign dma_done[j]     = dma_done_i[Gm];

      tsched_group_disp i_disp (
        .clk_i,
        .rst_ni,
        .blk_valid_i     (blk_valid[j]),
        .blk_i           (blk[j]),
        .pop_o           (pop[j]),
        .idle_o          (idle[j]),
        .gdone_valid_o   (gdone_valid[j]),
        .gdone_ready_i   (gdone_ready[j]),
        .gdone_o         (gdone[j]),
        .pe_start_o      (pe_start_o[Gm]),
        .pe_blk_o        (pe_blk_o[Gm]),
        .pe_done_valid_i (pe_done_valid_i[Gm]),
        .pe_done_ready_o (pe_done_ready_o[Gm])
      );
    end
  end

endmodule
