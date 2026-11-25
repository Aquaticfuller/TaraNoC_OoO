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
  output logic [IdxW-1:0]          idx_o,
  output logic [N-1:0]             oh_o       // the same choice one-hot; zero when valid_o is low
);

  localparam int unsigned M  = (N + 3) / 4;
  localparam int unsigned P2 = 1 << ((M > 1) ? $clog2(M) : 1);

  logic [M-1:0]           v1_d, v1_q;
  logic [M-1:0][KeyW-1:0] k1_d, k1_q;
  logic [M-1:0][IdxW-1:0] i1_d, i1_q;
  logic                   v2_d, v2_q;
  logic [IdxW-1:0]        i2_d, i2_q;
  logic [N-1:0]           oh_d, oh_q;

  // Both steps are binary trees in heap layout (node i has the children 2i and 2i + 1). The left child
  // wins unless the right one is valid and strictly smaller, so equal keys resolve to the lower index.

  // Step 1: the smallest of each group of four.
  always_comb begin
    for (int unsigned m = 0; m < M; m++) begin
      logic [7:0]           v;
      logic [7:0][KeyW-1:0] k;
      logic [7:0][IdxW-1:0] x;
      v = '0;
      k = '0;
      x = '0;
      for (int unsigned j = 0; j < 4; j++) begin
        if (4 * m + j < N) begin
          v[4 + j] = valid_i[4 * m + j];
          k[4 + j] = key_i[4 * m + j];
          x[4 + j] = IdxW'(4 * m + j);
        end
      end
      for (int unsigned i = 3; i >= 1; i--) begin
        if (v[2 * i + 1] && (!v[2 * i] || (k[2 * i + 1] < k[2 * i]))) begin
          v[i] = 1'b1;
          k[i] = k[2 * i + 1];
          x[i] = x[2 * i + 1];
        end else begin
          v[i] = v[2 * i];
          k[i] = k[2 * i];
          x[i] = x[2 * i];
        end
      end
      v1_d[m] = v[1];
      k1_d[m] = k[1];
      i1_d[m] = x[1];
    end
  end

  // Step 2: the smallest of the group winners.
  always_comb begin
    logic [2*P2-1:0]           v;
    logic [2*P2-1:0][KeyW-1:0] k;
    logic [2*P2-1:0][IdxW-1:0] x;
    v = '0;
    k = '0;
    x = '0;
    for (int unsigned m = 0; m < M; m++) begin
      v[P2 + m] = v1_q[m];
      k[P2 + m] = k1_q[m];
      x[P2 + m] = i1_q[m];
    end
    for (int unsigned i = P2 - 1; i >= 1; i--) begin
      if (v[2 * i + 1] && (!v[2 * i] || (k[2 * i + 1] < k[2 * i]))) begin
        v[i] = 1'b1;
        k[i] = k[2 * i + 1];
        x[i] = x[2 * i + 1];
      end else begin
        v[i] = v[2 * i];
        k[i] = k[2 * i];
        x[i] = x[2 * i];
      end
    end
    v2_d = v[1];
    i2_d = x[1];
    for (int unsigned n = 0; n < N; n++) oh_d[n] = v[1] & (x[1] == IdxW'(n));
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      v1_q <= '0;
      k1_q <= '0;
      i1_q <= '0;
      v2_q <= 1'b0;
      i2_q <= '0;
      oh_q <= '0;
    end else begin
      v1_q <= v1_d;
      k1_q <= k1_d;
      i1_q <= i1_d;
      v2_q <= v2_d;
      i2_q <= i2_d;
      oh_q <= oh_d;
    end
  end

  assign valid_o = v2_q;
  assign idx_o   = i2_q;
  assign oh_o    = oh_q;

endmodule
