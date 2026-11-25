// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Simulation harness: the task scheduler in front of one domain of real cluster hardware.
//
// The cluster hardware's own testbench instantiates this module as its external dispatcher (its hook
// EXT_DISPATCH) and keeps doing what it always does: clock, reset, loading the program of the cores
// into L2, waking the cores. This module holds
//   the task scheduler (tsched_top with one domain) and the bridges to the cores and to the DMA engines,
//   a host model that feeds the task instructions of a program file (+DIR=<dir>/prog.txt); after a TJoin
//     with bit 0 of its argument set it waits until the scheduler is idle, as a program does that needs the
//     results before it goes on,
//   the end of the test: all instructions taken and no task left in the window.
// The PEs and the DMA engines are real: a block runs for as long as the core and its engine need, a load
// for as long as the engines of the groups need to copy it from L2 into the L1 slot.
//   +SLOT_BASE=<hex>   L1 address of slot 0 (the PE program reserves the slots and reads them there)
//   +TRACE             print every chunk of a load and every start and completion of a block with its cycle
//   +DMA_MODEL         use a model of the DMA engines instead (a chunk takes its bytes divided by the lane
//                      rate, nothing is copied): for programs whose loads have no real L2 data behind them

module tsched_harness import tsched_pkg::*; #(
  parameter int unsigned NumCores  = 64,
  parameter int unsigned NumGroups = tsched_pkg::NumGroups,
  parameter int unsigned DispWidth = 96
) (
  input  logic                                clk_i,
  input  logic                                rst_ni,
  output logic [NumCores-1:0]                 disp_start_o,
  output logic [NumCores-1:0][DispWidth-1:0]  disp_desc_o,
  input  logic [NumCores-1:0]                 disp_done_valid_i,
  output logic [NumCores-1:0]                 disp_done_ready_o,
  output logic                    [NumGroups-1:0] dma_hw_req_valid_o,
  input  logic                    [NumGroups-1:0] dma_hw_req_ready_i,
  output mempool_pkg::dma_hw_req_t [NumGroups-1:0] dma_hw_req_o,
  input  logic                    [NumGroups-1:0] dma_hw_done_i
);

  // Bytes of one group in a row of L1, and bytes of one L1 slot (the PE program reserves the same).
  localparam int unsigned GroupBytes = mempool_pkg::NumBanksPerGroup * 4;
  localparam int unsigned SlotBytes  =
