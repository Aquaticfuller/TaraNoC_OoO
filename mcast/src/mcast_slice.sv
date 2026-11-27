// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// One merge slice: several requesters that load the same line get it with one fetch.
//
// This is the idea of MergeCast (the group MSHR of TeraNoC + Spatz) for a line that is one beat: a
// 512-bit burst on the wide network, or one word on the narrow one. The slice serves the few vector
// units that software has arranged to load the same lines in step (the sharers of one operand of a
// matrix product). It knows nothing about the network: a wrapper per kind of network feeds it keys.
//
//   request   The first load of a line (key = target group and address) allocates an entry and is
//             recorded as its first subscriber. Later loads of the same key join the entry. The
//             requester is acknowledged at once in both cases; nothing leaves for the network yet.
//   hold      The fetch is withheld until the entry has `target_i` subscribers. Software sets the
//             target to the exact number of sharers, so this always happens; the window (HoldTicks
//             ticks of 2**PrescaleW cycles, 127 x 64 as in MergeCast) only bounds the wait when the
//             setting is wrong. A window that expires is reported on `timeout_o`.
//   fetch     One request per entry, tagged with the entry's number, on the lane of its first
//             requester.
//   cast      The returned line is kept in the slice's one data register and handed to every
//             subscriber with that subscriber's own identification. Each subscriber names a delivery
//             port (the tile it sits in); different ports are served in the same cycle.
//
// An entry cannot be joined once it is closed (target reached or window expired): a later load of the
// same key gets an entry of its own. There is no response cache: with exact targets no requester
// comes late.
//
// Throughput: one request is taken per cycle (round robin over the lanes) and one returned line is
// cast at a time. Both are far above the rate at which the sharers of a slice load lines.

