// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Handle file: the state and the lifetime of every physical handle.
//
// State
//   placed    the handle is data in an L1 slot: set, with domain and slot, when its load is issued
//   done      the task that defines the handle has finished
//   ref       tasks renamed with this handle as their data (s1) and not yet done
//   unmapped  the mapping of the handle has ended: no later task can name it
//   used      a task that computes on the data has been issued (placed handles only). Data that is
//             placed and not yet used is work a domain will get later; the load placement counts it.
//
// Release
//   A handle, and the slot it holds, is released when it is unmapped, done, and has no reference left.
//   The three conditions only ever become true and then stay true: a handle that is unmapped gets no new
//   reference, and done is never cleared. So the release can be found by a slow sweep: one releasable
//   handle is picked per cycle and released in the next cycle. Release does not wait for the window, so
//   one long task does not hold the slots of the tasks renamed after it.
//
//   A handle used only for order (s2) needs no reference: such a task either sees done at rename, or it
//   is woken by the done event, and the handle cannot be released before it is done. After that event a
//   waiting task may still hold the tag, and a later owner of the same handle may raise done for it
//   again, which only sets a bit that is already set.

module tsched_handle_file import tsched_pkg::*; #(
  parameter int unsigned NumRead = 2
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,
  // rename
  input  logic                  alloc_valid_i,
  input  phys_t                 alloc_i,
  input  logic  [1:0]           unmap_valid_i,
  input  phys_t [1:0]           unmap_i,
  // references on data handles: taken at rename, returned when the task is done
  input  logic                  ref_inc_i,
  input  phys_t                 ref_inc_p_i,
  input  logic                  ref_dec_i,
  input  phys_t                 ref_dec_p_i,
  // wake-up buses
  input  wake_place_t           place_i,
  input  wake_done_t            done_i,
  // a task that computes on the data of use_i was issued
  input  logic                  use_valid_i,
  input  phys_t                 use_i,
  // placed data stopped waiting for its first task: [0] it was used, [1] it was released unused
  output logic  [1:0]           unused_dec_valid_o,
  output dom_t  [1:0]           unused_dec_dom_o,
  // reads
  input  phys_t   [NumRead-1:0] rd_i,
  output hstate_t [NumRead-1:0] rd_o,
  output logic    [NumRead-1:0] rd_sat_o,     // the reference counter of the handle is at its maximum
  // release
  output logic                  free_valid_o,
  output phys_t                 free_o,
  output logic                  slot_free_valid_o,
  output dom_t                  slot_free_dom_o,
  output slot_t                 slot_free_o
);

  logic  [NumPhys-1:0]           live_d, live_q;
  logic  [NumPhys-1:0]           unmapped_d, unmapped_q;
  logic  [NumPhys-1:0]           placed_d, placed_q;
  logic  [NumPhys-1:0]           done_d, done_q;
  logic  [NumPhys-1:0]           used_d, used_q;
  logic  [NumPhys-1:0][RefW-1:0] ref_d, ref_q;
  dom_t  [NumPhys-1:0]           dom_q;
  slot_t [NumPhys-1:0]           slot_q;

  // -------------------------------------------------------------------------------------------
  // Release sweep
  // -------------------------------------------------------------------------------------------
  logic [NumPhys-1:0] releasable;
  logic               gc_v_d, gc_v_q;
  phys_t              gc_d, gc_q;
  logic               gc_none;

  for (genvar p = 0; p < NumPhys; p++) begin : gen_rel
    // The handle being released in this cycle is still live; it must not be picked again.
    assign releasable[p] = live_q[p] & unmapped_q[p] & done_q[p] & (ref_q[p] == '0)
                         & ~(gc_v_q & (gc_q == phys_t'(p)));
  end

  lzc #(
    .WIDTH (NumPhys),
    .MODE  (1'b0)
  ) i_lzc_rel (
    .in_i    (releasable),
    .cnt_o   (gc_d),
    .empty_o (gc_none)
  );
  assign gc_v_d = ~gc_none;

  assign free_valid_o      = gc_v_q;
  assign free_o            = gc_q;
  assign slot_free_valid_o = gc_v_q & placed_q[gc_q];
  assign slot_free_dom_o   = dom_q[gc_q];
  assign slot_free_o       = slot_q[gc_q];

  // A handle with a task being issued holds a reference, so it is not the one being released.
  assign unused_dec_valid_o[0] = use_valid_i & placed_q[use_i] & ~used_q[use_i];
  assign unused_dec_dom_o[0]   = dom_q[use_i];
  assign unused_dec_valid_o[1] = gc_v_q & placed_q[gc_q] & ~used_q[gc_q];
  assign unused_dec_dom_o[1]   = dom_q[gc_q];

  // -------------------------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------------------------
  // The writers of one bit vector never set and clear the same handle in a cycle: allocation targets a
  // handle that is not live, every other event a live one.
  always_comb begin
    live_d     = live_q;
    unmapped_d = unmapped_q;
    placed_d   = placed_q;
    done_d     = done_q;
    used_d     = used_q;
    if (gc_v_q) live_d[gc_q] = 1'b0;
    if (use_valid_i) used_d[use_i] = 1'b1;
    if (alloc_valid_i) begin
      used_d[alloc_i]     = 1'b0;
      live_d[alloc_i]     = 1'b1;
      unmapped_d[alloc_i] = 1'b0;
      placed_d[alloc_i]   = 1'b0;
      done_d[alloc_i]     = 1'b0;
    end
    for (int unsigned k = 0; k < 2; k++) begin
      if (unmap_valid_i[k]) unmapped_d[unmap_i[k]] = 1'b1;
    end
    if (place_i.v) placed_d[place_i.tag] = 1'b1;
    if (done_i.v)  done_d[done_i.tag]    = 1'b1;
  end

  for (genvar p = 0; p < NumPhys; p++) begin : gen_ref
    logic inc, dec;
    assign inc      = ref_inc_i & (ref_inc_p_i == phys_t'(p));
    assign dec      = ref_dec_i & (ref_dec_p_i == phys_t'(p));
    assign ref_d[p] = ref_q[p] + RefW'(inc) - RefW'(dec);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      live_q     <= '0;
      unmapped_q <= '0;
      placed_q   <= '0;
      done_q     <= '0;
      used_q     <= '0;
      ref_q      <= '0;
      gc_v_q     <= 1'b0;
      gc_q       <= '0;
    end else begin
      live_q     <= live_d;
      unmapped_q <= unmapped_d;
      placed_q   <= placed_d;
      done_q     <= done_d;
      used_q     <= used_d;
      ref_q      <= ref_d;
      gc_v_q     <= gc_v_d;
      gc_q       <= gc_d;
    end
  end

  // Read only while `placed` is set, so no reset.
  always_ff @(posedge clk_i) begin
    if (place_i.v) begin
      dom_q[place_i.tag]  <= place_i.dom;
      slot_q[place_i.tag] <= place_i.slot;
    end
  end

  for (genvar r = 0; r < NumRead; r++) begin : gen_read
    assign rd_o[r]     = '{placed: placed_q[rd_i[r]], done: done_q[rd_i[r]], dom: dom_q[rd_i[r]], slot: slot_q[rd_i[r]]};
    assign rd_sat_o[r] = &ref_q[rd_i[r]];
  end

`ifndef TARGET_SYNTHESIS
  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!(alloc_valid_i && live_q[alloc_i])) else $error("[tsched_handle_file] handle %0d allocated twice", alloc_i);
      assert (!(ref_dec_i && (ref_q[ref_dec_p_i] == '0)))
        else $error("[tsched_handle_file] reference of handle %0d returned twice", ref_dec_p_i);
      assert (!(ref_inc_i && !ref_dec_i && (&ref_q[ref_inc_p_i])))
        else $error("[tsched_handle_file] reference counter of handle %0d overflows", ref_inc_p_i);
      assert (!(ref_inc_i && unmapped_q[ref_inc_p_i]))
        else $error("[tsched_handle_file] reference on handle %0d after its mapping ended", ref_inc_p_i);
    end
  end
  // pragma translate_on
`endif

endmodule
