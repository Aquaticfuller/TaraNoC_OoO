// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// One-hot multiplexer: the OR of the selected inputs, built as a balanced binary tree so that its depth
// is log2(N) whatever the synthesis tool does with a reduction written as a loop. The select must be
// one-hot or zero; with no select the output is zero.

module tsched_oh_mux #(
  parameter int unsigned N = 32,
  parameter int unsigned W = 8
) (
  input  logic [N-1:0]        sel_i,
  input  logic [N-1:0][W-1:0] data_i,
  output logic [W-1:0]        data_o
);

  localparam int unsigned P = 1 << ((N > 1) ? $clog2(N) : 1);

  // Heap layout: node i has the children 2i and 2i + 1; the leaves are nodes P .. 2P - 1.
  logic [2*P-1:0][W-1:0] node;

  always_comb begin
    node = '0;
    for (int unsigned i = 0; i < N; i++) node[P + i] = {W{sel_i[i]}} & data_i[i];
    for (int unsigned i = P - 1; i >= 1; i--) node[i] = node[2 * i] | node[2 * i + 1];
  end

  assign data_o = node[1];

endmodule
