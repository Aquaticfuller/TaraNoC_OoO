// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// First set bit of a wide vector, as a one-hot vector and as an index.
//
// The search has two levels that run in parallel: the first set bit inside every block of B bits, and
// the first block that has a set bit. The one-hot result is the AND of the two, so a user that clears
// or sets the chosen bit needs no decode of the index. The index comes from one-hot multiplexers.

module tsched_first_oh #(
  parameter int unsigned N = 256,
  parameter int unsigned B = 16,
  // derived
  parameter int unsigned W = (N > 1) ? $clog2(N) : 1
) (
  input  logic [N-1:0] in_i,
  output logic         any_o,
  output logic [N-1:0] oh_o,
  output logic [W-1:0] idx_o
);

  localparam int unsigned NB = (N + B - 1) / B;
  localparam int unsigned BW = (B > 1) ? $clog2(B) : 1;
  localparam int unsigned NW = (NB > 1) ? $clog2(NB) : 1;

  logic [NB-1:0][B-1:0]  blk, in_first;
  logic [NB-1:0]         blk_any, blk_first;
  logic [NB-1:0][BW-1:0] in_idx;
  logic [NB-1:0][NW-1:0] blk_num;
  logic [B-1:0][BW-1:0]  pos;
  logic [BW-1:0]         lo;
  logic [NW-1:0]         hi;

  for (genvar i = 0; i < B; i++) begin : gen_pos
    assign pos[i] = BW'(i);
  end

  for (genvar b = 0; b < NB; b++) begin : gen_blk
    for (genvar i = 0; i < B; i++) begin : gen_bit
      if (b * B + i < N) begin : gen_in
        assign blk[b][i] = in_i[b * B + i];
      end else begin : gen_pad
        assign blk[b][i] = 1'b0;
      end
      if (i == 0) begin : gen_f0
        assign in_first[b][i] = blk[b][i];
      end else begin : gen_fi
        assign in_first[b][i] = blk[b][i] & ~(|blk[b][i-1:0]);
      end
      if (b * B + i < N) begin : gen_oh
        assign oh_o[b * B + i] = blk_first[b] & in_first[b][i];
      end
    end
    assign blk_any[b] = |blk[b];
    assign blk_num[b] = NW'(b);
    if (b == 0) begin : gen_b0
      assign blk_first[b] = blk_any[b];
    end else begin : gen_bi
      assign blk_first[b] = blk_any[b] & ~(|blk_any[b-1:0]);
    end

    tsched_oh_mux #(
      .N (B),
      .W (BW)
    ) i_in_idx (
      .sel_i  (in_first[b]),
      .data_i (pos),
      .data_o (in_idx[b])
    );
  end

  tsched_oh_mux #(
    .N (NB),
    .W (BW)
  ) i_lo (
    .sel_i  (blk_first),
    .data_i (in_idx),
    .data_o (lo)
  );

  tsched_oh_mux #(
    .N (NB),
    .W (NW)
  ) i_hi (
    .sel_i  (blk_first),
    .data_i (blk_num),
    .data_o (hi)
  );

  assign any_o = |blk_any;
  assign idx_o = W'({hi, lo});

endmodule
