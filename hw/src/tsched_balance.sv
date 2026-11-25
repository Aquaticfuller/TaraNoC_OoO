// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Balancer: the cluster level moves single blocks from domains that have more ready blocks than idle
// PEs to domains that have idle PEs and nothing to run.
//
// Every domain reports, per PE class, how many of its groups want a block (want) and whether it has
// blocks to spare (give). One move per cycle is started, in two register stages:
//
//   pick   a domain and class that wants more blocks than are already on their way to it, and for which
//          a giving domain exists within BalReach steps on the domain mesh; round robin
//   give   among those giving domains the direct neighbours go first, round robin; that domain gets a
//          give command
//
// The giving domain answers after a fixed number of cycles with the block, or with "nothing to give".
// The block is passed on to the domain that wanted it. Since all links have the same number of stages
// and one command leaves per cycle, at most one answer arrives per cycle.
//
// Per receiving domain two things are counted: the blocks on their way per class (never more than it
// wants), and the room in its queue for blocks of other domains (BorDepth). Both are given back when the
// block leaves that queue for a group, or when the giving domain had nothing.
//
// The balancer also tells every domain, per class, whether a domain within BalReach steps wants blocks
// (wanted). A domain then does not fill next-block registers in advance for that class: a block held in
// such a register cannot be given away any more, and would wait for an own PE while PEs next door idle.
//
// The distance limit keeps a block near the data it reads: L1 is shared, so any PE can run the block,
// but a far PE is slower, and a long block that runs far away ends its task late.

