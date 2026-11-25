// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Handle rename: one task instruction per cycle, in two stages.
//
//   map       read and update the map table, take a fresh physical handle
//   dispatch  check the window, the queue and the user counter of the data handle, then enter the task
//
// Task instructions are not speculative, so the map table is final once it is written and the map
// stage never has to be undone. The two stages are separated by a two-entry buffer whose ready is a
// register: the checks of the dispatch stage do not reach back into the map table or to the host.
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
  output logic        busy_o,          // an instruction is between the two stages
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

  logic  is_load, is_run, is_free;
  logic  need_pd;
  logic  s1_v, s2_v;
  phys_t s1, s2;
  logic  kill;
  logic  old_v;
  phys_t old;
  logic  fire;                  // an instruction passes the map stage

  // What the dispatch stage needs of an instruction.
  typedef struct packed {
    top_e  op;
    logic  pd_v;
    phys_t pd;
    logic  s1_v;
    phys_t s1;
    logic  s2_v;
    phys_t s2;
    logic  old_v;     // the earlier mapping of hd ends
    phys_t old;
    logic  kill_v;    // the mapping of hs1 ends, and it is not the one in `old`
    logic  follow;
    cls_t  cls;
    nblk_t nblk;
    kern_t kern;
    arg_t  arg;
    len_t  len;
    addr_t addr;
  } ren_t;

  ren_t  m, r;                  // map stage output, dispatch stage input
  logic  m_valid, m_ready;
  logic  r_valid, r_ready, r_fire;
  logic  r_load, r_run, r_free;
  logic  q_ready;

  assign is_load = instr_i.op == TLoad;
  assign is_run  = instr_i.op == TRun;
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
  logic [NumPhys-1:0] cand_oh;
  logic               cand_any;
  logic               refill;

  // The first free handle, one-hot to clear its bit and as an index for the register.
  tsched_first_oh #(
    .N (NumPhys)
  ) i_first_free (
    .in_i  (free_q),
    .any_o (cand_any),
    .oh_o  (cand_oh),
    .idx_o (cand)
  );

  assign m_valid       = instr_valid_i & (~need_pd | nf_valid_q);
  assign instr_ready_o = m_ready & (~need_pd | nf_valid_q);
  assign fire          = instr_valid_i & instr_ready_o;

  assign refill = (~nf_valid_q | (fire & need_pd)) & cand_any;

  always_comb begin
    free_d     = free_q & ~({NumPhys{refill}} & cand_oh);
    nf_d       = nf_q;
    nf_valid_d = nf_valid_q;
    if (refill) begin
      nf_d       = cand;
      nf_valid_d = 1'b1;
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
  // Map stage to dispatch stage
  // -------------------------------------------------------------------------------------------
  assign m = '{
    op:     instr_i.op,
    pd_v:   need_pd,
    pd:     nf_q,
    s1_v:   s1_v,
    s1:     s1,
    s2_v:   s2_v,
    s2:     s2,
    old_v:  old_v,
    old:    old,
    kill_v: kill & ~(old_v & (instr_i.hd == instr_i.hs1)),
    follow: instr_i.follow,
    cls:    instr_i.cls,
    nblk:   instr_i.nblk,
    kern:   instr_i.kern,
    arg:    instr_i.arg,
    len:    instr_i.len,
    addr:   instr_i.addr
  };

  spill_register #(
    .T      (ren_t),
    .Bypass (1'b0)
  ) i_stage (
    .clk_i,
    .rst_ni,
    .valid_i (m_valid),
    .ready_o (m_ready),
    .data_i  (m),
    .valid_o (r_valid),
    .ready_i (r_ready),
    .data_o  (r)
  );

  // -------------------------------------------------------------------------------------------
  // Dispatch stage
  // -------------------------------------------------------------------------------------------
  assign r_load = r.op == TLoad;
  assign r_run  = r.op == TRun;
  assign r_free = r.op == TFree;

  // A run that uses data takes a reference on its handle, which needs room in the user counter of that
  // handle. The counter is read from the handle file one cycle ahead, into chk_q and sat_q, so that this
  // wide read is not in front of the checks below. chk_q says that the instruction now in this stage
  // waited here in the previous cycle: the read was for its handle, and no reference was taken since.
  // The counter can only have gone down, so a stale "full" costs a cycle and a stale "room" does not
  // occur. Such a run stays two cycles in this stage; every other instruction stays one.
  logic chk_q, sat_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      chk_q <= 1'b0;
      sat_q <= 1'b0;
    end else begin
      chk_q <= r_valid & ~r_fire;
      sat_q <= s1_sat_i;
    end
  end

  assign q_ready = r_load ? loadq_ready_i : (r_run ? (riq_ready_i & (~r.s1_v | (chk_q & ~sat_q))) : 1'b1);
  assign r_ready = (win_ready_i | r_free) & q_ready;
  assign r_fire  = r_valid & r_ready;
  assign busy_o  = r_valid;

  assign alloc_valid_o = r_fire & r.pd_v;
  assign alloc_o       = r.pd;

  // A TFree only ends a mapping: it takes no window entry.
  assign win_valid_o = r_fire & ~r_free;
  assign win_o       = '{is_join: r.op == TJoin, pd_v: r.pd_v, pd: r.pd, s1_v: r.s1_v & r_run, s1: r.s1};

  // Mappings that ended in the map stage: the old one of hd, and the killed hs1.
  assign unmap_valid_o[0] = r_fire & r.old_v;
  assign unmap_o[0]       = r.old;
  assign unmap_valid_o[1] = r_fire & r.kill_v;
  assign unmap_o[1]       = r.s1;

  assign loadq_valid_o = r_fire & r_load;
  assign loadq_o       = '{wid: win_wid_i, pd: r.pd, len: r.len, addr: r.addr};

  assign riq_valid_o = r_fire & r_run;
  assign riq_o       = '{wid: win_wid_i, s1_v: r.s1_v, s1: r.s1, follow: r.follow, s2_v: r.s2_v, s2: r.s2,
                         cls: r.cls, nblk: r.nblk, kern: r.kern, arg: r.arg};

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
      if (fire && need_pd) assert (nf_valid_q) else $error("[tsched_rename] handle taken while none is ready");
    end
  end
  // pragma translate_on
`endif

endmodule
