// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Task scheduler, complete: the cluster level and the cluster side, joined by registered links.
//
// LinkStages register stages sit on every link between the cluster level and a domain, to cover the
// distance. The task and load links carry valid and data only (the cluster level counts credits); the
// completion links use spill registers.

module tsched_top import tsched_pkg::*; #(
  parameter int unsigned LinkStages = 1,
  parameter bit          LendEn     = 1'b1,
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

  logic      [NumDomains-1:0] be_run_valid, be_load_valid;
  run_req_t                   be_run;
  load_req_t                  be_load;
  logic      [NumDomains-1:0] be_done_valid, be_done_ready;
  done_t     [NumDomains-1:0] be_done;

  logic      [NumDomains-1:0] cl_run_valid, cl_load_valid;
  run_req_t  [NumDomains-1:0] cl_run;
  load_req_t [NumDomains-1:0] cl_load;
  logic      [NumDomains-1:0] cl_done_valid, cl_done_ready;
  done_t     [NumDomains-1:0] cl_done;

  tsched_backend i_backend (
    .clk_i,
    .rst_ni,
    .instr_valid_i,
    .instr_ready_o,
    .instr_i,
    .run_valid_o  (be_run_valid),
    .run_o        (be_run),
    .load_valid_o (be_load_valid),
    .load_o       (be_load),
    .done_valid_i (be_done_valid),
    .done_ready_o (be_done_ready),
    .done_i       (be_done),
    .idle_o
  );

  for (genvar d = 0; d < NumDomains; d++) begin : gen_link
    // One element per stage boundary; element 0 is the cluster-level end of the forward links and the
    // domain end of the completion link.
    logic      run_v  [LinkStages+1];
    logic      load_v [LinkStages+1];
    run_req_t  run_p  [LinkStages+1];
    load_req_t load_p [LinkStages+1];
    logic      done_v [LinkStages+1];
    logic      done_r [LinkStages+1];
    done_t     done_p [LinkStages+1];

    assign run_v[0]  = be_run_valid[d];
    assign run_p[0]  = be_run;
    assign load_v[0] = be_load_valid[d];
    assign load_p[0] = be_load;

    for (genvar s = 0; s < LinkStages; s++) begin : gen_stage
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          run_v[s+1]  <= 1'b0;
          load_v[s+1] <= 1'b0;
        end else begin
          run_v[s+1]  <= run_v[s];
          load_v[s+1] <= load_v[s];
        end
      end
      always_ff @(posedge clk_i) begin
        if (run_v[s])  run_p[s+1]  <= run_p[s];
        if (load_v[s]) load_p[s+1] <= load_p[s];
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
    assign cl_run[d]        = run_p[LinkStages];
    assign cl_load_valid[d] = load_v[LinkStages];
    assign cl_load[d]       = load_p[LinkStages];

    assign done_v[0]         = cl_done_valid[d];
    assign done_p[0]         = cl_done[d];
    assign cl_done_ready[d]  = done_r[0];
    assign be_done_valid[d]  = done_v[LinkStages];
    assign be_done[d]        = done_p[LinkStages];
    assign done_r[LinkStages] = be_done_ready[d];
  end

  tsched_cluster #(
    .LendEn  (LendEn),
    .LendMin (LendMin)
  ) i_cluster (
    .clk_i,
    .rst_ni,
    .run_valid_i  (cl_run_valid),
    .run_i        (cl_run),
    .load_valid_i (cl_load_valid),
    .load_i       (cl_load),
    .done_valid_o (cl_done_valid),
    .done_ready_i (cl_done_ready),
    .done_o       (cl_done),
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
