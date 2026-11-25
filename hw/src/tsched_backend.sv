// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Cluster level of the task scheduler: the part that sits in the back end of the host CPU.
//
//   task instruction -> rename (map stage, dispatch stage) -> window (until retire)
//                              -> load queue      -> placement -> load port of a domain
//                              -> run issue queue -> select    -> task port of a domain
//   completions of the domains -> one per cycle -> window, wake-up, credits
//   handle file                -> releases a handle and its slot when its last user is done
//   balancer                   -> moves single blocks from domains with waiting blocks to domains with
//                                 idle PEs (see tsched_balance)
//
// One task instruction is renamed, one load and one run are issued, one completion is taken and one
// task retires per cycle. Tasks run for hundreds of cycles, so these rates are far above what the
// cluster needs, and every structure stays a single-port one.
//
// Flow control to the domains is by counting here, not by ready wires: a domain holds at most
// DomTaskDepth tasks (credits) and streams one load at a time. The links can therefore be pipelined
// freely. Completions return with valid/ready.

module tsched_backend import tsched_pkg::*; #(
  parameter bit BalEn = 1'b1
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  // task instructions from the host, in program order and no longer speculative
  input  logic                      instr_valid_i,
  output logic                      instr_ready_o,
  input  tinstr_t                   instr_i,
  // task ports: one valid per domain, shared payload
  output logic     [NumDomains-1:0] run_valid_o,
  output run_req_t                  run_o,
  // load ports
  output logic     [NumDomains-1:0] load_valid_o,
  output load_req_t                 load_o,
  // completions
  input  logic     [NumDomains-1:0] done_valid_i,
  output logic     [NumDomains-1:0] done_ready_o,
  input  done_t    [NumDomains-1:0] done_i,
  // balancing: reports, give commands, answers, blocks for other domains, queue credits, returns
  input  rep_t     [NumDomains-1:0] rep_i,
  output logic     [NumDomains-1:0] give_valid_o,
  output give_t                     give_o,
  input  logic     [NumDomains-1:0] rblk_valid_i,
  input  rblk_t    [NumDomains-1:0] rblk_i,
  output logic     [NumDomains-1:0] bblk_valid_o,
  output blk_t                      bblk_o,
  input  logic     [NumDomains-1:0] bpop_valid_i,
  input  logic     [NumDomains-1:0] bpop_cls_i,
  output logic     [NumDomains-1:0][NumCls-1:0] wanted_o,   // a domain within reach wants the class
  output logic     [NumDomains-1:0] ret_valid_o,    // a block that a domain gave away is done
  output tix_t                      ret_tix_o,
  // no task in the window
  output logic                      idle_o
);

  localparam int unsigned CredW = $clog2(DomTaskDepth + 1);
  localparam int unsigned KeyW  = BlkCntW + DomW;
  localparam int unsigned NumDn = NumDomains + 1;      // domains, and the join of the window
  localparam int unsigned DnW   = $clog2(NumDn);

  // -------------------------------------------------------------------------------------------
  // Rename, window, handle file
  // -------------------------------------------------------------------------------------------
  logic        win_ready, win_alloc_valid, win_empty, ren_busy;
  wid_t        win_wid;
  win_alloc_t  win_alloc;
  logic        loadq_ready, loadq_valid;
  loadq_t      loadq;
  logic        riq_ready, riq_valid;
  riq_push_t   riq;
  logic        alloc_valid;
  phys_t       alloc;
  logic        grant_valid, grant_any, issue_valid;
  dom_t        grant_dom;
  phys_t       issue_s1;
  run_req_t    issue;
  logic  [1:0] unmap_valid;
  phys_t [1:0] unmap;
  logic        free_valid;
  phys_t       free;
  logic  [1:0] unused_dec_valid;
  dom_t  [1:0] unused_dec_dom;
  logic        slot_free_valid;
  dom_t        slot_free_dom;
  slot_t       slot_free;

  wake_place_t place;
  wake_done_t  wake_done_q;
  logic        wake_v_q;
  phys_t       wake_tag_q;
  // The reference a finished task held on its data handle, returned one cycle after the window read.
  logic        rdec_v_q;
  phys_t       rdec_q;
  assign wake_done_q = '{v: wake_v_q, tag: wake_tag_q};

  phys_t   [1:0] hf_rd;
  hstate_t [1:0] hf_state;
  logic    [1:0] hf_sat;

  tsched_rename i_rename (
    .clk_i,
    .rst_ni,
    .instr_valid_i,
    .instr_ready_o,
    .instr_i,
    .busy_o        (ren_busy),
    .win_ready_i   (win_ready),
    .win_wid_i     (win_wid),
    .win_valid_o   (win_alloc_valid),
    .win_o         (win_alloc),
    .loadq_ready_i (loadq_ready),
    .loadq_valid_o (loadq_valid),
    .loadq_o       (loadq),
    .riq_ready_i   (riq_ready),
    .riq_valid_o   (riq_valid),
    .riq_o         (riq),
    .alloc_valid_o (alloc_valid),
    .alloc_o       (alloc),
    .unmap_valid_o (unmap_valid),
    .unmap_o       (unmap),
    .s1_sat_i      (hf_sat[0]),
    .free_valid_i  (free_valid),
    .free_i        (free)
  );

  // Completion taken this cycle (registered arbiter output).
  logic           dn_valid_q;
  done_t          dn_q;
  logic [DnW-1:0] dn_src_q;
  logic           dn_pd_v, dn_s1_v;
  phys_t          dn_pd, dn_s1;
  logic           join_valid, join_ready;
  wid_t           join_wid;

  tsched_window i_window (
    .clk_i,
    .rst_ni,
    .ready_o       (win_ready),
    .wid_o         (win_wid),
    .alloc_valid_i (win_alloc_valid),
    .alloc_i       (win_alloc),
    .done_valid_i  (dn_valid_q & ~dn_q.is_ret),
    .done_wid_i    (dn_q.wid),
    .done_pd_v_o   (dn_pd_v),
    .done_pd_o     (dn_pd),
    .done_s1_v_o   (dn_s1_v),
    .done_s1_o     (dn_s1),
    .join_valid_o  (join_valid),
    .join_ready_i  (join_ready),
    .join_wid_o    (join_wid),
    .empty_o       (win_empty)
  );

  assign idle_o = win_empty & ~ren_busy;

  // Read ports: the two handles of the task in the dispatch stage of rename.
  assign hf_rd[0] = riq.s1;
  assign hf_rd[1] = riq.s2;

  tsched_handle_file #(
    .NumRead (2)
  ) i_handle_file (
    .clk_i,
    .rst_ni,
    .alloc_valid_i     (alloc_valid),
    .alloc_i           (alloc),
    .unmap_valid_i     (unmap_valid),
    .unmap_i           (unmap),
    .ref_inc_i         (riq_valid & riq.s1_v),
    .ref_inc_p_i       (riq.s1),
    .ref_dec_i         (rdec_v_q),
    .ref_dec_p_i       (rdec_q),
    .place_i           (place),
    .done_i            (wake_done_q),
    .use_valid_i       (issue_valid & issue.slot_v),
    .use_i             (issue_s1),
    .unused_dec_valid_o(unused_dec_valid),
    .unused_dec_dom_o  (unused_dec_dom),
    .rd_i              (hf_rd),
    .rd_o              (hf_state),
    .rd_sat_o          (hf_sat),
    .free_valid_o      (free_valid),
    .free_o            (free),
    .slot_free_valid_o (slot_free_valid),
    .slot_free_dom_o   (slot_free_dom),
    .slot_free_o       (slot_free)
  );

  // -------------------------------------------------------------------------------------------
  // Work and credits per domain
  // -------------------------------------------------------------------------------------------
  logic [NumDomains-1:0][BlkCntW-1:0] blk_out_d, blk_out_q;
  logic [NumDomains-1:0][CredW-1:0]   cred_d, cred_q;
  logic [NumDomains-1:0]              credit_ok;

  dom_t     issue_dom;

  logic run_done;          // a run finished in domain dn_src_q
  logic load_done;         // a load finished in domain dn_src_q
  assign run_done  = dn_valid_q & ~dn_q.is_load & ~dn_q.is_ret & (dn_src_q != DnW'(NumDomains));
  assign load_done = dn_valid_q &  dn_q.is_load;

  always_comb begin
    blk_out_d = blk_out_q;
    cred_d    = cred_q;
    for (int unsigned d = 0; d < NumDomains; d++) begin
      logic gnt, iss, dec;
      gnt = grant_valid & (grant_dom == dom_t'(d));
      iss = issue_valid & (issue_dom == dom_t'(d));
      dec = run_done & (dn_src_q == DnW'(d));
      // Blocks are counted when the task is read from its entry, credits one stage earlier.
      blk_out_d[d] = blk_out_q[d] + (iss ? BlkCntW'(issue.nblk) : '0) - (dec ? BlkCntW'(dn_q.nblk) : '0);
      cred_d[d]    = cred_q[d] + CredW'(dec) - CredW'(gnt);
      // The task in the grant stage has not taken its credit yet.
      credit_ok[d] = (cred_q[d] > CredW'(1)) | ((cred_q[d] == CredW'(1)) & ~gnt);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      blk_out_q <= '0;
      cred_q    <= {NumDomains{CredW'(DomTaskDepth)}};
    end else begin
      blk_out_q <= blk_out_d;
      cred_q    <= cred_d;
    end
  end

  // -------------------------------------------------------------------------------------------
  // Loads
  // -------------------------------------------------------------------------------------------
  tsched_load_issue i_load_issue (
    .clk_i,
    .rst_ni,
    .ready_o           (loadq_ready),
    .push_i            (loadq_valid),
    .push_data_i       (loadq),
    .blk_out_i         (blk_out_q),
    .load_done_i       (load_done),
    .load_done_dom_i   (dom_t'(dn_src_q)),
    .unused_dec_valid_i(unused_dec_valid),
    .unused_dec_dom_i  (unused_dec_dom),
    .slot_free_valid_i (slot_free_valid),
    .slot_free_dom_i   (slot_free_dom),
    .slot_free_i       (slot_free),
    .load_valid_o,
    .load_o,
    .place_o           (place)
  );

  // -------------------------------------------------------------------------------------------
  // Runs
  // -------------------------------------------------------------------------------------------
  // Domain for a task without placed data: the least loaded one that has a credit. The choice is two
  // cycles old and the blocks of a task are counted two cycles after its grant, so after such a task is
  // granted the next one waits until the choice has seen it.
  logic [NumDomains-1:0][KeyW-1:0] any_key;
  logic                            any_v;
  dom_t                            any_dom;
  logic [NumDomains-1:0]           any_oh;
  dom_t                            any_rot_q;
  logic [3:0]                      any_hold_q;

  for (genvar d = 0; d < NumDomains; d++) begin : gen_any_key
    assign any_key[d] = {blk_out_q[d], dom_t'(DomW'(d) - any_rot_q)};
  end

  tsched_argmin #(
    .N    (NumDomains),
    .KeyW (KeyW)
  ) i_any (
    .clk_i,
    .rst_ni,
    .valid_i (credit_ok),
    .key_i   (any_key),
    .valid_o (any_v),
    .idx_o   (any_dom),
    .oh_o    (any_oh)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      any_rot_q  <= '0;
      any_hold_q <= '0;
    end else begin
      any_hold_q <= {any_hold_q[2:0], 1'b0};
      if (grant_valid && grant_any) begin
        any_rot_q  <= grant_dom + dom_t'(PlaceStride);
        any_hold_q <= '1;
      end
    end
  end

  logic any_ok;
  assign any_ok = (|(credit_ok & any_oh)) & ~(|any_hold_q) & ~(grant_valid & grant_any);

  tsched_run_iq i_run_iq (
    .clk_i,
    .rst_ni,
    .ready_o       (riq_ready),
    .push_i        (riq_valid),
    .push_data_i   (riq),
    .s1_state_i    (hf_state[0]),
    .s2_state_i    (hf_state[1]),
    .place_i       (place),
    .done_i        (wake_done_q),
    .credit_ok_i   (credit_ok),
    .any_ok_i      (any_ok),
    .any_dom_i     (any_dom),
    .grant_valid_o (grant_valid),
    .grant_any_o   (grant_any),
    .grant_dom_o   (grant_dom),
    .issue_valid_o (issue_valid),
    .issue_dom_o   (issue_dom),
    .issue_s1_o    (issue_s1),
    .issue_o       (issue)
  );

  always_comb begin
    run_valid_o = '0;
    run_valid_o[issue_dom] = issue_valid;
  end
  assign run_o = issue;

  // -------------------------------------------------------------------------------------------
  // Completions: one per cycle, round robin over the domains and the join of the window
  // -------------------------------------------------------------------------------------------
  logic  [NumDn-1:0] arb_req, arb_gnt;
  done_t [NumDn-1:0] arb_data;
  logic              arb_valid;
  done_t             arb_out;
  logic [DnW-1:0]    arb_idx;

  assign arb_req               = {join_valid, done_valid_i};
  assign arb_data[NumDn-2:0]   = done_i;
  assign arb_data[NumDn-1]     = '{wid: join_wid, is_load: 1'b0, is_ret: 1'b0, nblk: '0, dom: '0, tix: '0};
  assign done_ready_o          = arb_gnt[NumDn-2:0];
  assign join_ready            = arb_gnt[NumDn-1];

  rr_arb_tree #(
    .NumIn     (NumDn),
    .DataType  (done_t),
    .ExtPrio   (1'b0),
    .AxiVldRdy (1'b1),
    .LockIn    (1'b1),
    .FairArb   (1'b1)
  ) i_done_arb (
    .clk_i,
    .rst_ni,
    .flush_i (1'b0),
    .rr_i    ('0),
    .req_i   (arb_req),
    .gnt_o   (arb_gnt),
    .data_i  (arb_data),
    .req_o   (arb_valid),
    .gnt_i   (1'b1),
    .data_o  (arb_out),
    .idx_o   (arb_idx)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dn_valid_q <= 1'b0;
      ret_valid_o <= '0;
      wake_v_q   <= 1'b0;
      rdec_v_q   <= 1'b0;
    end else begin
      dn_valid_q <= arb_valid;
      wake_v_q   <= dn_valid_q & ~dn_q.is_ret & dn_pd_v;
      rdec_v_q   <= dn_valid_q & ~dn_q.is_ret & dn_s1_v;
      // A block run for another domain: its completion goes on to the domain that holds the task.
      for (int unsigned d = 0; d < NumDomains; d++) begin
        ret_valid_o[d] <= dn_valid_q & dn_q.is_ret & (dn_q.dom == dom_t'(d));
      end
    end
  end

  always_ff @(posedge clk_i) begin
    dn_q       <= arb_out;
    dn_src_q   <= arb_idx;
    wake_tag_q <= dn_pd;
    ret_tix_o  <= dn_q.tix;
    rdec_q     <= dn_s1;
  end

  // -------------------------------------------------------------------------------------------
  // Balancing between domains
  // -------------------------------------------------------------------------------------------
  tsched_balance #(
    .BalEn (BalEn)
  ) i_balance (
    .clk_i,
    .rst_ni,
    .rep_i,
    .give_valid_o,
    .give_o,
    .rblk_valid_i,
    .rblk_i,
    .bblk_valid_o,
    .bblk_o,
    .bpop_valid_i,
    .bpop_cls_i,
    .wanted_o
  );

`ifndef TARGET_SYNTHESIS
  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned d = 0; d < NumDomains; d++) begin
        assert (!(grant_valid && (grant_dom == dom_t'(d)) && (cred_q[d] == '0)))
          else $error("[tsched_backend] task issued to domain %0d without a credit", d);
      end
    end
  end
  // pragma translate_on
`endif

endmodule
