// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Run issue queue and port select: renamed TRun tasks wait here for their handles, then the oldest
// ready one goes to a scheduling domain.
//
// Readiness
//   s1 (data)   ready when its handle is done, or already when it is placed if the task follows the stream
//   s2 (order)  ready when its handle is done. With `chain` the task follows the task of s2 block by block,
//               and is ready as soon as that task has been issued: it is then issued behind it, to the same
//               domain, and that domain releases its blocks as the blocks of the first task are done. A
//               chained task with data in another domain than the task it follows waits for done instead,
//               and so does one whose first task is done before it is granted (it is then an ordinary task).
//   An entry watches the two wake-up buses. An entry cannot see a stale match: the handles it names stay
//   allocated until it has retired (release rule in tsched_rename).
//
// Port select
//   A task whose data is placed goes to the domain that holds the data (its home). The cluster level
//   does not redirect such a task: PEs of other domains fetch single blocks from the home domain instead.
//   A chained task goes to the domain of the task it follows.
//   A task with neither goes to the domain any_dom_i (the least loaded one).
//   The home port must have a credit. One task is granted per cycle.
//   The least loaded domain is known a few cycles after a credit has returned (any_ok_i). A ready task that
//   waits for it keeps the younger tasks waiting too: otherwise a younger task with placed data takes the
//   credit in the cycle it returns, every time, and the older task starves while that domain has such tasks.
//
// Two register stages follow the grant, so that the wide read of the granted entry is not in the
// select path:
//   grant stage  which entry (one-hot) and which domain. The credit counters are updated from this
//                stage, and the port state given to this module already accounts for the task in it.
//   issue stage  the task itself, read from the entry. The entry is invalid from the grant on, and it
//                cannot be filled again before the cycle after this read: the search for the next free
//                entry sees it one cycle after the grant and reserves it one cycle later still.

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
  input  wake_run_t             run_i,
  input  wake_done_t            done_i,
  // port state
  input  logic [NumDomains-1:0] credit_ok_i,
  input  logic                  any_ok_i,
  input  dom_t                  any_dom_i,
  // grant stage
  output logic                  grant_valid_o,
  output logic                  grant_any_o,     // the task goes to any_dom_i
  output dom_t                  grant_dom_o,
  // issue stage
  output logic                  issue_valid_o,
  output dom_t                  issue_dom_o,
  output phys_t                 issue_s1_o,      // data handle of the task, valid if issue_o.slot_v
  output logic                  issue_pd_v_o,    // handle the task defines
  output phys_t                 issue_pd_o,
  output run_req_t              issue_o          // without the entry of the task table (tix)
);

  localparam int unsigned N    = RunIqDepth;

  // What the scheduler needs of an entry.
  logic  [N-1:0] valid_d, valid_q;
  logic  [N-1:0] s1_v_q, s1_follow_q, s2_v_q;
  phys_t [N-1:0] s1_q, s2_q;
  logic  [N-1:0] s1_placed_d, s1_placed_q;
  logic  [N-1:0] s1_done_d, s1_done_q;
  logic  [N-1:0] s2_done_d, s2_done_q;
  dom_t  [N-1:0] dom_d, dom_q;            // domain of the data if it is placed, else of the task of s2
  slot_t [N-1:0] slot_d, slot_q;
  // Chained tasks: the task of s2 has been issued, to domain pdom, entry ptix of its task table.
  logic  [N-1:0] chain_q;
  logic  [N-1:0] s2_iss_d, s2_iss_q;
  dom_t  [N-1:0] pdom_d, pdom_q;
  tix_t  [N-1:0] ptix_d, ptix_q;
  // The task can go behind the task of s2: that task is issued, and the data of this one, if any, is in
  // the same domain. Kept as a register so that the request below stays short.
  logic  [N-1:0] link_d, link_q;
  // What only the domain needs.
  typedef struct packed {
    wid_t  wid;
    logic  pd_v;
    phys_t pd;
    cls_t  cls;
    vslow_t vslow;
    nblk_t nblk;
    kern_t kern;
    arg_t  arg;
  } payload_t;
  payload_t [N-1:0] payload_q;

  logic [N-1:0]    push_oh;
  logic [N-1:0]    req, hold, sel, gnt;
  logic            gnt_any;

  // The entry the next push fills is chosen ahead of time and held one-hot in a register, so the search
  // for a free entry is not in the push path and every write below is enabled by one register bit. The
  // reserved entry is not valid yet; the search skips it.
  logic [N-1:0] nf_d, nf_q;
  logic [N-1:0] free_cand, free_first;

  assign free_cand  = ~valid_q & ~nf_q;
  assign free_first = free_cand & (~free_cand + N'(1));
  assign ready_o    = |nf_q;
  assign push_oh    = nf_q & {N{push_i}};

  always_comb begin
    nf_d = nf_q;
    if (push_i || !ready_o) nf_d = free_first;
  end

  // -------------------------------------------------------------------------------------------
  // Wake-up
  // -------------------------------------------------------------------------------------------
  logic push_place_hit, push_done1_hit, push_done2_hit, push_run_hit;
  assign push_place_hit = place_i.v & (place_i.tag == push_data_i.s1);
  assign push_run_hit   = run_i.v   & (run_i.tag   == push_data_i.s2);
  assign push_done1_hit = done_i.v  & (done_i.tag  == push_data_i.s1);
  assign push_done2_hit = done_i.v  & (done_i.tag  == push_data_i.s2);

  always_comb begin
    s1_placed_d = s1_placed_q;
    s1_done_d   = s1_done_q;
    s2_done_d   = s2_done_q;
    dom_d       = dom_q;
    slot_d      = slot_q;
    s2_iss_d    = s2_iss_q;
    pdom_d      = pdom_q;
    ptix_d      = ptix_q;
    for (int unsigned i = 0; i < N; i++) begin
      logic chain;
      chain = chain_q[i];
      // The task of s2 is issued. A stale tag cannot do harm: the handle of s2 is only given to another
      // task after it is done, and from then on the entry no longer looks at this state.
      if (valid_q[i] && s2_v_q[i] && run_i.v && (run_i.tag == s2_q[i])) begin
        s2_iss_d[i] = 1'b1;
        pdom_d[i]   = run_i.dom;
        ptix_d[i]   = run_i.tix;
        if (!s1_placed_q[i]) dom_d[i] = run_i.dom;
      end
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
        s2_iss_d[i]    = push_data_i.s2_v & (s2_state_i.issued | push_run_hit);
        pdom_d[i]      = push_run_hit ? run_i.dom : s2_state_i.dom;
        ptix_d[i]      = push_run_hit ? run_i.tix : tix_t'(s2_state_i.loc);
        dom_d[i]       = push_place_hit ? place_i.dom : (s1_placed_d[i] ? s1_state_i.dom : pdom_d[i]);
        slot_d[i]      = push_place_hit ? place_i.slot : slot_t'(s1_state_i.loc);
        chain          = push_data_i.chain & push_data_i.s2_v;
      end
      link_d[i] = chain & s2_iss_d[i] & (dom_d[i] == pdom_d[i]);
    end
  end

  // -------------------------------------------------------------------------------------------
  // Select: the oldest ready entry whose port can take a task
  // -------------------------------------------------------------------------------------------
  logic [N-1:0] live, fixed;
  for (genvar i = 0; i < N; i++) begin : gen_req
    logic s1_ok, s2_ok;
    // A chained task does not follow a stream as well: its data must be complete.
    assign s1_ok    = ~s1_v_q[i] | s1_done_q[i] | (s1_follow_q[i] & s1_placed_q[i] & ~chain_q[i]);
    assign s2_ok    = ~s2_v_q[i] | s2_done_q[i] | link_q[i];
    // live: granted now, the task goes behind the task of s2. fixed: its domain is given.
    assign live[i]  = link_q[i] & ~s2_done_q[i];
    assign fixed[i] = s1_placed_q[i] | live[i];
    assign req[i]   = valid_q[i] & s1_ok & s2_ok & (fixed[i] ? credit_ok_i[dom_q[i]] : any_ok_i);
    assign hold[i]  = valid_q[i] & s1_ok & s2_ok & ~fixed[i] & ~any_ok_i;
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
    .req_i     (req | hold),
    .gnt_o     (sel)
  );
  assign gnt = sel & req;

  // The grant is one-hot, so a field of the granted entry is a one-hot multiplexer over the entries.
  // Grant stage: only the domain, which is narrow.
  localparam int unsigned GntW = 2 + DomW;
  localparam int unsigned RdW  = $bits(payload_t) + PhysW + SlotW + TixW + 2;

  logic [N-1:0]           gnt_q;
  logic [N-1:0][GntW-1:0] gnt_fields;
  logic [N-1:0][RdW-1:0]  rd_fields;
  dom_t                   sel_dom;
  logic                   sel_fixed, sel_live;
  logic                   grant_live_q;
  payload_t               rd_payload;
  phys_t                  rd_s1;
  slot_t                  rd_slot;
  tix_t                   rd_ptix;
  logic                   rd_placed, rd_follow;

  for (genvar i = 0; i < N; i++) begin : gen_fields
    assign gnt_fields[i] = {fixed[i], live[i], dom_q[i]};
    assign rd_fields[i]  = {payload_q[i], s1_q[i], slot_q[i], ptix_q[i], s1_placed_q[i], s1_follow_q[i]};
  end

  tsched_oh_mux #(
    .N (N),
    .W (GntW)
  ) i_gnt_mux (
    .sel_i  (gnt),
    .data_i (gnt_fields),
    .data_o ({sel_fixed, sel_live, sel_dom})
  );
  assign gnt_any = |gnt;

  // Issue stage: the rest of the entry, selected by the registered grant.
  tsched_oh_mux #(
    .N (N),
    .W (RdW)
  ) i_rd_mux (
    .sel_i  (gnt_q),
    .data_i (rd_fields),
    .data_o ({rd_payload, rd_s1, rd_slot, rd_ptix, rd_placed, rd_follow})
  );

  always_comb begin
    valid_d = (valid_q & ~gnt) | push_oh;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q       <= '0;
      nf_q          <= '0;
      s1_placed_q   <= '0;
      s1_done_q     <= '0;
      s2_done_q     <= '0;
      s2_iss_q      <= '0;
      link_q        <= '0;
      gnt_q         <= '0;
      grant_valid_o <= 1'b0;
      issue_valid_o <= 1'b0;
    end else begin
      valid_q       <= valid_d;
      nf_q          <= nf_d;
      s1_placed_q   <= s1_placed_d;
      s1_done_q     <= s1_done_d;
      s2_done_q     <= s2_done_d;
      s2_iss_q      <= s2_iss_d;
      link_q        <= link_d;
      gnt_q         <= gnt;
      grant_valid_o <= gnt_any;
      issue_valid_o <= grant_valid_o;
    end
  end

  always_ff @(posedge clk_i) begin
    dom_q  <= dom_d;
    slot_q <= slot_d;
    pdom_q <= pdom_d;
    ptix_q <= ptix_d;
    for (int unsigned i = 0; i < N; i++) begin
      if (push_oh[i]) begin
        s1_v_q[i]      <= push_data_i.s1_v;
        s1_follow_q[i] <= push_data_i.follow;
        s1_q[i]        <= push_data_i.s1;
        s2_v_q[i]      <= push_data_i.s2_v;
        s2_q[i]        <= push_data_i.s2;
        chain_q[i]     <= push_data_i.chain & push_data_i.s2_v;
        payload_q[i]   <= '{wid: push_data_i.wid, pd_v: push_data_i.pd_v, pd: push_data_i.pd, cls: push_data_i.cls,
                            vslow: push_data_i.vslow, nblk: push_data_i.nblk, kern: push_data_i.kern,
                            arg: push_data_i.arg};
      end
    end
    if (gnt_any) begin
      grant_any_o  <= ~sel_fixed;
      grant_dom_o  <= sel_fixed ? sel_dom : any_dom_i;
      grant_live_q <= sel_live;
    end
    if (grant_valid_o) begin
      issue_dom_o  <= grant_dom_o;
      issue_s1_o   <= rd_s1;
      issue_pd_v_o <= rd_payload.pd_v;
      issue_pd_o   <= rd_payload.pd;
      // A task that goes behind another one reads complete data: it does not follow a stream as well.
      issue_o      <= '{wid: rd_payload.wid, tix: '0, cls: rd_payload.cls, vslow: rd_payload.vslow, nblk: rd_payload.nblk,
                        slot_v: rd_placed, follow: rd_placed & rd_follow & ~grant_live_q, slot: rd_slot,
                        ftask: grant_live_q, ptix: rd_ptix, kern: rd_payload.kern, arg: rd_payload.arg};
    end
  end

`ifndef TARGET_SYNTHESIS
  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!(push_i && !ready_o)) else $error("[tsched_run_iq] push into a full queue");
      assert ($onehot0(gnt)) else $error("[tsched_run_iq] more than one grant");
    end
  end
  // pragma translate_on
`endif

endmodule
