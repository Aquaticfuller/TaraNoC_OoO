// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Index of the smallest key among the valid inputs, registered after each of two reduction steps
// (groups of four, then the group winners). The result therefore describes the inputs of two cycles
// ago: a user must check that the chosen input is still valid before acting on it. Equal keys resolve
// to the lower index, so a caller that wants rotation puts the rotated position in the low key bits.

module tsched_argmin #(
  parameter  int unsigned N    = 16,
  parameter  int unsigned KeyW = 12,
  localparam int unsigned IdxW = (N > 1) ? $clog2(N) : 1
) (
  input  logic                     clk_i,
  input  logic                     rst_ni,
  input  logic [N-1:0]             valid_i,
  input  logic [N-1:0][KeyW-1:0]   key_i,
  output logic                     valid_o,
  output logic [IdxW-1:0]          idx_o
);

  localparam int unsigned M = (N + 3) / 4;

  logic [M-1:0]           v1_d, v1_q;
  logic [M-1:0][KeyW-1:0] k1_d, k1_q;
  logic [M-1:0][IdxW-1:0] i1_d, i1_q;
  logic                   v2_d, v2_q;
  logic [KeyW-1:0]        k2;
  logic [IdxW-1:0]        i2_d, i2_q;

  always_comb begin
    for (int unsigned m = 0; m < M; m++) begin
      v1_d[m] = 1'b0;
      k1_d[m] = '1;
      i1_d[m] = '0;
      for (int unsigned j = 0; j < 4; j++) begin
        if ((4 * m + j < N) && valid_i[4 * m + j] && (!v1_d[m] || (key_i[4 * m + j] < k1_d[m]))) begin
          v1_d[m] = 1'b1;
          k1_d[m] = key_i[4 * m + j];
          i1_d[m] = IdxW'(4 * m + j);
        end
      end
    end
  end

  always_comb begin
    v2_d = 1'b0;
    k2   = '1;
    i2_d = '0;
    for (int unsigned m = 0; m < M; m++) begin
      if (v1_q[m] && (!v2_d || (k1_q[m] < k2))) begin
        v2_d = 1'b1;
        k2   = k1_q[m];
        i2_d = i1_q[m];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      v1_q <= '0;
      k1_q <= '0;
      i1_q <= '0;
      v2_q <= 1'b0;
      i2_q <= '0;
    end else begin
      v1_q <= v1_d;
      k1_q <= k1_d;
      i1_q <= i1_d;
      v2_q <= v2_d;
      i2_q <= i2_d;
    end
  end

  assign valid_o = v2_q;
  assign idx_o   = i2_q;

endmodule
