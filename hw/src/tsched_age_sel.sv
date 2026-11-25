// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Oldest-first select over a table whose entries are filled and freed in any order.
//
// older_q[i][j] says that entry j was pushed before entry i. Pushing entry i sets row i to the entries
// valid at that time and clears column i, so a bit about a freed entry can only be stale while that entry
// is invalid, and an invalid entry never requests. Among the requesters of one select the grant goes to
// the one with no older requester, which is unique because push order is a total order.

module tsched_age_sel #(
  parameter int unsigned N      = 32,
  parameter int unsigned NumSel = 1
) (
  input  logic                     clk_i,
  input  logic                     rst_ni,
  input  logic                     push_i,
  input  logic [N-1:0]             push_oh_i,   // one-hot: the entry being filled
  input  logic [N-1:0]             valid_i,     // entries valid before this push
  input  logic [NumSel-1:0][N-1:0] req_i,
  output logic [NumSel-1:0][N-1:0] gnt_o        // one-hot: the oldest requester of each select
);

  logic [N-1:0][N-1:0] older_d, older_q;

  always_comb begin
    older_d = older_q;
    if (push_i) begin
      for (int unsigned i = 0; i < N; i++) begin
        for (int unsigned j = 0; j < N; j++) begin
          if (push_oh_i[i]) begin
            older_d[i][j] = valid_i[j] & ~push_oh_i[j];
          end else if (push_oh_i[j]) begin
            older_d[i][j] = 1'b0;
          end
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      older_q <= '0;
    end else if (push_i) begin
      older_q <= older_d;
    end
  end

  for (genvar s = 0; s < NumSel; s++) begin : gen_sel
    for (genvar i = 0; i < N; i++) begin : gen_entry
      assign gnt_o[s][i] = req_i[s][i] & ~(|(older_q[i] & req_i[s]));
    end
  end

endmodule
