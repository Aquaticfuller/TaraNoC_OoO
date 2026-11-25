// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Task window: every renamed task, in program order, from rename until it is done and all older tasks
// are done. It is the reorder buffer of the tasks: it bounds the tasks in flight, gives each one the
// index its completion returns with, and keeps program order for TJoin. Handles and slots are released
// by the handle file, not by retirement.
//
// A TJoin has nothing to execute. It asks for its completion when it is the oldest task, which makes it
// a barrier: its handle becomes done only after every older task is done.

module tsched_window import tsched_pkg::*; (
  input  logic        clk_i,
  input  logic        rst_ni,
  // allocation at rename
  output logic        ready_o,
  output wid_t        wid_o,
  input  logic        alloc_valid_i,
  input  win_alloc_t  alloc_i,
  // completion of the task in entry done_wid_i; returns the handle that task defines and the data
  // handle it held a reference on
  input  logic        done_valid_i,
  input  wid_t        done_wid_i,
  output logic        done_pd_v_o,
  output phys_t       done_pd_o,
  output logic        done_s1_v_o,
  output phys_t       done_s1_o,
  // the oldest task is a TJoin that waits for its completion
  output logic        join_valid_o,
  input  logic        join_ready_i,
  output wid_t        join_wid_o,
  output logic        empty_o
);

  localparam int unsigned CntW = $clog2(WinDepth + 1);

  logic  [WinDepth-1:0] done_d, done_q;
  logic  [WinDepth-1:0] join_q;
  logic  [WinDepth-1:0] pd_v_q, s1_v_q;
  phys_t [WinDepth-1:0] pd_q, s1_q;

  wid_t            head_d, head_q, tail_d, tail_q;
  logic [CntW-1:0] cnt_d, cnt_q;
  logic            join_sent_d, join_sent_q;
  logic            retire;

  assign ready_o = cnt_q != CntW'(WinDepth);
  assign wid_o   = tail_q;
  assign empty_o = cnt_q == '0;

  assign retire = (cnt_q != '0) & done_q[head_q];

  assign done_pd_v_o = pd_v_q[done_wid_i];
  assign done_pd_o   = pd_q[done_wid_i];
  assign done_s1_v_o = s1_v_q[done_wid_i];
  assign done_s1_o   = s1_q[done_wid_i];

  assign join_valid_o = (cnt_q != '0) & join_q[head_q] & ~done_q[head_q] & ~join_sent_q;
  assign join_wid_o   = head_q;

  function automatic wid_t inc(input wid_t p);
    return (p == wid_t'(WinDepth - 1)) ? '0 : p + wid_t'(1);
  endfunction

  always_comb begin
    done_d      = done_q;
    head_d      = head_q;
    tail_d      = tail_q;
    cnt_d       = cnt_q;
    join_sent_d = join_sent_q;
    if (done_valid_i) done_d[done_wid_i] = 1'b1;
    if (join_valid_o && join_ready_i) join_sent_d = 1'b1;
    if (retire) begin
      head_d      = inc(head_q);
      join_sent_d = 1'b0;
    end
    if (alloc_valid_i) begin
      // The tail entry is not valid before this allocation, so no completion targets it.
      done_d[tail_q] = 1'b0;
      tail_d         = inc(tail_q);
    end
    // Allocation arrives late (it waits for the checks of the dispatch stage), so it only selects.
    unique case ({alloc_valid_i, retire})
      2'b10:   cnt_d = cnt_q + CntW'(1);
      2'b01:   cnt_d = cnt_q - CntW'(1);
      default: cnt_d = cnt_q;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      done_q      <= '0;
      head_q      <= '0;
      tail_q      <= '0;
      cnt_q       <= '0;
      join_sent_q <= 1'b0;
    end else begin
      done_q      <= done_d;
      head_q      <= head_d;
      tail_q      <= tail_d;
      cnt_q       <= cnt_d;
      join_sent_q <= join_sent_d;
    end
  end

  // Payload: written once at allocation, read while the entry is valid. No reset needed.
  always_ff @(posedge clk_i) begin
    if (alloc_valid_i) begin
      join_q[tail_q] <= alloc_i.is_join;
      pd_v_q[tail_q] <= alloc_i.pd_v;
      pd_q[tail_q]   <= alloc_i.pd;
      s1_v_q[tail_q] <= alloc_i.s1_v;
      s1_q[tail_q]   <= alloc_i.s1;
    end
  end

`ifndef TARGET_SYNTHESIS
  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!(alloc_valid_i && !ready_o)) else $error("[tsched_window] allocation into a full window");
      assert (!(done_valid_i && done_q[done_wid_i]))
        else $error("[tsched_window] task %0d completed twice", done_wid_i);
    end
  end
  // pragma translate_on
`endif

endmodule
