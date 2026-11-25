// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Bridge between the load units of the task scheduler and the DMA engines of the cluster hardware.
//
// The scheduler asks the DMA engine of a group for one chunk of a load: `len` bytes, the group's share of
// the bytes [off, off + GroupsPerDomain * len) of the load. This module turns the chunk into the transfer
// the engine understands: pieces of one group stripe, a fixed distance apart.
//
// Memory layout it assumes (that of the cluster hardware):
//   L1 is interleaved over the groups. Group i owns GroupBytes bytes of every row of L1, at i * GroupBytes
//   in the row, and a row has one stripe of every group of the cluster.
//   A load occupies whole rows of one slot. In a row it fills the stripes of the four groups of its domain
//   (group ids 4d .. 4d+3, a 2 x 2 square in Z-order), so a row holds 4 * GroupBytes bytes of the load.
//   In L2 the load is contiguous: row after row, in a row group after group.
//
//   source       addr + off + g * GroupBytes                         next piece 4 * GroupBytes further
//   destination  slot_base + (slot * SlotBytes + off) * NumDomains
//                          + i * GroupBytes                          next piece one row of L1 further
//   pieces       len / GroupBytes, each GroupBytes long
//
// with i the id of the group in the cluster (Z-order, tsched_sys_pkg) and g = i mod 4 its place in its
// domain, the order in which the address windows of the cluster lay a domain out. The scheduler's own
// group index is converted here. A PE reads the slot as one contiguous range through such a window.
// A chunk must be whole stripes: the length of a load is a multiple of 4 * ChunksPerGroup * GroupBytes.

module tsched_dma_bridge import tsched_pkg::*; #(
  parameter  int unsigned GroupBytes = 512,     // bytes of one group in a row of L1, a power of two
  parameter  int unsigned SlotBytes  = 16384,   // bytes of the load one slot holds, a power of two
  parameter  int unsigned HwAddrW    = 32,
  parameter  type         hw_req_t   = logic,   // {src, dst, len, src_stride, dst_stride, reps}
  localparam int unsigned GrpShift   = $clog2(GroupBytes),
  localparam int unsigned DomShift   = $clog2(NumDomains)
) (
  // L1 address of slot 0, a row boundary (configuration, constant while loads run)
  input  logic     [HwAddrW-1:0]    slot_base_i,
  // load units
  input  logic     [NumGroups-1:0]  dma_valid_i,
  output logic     [NumGroups-1:0]  dma_ready_o,
  input  dma_req_t [NumGroups-1:0]  dma_i,
  output logic     [NumGroups-1:0]  dma_done_o,
  // DMA engines
  output logic     [NumGroups-1:0]  hw_valid_o,
  input  logic     [NumGroups-1:0]  hw_ready_i,
  output hw_req_t  [NumGroups-1:0]  hw_req_o,
  input  logic     [NumGroups-1:0]  hw_done_i
);

  for (genvar r = 0; r < NumGroups; r++) begin : gen_group
    localparam int unsigned I = tsched_sys_pkg::zid_of_group(r);   // the group in the cluster
    localparam int unsigned G = I % GroupsPerDomain;               // its place in its domain
    logic [HwAddrW-1:0] in_slot;
    assign hw_valid_o[I]  = dma_valid_i[r];
    assign dma_ready_o[r] = hw_ready_i[I];
    assign dma_done_o[r]  = hw_done_i[I];
    // Byte of the load inside the slot area of its domain.
    assign in_slot = HwAddrW'(dma_i[r].slot) * HwAddrW'(SlotBytes) + HwAddrW'(dma_i[r].off);
    always_comb begin
      hw_req_o[I]            = '0;
      hw_req_o[I].src        = HwAddrW'(dma_i[r].addr) + HwAddrW'(dma_i[r].off) + HwAddrW'(G * GroupBytes);
      hw_req_o[I].dst        = slot_base_i + (in_slot << DomShift) + HwAddrW'(I * GroupBytes);
      hw_req_o[I].len        = GroupBytes;
      hw_req_o[I].src_stride = GroupsPerDomain * GroupBytes;
      hw_req_o[I].dst_stride = NumGroups * GroupBytes;
      hw_req_o[I].reps       = 32'(dma_i[r].len >> GrpShift);
    end
  end

`ifndef TARGET_SYNTHESIS
  initial begin
    assert (GroupBytes == 2**GrpShift && SlotBytes == 2**$clog2(SlotBytes) && NumDomains == 2**DomShift)
      else $fatal(1, "[tsched_dma_bridge] GroupBytes, SlotBytes and the number of domains must be powers of two");
  end
`endif

endmodule
