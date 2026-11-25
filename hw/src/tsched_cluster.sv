// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Cluster side of the task scheduler: the domain schedulers and the group dispatchers. The domains have
// no links to each other; work moves between them through the cluster level.
//
// Numbering
//   domain d   = dy * DomPerSide + dx
//   group      = gy * (2 * DomPerSide) + gx on the group mesh; group j of domain d sits at
//                gx = 2 * dx + j % 2, gy = 2 * dy + j / 2

module tsched_cluster import tsched_pkg::*; #(
  parameter bit          BalEn   = 1'b1,
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
  // balancing by the cluster level, per domain
  output rep_t      [NumDomains-1:0]          rep_o,
  input  logic      [NumDomains-1:0]          give_valid_i,
  input  give_t     [NumDomains-1:0]          give_i,
  output logic      [NumDomains-1:0]          rblk_valid_o,
  output rblk_t     [NumDomains-1:0]          rblk_o,
  input  logic      [NumDomains-1:0]          bblk_valid_i,
  input  blk_t      [NumDomains-1:0]          bblk_i,
  output logic      [NumDomains-1:0]          bpop_valid_o,
  output logic      [NumDomains-1:0]          bpop_cls_o,
  input  logic      [NumDomains-1:0]          ret_valid_i,
  input  tix_t      [NumDomains-1:0]          ret_tix_i,
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

  for (genvar d = 0; d < NumDomains; d++) begin : gen_domain
    logic   [GroupsPerDomain-1:0]             blk_valid;
    gblk_t  [GroupsPerDomain-1:0]             blk;
    logic   [GroupsPerDomain-1:0][NumCls-1:0] pop, idle;
    logic   [GroupsPerDomain-1:0]             gdone_valid, gdone_ready;
    gdone_t [GroupsPerDomain-1:0]             gdone;
    logic   [GroupsPerDomain-1:0]             dma_valid, dma_ready, dma_done;
    dma_req_t [GroupsPerDomain-1:0]           dma;

    tsched_domain #(
      .DomId   (d),
      .BalEn   (BalEn),
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
      .rep_o          (rep_o[d]),
      .give_valid_i   (give_valid_i[d]),
      .give_i         (give_i[d]),
      .rblk_valid_o   (rblk_valid_o[d]),
      .rblk_o         (rblk_o[d]),
      .bblk_valid_i   (bblk_valid_i[d]),
      .bblk_i         (bblk_i[d]),
      .bpop_valid_o   (bpop_valid_o[d]),
      .bpop_cls_o     (bpop_cls_o[d]),
      .ret_valid_i    (ret_valid_i[d]),
      .ret_tix_i      (ret_tix_i[d])
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
