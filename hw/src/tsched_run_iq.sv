// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Run issue queue and port select: renamed TRun tasks wait here for their handles, then the oldest
// ready one goes to a scheduling domain.
//
// Readiness
//   s1 (data)   ready when its handle is done, or already when it is placed if the task follows the stream
//   s2 (order)  ready when its handle is done
//   An entry watches the two wake-up buses. An entry cannot see a stale match: the handles it names stay
//   allocated until it has retired (release rule in tsched_rename).
//
// Port select
//   A task whose data is placed goes to the domain that holds the data (its home). The cluster level
//   does not redirect such a task: PEs of other domains fetch single blocks from the home domain instead.
//   A task without placed data goes to the domain any_dom_i (the least loaded one).
//   The home port must have a credit. One task is issued per cycle and the issue is registered, so the
//   credit and load counters are updated from that register one cycle after the grant; the port state
//   given to this module already accounts for the task in the register.

module tsched_run_iq import tsched_pkg::*; (
  input  logic                  clk_i,
  input  logic                  rst_ni,
  // from rename, with the state of the two handles read from the handle file in the same cycle
  output logic                  ready_o,
  input  logic                  push_i,
  input  riq_push_t             push_data_i,
  input  hstate_t               s1_state_i,
  input  hstate_t               s2_state_i,
  // wake-up buses
  input  wake_place_t           place_i,
  input  wake_done_t            done_i,
  // port state
  input  logic [NumDomains-1:0] credit_ok_i,
  input  logic                  any_ok_i,
  input  dom_t                  any_dom_i,
  // issue, registered
  output logic                  issue_valid_o,
  output logic                  issue_any_o,     // the task went to any_dom_i
  output dom_t                  issue_dom_o,
  output run_req_t              issue_o
);

  localparam int unsigned N    = RunIqDepth;
  localparam int unsigned IdxW = idx_w(N);

  // What the scheduler needs of an entry.
  logic  [N-1:0] valid_d, valid_q;
  logic  [N-1:0] s1_v_q, s1_follow_q, s2_v_q;
  phys_t [N-1:0] s1_q, s2_q;
  logic  [N-1:0] s1_placed_d, s1_placed_q;
  logic  [N-1:0] s1_done_d, s1_done_q;
  logic  [N-1:0] s2_done_d, s2_done_q;
  dom_t  [N-1:0] dom_d, dom_q;
  slot_t [N-1:0] slot_d, slot_q;
  // What only the domain needs.
  typedef struct packed {
    wid_t  wid;
    cls_t  cls;
    nblk_t nblk;
    kern_t kern;
    arg_t  arg;
  } payload_t;
  payload_t [N-1:0] payload_q;

  logic [N-1:0]    push_oh;
  logic [IdxW-1:0] push_idx;
  logic            full;
  logic [N-1:0]    req, gnt;
  logic            gnt_any;

  lzc #(
    .WIDTH (N),
    .MODE  (1'b0)
  ) i_lzc_free (
    .in_i    (~valid_q),
    .cnt_o   (push_idx),
    .empty_o (full)
  );

  assign ready_o = ~full;
  always_comb begin
    push_oh = '0;
    push_oh[push_idx] = push_i;
  end

  // -------------------------------------------------------------------------------------------
  // Wake-up
  // -------------------------------------------------------------------------------------------
  logic push_place_hit, push_done1_hit, push_done2_hit;
  assign push_place_hit = place_i.v & (place_i.tag == push_data_i.s1);
  assign push_done1_hit = done_i.v  & (done_i.tag  == push_data_i.s1);
  assign push_done2_hit = done_i.v  & (done_i.tag  == push_data_i.s2);

  always_comb begin
    s1_placed_d = s1_placed_q;
    s1_done_d   = s1_done_q;
    s2_done_d   = s2_done_q;
    dom_d       = dom_q;
    slot_d      = slot_q;
    for (int unsigned i = 0; i < N; i++) begin
      if (valid_q[i] && s1_v_q[i] && place_i.v && (place_i.tag == s1_q[i])) begin
        s1_placed_d[i] = 1'b1;
        dom_d[i]       = place_i.dom;
        slot_d[i]      = place_i.slot;
      end
      if (valid_q[i] && s1_v_q[i] && done_i.v && (done_i.tag == s1_q[i])) s1_done_d[i] = 1'b1;
      if (valid_q[i] && s2_v_q[i] && done_i.v && (done_i.tag == s2_q[i])) s2_done_d[i] = 1'b1;
      // A new entry takes the state the handle file holds, plus what the buses carry in this cycle
      // (the file is written from the buses one cycle later).
      if (push_oh[i]) begin
        s1_placed_d[i] = push_data_i.s1_v & (s1_state_i.placed | push_place_hit);
        s1_done_d[i]   = push_data_i.s1_v & (s1_state_i.done | push_done1_hit);
        s2_done_d[i]   = push_data_i.s2_v & (s2_state_i.done | push_done2_hit);
        dom_d[i]       = push_place_hit ? place_i.dom  : s1_state_i.dom;
        slot_d[i]      = push_place_hit ? place_i.slot : s1_state_i.slot;
      end
    end
  end

  // -------------------------------------------------------------------------------------------
  // Select: the oldest ready entry whose port can take a task
  // -------------------------------------------------------------------------------------------
  for (genvar i = 0; i < N; i++) begin : gen_req
    logic s1_ok, s2_ok;
    assign s1_ok  = ~s1_v_q[i] | s1_done_q[i] | (s1_follow_q[i] & s1_placed_q[i]);
    assign s2_ok  = ~s2_v_q[i] | s2_done_q[i];
    assign req[i] = valid_q[i] & s1_ok & s2_ok & (s1_placed_q[i] ? credit_ok_i[dom_q[i]] : any_ok_i);
  end

  tsched_age_sel #(
    .N      (N),
    .NumSel (1)
  ) i_age (
    .clk_i,
    .rst_ni,
    .push_i    (push_i),
    .push_oh_i (push_oh),
    .valid_i   (valid_q),
    .req_i     (req),
    .gnt_o     (gnt)
  );

  // The grant is one-hot, so the selected entry is an OR over the gated entries.
  payload_t sel_payload;
  dom_t     sel_dom;
  slot_t    sel_slot;
  logic     sel_placed, sel_follow;
  always_comb begin
    sel_payload = '0;
    sel_dom     = '0;
    sel_slot    = '0;
    sel_placed  = 1'b0;
    sel_follow  = 1'b0;
    for (int unsigned i = 0; i < N; i++) begin
      sel_payload |= {$bits(payload_t){gnt[i]}} & payload_q[i];
      sel_dom     |= {DomW{gnt[i]}}  & dom_q[i];
      sel_slot    |= {SlotW{gnt[i]}} & slot_q[i];
      sel_placed  |= gnt[i] & s1_placed_q[i];
      sel_follow  |= gnt[i] & s1_follow_q[i];
    end
  end
  assign gnt_any = |gnt;

  always_comb begin
    valid_d = (valid_q & ~gnt) | push_oh;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q       <= '0;
      s1_placed_q   <= '0;
      s1_done_q     <= '0;
      s2_done_q     <= '0;
      issue_valid_o <= 1'b0;
    end else begin
      valid_q       <= valid_d;
      s1_placed_q   <= s1_placed_d;
      s1_done_q     <= s1_done_d;
      s2_done_q     <= s2_done_d;
      issue_valid_o <= gnt_any;
    end
  end

  always_ff @(posedge clk_i) begin
    dom_q  <= dom_d;
    slot_q <= slot_d;
    if (push_i) begin
      s1_v_q[push_idx]      <= push_data_i.s1_v;
      s1_follow_q[push_idx] <= push_data_i.follow;
      s1_q[push_idx]        <= push_data_i.s1;
      s2_v_q[push_idx]      <= push_data_i.s2_v;
      s2_q[push_idx]        <= push_data_i.s2;
      payload_q[push_idx]   <= '{wid: push_data_i.wid, cls: push_data_i.cls, nblk: push_data_i.nblk,
                                 kern: push_data_i.kern, arg: push_data_i.arg};
    end
    if (gnt_any) begin
      issue_any_o <= ~sel_placed;
      issue_dom_o <= sel_placed ? sel_dom : any_dom_i;
      issue_o     <= '{wid: sel_payload.wid, cls: sel_payload.cls, nblk: sel_payload.nblk,
                       slot_v: sel_placed, follow: sel_placed & sel_follow, slot: sel_slot,
                       kern: sel_payload.kern, arg: sel_payload.arg};
    end
  end

`ifndef TARGET_SYNTHESIS
  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!(push_i && full)) else $error("[tsched_run_iq] push into a full queue");
      assert ($onehot0(gnt)) else $error("[tsched_run_iq] more than one grant");
    end
  end
  // pragma translate_on
`endif

endmodule