`ifdef TSCHED_SLOT_BYTES `TSCHED_SLOT_BYTES `else 16384 `endif;

  localparam int unsigned LinkStages = 2;

  logic                                 instr_valid, instr_ready, idle;
  tinstr_t                              instr;
  logic      [NumGroups-1:0]            dma_valid, dma_ready, dma_done;
  dma_req_t  [NumGroups-1:0]            dma;
  logic      [NumGroups-1:0][NumPes-1:0] pe_start, pe_done_valid, pe_done_ready;
  blk_t      [NumGroups-1:0][NumCls-1:0] pe_blk;

  tsched_top #(
    .LinkStages (LinkStages)
  ) i_tsched (
    .clk_i,
    .rst_ni,
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

  tsched_disp_bridge #(
    .TilesPerGroup (NumTensor),
    .CoresPerTile  (NumCores / NumGroups / NumTensor),
    .DispWidth     (DispWidth)
  ) i_bridge (
    .pe_start_i        (pe_start),
    .pe_blk_i          (pe_blk),
    .pe_done_valid_o   (pe_done_valid),
    .pe_done_ready_i   (pe_done_ready),
    .disp_start_o,
    .disp_desc_o,
    .disp_done_valid_i,
    .disp_done_ready_o
  );

  // ---------------------------------------------------------------------------------------------
  // DMA engines: the real ones through the bridge, or the model
  // ---------------------------------------------------------------------------------------------
  logic        [31:0]                       slot_base;
  bit                                       dma_model;
  logic        [NumGroups-1:0]              hw_valid, hw_ready, hw_done;
  logic        [NumGroups-1:0]              mdl_ready, mdl_done;

  tsched_dma_bridge #(
    .GroupBytes (GroupBytes),
    .SlotBytes  (SlotBytes ),
    .hw_req_t   (mempool_pkg::dma_hw_req_t)
  ) i_dma_bridge (
    .slot_base_i (slot_base),
    .dma_valid_i (dma_valid),
    .dma_ready_o (hw_ready ),
    .dma_i       (dma      ),
    .dma_done_o  (hw_done  ),
    .hw_valid_o  (hw_valid ),
    .hw_ready_i  (dma_hw_req_ready_i),
    .hw_req_o    (dma_hw_req_o      ),
    .hw_done_i   (dma_hw_done_i     )
  );
  assign dma_hw_req_valid_o = dma_model ? '0 : hw_valid;
  assign dma_ready          = dma_model ? mdl_ready : hw_ready;
  assign dma_done           = dma_model ? mdl_done  : hw_done;

  initial begin
    slot_base = '0;
    dma_model = $test$plusargs("DMA_MODEL");
    if (!dma_model && !$value$plusargs("SLOT_BASE=%h", slot_base))
      $fatal(1, "[tsched] +SLOT_BASE=<hex L1 address of slot 0> or +DMA_MODEL is required");
    if (NumGroups != tsched_pkg::NumGroups)
      $fatal(1, "[tsched] the cluster has %0d groups, the scheduler is built for %0d", NumGroups, tsched_pkg::NumGroups);
    $display("[tsched] DMA engines: %s, slot base %h, %0d bytes per slot, %0d bytes per group in a row",
             dma_model ? "model" : "real", slot_base, SlotBytes, GroupBytes);
  end

  // ---------------------------------------------------------------------------------------------
  // Program
  // ---------------------------------------------------------------------------------------------
  tinstr_t     prog [$];
  string       dir;
  int unsigned lane_bpc100 = 6016;    // bytes per 100 cycles of one stream lane
  int unsigned timeout     = 2000000; // cycles without a start or a completion
  bit          loaded;

  initial begin
    int fd;
    int op, hd_v, hd, hs1_v, hs1, follow, kill, hs2_v, hs2, cls, nblk, kern, len;
    longint arg, addr;
    tinstr_t i;
    if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "[tsched] +DIR=<directory with prog.txt> is required");
    void'($value$plusargs("LANE_BPC100=%d", lane_bpc100));
    void'($value$plusargs("TIMEOUT=%d", timeout));
    fd = $fopen({dir, "/prog.txt"}, "r");
    if (fd == 0) $fatal(1, "[tsched] cannot open %s/prog.txt", dir);
    while ($fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d", op, hd_v, hd, hs1_v, hs1, follow, kill,
                   hs2_v, hs2, cls, nblk, kern, arg, len, addr) == 15) begin
      i = '{op: top_e'(op[1:0]), hd_v: hd_v[0], hd: hd[ArchW-1:0], hs1_v: hs1_v[0], hs1: hs1[ArchW-1:0],
            follow: follow[0], kill: kill[0], hs2_v: hs2_v[0], hs2: hs2[ArchW-1:0], cls: cls[NumCls-1:0],
            nblk: nblk[NblkW-1:0], kern: kern[KernW-1:0], arg: arg[ArgW-1:0], len: len[LenW-1:0],
            addr: addr[AddrW-1:0]};
      prog.push_back(i);
    end
    $fclose(fd);
    $display("[tsched] %0d instructions from %s", prog.size(), dir);
    loaded = 1'b1;
  end

  // ---------------------------------------------------------------------------------------------
  // Host
  // ---------------------------------------------------------------------------------------------
  int unsigned pc, hold;
  bit          waiting, trace;
  longint unsigned cycle, last_event;

  initial trace = $test$plusargs("TRACE");

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc          <= 0;
      instr_valid <= 1'b0;
      waiting     <= 1'b0;
      hold        <= 0;
    end else if (loaded) begin
      if (instr_valid && instr_ready) begin
        instr_valid <= 1'b0;
        pc          <= pc + 1;
        if ((instr.op == TJoin) && instr.arg[0]) begin
          waiting <= 1'b1;
          hold    <= 32;    // the join is in the window before idle is looked at
        end
      end else if (waiting) begin
        if (hold != 0) hold <= hold - 1;
        else if (idle) begin
          waiting <= 1'b0;
          if (trace) $display("[tsched] T %0d host goes on after the join (instruction %0d)", cycle, pc);
        end
      end else if (!instr_valid && (pc < prog.size())) begin
        instr_valid <= 1'b1;
        instr       <= prog[pc];
      end
    end
  end

  // ---------------------------------------------------------------------------------------------
  // DMA engines (model)
  // ---------------------------------------------------------------------------------------------
  int unsigned     st_chunks;
  longint unsigned st_load_first, st_load_last;
  for (genvar g = 0; g < NumGroups; g++) begin : gen_dma
    int unsigned left;
    initial begin
      mdl_ready[g] = 1'b1;
      mdl_done[g]  = 1'b0;
      left         = 0;
    end
    always @(posedge clk_i) begin
      mdl_done[g] <= 1'b0;
      if (rst_ni && dma_model && dma_valid[g] && mdl_ready[g]) begin
        left          = (int'(dma[g].len) * 100 + lane_bpc100 - 1) / lane_bpc100;
        if (left == 0) left = 1;
        mdl_ready[g] <= 1'b0;
      end else if (!mdl_ready[g]) begin
        left = left - 1;
        if (left == 0) begin
          mdl_done[g]  <= 1'b1;
          mdl_ready[g] <= 1'b1;
        end
      end
    end
  end
  always @(posedge clk_i) begin
    if (rst_ni) begin
      for (int g = 0; g < NumGroups; g++) begin
        if (dma_valid[g] && dma_ready[g] && (st_load_first == 0)) st_load_first = cycle;
        if (dma_valid[g] && dma_ready[g] && trace)
          $display("[tsched] T %0d chunk issued group %0d chunk %0d slot %0d", cycle, g, dma[g].chunk, dma[g].slot);
        if (dma_done[g]) begin
          st_chunks++;
          st_load_last = cycle;
          if (trace) $display("[tsched] T %0d chunk done group %0d", cycle, g);
        end
      end
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Statistics and end of the test
  // ---------------------------------------------------------------------------------------------
  int unsigned     st_start [NumCls], st_done [NumCls];
  longint unsigned st_busy  [NumCls];
  longint unsigned t_start  [NumGroups][NumPes];
  longint unsigned first_start;
  int unsigned     idle_cnt;

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      cycle      <= 0;
      last_event  = 0;
    end else begin
      cycle <= cycle + 1;
      for (int g = 0; g < NumGroups; g++) begin
        for (int p = 0; p < NumPes; p++) begin
          automatic int c = (p < NumTensor) ? ClsT : ClsV;
          if (pe_start[g][p]) begin
            st_start[c]++;
            t_start[g][p] = cycle;
            last_event    = cycle;
            if (first_start == 0) first_start = cycle;
            if (trace) $display("[tsched] T %0d start %s group %0d pe %0d kernel %0d block %0d of %0d", cycle,
                                (c == ClsT) ? "tensor" : "vector", g, p, pe_blk[g][c].kern, pe_blk[g][c].bidx, pe_blk[g][c].nblk);
          end
          if (pe_done_valid[g][p] && pe_done_ready[g][p]) begin
            st_done[c]++;
            st_busy[c] += cycle - t_start[g][p];
            last_event  = cycle;
            if (trace) $display("[tsched] T %0d done %s group %0d pe %0d", cycle, (c == ClsT) ? "tensor" : "vector", g, p);
          end
        end
      end
      idle_cnt <= (loaded && (pc == prog.size()) && !instr_valid && !waiting && idle) ? idle_cnt + 1 : 0;
      if (idle_cnt == 16) begin
        $display("[tsched] RESULT cycles=%0d first_start=%0d instructions=%0d", cycle, first_start, prog.size());
        $display("[tsched] RESULT blocks_tensor=%0d blocks_vector=%0d done_tensor=%0d done_vector=%0d chunks=%0d",
                 st_start[ClsT], st_start[ClsV], st_done[ClsT], st_done[ClsV], st_chunks);
        $display("[tsched] RESULT first_chunk_issued=%0d last_chunk_done=%0d", st_load_first, st_load_last);
        $display("[tsched] RESULT mean_cycles_tensor=%0d mean_cycles_vector=%0d",
                 st_done[ClsT] ? st_busy[ClsT] / st_done[ClsT] : 0, st_done[ClsV] ? st_busy[ClsV] / st_done[ClsV] : 0);
        if ((st_start[ClsT] == st_done[ClsT]) && (st_start[ClsV] == st_done[ClsV])) $display("[tsched] PASS");
        else                                                                      $display("[tsched] FAIL: blocks started and done differ");
        $finish;
      end
      if (cycle - last_event > timeout) begin
        $display("[tsched] FAIL: no start or completion for %0d cycles at cycle %0d (pc %0d of %0d, idle %0b)",
                 timeout, cycle, pc, prog.size(), idle);
        $finish;
      end
    end
  end

endmodule