module tsched_balance import tsched_pkg::*; #(
  parameter bit BalEn = 1'b1
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,
  // reports of the domains
  input  rep_t  [NumDomains-1:0] rep_i,
  // give commands: one valid per domain, shared payload
  output logic  [NumDomains-1:0] give_valid_o,
  output give_t                  give_o,
  // answers of the giving domains
  input  logic  [NumDomains-1:0] rblk_valid_i,
  input  rblk_t [NumDomains-1:0] rblk_i,
  // blocks to the receiving domains: one valid per domain, shared payload
  output logic  [NumDomains-1:0] bblk_valid_o,
  output blk_t                   bblk_o,
  // a block left the queue of a receiving domain
  input  logic  [NumDomains-1:0] bpop_valid_i,
  input  logic  [NumDomains-1:0] bpop_cls_i,
  // per domain and class: a domain within reach wants blocks of the class
  output logic  [NumDomains-1:0][NumCls-1:0] wanted_o
);

  localparam int unsigned N    = NumDomains;
  localparam int unsigned S    = DomPerSide;
  localparam int unsigned BW   = $clog2(BorDepth + 1);
  localparam int unsigned NReq = N * NumCls;

  // Domains whose distance from d on the mesh is at least lo and at most hi.
  function automatic logic [N-1:0][N-1:0] ring(input int lo, input int hi);
    logic [N-1:0][N-1:0] m;
    for (int d = 0; d < N; d++) begin
      for (int h = 0; h < N; h++) begin
        int dx, dy, steps;
        dx   = (h % S) - (d % S);
        dy   = (h / S) - (d / S);
        steps = ((dx < 0) ? -dx : dx) + ((dy < 0) ? -dy : dy);
        m[d][h] = (steps >= lo) && (steps <= hi);
      end
    end
    return m;
  endfunction

  localparam logic [N-1:0][N-1:0] Near = ring(1, 1);
  localparam logic [N-1:0][N-1:0] Far  = ring(2, int'(BalReach));

  logic [N-1:0][NumCls-1:0][WantW-1:0] infl_d, infl_q;   // blocks on their way to a domain, per class
  logic [N-1:0][BW-1:0]                bfree_d, bfree_q; // room in the queue of a domain

  logic [NumCls-1:0][N-1:0] give_vec;
  for (genvar c = 0; c < NumCls; c++) begin : gen_gv
    for (genvar h = 0; h < N; h++) begin : gen_h
      assign give_vec[c][h] = rep_i[h].give[c];
    end
  end

  // Wanted: any domain within reach (not the domain itself) wants more blocks of the class than are
  // already on their way to it. Registered.
  logic [NumCls-1:0][N-1:0] want_vec;
  logic [N-1:0][NumCls-1:0] wanted_d;
  for (genvar c = 0; c < NumCls; c++) begin : gen_wv
    for (genvar h = 0; h < N; h++) begin : gen_h
      assign want_vec[c][h] = rep_i[h].want[c] > infl_q[h][c];
    end
  end
  for (genvar d = 0; d < N; d++) begin : gen_wanted
    for (genvar c = 0; c < NumCls; c++) begin : gen_c
      assign wanted_d[d][c] = BalEn & (|(want_vec[c] & (Near[d] | Far[d])));
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) wanted_o <= '0;
    else         wanted_o <= wanted_d;
  end

  // -------------------------------------------------------------------------------------------
  // Pick stage
  // -------------------------------------------------------------------------------------------
  logic              pick_v_q;
  logic [N-1:0]      pick_doh_q;     // receiving domain, one-hot
  logic              pick_c_q;       // class
  logic [NReq-1:0]   req, gnt;
  logic              req_any;
  logic [N-1:0]      gnt_dom;
  logic              gnt_cls;

  for (genvar d = 0; d < N; d++) begin : gen_req
    for (genvar c = 0; c < NumCls; c++) begin : gen_c
      // The domain picked in the previous cycle is left out: its counters move in this cycle.
      assign req[d * NumCls + c] = BalEn & (rep_i[d].want[c] > infl_q[d][c]) & (bfree_q[d] != '0)
                                 & ~(pick_v_q & pick_doh_q[d]) & (|(give_vec[c] & (Near[d] | Far[d])));
    end
  end

  tsched_rr_sel #(.N (NReq)) i_pick (
    .clk_i,
    .rst_ni,
    .req_i  (req),
    .take_i (req_any),
    .any_o  (req_any),
    .gnt_o  (gnt)
  );

  always_comb begin
    gnt_cls = 1'b0;
    for (int unsigned d = 0; d < N; d++) begin
      gnt_dom[d] = |gnt[d * NumCls +: NumCls];
      gnt_cls   |= gnt[d * NumCls + NumCls - 1];
    end
  end

  // -------------------------------------------------------------------------------------------
  // Give stage
  // -------------------------------------------------------------------------------------------
  logic [N-1:0] near_m, far_m, cand_near, cand_far, g_near, g_far, give_oh;
  logic         any_near, any_far, issue;
  dom_t [N-1:0] dom_id;
  dom_t         pick_dom;

  for (genvar d = 0; d < N; d++) begin : gen_id
    assign dom_id[d] = dom_t'(d);
  end

  tsched_oh_mux #(.N (N), .W (N)) i_near_m (.sel_i (pick_doh_q), .data_i (Near), .data_o (near_m));
  tsched_oh_mux #(.N (N), .W (N)) i_far_m  (.sel_i (pick_doh_q), .data_i (Far),  .data_o (far_m));
  tsched_oh_mux #(.N (N), .W (DomW)) i_dom (.sel_i (pick_doh_q), .data_i (dom_id), .data_o (pick_dom));

  assign cand_near = give_vec[pick_c_q] & near_m;
  assign cand_far  = give_vec[pick_c_q] & far_m;
  assign issue     = pick_v_q & (any_near | any_far);
  assign give_oh   = any_near ? g_near : g_far;

  tsched_rr_sel #(.N (N)) i_sel_near (
    .clk_i,
    .rst_ni,
    .req_i  (cand_near),
    .take_i (pick_v_q & any_near),
    .any_o  (any_near),
    .gnt_o  (g_near)
  );

  tsched_rr_sel #(.N (N)) i_sel_far (
    .clk_i,
    .rst_ni,
    .req_i  (cand_far),
    .take_i (pick_v_q & ~any_near & any_far),
    .any_o  (any_far),
    .gnt_o  (g_far)
  );

  // -------------------------------------------------------------------------------------------
  // Answers
  // -------------------------------------------------------------------------------------------
  rblk_t r;
  logic  r_v, nack;

  tsched_oh_mux #(.N (N), .W ($bits(rblk_t))) i_r (.sel_i (rblk_valid_i), .data_i (rblk_i), .data_o (r));
  assign r_v  = |rblk_valid_i;
  assign nack = r_v & ~r.ok;

  // -------------------------------------------------------------------------------------------
  // Counters
  // -------------------------------------------------------------------------------------------
  always_comb begin
    for (int unsigned d = 0; d < N; d++) begin
      logic inc_d, back_d;
      inc_d  = issue & pick_doh_q[d];
      back_d = nack & (r.rcv == dom_t'(d));
      for (int unsigned c = 0; c < NumCls; c++) begin
        infl_d[d][c] = infl_q[d][c] + WantW'(inc_d & (pick_c_q == 1'(c)))
                     - WantW'(back_d & (r.b.pcls == 1'(c)))
                     - WantW'(bpop_valid_i[d] & (bpop_cls_i[d] == 1'(c)));
      end
      bfree_d[d] = bfree_q[d] - BW'(inc_d) + BW'(back_d) + BW'(bpop_valid_i[d]);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pick_v_q     <= 1'b0;
      pick_doh_q   <= '0;
      pick_c_q     <= 1'b0;
      give_valid_o <= '0;
      bblk_valid_o <= '0;
      infl_q       <= '0;
      bfree_q      <= {N{BW'(BorDepth)}};
    end else begin
      pick_v_q     <= req_any;
      pick_doh_q   <= gnt_dom;
      pick_c_q     <= gnt_cls;
      give_valid_o <= {N{issue}} & give_oh;
      for (int unsigned d = 0; d < N; d++) bblk_valid_o[d] <= r_v & r.ok & (r.rcv == dom_t'(d));
      infl_q       <= infl_d;
      bfree_q      <= bfree_d;
    end
  end

  always_ff @(posedge clk_i) begin
    if (issue) give_o <= '{cls: pick_c_q, rcv: pick_dom};
    if (r_v)   bblk_o <= r.b;
  end

`ifndef TARGET_SYNTHESIS
  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert ($onehot0(rblk_valid_i)) else $error("[tsched_balance] two answers in one cycle");
      for (int unsigned d = 0; d < N; d++) begin
        assert (!((issue && pick_doh_q[d]) && (bfree_q[d] == '0)))
          else $error("[tsched_balance] block sent to domain %0d without room in its queue", d);
        assert (32'(bfree_q[d]) + 32'(bpop_valid_i[d]) + 32'(nack && (r.rcv == dom_t'(d))) <= BorDepth)
          else $error("[tsched_balance] more room returned by domain %0d than it has", d);
        for (int unsigned c = 0; c < NumCls; c++) begin
          assert (!(bpop_valid_i[d] && (bpop_cls_i[d] == 1'(c)) && (infl_q[d][c] == '0)))
            else $error("[tsched_balance] domain %0d took a block of class %0d that was not on its way", d, c);
        end
      end
    end
  end
  // pragma translate_on
`endif

endmodule