module mcast_slice #(
  parameter int unsigned NumLanes   = 8,    // request lanes
  parameter int unsigned NumEntries = 8,    // lines that can wait or be in flight at once
  parameter int unsigned NumSubs    = 4,    // subscribers per entry, the largest target
  parameter int unsigned NumDports  = 4,    // delivery ports
  parameter int unsigned KeyW       = 22,
  parameter int unsigned SubW       = 10,   // what identifies a requester to its delivery port
  parameter int unsigned DataW      = 512,
  parameter int unsigned HoldTicks  = 127,
  parameter int unsigned PrescaleW  = 6,
  // Dependent. Do not change.
  parameter int unsigned LaneW  = (NumLanes   > 1) ? $clog2(NumLanes)   : 1,
  parameter int unsigned EntW   = (NumEntries > 1) ? $clog2(NumEntries) : 1,
  parameter int unsigned DportW = (NumDports  > 1) ? $clog2(NumDports)  : 1,
  parameter int unsigned CntW   = $clog2(NumSubs + 1)
) (
  input  logic                                clk_i,
  input  logic                                rst_ni,

  // Number of sharers of every line, 1 to NumSubs. Must only change while `busy_o` is low.
  input  logic [CntW-1:0]                     target_i,

  // Loads to merge, one lane per port of a requester's tile.
  input  logic [NumLanes-1:0]                 req_valid_i,
  input  logic [NumLanes-1:0][KeyW-1:0]       req_key_i,
  input  logic [NumLanes-1:0][SubW-1:0]       req_sub_i,
  input  logic [NumLanes-1:0][DportW-1:0]     req_dport_i,
  output logic [NumLanes-1:0]                 req_ready_o,

  // The one fetch of an entry.
  output logic                                fetch_valid_o,
  output logic [KeyW-1:0]                     fetch_key_o,
  output logic [LaneW-1:0]                    fetch_lane_o,
  output logic [EntW-1:0]                     fetch_tag_o,
  input  logic                                fetch_ready_i,

  // The returned line.
  input  logic                                resp_valid_i,
  input  logic [EntW-1:0]                     resp_tag_i,
  input  logic [DataW-1:0]                    resp_data_i,
  output logic                                resp_ready_o,

  // The line for one subscriber per delivery port.
  output logic [NumDports-1:0]                dlv_valid_o,
  output logic [NumDports-1:0][SubW-1:0]      dlv_sub_o,
  output logic [DataW-1:0]                    dlv_data_o,
  input  logic [NumDports-1:0]                dlv_ready_i,

  output logic                                busy_o,      // an entry is in use
  output logic                                timeout_o    // a hold window expired: wrong target or sharers out of step
);

  localparam int unsigned HoldW   = $clog2(HoldTicks + 1);
  localparam int unsigned SubIdxW = (NumSubs > 1) ? $clog2(NumSubs) : 1;

  typedef struct packed {
    logic [SubW-1:0]   id;
    logic [DportW-1:0] dport;
  } sub_t;

  // ---------------------------------------------------------------- state
  logic [NumEntries-1:0]              valid_q, closed_q, issued_q;
  logic [NumEntries-1:0][KeyW-1:0]    key_q;
  logic [NumEntries-1:0][LaneW-1:0]   lane_q;
  logic [NumEntries-1:0][CntW-1:0]    cnt_q;
  logic [NumEntries-1:0][HoldW-1:0]   hold_q;
  sub_t [NumEntries-1:0][NumSubs-1:0] sub_q;

  logic                  dv_q;        // the data register holds a line that is being cast
  logic [EntW-1:0]       cur_q;       // its entry
  logic [NumSubs-1:0]    pend_q;      // subscribers that have not received it
  logic [DataW-1:0]      data_q;

  logic [PrescaleW-1:0]  presc_q;
  logic                  tick;

  // ---------------------------------------------------------------- request: take one lane per cycle
  logic [NumLanes-1:0]   lane_gnt;
  logic                  lane_any, take;
  logic [KeyW-1:0]       in_key;
  sub_t                  in_sub;
  logic [LaneW-1:0]      in_lane;

  mcast_rr #(.N(NumLanes)) i_lane_rr (
    .clk_i, .rst_ni, .req_i(req_valid_i), .take_i(take), .any_o(lane_any), .gnt_o(lane_gnt)
  );

  always_comb begin
    in_key  = '0;
    in_sub  = '0;
    in_lane = '0;
    for (int unsigned l = 0; l < NumLanes; l++) begin
      in_key  |= {KeyW{lane_gnt[l]}} & req_key_i[l];
      in_sub  |= {$bits(sub_t){lane_gnt[l]}} & {req_sub_i[l], req_dport_i[l]};
      in_lane |= {LaneW{lane_gnt[l]}} & LaneW'(l);
    end
  end

  // An open entry of the same key, or else the first free entry.
  logic [NumEntries-1:0] hit, free_first;
  logic                  hit_any, free_any;
  for (genvar e = 0; e < NumEntries; e++) begin : gen_hit
    assign hit[e] = valid_q[e] & ~closed_q[e] & (key_q[e] == in_key);
    if (e == 0) begin : gen_f0
      assign free_first[e] = ~valid_q[e];
    end else begin : gen_fn
      assign free_first[e] = ~valid_q[e] & (&valid_q[e-1:0]);
    end
  end
  assign hit_any  = |hit;
  assign free_any = ~(&valid_q);
  assign take     = lane_any & (hit_any | free_any);
  assign req_ready_o = lane_gnt & {NumLanes{hit_any | free_any}};

  // ---------------------------------------------------------------- fetch: one closed entry per cycle
  logic [NumEntries-1:0] fetch_gnt;
  logic                  fetch_take;

  mcast_rr #(.N(NumEntries)) i_fetch_rr (
    .clk_i, .rst_ni, .req_i(valid_q & closed_q & ~issued_q), .take_i(fetch_take),
    .any_o(fetch_valid_o), .gnt_o(fetch_gnt)
  );
  assign fetch_take = fetch_valid_o & fetch_ready_i;

  always_comb begin
    fetch_key_o  = '0;
    fetch_lane_o = '0;
    fetch_tag_o  = '0;
    for (int unsigned e = 0; e < NumEntries; e++) begin
      fetch_key_o  |= {KeyW{fetch_gnt[e]}} & key_q[e];
      fetch_lane_o |= {LaneW{fetch_gnt[e]}} & lane_q[e];
      fetch_tag_o  |= {EntW{fetch_gnt[e]}} & EntW'(e);
    end
  end

  // ---------------------------------------------------------------- cast
  sub_t [NumSubs-1:0]                   cur_sub;
  logic [CntW-1:0]                      cur_cnt;
  logic [NumDports-1:0][NumSubs-1:0]    dlv_sel;     // the subscriber each port serves, one-hot
  logic [NumSubs-1:0]                   dlv_done;
  logic                                 cast_last;

  assign cur_sub      = sub_q[cur_q];
  assign cur_cnt      = cnt_q[cur_q];
  assign resp_ready_o = ~dv_q;
  assign dlv_data_o   = data_q;

  for (genvar d = 0; d < NumDports; d++) begin : gen_dlv
    logic [NumSubs-1:0] want;
    for (genvar s = 0; s < NumSubs; s++) begin : gen_want
      assign want[s] = dv_q & pend_q[s] & (cur_sub[s].dport == DportW'(d));
      if (s == 0) begin : gen_s0
        assign dlv_sel[d][s] = want[s];
      end else begin : gen_sn
        assign dlv_sel[d][s] = want[s] & ~(|want[s-1:0]);
      end
    end
    assign dlv_valid_o[d] = |want;
    always_comb begin
      dlv_sub_o[d] = '0;
      for (int unsigned s = 0; s < NumSubs; s++) dlv_sub_o[d] |= {SubW{dlv_sel[d][s]}} & cur_sub[s].id;
    end
  end

  always_comb begin
    dlv_done = '0;
    for (int unsigned d = 0; d < NumDports; d++) dlv_done |= dlv_sel[d] & {NumSubs{dlv_ready_i[d]}};
  end
  assign cast_last = dv_q & ((pend_q & ~dlv_done) == '0);

  // ---------------------------------------------------------------- update
  assign tick      = (presc_q == '1);
  assign busy_o    = |valid_q;

  logic [NumEntries-1:0] expire;
  for (genvar e = 0; e < NumEntries; e++) begin : gen_expire
    assign expire[e] = valid_q[e] & ~closed_q[e] & tick & (hold_q[e] == '0);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q   <= '0;
      closed_q  <= '0;
      issued_q  <= '0;
      dv_q      <= 1'b0;
      pend_q    <= '0;
      presc_q   <= '0;
      timeout_o <= 1'b0;
    end else begin
      presc_q   <= presc_q + 1'b1;
      timeout_o <= |expire;

      for (int unsigned e = 0; e < NumEntries; e++) begin
        // The window of an open entry.
        if (valid_q[e] && !closed_q[e] && tick) begin
          if (hold_q[e] == '0) closed_q[e] <= 1'b1;
          else                 hold_q[e]   <= hold_q[e] - 1'b1;
        end
        // A subscriber joins.
        if (take && hit[e]) begin
          cnt_q[e] <= cnt_q[e] + 1'b1;
          if (cnt_q[e] + 1'b1 == target_i) closed_q[e] <= 1'b1;
        end
        // A new line.
        if (take && !hit_any && free_first[e]) begin
          valid_q[e]  <= 1'b1;
          closed_q[e] <= (target_i <= CntW'(1));
          issued_q[e] <= 1'b0;
          cnt_q[e]    <= CntW'(1);
          hold_q[e]   <= HoldW'(HoldTicks);
        end
        if (fetch_take && fetch_gnt[e]) issued_q[e] <= 1'b1;
        // Every subscriber has the line.
        if (cast_last && (cur_q == EntW'(e))) valid_q[e] <= 1'b0;
      end

      if (resp_valid_i && resp_ready_o) begin
        dv_q   <= 1'b1;
        cur_q  <= resp_tag_i;
        for (int unsigned s = 0; s < NumSubs; s++) pend_q[s] <= (CntW'(s) < cnt_q[resp_tag_i]);
      end else if (dv_q) begin
        pend_q <= pend_q & ~dlv_done;
        if (cast_last) dv_q <= 1'b0;
      end
    end
  end

  // Fields without reset: written when an entry is allocated or joined, read only while it is valid.
  always_ff @(posedge clk_i) begin
    for (int unsigned e = 0; e < NumEntries; e++) begin
      if (take && hit[e]) sub_q[e][cnt_q[e][SubIdxW-1:0]] <= in_sub;
      if (take && !hit_any && free_first[e]) begin
        key_q[e]    <= in_key;
        lane_q[e]   <= in_lane;
        sub_q[e][0] <= in_sub;
      end
    end
    if (resp_valid_i && resp_ready_o) data_q <= resp_data_i;
  end

`ifndef TARGET_SYNTHESIS
  // A response must name an entry whose fetch is out, and an entry never holds more than its slots.
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      resp_valid_i |-> (valid_q[resp_tag_i] && issued_q[resp_tag_i]))
    else $error("[mcast] response for entry %0d, which has no fetch out", resp_tag_i);
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      busy_o |-> (target_i >= 1 && target_i <= NumSubs))
    else $error("[mcast] target %0d outside 1..%0d", target_i, NumSubs);
`endif

endmodule

// Round-robin select with a one-hot grant: the requests behind the last grant that was used go first.
module mcast_rr #(
  parameter int unsigned N = 8
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [N-1:0] req_i,
  input  logic         take_i,
  output logic         any_o,
  output logic [N-1:0] gnt_o
);
  logic [N-1:0] mask_q, hi, hi_first, lo_first, behind;

  assign hi = req_i & mask_q;
  assign lo_first[0] = req_i[0];
  assign hi_first[0] = hi[0];
  assign behind[0]   = 1'b0;
  for (genvar i = 1; i < N; i++) begin : gen_first
    assign lo_first[i] = req_i[i] & ~(|req_i[i-1:0]);
    assign hi_first[i] = hi[i] & ~(|hi[i-1:0]);
    assign behind[i]   = |gnt_o[i-1:0];
  end
  assign any_o = |req_i;
  assign gnt_o = (|hi) ? hi_first : lo_first;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)     mask_q <= '0;
    else if (take_i) mask_q <= behind;
  end
endmodule
