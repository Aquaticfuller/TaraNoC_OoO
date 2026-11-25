// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Bridge between the group dispatchers of the task scheduler and the cores of the cluster hardware.
//
// In the cluster a PE is a core. Core 0 of a tile has no vector unit and drives the tile's tensor
// engine: it is the tensor PE of that tile. The other cores of a tile have a vector unit each: they are
// the vector PEs. A group dispatcher numbers its PEs tensor engines first, then vector units.
//
// The dispatcher starts a PE with a pulse and holds the block of each PE class on a bus. The core side
// takes a pulse per core with a descriptor of DispWidth bits, which a small register block in the tile
// shows to the core (fsync_shim in the cluster hardware). Completions pass straight through.
//
// Descriptor, as the software of the core reads it (three words):
//   word 0  [31:0]  argument of the kernel
//   word 1  [7:0]   kernel     [17:8] index of the block     [27:18] blocks of the task    [28] PE class
//   word 2  [7:0]   domain that holds the data   [8] the task has data in a slot   [15:12] slot
//           [23:16] index of the task in that domain

module tsched_disp_bridge import tsched_pkg::*; #(
  parameter  int unsigned TilesPerGroup = 4,
  parameter  int unsigned CoresPerTile  = 4,
  parameter  int unsigned DispWidth     = 96,
  localparam int unsigned CoresPerGroup = TilesPerGroup * CoresPerTile,
  localparam int unsigned NumCores      = NumGroups * CoresPerGroup
) (
  // group dispatchers
  input  logic [NumGroups-1:0][NumPes-1:0]    pe_start_i,
  input  blk_t [NumGroups-1:0][NumCls-1:0]    pe_blk_i,
  output logic [NumGroups-1:0][NumPes-1:0]    pe_done_valid_o,
  input  logic [NumGroups-1:0][NumPes-1:0]    pe_done_ready_i,
  // cores
  output logic [NumCores-1:0]                 disp_start_o,
  output logic [NumCores-1:0][DispWidth-1:0]  disp_desc_o,
  input  logic [NumCores-1:0]                 disp_done_valid_i,
  output logic [NumCores-1:0]                 disp_done_ready_o
);

  localparam int unsigned VecPerTile = CoresPerTile - 1;

  // Core of PE p of a group, counted inside the group.
  function automatic int unsigned core_of(input int unsigned p);
    if (p < NumTensor) return p * CoresPerTile;
    return ((p - NumTensor) / VecPerTile) * CoresPerTile + 1 + (p - NumTensor) % VecPerTile;
  endfunction

  function automatic logic [95:0] pack(input blk_t b);
    logic [2:0][31:0] w;
    w    = '0;
    w[0] = 32'(b.arg);
    w[1] = {3'b0, b.pcls, 10'(b.nblk), 10'(b.bidx), 8'(b.kern)};
    w[2] = {8'b0, 8'(b.tix), 4'(b.slot), 3'b0, b.slot_v, 8'(b.dom)};
    return w;
  endfunction

  for (genvar g = 0; g < NumGroups; g++) begin : gen_group
    for (genvar p = 0; p < NumPes; p++) begin : gen_pe
      localparam int unsigned Core = g * CoresPerGroup + core_of(p);
      localparam int unsigned Cls  = (p < NumTensor) ? ClsT : ClsV;
      assign disp_start_o[Core]      = pe_start_i[g][p];
      assign disp_desc_o[Core]       = DispWidth'(pack(pe_blk_i[g][Cls]));
      assign pe_done_valid_o[g][p]   = disp_done_valid_i[Core];
      assign disp_done_ready_o[Core] = pe_done_ready_i[g][p];
    end
  end

`ifndef TARGET_SYNTHESIS
  initial begin
    assert (NumTensor == TilesPerGroup && NumVector == TilesPerGroup * VecPerTile)
      else $fatal(1, "[tsched_disp_bridge] %0d tensor and %0d vector PEs per group do not match %0d tiles of %0d cores",
                  NumTensor, NumVector, TilesPerGroup, CoresPerTile);
  end
`endif

endmodule
