// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Round-robin select with a one-hot grant.
//
// The requests behind the last grant that was used go first, in index order; if there is none, the
// lowest request wins. Both searches run in parallel and the grant stays one-hot, so the logic that
// uses it is an AND-OR and needs no index decode. `take_i` only moves the starting point: it may
// arrive late without lengthening the path to the grant.

module tsched_rr_sel #(
  parameter int unsigned N = 8
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [N-1:0] req_i,
  input  logic         take_i,   // the grant is used
  output logic         any_o,
  output logic [N-1:0] gnt_o
);

  logic [N-1:0] mask_q;          // positions behind the last grant that was used
  logic [N-1:0] hi, hi_first, lo_first, behind;

  assign hi = req_i & mask_q;

  assign lo_first[0] = req_i[0];
  assign hi_first[0] = hi[0];
  assign behind[0]   = 1'b0;
  for (genvar i = 1; i < N; i++) begin : gen_first
    assign lo_first[i] = req_i[i] & ~(|req_i[i-1:0]);
    assign hi_first[i] = hi[i] & ~(|hi[i-1:0]);
    assign behind[i]   = |gnt_o[i-1:0];
  end

  assign any_o = |req_i;
  assign gnt_o = (|hi) ? hi_first : lo_first;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mask_q <= '0;
    end else if (take_i) begin
      mask_q <= behind;
    end
  end

endmodule
