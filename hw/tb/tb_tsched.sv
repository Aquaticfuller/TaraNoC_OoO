// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Testbench of the task scheduler. The host, the DMA engines and the PEs are models:
//   host   feeds the task instructions of a program file, one every INSTR_GAP + 1 cycles
//   DMA    a chunk takes len / lane rate cycles
//   PE     a block takes LAUNCH cycles plus the time the program's task table gives for the PE class and
//          for the distance between the PE's group and the domain that holds the data
// The files come from scripts/gen_program.py (see there for the formats):
//   +DIR=<directory> with prog.txt, tasks.txt, hop.txt
//
// Checks (each is an error, and the run ends with the number of errors)
//   every block of every task starts exactly once, on a PE class the task allows
//   a block of a task that follows the stream starts only when enough of its slot has arrived;
//   a block of any other task with data starts only when the slot is complete
//   a task starts only after the tasks it must wait for are done
//   a slot is not loaded again while a task still uses it
//   the program ends with an empty window and every task done

`timescale 1ns/1ps

module tb_tsched;

  import tsched_pkg::*;

  localparam realtime     ClkPeriod  = 1ns;
  localparam int unsigned LinkStages =
`ifdef TB_LINK_STAGES `TB_LINK_STAGES `else 2 `endif;
  localparam bit          BalEn =
`ifdef TB_NO_LEND 1'b0 `else 1'b1 `endif;
  localparam int unsigned LendMin =
`ifdef TB_LEND_MIN `TB_LEND_MIN `else 1 `endif;
  localparam int unsigned C = ChunksPerGroup;

  logic clk, rst_n;

  initial begin
    clk = 1'b0;
    forever #(ClkPeriod / 2.0) clk = ~clk;
  end

  // ---------------------------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------------------------
  logic      instr_valid, instr_ready, idle;
  tinstr_t   instr;
  logic      [NumGroups-1:0]             dma_valid, dma_ready, dma_done;
  dma_req_t  [NumGroups-1:0]             dma;
  logic      [NumGroups-1:0][NumPes-1:0] pe_start, pe_done_valid, pe_done_ready;
  blk_t      [NumGroups-1:0][NumCls-1:0] pe_blk;

  tsched_top #(
    .LinkStages (LinkStages),
    .BalEn      (BalEn),
    .LendMin    (LendMin)
  ) i_dut (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .instr_valid_i   (instr_valid),
    .instr_ready_o   (instr_ready),
    .instr_i         (instr),
    .idle_o          (idle),
    .dma_valid_o     (dma_valid),
    .dma_ready_i     (dma_ready),
    .dma_o           (dma),
    .dma_done_i      (dma_done),
    .pe_start_o      (pe_start),
    .pe_blk_o        (pe_blk),
    .pe_done_valid_i (pe_done_valid),
    .pe_done_ready_o (pe_done_ready)
  );

  // ---------------------------------------------------------------------------------------------
  // Program and tables
  // ---------------------------------------------------------------------------------------------
  string       dir;
  int unsigned lane_bpc100 = 6016;    // bytes per cycle of one lane, times 100
  int unsigned launch      = 16;      // cycles from the start pulse to the first cycle of work
  int unsigned instr_gap   = 0;
  longint unsigned timeout = 2000000; // cycles without any event before the run is declared hung

  tinstr_t prog [$];
  int unsigned n_tasks, n_hop;
  int          hopidx [NumGroups][NumDomains];
  int unsigned dur [];                // [(task * NumCls + cls) * n_hop + hop]
  bit [NumCls-1:0] t_cls [];
  int unsigned t_nblk [];
  bit          t_follow [];
  int unsigned t_need [];             // tasks 0 .. need-1 must be done before this one starts
  int          t_dep [];              // this task must be done before, or -1

  function automatic int unsigned dom_of(input int unsigned g);
    int unsigned side = 2 * DomPerSide;
    return ((g / side) / 2) * DomPerSide + (g % side) / 2;
  endfunction

  task automatic load_files();
    int fd, n, g_n, r_n, idx;
    int op, hd_v, hd, hs1_v, hs1, follow, kill, hs2_v, hs2, cls, nblk, kern, len;
    longint arg, addr;
    tinstr_t i;
    if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "+DIR=<directory> is required");
    void'($value$plusargs("LANE_BPC100=%d", lane_bpc100));
    void'($value$plusargs("LAUNCH=%d", launch));
    void'($value$plusargs("INSTR_GAP=%d", instr_gap));
    void'($value$plusargs("TIMEOUT=%d", timeout));

    fd = $fopen({dir, "/hop.txt"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/hop.txt", dir);
    n = $fscanf(fd, "%d %d %d", g_n, r_n, n_hop);
    if (g_n != NumGroups || r_n != NumDomains) $fatal(1, "hop.txt is for %0d groups and %0d domains", g_n, r_n);
    for (int g = 0; g < NumGroups; g++) for (int r = 0; r < NumDomains; r++) n = $fscanf(fd, "%d", hopidx[g][r]);
    $fclose(fd);

    fd = $fopen({dir, "/tasks.txt"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/tasks.txt", dir);
    n = $fscanf(fd, "%d", n_tasks);
    dur      = new[n_tasks * NumCls * n_hop];
    t_cls    = new[n_tasks];
    t_nblk   = new[n_tasks];
    t_follow = new[n_tasks];
    t_need   = new[n_tasks];
    t_dep    = new[n_tasks];
    for (int t = 0; t < n_tasks; t++) begin
      n = $fscanf(fd, "%d %d %d %d %d %d", idx, cls, nblk, follow, t_need[t], t_dep[t]);
      if (idx != t) $fatal(1, "tasks.txt: line %0d has index %0d", t, idx);
      t_cls[t]    = cls[NumCls-1:0];
      t_nblk[t]   = nblk;
      t_follow[t] = follow[0];
      for (int k = 0; k < NumCls * n_hop; k++) n = $fscanf(fd, "%d", dur[t * NumCls * n_hop + k]);
    end
    $fclose(fd);

    fd = $fopen({dir, "/prog.txt"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/prog.txt", dir);
    while ($fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d", op, hd_v, hd, hs1_v, hs1, follow, kill,
                   hs2_v, hs2, cls, nblk, kern, arg, len, addr) == 15) begin
      i = '{op: top_e'(op[1:0]), hd_v: hd_v[0], hd: hd[ArchW-1:0], hs1_v: hs1_v[0], hs1: hs1[ArchW-1:0],
            follow: follow[0], kill: kill[0], hs2_v: hs2_v[0], hs2: hs2[ArchW-1:0], cls: cls[NumCls-1:0],
            nblk: nblk[NblkW-1:0], kern: kern[KernW-1:0], arg: arg[ArgW-1:0], len: len[LenW-1:0],
            addr: addr[AddrW-1:0]};
      prog.push_back(i);
    end
    $fclose(fd);
    $display("[tb] %0d instructions, %0d run tasks, %0d distances", prog.size(), n_tasks, n_hop);
  endtask

  // ---------------------------------------------------------------------------------------------
  // Bookkeeping
  // ---------------------------------------------------------------------------------------------
  longint unsigned cycle;
  longint unsigned last_event;
  int unsigned     errors;

  bit [(1<<NblkW)-1:0] t_started [];  // blocks of a task that have started
  int unsigned t_ndone [];            // blocks of a task that are done
  bit          t_done [];
  int unsigned done_prefix;           // tasks 0 .. done_prefix-1 are done
  int unsigned tasks_done;

  // Stream progress as the PEs may rely on it.
  int unsigned g_slot   [NumGroups];
  int unsigned g_chunks [NumGroups];
  bit          slot_full [NumDomains][SlotsPerDomain];
  int unsigned slot_users [NumDomains][SlotsPerDomain];
  int          t_slot_dom [];
  int          t_slot [];

  // Statistics.
  longint unsigned st_busy [NumCls], st_blocks [NumCls], st_away [NumCls];
  longint unsigned st_lane_cycles, st_loads, st_win_sum;
  int unsigned     st_win_max, st_riq_max;

  function automatic void err(input string s);
    errors++;
    $display("[tb] ERROR at cycle %0d: %s", cycle, s);
    if (errors >= 50) begin
      $display("[tb] FAIL: too many errors");
      $finish;
    end
  endfunction

  // Progress of a slot in chunks: the load in flight if all groups of the domain work on that slot.
  function automatic int unsigned slot_prog(input int unsigned d, input int unsigned s);
    int unsigned p = C;
    if (slot_full[d][s]) return C;
    for (int g = 0; g < NumGroups; g++) begin
      if (dom_of(g) == d) begin
        if (g_slot[g] != s) return 0;
        if (g_chunks[g] < p) p = g_chunks[g];
      end
    end
    return p;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Host
  // ---------------------------------------------------------------------------------------------
  int unsigned pc, gap_cnt;
  bit          loaded;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc          <= 0;
      gap_cnt     <= 0;
      instr_valid <= 1'b0;
    end else if (loaded) begin
      if (instr_valid && instr_ready) begin
        instr_valid <= 1'b0;
        pc          <= pc + 1;
        gap_cnt     <= instr_gap;
        last_event   = cycle;
      end else if (!instr_valid && (pc < prog.size())) begin
        if (gap_cnt != 0) gap_cnt <= gap_cnt - 1;
        else begin
          instr_valid <= 1'b1;
          instr       <= prog[pc];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------------------------
  // DMA engines
  // ---------------------------------------------------------------------------------------------
  for (genvar g = 0; g < NumGroups; g++) begin : gen_dma
    initial begin
      dma_ready[g] = 1'b1;
      dma_done[g]  = 1'b0;
    end
    always @(posedge clk) begin
      if (rst_n && dma_valid[g] && dma_ready[g]) begin
        automatic int unsigned d = (int'(dma[g].len) * 100 + lane_bpc100 - 1) / lane_bpc100;
        if (d == 0) d = 1;
        dma_ready[g] <= 1'b0;
        dma_done[g]  <= #(d * ClkPeriod) 1'b1;
        st_lane_cycles += d;
        if (dma[g].chunk == '0) begin
          automatic int unsigned dm = dom_of(g);
          g_slot[g]   = dma[g].slot;
          g_chunks[g] = 0;
          if (slot_users[dm][dma[g].slot] != 0)
            err($sformatf("load into slot %0d of domain %0d while %0d tasks use it", dma[g].slot, dm,
                          slot_users[dm][dma[g].slot]));
          slot_full[dm][dma[g].slot] = 1'b0;
        end
      end
      if (dma_done[g]) begin
        dma_done[g]  <= 1'b0;
        dma_ready[g] <= 1'b1;
        g_chunks[g]++;
        last_event = cycle;
        if (slot_prog(dom_of(g), g_slot[g]) == C) begin
          if (!slot_full[dom_of(g)][g_slot[g]]) st_loads++;
          slot_full[dom_of(g)][g_slot[g]] = 1'b1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------------------------
  // PEs
  // ---------------------------------------------------------------------------------------------
  for (genvar g = 0; g < NumGroups; g++) begin : gen_grp
    for (genvar p = 0; p < NumPes; p++) begin : gen_pe
      localparam int unsigned Cls = (p < NumTensor) ? ClsT : ClsV;
      blk_t cur;
      initial pe_done_valid[g][p] = 1'b0;
      always @(posedge clk) begin
        if (rst_n && pe_start[g][p]) begin
          automatic blk_t        b = pe_blk[g][Cls];
          automatic int unsigned t = b.arg;
          automatic int unsigned d;
          cur = b;
          last_event = cycle;
          if (t >= n_tasks) begin
            err($sformatf("block of unknown task %0d", t));
          end else begin
            d = dur[(t * NumCls + Cls) * n_hop + hopidx[g][b.dom]];
            if (b.pcls != Cls[0] || !t_cls[t][Cls])
              err($sformatf("task %0d block %0d on a PE of class %0d", t, b.bidx, Cls));
            if (b.bidx >= t_nblk[t] || b.nblk != t_nblk[t])
              err($sformatf("task %0d: block %0d of %0d, expected %0d blocks", t, b.bidx, b.nblk, t_nblk[t]));
            else if (t_started[t][b.bidx])
              err($sformatf("task %0d block %0d started twice", t, b.bidx));
            t_started[t][b.bidx] = 1'b1;
            if (done_prefix < t_need[t])
              err($sformatf("task %0d started with only the first %0d tasks done, needs %0d", t, done_prefix, t_need[t]));
            if (t_dep[t] >= 0 && !t_done[t_dep[t]])
              err($sformatf("task %0d started before task %0d was done", t, t_dep[t]));
            if (b.slot_v) begin
              automatic int unsigned pr = slot_prog(b.dom, b.slot);
              if (t_follow[t] ? ((int'(b.bidx) + 1) * C > pr * t_nblk[t]) : (pr != C))
                err($sformatf("task %0d block %0d of %0d started with %0d of %0d chunks in slot %0d of domain %0d",
                              t, b.bidx, t_nblk[t], pr, C, b.slot, b.dom));
              if (t_slot_dom[t] < 0) begin
                t_slot_dom[t] = b.dom;
                t_slot[t]     = b.slot;
                slot_users[b.dom][b.slot]++;
              end
            end
            st_busy[Cls]   += d;
            st_blocks[Cls] += 1;
            if (dom_of(g) != b.dom) st_away[Cls] += 1;
            pe_done_valid[g][p] <= #((d + launch) * ClkPeriod) 1'b1;
          end
        end
        if (pe_done_valid[g][p] && pe_done_ready[g][p]) begin
          automatic int unsigned t = cur.arg;
          pe_done_valid[g][p] <= 1'b0;
          last_event = cycle;
          t_ndone[t]++;
          if (t_ndone[t] == t_nblk[t]) begin
            t_done[t] = 1'b1;
            tasks_done++;
            if (t_slot_dom[t] >= 0) slot_users[t_slot_dom[t]][t_slot[t]]--;
            while (done_prefix < n_tasks && t_done[done_prefix]) begin
              done_prefix++;
              // The next task waits for everything before it: a phase of the program ends here.
              if (done_prefix == n_tasks || t_need[done_prefix] == done_prefix)
                $display("[tb] PHASE tasks_done=%0d cycle=%0d", done_prefix, cycle);
            end
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n) begin
      cycle <= cycle + 1;
      st_win_sum += i_dut.i_backend.i_window.cnt_q;
      if (i_dut.i_backend.i_window.cnt_q > st_win_max) st_win_max = i_dut.i_backend.i_window.cnt_q;
      if ($countones(i_dut.i_backend.i_run_iq.valid_q) > st_riq_max)
        st_riq_max = $countones(i_dut.i_backend.i_run_iq.valid_q);
    end
  end

  task automatic report();
    $display("[tb] RESULT cycles=%0d instructions=%0d tasks=%0d tasks_done=%0d errors=%0d", cycle, pc, n_tasks,
             tasks_done, errors);
    $display("[tb] RESULT blocks_tensor=%0d blocks_vector=%0d away_tensor=%0d away_vector=%0d", st_blocks[ClsT],
             st_blocks[ClsV], st_away[ClsT], st_away[ClsV]);
    $display("[tb] RESULT busy_tensor=%0d busy_vector=%0d lane_cycles=%0d loads=%0d", st_busy[ClsT], st_busy[ClsV],
             st_lane_cycles, st_loads);
    $display("[tb] RESULT win_max=%0d win_mean=%0.2f riq_max=%0d", st_win_max,
             cycle ? real'(st_win_sum) / real'(cycle) : 0.0, st_riq_max);
  endtask

  initial begin
    rst_n       = 1'b0;
    loaded      = 1'b0;
    cycle       = 0;
    last_event  = 0;
    errors      = 0;
    done_prefix = 0;
    tasks_done  = 0;
    load_files();
    t_started  = new[n_tasks];
    t_ndone    = new[n_tasks];
    t_done     = new[n_tasks];
    t_slot_dom = new[n_tasks];
    t_slot     = new[n_tasks];
    foreach (t_slot_dom[t]) t_slot_dom[t] = -1;
    repeat (5) @(posedge clk);
    #(ClkPeriod / 4.0) rst_n = 1'b1;
    loaded = 1'b1;
    forever begin
      @(posedge clk);
      if ((pc == prog.size()) && idle && (cycle > 10)) begin
        repeat (20) @(posedge clk);
        for (int t = 0; t < n_tasks; t++) begin
          if (!t_done[t]) err($sformatf("task %0d not done: %0d of %0d blocks", t, t_ndone[t], t_nblk[t]));
        end
        if (!idle) err("window not empty at the end");
        report();
        if (errors == 0) $display("[tb] PASS"); else $display("[tb] FAIL");
        $finish;
      end
      if (cycle - last_event > timeout) begin
        err($sformatf("no event for %0d cycles: pc %0d of %0d, %0d of %0d tasks done", timeout, pc, prog.size(),
                      tasks_done, n_tasks));
        report();
        $display("[tb] FAIL");
        $finish;
      end
    end
  end

endmodule
