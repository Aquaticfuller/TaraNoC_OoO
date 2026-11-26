// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Task scheduler, complete: the cluster level and the cluster side, joined by registered links.
//
// LinkStages register stages sit on every link between the cluster level and a domain, to cover the
// distance. The task and load links carry valid and data only (the cluster level counts credits); the
// completion links use spill registers. The links of the balancer (reports, give commands, answers,
// blocks, queue credits, returns) carry valid and data only and have the same number of stages.

module tsched_top import tsched_pkg::*; #(
  parameter int unsigned LinkStages = 1,
  parameter bit          BalEn      = 1'b1,
  parameter int unsigned LendMin    = 1
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,
  // task instructions from the host, in program order and no longer speculative
  input  logic                                  instr_valid_i,
  output logic                                  instr_ready_o,
  input  tinstr_t                               instr_i,
  output logic                                  idle_o,
  // DMA engines, per group
  output logic      [NumGroups-1:0]             dma_valid_o,
  input  logic      [NumGroups-1:0]             dma_ready_i,
  output dma_req_t  [NumGroups-1:0]             dma_o,
  input  logic      [NumGroups-1:0]             dma_done_i,
  // PEs, per group
  output logic      [NumGroups-1:0][NumPes-1:0] pe_start_o,
  output blk_t      [NumGroups-1:0][NumCls-1:0] pe_blk_o,
  input  logic      [NumGroups-1:0][NumPes-1:0] pe_done_valid_i,
  output logic      [NumGroups-1:0][NumPes-1:0] pe_done_ready_o
);

  logic      [NumDomains-1:0] be_run_valid, be_load_valid, be_reg_valid, cl_reg_valid;
  run_req_t                   be_run;
  load_req_t                  be_load;
  logic      [NumDomains-1:0] be_done_valid, be_done_ready;
  done_t     [NumDomains-1:0] be_done;

  // balancing: be_* at the cluster level, cl_* at the domains
  rep_t      [NumDomains-1:0] be_rep, cl_rep;
  logic      [NumDomains-1:0] be_give_valid, cl_give_valid;
  give_t                      be_give;
  give_t     [NumDomains-1:0] cl_give;
  logic      [NumDomains-1:0] be_rblk_valid, cl_rblk_valid;
  rblk_t     [NumDomains-1:0] be_rblk, cl_rblk;
  logic      [NumDomains-1:0] be_bblk_valid, cl_bblk_valid;
  blk_t                       be_bblk;
  blk_t      [NumDomains-1:0] cl_bblk;
  logic      [NumDomains-1:0] be_bpop_valid, be_bpop_cls, cl_bpop_valid, cl_bpop_cls;
  logic      [NumDomains-1:0][NumCls-1:0] be_wanted, cl_wanted;
  logic      [NumDomains-1:0] be_ret_valid, cl_ret_valid;
  ret_t                       be_ret;
  ret_t      [NumDomains-1:0] cl_ret;

  logic      [NumDomains-1:0] cl_run_valid, cl_load_valid;
  run_req_t  [NumDomains-1:0] cl_run;
  load_req_t [NumDomains-1:0] cl_load;
  logic      [NumDomains-1:0] cl_done_valid, cl_done_ready;
  done_t     [NumDomains-1:0] cl_done;

  tsched_backend #(
    .BalEn (BalEn)
  ) i_backend (
    .clk_i,
    .rst_ni,
    .instr_valid_i,
    .instr_ready_o,
    .instr_i,
    .run_valid_o  (be_run_valid),
    .run_o        (be_run),
    .reg_valid_o  (be_reg_valid),
    .load_valid_o (be_load_valid),
    .load_o       (be_load),
    .done_valid_i (be_done_valid),
    .done_ready_o (be_done_ready),
    .done_i       (be_done),
    .rep_i        (be_rep),
    .give_valid_o (be_give_valid),
    .give_o       (be_give),
    .rblk_valid_i (be_rblk_valid),
    .rblk_i       (be_rblk),
    .bblk_valid_o (be_bblk_valid),
    .bblk_o       (be_bblk),
    .bpop_valid_i (be_bpop_valid),
    .bpop_cls_i   (be_bpop_cls),
    .wanted_o     (be_wanted),
    .ret_valid_o  (be_ret_valid),
    .ret_o        (be_ret),
    .idle_o
  );

  for (genvar d = 0; d < NumDomains; d++) begin : gen_link
    // One element per stage boundary; element 0 is the cluster-level end of the forward links and the
    // domain end of the completion link.
    logic      run_v  [LinkStages+1];
    logic      reg_v  [LinkStages+1];     // a registration: travels with the payload of the task link
    logic      load_v [LinkStages+1];
    run_req_t  run_p  [LinkStages+1];
    load_req_t load_p [LinkStages+1];
    logic      done_v [LinkStages+1];
    logic      done_r [LinkStages+1];
    done_t     done_p [LinkStages+1];
    // balancer links: element 0 is the sending end
    logic      give_v [LinkStages+1];
    give_t     give_p [LinkStages+1];
    logic      bblk_v [LinkStages+1];
    blk_t      bblk_p [LinkStages+1];
    logic      ret_v  [LinkStages+1];
    ret_t      ret_p  [LinkStages+1];
    rep_t      rep_p  [LinkStages+1];
    logic      rblk_v [LinkStages+1];
    rblk_t     rblk_p [LinkStages+1];
    logic      bpop_v [LinkStages+1];
    logic      bpop_c [LinkStages+1];
    logic [NumCls-1:0] want_p [LinkStages+1];

    assign run_v[0]  = be_run_valid[d];
    assign reg_v[0]  = be_reg_valid[d];
    assign run_p[0]  = be_run;
    assign load_v[0] = be_load_valid[d];
    assign load_p[0] = be_load;
    assign give_v[0] = be_give_valid[d];
    assign give_p[0] = be_give;
    assign bblk_v[0] = be_bblk_valid[d];
    assign bblk_p[0] = be_bblk;
    assign ret_v[0]  = be_ret_valid[d];
    assign ret_p[0]  = be_ret;
    assign rep_p[0]  = cl_rep[d];
    assign rblk_v[0] = cl_rblk_valid[d];
    assign rblk_p[0] = cl_rblk[d];
    assign bpop_v[0] = cl_bpop_valid[d];
    assign bpop_c[0] = cl_bpop_cls[d];
    assign want_p[0] = be_wanted[d];

    for (genvar s = 0; s < LinkStages; s++) begin : gen_stage
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          run_v[s+1]  <= 1'b0;
          reg_v[s+1]  <= 1'b0;
          load_v[s+1] <= 1'b0;
          give_v[s+1] <= 1'b0;
          bblk_v[s+1] <= 1'b0;
          ret_v[s+1]  <= 1'b0;
          rblk_v[s+1] <= 1'b0;
          bpop_v[s+1] <= 1'b0;
          rep_p[s+1]  <= '0;
          want_p[s+1] <= '0;
        end else begin
          run_v[s+1]  <= run_v[s];
          reg_v[s+1]  <= reg_v[s];
          load_v[s+1] <= load_v[s];
          give_v[s+1] <= give_v[s];
          bblk_v[s+1] <= bblk_v[s];
          ret_v[s+1]  <= ret_v[s];
          rblk_v[s+1] <= rblk_v[s];
          bpop_v[s+1] <= bpop_v[s];
          rep_p[s+1]  <= rep_p[s];
          want_p[s+1] <= want_p[s];
        end
      end
      always_ff @(posedge clk_i) begin
        if (run_v[s] || reg_v[s]) run_p[s+1] <= run_p[s];
        if (load_v[s]) load_p[s+1] <= load_p[s];
        if (give_v[s]) give_p[s+1] <= give_p[s];
        if (bblk_v[s]) bblk_p[s+1] <= bblk_p[s];
        if (ret_v[s])  ret_p[s+1]  <= ret_p[s];
        if (rblk_v[s]) rblk_p[s+1] <= rblk_p[s];
        if (bpop_v[s]) bpop_c[s+1] <= bpop_c[s];
      end

      spill_register #(
        .T (done_t)
      ) i_done_spill (
        .clk_i,
        .rst_ni,
        .valid_i (done_v[s]),
        .ready_o (done_r[s]),
        .data_i  (done_p[s]),
        .valid_o (done_v[s+1]),
        .ready_i (done_r[s+1]),
        .data_o  (done_p[s+1])
      );
    end

    assign cl_run_valid[d]  = run_v[LinkStages];
    assign cl_reg_valid[d]  = reg_v[LinkStages];
    assign cl_run[d]        = run_p[LinkStages];
    assign cl_load_valid[d] = load_v[LinkStages];
    assign cl_load[d]       = load_p[LinkStages];
    assign cl_give_valid[d] = give_v[LinkStages];
    assign cl_give[d]       = give_p[LinkStages];
    assign cl_bblk_valid[d] = bblk_v[LinkStages];
    assign cl_bblk[d]       = bblk_p[LinkStages];
    assign cl_ret_valid[d]  = ret_v[LinkStages];
    assign cl_ret[d]        = ret_p[LinkStages];
    assign be_rep[d]        = rep_p[LinkStages];
    assign be_rblk_valid[d] = rblk_v[LinkStages];
    assign be_rblk[d]       = rblk_p[LinkStages];
    assign be_bpop_valid[d] = bpop_v[LinkStages];
    assign be_bpop_cls[d]   = bpop_c[LinkStages];
    assign cl_wanted[d]     = want_p[LinkStages];

    assign done_v[0]         = cl_done_valid[d];
    assign done_p[0]         = cl_done[d];
    assign cl_done_ready[d]  = done_r[0];
    assign be_done_valid[d]  = done_v[LinkStages];
    assign be_done[d]        = done_p[LinkStages];
    assign done_r[LinkStages] = be_done_ready[d];
  end

  tsched_cluster #(
    .BalEn   (BalEn),
    .LendMin (LendMin)
  ) i_cluster (
    .clk_i,
    .rst_ni,
    .run_valid_i  (cl_run_valid),
    .reg_valid_i  (cl_reg_valid),
    .run_i        (cl_run),
    .load_valid_i (cl_load_valid),
    .load_i       (cl_load),
    .done_valid_o (cl_done_valid),
    .done_ready_i (cl_done_ready),
    .done_o       (cl_done),
    .rep_o        (cl_rep),
    .give_valid_i (cl_give_valid),
    .give_i       (cl_give),
    .rblk_valid_o (cl_rblk_valid),
    .rblk_o       (cl_rblk),
    .bblk_valid_i (cl_bblk_valid),
    .bblk_i       (cl_bblk),
    .bpop_valid_o (cl_bpop_valid),
    .bpop_cls_o   (cl_bpop_cls),
    .wanted_i     (cl_wanted),
    .ret_valid_i  (cl_ret_valid),
    .ret_i        (cl_ret),
    .dma_valid_o,
    .dma_ready_i,
    .dma_o,
    .dma_done_i,
    .pe_start_o,
    .pe_blk_o,
    .pe_done_valid_i,
    .pe_done_ready_o
  );

endmodule
