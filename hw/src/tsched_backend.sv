// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Cluster level of the task scheduler: the part that sits in the back end of the host CPU.
//
//   task instruction -> rename -> window (until retire)
//                              -> load queue      -> placement -> load port of a domain
//                              -> run issue queue -> select    -> task port of a domain
//   completions of the domains -> one per cycle -> window, wake-up, credits
//   handle file                -> releases a handle and its slot when its last user is done
//
// One task instruction is renamed, one load and one run are issued, one completion is taken and one
// task retires per cycle. Tasks run for hundreds of cycles, so these rates are far above what the
// cluster needs, and every structure stays a single-port one.
//
// Flow control to the domains is by counting here, not by ready wires: a domain holds at most
// DomTaskDepth tasks (credits) and streams one load at a time. The links can therefore be pipelined
// freely. Completions return with valid/ready.

module tsched_backend import tsched_pkg::*; (
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
  logic        win_ready, win_alloc_valid;
  wid_t        win_wid;
  win_alloc_t  win_alloc;
  logic        loadq_ready, loadq_valid;
  loadq_t      loadq;
  logic        riq_ready, riq_valid;
  riq_push_t   riq;
  logic        alloc_valid;
  phys_t       alloc;
  logic        issue_valid, issue_any;
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
    .done_valid_i  (dn_valid_q),
    .done_wid_i    (dn_q.wid),
    .done_pd_v_o   (dn_pd_v),
    .done_pd_o     (dn_pd),
    .done_s1_v_o   (dn_s1_v),
    .done_s1_o     (dn_s1),
    .join_valid_o  (join_valid),
    .join_ready_i  (join_ready),
    .join_wid_o    (join_wid),
    .empty_o       (idle_o)
  );

  // Read ports: the two handles of the task being renamed.
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
    .ref_dec_i         (dn_valid_q & dn_s1_v),
    .ref_dec_p_i       (dn_s1),
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
  assign run_done  = dn_valid_q & ~dn_q.is_load & (dn_src_q != DnW'(NumDomains));
  assign load_done = dn_valid_q &  dn_q.is_load;

  always_comb begin
    blk_out_d = blk_out_q;
    cred_d    = cred_q;
    for (int unsigned d = 0; d < NumDomains; d++) begin
      logic inc, dec;
      inc = issue_valid & (issue_dom == dom_t'(d));
      dec = run_done & (dn_src_q == DnW'(d));
      blk_out_d[d] = blk_out_q[d] + (inc ? BlkCntW'(issue.nblk) : '0) - (dec ? BlkCntW'(dn_q.nblk) : '0);
      cred_d[d]    = cred_q[d] + CredW'(dec) - CredW'(inc);
      // The task in the issue register has not taken its credit yet.
      credit_ok[d] = (cred_q[d] > CredW'(1)) | ((cred_q[d] == CredW'(1)) & ~inc);
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
  // cycles old, so after such a task is issued the next one waits until the choice has seen it.
  logic [NumDomains-1:0][KeyW-1:0] any_key;
  logic                            any_v;
  dom_t                            any_dom;
  dom_t                            any_rot_q;
  logic [1:0]                      any_hold_q;

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
    .idx_o   (any_dom)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      any_rot_q  <= '0;
      any_hold_q <= '0;
    end else begin
      any_hold_q <= {any_hold_q[0], 1'b0};
      if (issue_valid && issue_any) begin
        any_rot_q  <= issue_dom + dom_t'(PlaceStride);
        any_hold_q <= 2'b11;
      end
    end
  end

  logic any_ok;
  assign any_ok = any_v & credit_ok[any_dom] & ~(|any_hold_q) & ~(issue_valid & issue_any);

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
    .issue_valid_o (issue_valid),
    .issue_any_o   (issue_any),
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
  assign arb_data[NumDn-1]     = '{wid: join_wid, is_load: 1'b0, nblk: '0};
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
      wake_v_q   <= 1'b0;
    end else begin
      dn_valid_q <= arb_valid;
      wake_v_q   <= dn_valid_q & dn_pd_v;
    end
  end

  always_ff @(posedge clk_i) begin
    dn_q       <= arb_out;
    dn_src_q   <= arb_idx;
    wake_tag_q <= dn_pd;
  end

`ifndef TARGET_SYNTHESIS
  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned d = 0; d < NumDomains; d++) begin
        assert (!(issue_valid && (issue_dom == dom_t'(d)) && (cred_q[d] == '0)))
          else $error("[tsched_backend] task issued to domain %0d without a credit", d);
      end
    end
  end
  // pragma translate_on
`endif

endmodule
