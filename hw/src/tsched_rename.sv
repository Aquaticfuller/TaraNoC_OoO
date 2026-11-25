// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Handle rename: one task instruction per cycle.
//
// A program names NumArch handle registers. Each task that defines a handle gets a fresh physical
// handle, so a program can reuse one register for every piece of data it streams. The map table gives
// the physical handle a later task depends on.
//
// The mapping of a physical handle ends when a later task defines the same register, or when a TRun
// with `kill` or a TFree names it. From then on no new task can name the handle; the handle file
// releases it once its own task and the tasks that use its data are done (see tsched_handle_file).

module tsched_rename import tsched_pkg::*; (
  input  logic        clk_i,
  input  logic        rst_ni,
  // task instructions, program order
  input  logic        instr_valid_i,
  output logic        instr_ready_o,
  input  tinstr_t     instr_i,
  // window
  input  logic        win_ready_i,
  input  wid_t        win_wid_i,
  output logic        win_valid_o,
  output win_alloc_t  win_o,
  // load queue
  input  logic        loadq_ready_i,
  output logic        loadq_valid_o,
  output loadq_t      loadq_o,
  // run issue queue
  input  logic        riq_ready_i,
  output logic        riq_valid_o,
  output riq_push_t   riq_o,
  // handle file
  output logic        alloc_valid_o,   // a physical handle was allocated
  output phys_t       alloc_o,
  output logic [1:0]  unmap_valid_o,   // the mapping of a physical handle ended
  output phys_t [1:0] unmap_o,
  input  logic        s1_sat_i,        // no further task may use the data of riq_o.s1 for now
  input  logic        free_valid_i,    // a physical handle was released
  input  phys_t       free_i
);

  // -------------------------------------------------------------------------------------------
  // Map table
  // -------------------------------------------------------------------------------------------
  logic  [NumArch-1:0] map_v_d, map_v_q;
  phys_t [NumArch-1:0] map_d,   map_q;

  logic  is_load, is_run, is_join, is_free;
  logic  need_pd;
  logic  s1_v, s2_v;
  phys_t s1, s2;
  logic  kill;
  logic  old_v;
  phys_t old;
  logic  q_ready;
  logic  fire;

  assign is_load = instr_i.op == TLoad;
  assign is_run  = instr_i.op == TRun;
  assign is_join = instr_i.op == TJoin;
  assign is_free = instr_i.op == TFree;

  assign need_pd = instr_i.hd_v & ~is_free;
  assign s1_v    = instr_i.hs1_v & map_v_q[instr_i.hs1] & (is_run | is_free);
  assign s1      = map_q[instr_i.hs1];
  assign s2_v    = instr_i.hs2_v & map_v_q[instr_i.hs2] & is_run;
  assign s2      = map_q[instr_i.hs2];
  assign kill    = s1_v & (is_free | instr_i.kill);
  assign old_v   = need_pd & map_v_q[instr_i.hd];
  assign old     = map_q[instr_i.hd];

  // -------------------------------------------------------------------------------------------
  // Free list: a bitmap, with the next handle to hand out held in a register so that the search over
  // the bitmap is not in the rename path.
  // -------------------------------------------------------------------------------------------
  logic [NumPhys-1:0] free_d, free_q;
  logic               nf_valid_d, nf_valid_q;
  phys_t              nf_d, nf_q;
  phys_t              cand;
  logic               cand_empty;
  logic               refill;

  lzc #(
    .WIDTH (NumPhys),
    .MODE  (1'b0)
  ) i_lzc_free (
    .in_i    (free_q),
    .cnt_o   (cand),
    .empty_o (cand_empty)
  );

  assign q_ready       = is_load ? loadq_ready_i : (is_run ? (riq_ready_i & ~(s1_v & s1_sat_i)) : 1'b1);
  assign instr_ready_o = (win_ready_i | is_free) & (~need_pd | nf_valid_q) & q_ready;
  assign fire          = instr_valid_i & instr_ready_o;

  assign refill = (~nf_valid_q | (fire & need_pd)) & ~cand_empty;

  always_comb begin
    free_d     = free_q;
    nf_d       = nf_q;
    nf_valid_d = nf_valid_q;
    if (refill) begin
      nf_d         = cand;
      nf_valid_d   = 1'b1;
      free_d[cand] = 1'b0;
    end else if (fire && need_pd) begin
      nf_valid_d = 1'b0;
    end
    if (free_valid_i) free_d[free_i] = 1'b1;
  end

  always_comb begin
    map_v_d = map_v_q;
    map_d   = map_q;
    if (fire) begin
      if (kill) map_v_d[instr_i.hs1] = 1'b0;
      if (need_pd) begin
        map_v_d[instr_i.hd] = 1'b1;
        map_d[instr_i.hd]   = nf_q;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      map_v_q    <= '0;
      map_q      <= '0;
      free_q     <= '1;
      nf_valid_q <= 1'b0;
      nf_q       <= '0;
    end else begin
      map_v_q    <= map_v_d;
      map_q      <= map_d;
      free_q     <= free_d;
      nf_valid_q <= nf_valid_d;
      nf_q       <= nf_d;
    end
  end

  // -------------------------------------------------------------------------------------------
  // Outputs
  // -------------------------------------------------------------------------------------------
  assign alloc_valid_o = fire & need_pd;
  assign alloc_o       = nf_q;

  // A TFree only ends a mapping: it takes no window entry.
  assign win_valid_o = fire & ~is_free;
  assign win_o       = '{is_join: is_join, pd_v: need_pd, pd: nf_q, s1_v: s1_v & is_run, s1: s1};

  // Mappings that end: the old one of hd, and the killed hs1 unless it is that same handle.
  assign unmap_valid_o[0] = fire & old_v;
  assign unmap_o[0]       = old;
  assign unmap_valid_o[1] = fire & kill & ~(old_v & (instr_i.hd == instr_i.hs1));
  assign unmap_o[1]       = s1;

  assign loadq_valid_o = fire & is_load;
  assign loadq_o       = '{wid: win_wid_i, pd: nf_q, len: instr_i.len, addr: instr_i.addr};

  assign riq_valid_o = fire & is_run;
  assign riq_o       = '{wid: win_wid_i, s1_v: s1_v, s1: s1, follow: instr_i.follow, s2_v: s2_v, s2: s2,
                         cls: instr_i.cls, nblk: instr_i.nblk, kern: instr_i.kern, arg: instr_i.arg};

`ifndef TARGET_SYNTHESIS
  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      if (free_valid_i) begin
        assert (!free_q[free_i] && !(nf_valid_q && (nf_q == free_i)))
          else $error("[tsched_rename] handle %0d released twice", free_i);
      end
      if (fire && is_load) assert (instr_i.hd_v) else $error("[tsched_rename] TLoad without a handle");
      if (fire && is_run)  assert (instr_i.nblk != '0 && instr_i.cls != '0)
        else $error("[tsched_rename] TRun without blocks or without a PE class");
    end
  end
  // pragma translate_on
`endif

endmodule
