// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Unit test of one merge slice.
//
// NUM_REQ requesters walk the same list of lines, each at its own random pace and with up to
// OUTSTANDING loads open, as the sharers of a slice do. A memory model answers every fetch after a
// random delay. Checked: every requester gets every line it asked for, with its own identification
// and the right data; the slice fetches each line once per round (lines x REPEAT fetches in total);
// no hold window expires. With +WRONG_TARGET the target is one too high: every line must then leave
// by timeout and still be delivered correctly.
//
// Plusargs: +SEED=n +LINES=n +REPEAT=n (loads of every line per requester, 2 models the two fp16
// halves of a word) +STALL=percent (cycles in which the network or a delivery port is not ready).

module tb_mcast_slice;
  localparam int unsigned NUM_REQ     = `ifdef TB_NUM_REQ `TB_NUM_REQ `else 4 `endif;
  localparam int unsigned OUTSTANDING = 4;
  localparam int unsigned LANES       = 2 * NUM_REQ;
  localparam int unsigned ENTRIES     = 8;
  localparam int unsigned KEYW        = 22;
  localparam int unsigned SUBW        = 10;
  localparam int unsigned DATAW       = `ifdef TB_DATAW `TB_DATAW `else 512 `endif;
  localparam int unsigned HOLD_TICKS  = `ifdef TB_HOLD_TICKS `TB_HOLD_TICKS `else 127 `endif;
  localparam int unsigned DPW         = (NUM_REQ > 1) ? $clog2(NUM_REQ) : 1;
  localparam int unsigned CNTW        = $clog2(NUM_REQ + 1);
  localparam int unsigned ENTW        = $clog2(ENTRIES);
  localparam int unsigned LANEW       = $clog2(LANES);

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [CNTW-1:0]                 target;
  logic [LANES-1:0]                req_valid, req_ready;
  logic [LANES-1:0][KEYW-1:0]      req_key;
  logic [LANES-1:0][SUBW-1:0]      req_sub;
  logic [LANES-1:0][DPW-1:0]       req_dport;
  logic                            fetch_valid, fetch_ready;
  logic [KEYW-1:0]                 fetch_key;
  logic [LANEW-1:0]                fetch_lane;
  logic [ENTW-1:0]                 fetch_tag;
  logic                            resp_valid, resp_ready;
  logic [ENTW-1:0]                 resp_tag;
  logic [DATAW-1:0]                resp_data;
  logic [NUM_REQ-1:0]              dlv_valid, dlv_ready;
  logic [NUM_REQ-1:0][SUBW-1:0]    dlv_sub;
  logic [DATAW-1:0]                dlv_data;
  logic                            busy, timeout;

  mcast_slice #(
    .NumLanes(LANES), .NumEntries(ENTRIES), .NumSubs(NUM_REQ), .NumDports(NUM_REQ),
    .KeyW(KEYW), .SubW(SUBW), .DataW(DATAW), .HoldTicks(HOLD_TICKS)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .target_i(target),
    .req_valid_i(req_valid), .req_key_i(req_key), .req_sub_i(req_sub), .req_dport_i(req_dport),
    .req_ready_o(req_ready),
    .fetch_valid_o(fetch_valid), .fetch_key_o(fetch_key), .fetch_lane_o(fetch_lane),
    .fetch_tag_o(fetch_tag), .fetch_ready_i(fetch_ready),
    .resp_valid_i(resp_valid), .resp_tag_i(resp_tag), .resp_data_i(resp_data), .resp_ready_o(resp_ready),
    .dlv_valid_o(dlv_valid), .dlv_sub_o(dlv_sub), .dlv_data_o(dlv_data), .dlv_ready_i(dlv_ready),
    .busy_o(busy), .timeout_o(timeout)
  );

  int unsigned seed = 1, lines = 200, repeat_n = 1, stall = 20;
  bit          wrong_target;
  int unsigned errors = 0, fetches = 0, timeouts = 0, delivered = 0, cycles = 0;
  int unsigned wait_sum = 0, wait_max = 0;

  function automatic logic [KEYW-1:0] key_of(input int unsigned i);
    key_of = KEYW'(32'h155 + i * 37);        // distinct for the line counts used here
  endfunction
  function automatic logic [DATAW-1:0] data_of(input logic [KEYW-1:0] k);
    data_of = {(DATAW / 16){16'h5a00 ^ k[15:0]}};
  endfunction

  // ---------------------------------------------------------------- requesters
  // Requester r: next line to ask for, and its open loads (id -> key, issue cycle).
  int unsigned         nxt   [NUM_REQ];
  logic                open  [NUM_REQ][OUTSTANDING];
  logic [KEYW-1:0]     okey  [NUM_REQ][OUTSTANDING];
  int unsigned         ocyc  [NUM_REQ][OUTSTANDING];
  int unsigned         pause [NUM_REQ];
  logic                rv    [NUM_REQ];
  logic [KEYW-1:0]     rk    [NUM_REQ];
  int unsigned         rid   [NUM_REQ];

  always_comb begin
    req_valid = '0;
    req_key   = '0;
    req_sub   = '0;
    req_dport = '0;
    for (int unsigned r = 0; r < NUM_REQ; r++) begin
      // The lane depends on the address, as the port hash of a tile does.
      automatic int unsigned l = 2 * r + rk[r][0];
      req_valid[l] = rv[r];
      req_key[l]   = rk[r];
      req_sub[l]   = SUBW'((r << 4) | rid[r]);
      req_dport[l] = DPW'(r);
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int unsigned r = 0; r < NUM_REQ; r++) begin
        nxt[r] <= 0; rv[r] <= 1'b0; rk[r] <= '0; rid[r] <= 0; pause[r] <= $urandom_range(0, 40);
        for (int unsigned o = 0; o < OUTSTANDING; o++) open[r][o] <= 1'b0;
      end
    end else begin
      cycles <= cycles + 1;
      for (int unsigned r = 0; r < NUM_REQ; r++) begin
        automatic int unsigned l = 2 * r + rk[r][0];
        if (rv[r] && req_ready[l]) begin
          open[r][rid[r]] <= 1'b1;
          okey[r][rid[r]] <= rk[r];
          ocyc[r][rid[r]] <= cycles;
          rv[r]           <= 1'b0;
          nxt[r]          <= nxt[r] + 1;
          pause[r]        <= $urandom_range(0, 12);
        end else if (!rv[r] && nxt[r] < lines * repeat_n && !(wrong_target && r == NUM_REQ - 1)) begin
          if (pause[r] != 0) pause[r] <= pause[r] - 1;
          else begin
            for (int unsigned o = 0; o < OUTSTANDING; o++) begin
              if (!open[r][o]) begin
                rv[r]  <= 1'b1;
                rk[r]  <= key_of(nxt[r] / repeat_n);
                rid[r] <= o;
                break;
              end
            end
          end
        end
        // Delivery.
        if (dlv_valid[r] && dlv_ready[r]) begin
          automatic int unsigned who = dlv_sub[r] >> 4;
          automatic int unsigned id  = dlv_sub[r] & 4'hf;
          delivered = delivered + 1;
          if (who != r || id >= OUTSTANDING || !open[r][id]) begin
            $error("[tb] port %0d got a line for requester %0d id %0d that is not open", r, who, id);
            errors = errors + 1;
          end else begin
            if (dlv_data !== data_of(okey[r][id])) begin
              $error("[tb] requester %0d id %0d: wrong data for key %0h", r, id, okey[r][id]);
              errors = errors + 1;
            end
            open[r][id] <= 1'b0;
            wait_sum    = wait_sum + (cycles - ocyc[r][id]);
            if (cycles - ocyc[r][id] > wait_max) wait_max = cycles - ocyc[r][id];
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------- network and memory model
  typedef struct { logic [ENTW-1:0] tag; logic [KEYW-1:0] key; int unsigned due; } flight_t;
  flight_t flight [$];

  always @(posedge clk) begin
    fetch_ready <= ($urandom_range(0, 99) >= stall);
    for (int unsigned r = 0; r < NUM_REQ; r++) dlv_ready[r] <= ($urandom_range(0, 99) >= stall);
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_valid <= 1'b0;
    end else begin
      if (fetch_valid && fetch_ready) begin
        automatic flight_t f;
        f.tag = fetch_tag; f.key = fetch_key; f.due = cycles + $urandom_range(4, 30);
        flight.push_back(f);
        fetches <= fetches + 1;
      end
      if (timeout) timeouts <= timeouts + 1;
      if (resp_valid && resp_ready) resp_valid <= 1'b0;
      if (!resp_valid || resp_ready) begin
        // Responses may come back in any order.
        for (int unsigned i = 0; i < flight.size(); i++) begin
          if (flight[i].due <= cycles) begin
            resp_valid <= 1'b1;
            resp_tag   <= flight[i].tag;
            resp_data  <= data_of(flight[i].key);
            flight.delete(i);
            break;
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------- run
  initial begin
    void'($value$plusargs("SEED=%d", seed));
    void'($value$plusargs("LINES=%d", lines));
    void'($value$plusargs("REPEAT=%d", repeat_n));
    void'($value$plusargs("STALL=%d", stall));
    wrong_target = $test$plusargs("WRONG_TARGET");
    void'($urandom(seed));
    // A wrong target can only be one too LOW in slots; model "a sharer is missing" instead: the
    // target stays NUM_REQ and one requester never starts.
    target = CNTW'(NUM_REQ);
    repeat (5) @(posedge clk);
    rst_n = 1;

    fork
      begin
        automatic int unsigned active = wrong_target ? NUM_REQ - 1 : NUM_REQ;
        automatic int unsigned total  = active * lines * repeat_n;
        wait (delivered == total);
        repeat (20) @(posedge clk);
        if (busy) begin $error("[tb] slice still busy at the end"); errors++; end
        if (!wrong_target && fetches != lines * repeat_n) begin
          $error("[tb] %0d fetches, expected %0d", fetches, lines * repeat_n); errors++;
        end
        if (!wrong_target && timeouts != 0) begin $error("[tb] %0d timeouts", timeouts); errors++; end
        if (wrong_target && timeouts == 0) begin $error("[tb] no timeout with a missing sharer"); errors++; end
        $display("[tb] RESULT requesters %0d lines %0d repeat %0d: loads %0d fetches %0d timeouts %0d cycles %0d wait mean %0d max %0d",
                 NUM_REQ, lines, repeat_n, delivered, fetches, timeouts, cycles, wait_sum / (delivered ? delivered : 1), wait_max);
        if (errors == 0) $display("[tb] PASS"); else $display("[tb] FAIL %0d errors", errors);
        $finish;
      end
      begin
        repeat (wrong_target ? 200_000 : 40_000_000) @(posedge clk);
        $display("[tb] FAIL timeout of the test: delivered %0d fetches %0d", delivered, fetches);
        $display("[tb] valid %b closed %b issued %b dv %b pend %b in flight %0d resp_valid %b req_valid %b",
                 dut.valid_q, dut.closed_q, dut.issued_q, dut.dv_q, dut.pend_q, flight.size(), resp_valid, req_valid);
        for (int unsigned r = 0; r < NUM_REQ; r++)
          $display("[tb] requester %0d next %0d open %b%b%b%b pause %0d", r, nxt[r], open[r][3], open[r][2], open[r][1], open[r][0], pause[r]);
        $finish;
      end
    join
  end
endmodule
