//==============================================================================
// dma_internal_sva.sv
//------------------------------------------------------------------------------
// White-box assertions bound into RTL internals (see dma_sva_bind.sv).
// Port names match the internal signal names of the bound module so that the
// bind can use implicit (.*) connections.
//==============================================================================

//------------------------------------------------------------------------------
// Synchronous FIFO: never overflow / underflow
//------------------------------------------------------------------------------
module sva_sync_fifo (
  input logic clk,
  input logic rst_n,
  input logic flush,
  input logic push,
  input logic pop,
  input logic full,
  input logic empty
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n || flush);

  FIFO_NO_OVERFLOW:  assert property (push |-> !full);
  FIFO_NO_UNDERFLOW: assert property (pop  |-> !empty);
endmodule

//------------------------------------------------------------------------------
// Shared MFIFO pool: a push that needs a new line always finds one (the data
// path reserved it), only bytes that are present are popped, and the line
// lists stay consistent with the pool.
//------------------------------------------------------------------------------
module sva_mfifo #(
  parameter int NUM_CH = 4,
  parameter int DATA_W = 64,
  parameter int LINES  = 128
) (
  input logic                                       clk,
  input logic                                       rst_n,
  input logic [NUM_CH-1:0]                          flush,
  input logic                                       do_push,
  input logic                                       do_pop,
  input logic                                       alloc,
  input logic                                       free_any,
  input logic [$clog2(NUM_CH > 1 ? NUM_CH : 2)-1:0] push_ch,
  input logic [$clog2(NUM_CH > 1 ? NUM_CH : 2)-1:0] pop_ch,
  input logic [$clog2(DATA_W/8):0]                  push_n,
  input logic [$clog2(DATA_W/8):0]                  pop_n,
  input logic [$clog2(DATA_W/8*LINES):0]            count  [NUM_CH],
  input logic [$clog2(LINES+1)-1:0]                 nlines [NUM_CH],
  input logic [$clog2(DATA_W/8)-1:0]                wr_off [NUM_CH],
  input logic [LINES-1:0]                           own
);
  localparam int NB = DATA_W / 8;

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  int unsigned lines_sum;
  always_comb begin
    lines_sum = 0;
    for (int c = 0; c < NUM_CH; c++) lines_sum += nlines[c];
  end

  MFIFO_ALLOC_HAS_LINE: assert property (alloc |-> free_any);
  MFIFO_NO_UNDERFLOW:   assert property (do_pop |-> int'(pop_n) <= int'(count[pop_ch]));
  MFIFO_PUSH_NONZERO:   assert property (do_push |-> push_n != 0);
  // Every line in use belongs to exactly one list
  MFIFO_LINES_OWNED:    assert property (lines_sum == $countones(own));
  MFIFO_C_FULLISH:     cover  property ($countones(own) > LINES * 3 / 4);
  MFIFO_C_POOL_FULL:    cover  property (&own);

  for (genvar c = 0; c < NUM_CH; c++) begin : g_ch
    MFIFO_OFF_HAS_LINE: assert property (disable iff (!rst_n || flush[c])
        wr_off[c] != '0 |-> nlines[c] != '0);
    MFIFO_BYTES_FIT:    assert property (disable iff (!rst_n || flush[c])
        int'(count[c]) <= int'(nlines[c]) * NB);
  end
endmodule

//------------------------------------------------------------------------------
// Data path line reservation: the pool is never over-committed, and a channel
// never uses more lines than it has reserved.
//------------------------------------------------------------------------------
module sva_datapath #(
  parameter int NUM_CH      = 4,
  parameter int MFIFO_LINES = 128
) (
  input logic                                clk,
  input logic                                rst_n,
  input logic [$clog2(MFIFO_LINES+1)+3:0]    used,
  input logic [$clog2(MFIFO_LINES+1)-1:0]    held      [NUM_CH],
  input logic [$clog2(MFIFO_LINES+1)-1:0]    mf_nlines [NUM_CH],
  input logic [NUM_CH-1:0]                   mf_flush,
  input logic [NUM_CH-1:0]                   ld_lockup,
  input logic [NUM_CH-1:0]                   ld_req,
  input logic [NUM_CH-1:0]                   stuck,
  input logic                                deadlock,
  input logic [NUM_CH-1:0]                   adm_gnt,
  input logic [NUM_CH-1:0]                   ld_dlock,
  input logic                                lock_valid,
  input logic [$clog2(NUM_CH > 1 ? NUM_CH : 2)-1:0] lock_owner
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  DP_POOL_NOT_OVERCOMMITTED: assert property (int'(used) <= MFIFO_LINES);
  DP_LOCKUP_ONLY_ON_LOAD:    assert property ((ld_lockup & ~ld_req) == '0);
  DP_DLOCK_ONLY_ON_LOAD:     assert property ((ld_dlock & ~ld_req) == '0);
  // Load-lock: only its owner (or anyone while it is free) loads, one load
  // per cycle
  DP_LOADLOCK_OWNER:         assert property (|adm_gnt |-> !lock_valid || adm_gnt[lock_owner]);
  DP_ONE_LOAD:               assert property ($onehot0(adm_gnt));

  for (genvar c = 0; c < NUM_CH; c++) begin : g_ch
    DP_LINES_RESERVED: assert property (disable iff (!rst_n || mf_flush[c])
        mf_nlines[c] <= held[c]);
  end

  DP_C_WAIT_FOR_SPACE: cover property (|stuck && !deadlock);
  DP_C_DEADLOCK:       cover property (deadlock);
  DP_C_LOCK_WAIT:      cover property (lock_valid && |(stuck & ~(NUM_CH'(1) << lock_owner)));
endmodule

//------------------------------------------------------------------------------
// Toggle handshake CDC: the crossing payload must be stable while the
// destination sees it as valid (quasi-static bus rule).
//------------------------------------------------------------------------------
module sva_cdc_handshake #(
  parameter int WIDTH = 8
) (
  input logic             dst_clk,
  input logic             dst_rst_n,
  input logic             dst_valid,
  input logic             dst_ready,
  input logic [WIDTH-1:0] data_q
);
  CDC_DATA_STABLE: assert property (@(posedge dst_clk) disable iff (!dst_rst_n)
      dst_valid && !dst_ready |=> $stable(data_q));
  CDC_C_TRANSFER:  cover property (@(posedge dst_clk) disable iff (!dst_rst_n)
      dst_valid && dst_ready);
endmodule

//------------------------------------------------------------------------------
// Read engine: every data beat belongs to an outstanding burst and RLAST
// arrives exactly on the last beat.
//------------------------------------------------------------------------------
module sva_rd_engine
  import dma330_pkg::*;
#(
  parameter int NUM_CH = 4,
  parameter int ID_W   = 4
) (
  input logic              clk,
  input logic              rst_n,
  input logic              r_fire,
  input logic              r_is_ic,
  input logic [NUM_CH-1:0] trk_empty,
  input logic [ID_W-1:0]   m_rid,
  input logic              m_rlast,
  input logic [3:0]        r_beat,
  input xfer_t             r_head
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  RD_BEAT_HAS_BURST: assert property (
      r_fire && !r_is_ic |-> int'(m_rid) < NUM_CH && !trk_empty[m_rid]);
  RD_RLAST_POSITION: assert property (
      r_fire && !r_is_ic |-> m_rlast == (r_beat == r_head.len));
endmodule

//------------------------------------------------------------------------------
// Channel thread: transfer requests only while executing; never both at once.
//------------------------------------------------------------------------------
module sva_channel
  import dma330_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic ld_valid,
  input logic st_valid,
  input logic sev_valid,
  input logic flush_valid,
  input logic dp_flush,
  input logic faulting,
  input logic [3:0] status,
  input logic dp_idle,
  input logic ic_inv_req,
  input logic ic_refill,
  input logic [31:0] cpc
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  CH_ONE_REQ:          assert property (!(ld_valid && st_valid));
  CH_NO_REQ_FLUSHING:  assert property ((ld_valid || st_valid) |-> !dp_flush);
  CH_FAULT_FLUSHES:    assert property (faulting |-> dp_flush);
  CH_MISS_REQUIRES_REFILL: assert property (status == ST_CACHE_MISS |-> ic_refill);
  CH_UPDATE_NO_REISSUE: assert property (
      status == ST_UPDATING_PC |-> !(ld_valid || st_valid || sev_valid));
  CH_PC_COMMIT_PHASE: assert property (
      $past(rst_n) && $changed(cpc) |-> $past(status inside {ST_STOPPED, ST_UPDATING_PC}));
  CH_C_UPDATE_PC: cover property (status == ST_UPDATING_PC);
  CH_END_KILL_INVALIDATE: assert property (
      (status inside {ST_COMPLETING, ST_KILLING}) && dp_idle |-> ic_inv_req);
  CH_C_END_INVALIDATE: cover property (status == ST_COMPLETING && dp_idle && ic_inv_req);
  CH_C_KILL_INVALIDATE: cover property (status == ST_KILLING && dp_idle && ic_inv_req);
  CH_C_LD_ST:          cover  property (ld_valid ##[1:20] st_valid);
endmodule

// Fetch unit in the integrated design: a thread is never invalidated while it
// fetches (its maintenance comes from DMAWFE/DMAEND/DMAKILL in EXEC, from a
// DMAGO while Stopped, or from Completing/Killing). The fetch unit's own
// inv-during-fetch handling is therefore defensive here and is exercised by
// the directed unit test (tb/unit/dma_fetch_unit_tb.sv).
//------------------------------------------------------------------------------
module sva_fetch_unit (
  input logic clk,
  input logic rst_n,
  input logic fetch_req,
  input logic inv
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);
  FU_NO_INV_WHILE_FETCHING: assert property (!(fetch_req && inv));
endmodule

// Manager DMAEND/DMAKILL have no data transactions to drain. The faulted
// manager's debug DMAKILL takes a separate path from normal execution.
module sva_manager_cache
  import dma330_pkg::*;
(
  input logic clk, rst_n, in_exec_ok, ic_inv_req, faulting, dbg_valid,
  input insn_e cls,
  input logic [INSN_W-1:0] dbg_insn,
  input logic [3:0] status,
  input logic ic_refill,
  input logic [31:0] dpc
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);
  MGR_MISS_REQUIRES_REFILL: assert property (status == ST_CACHE_MISS |-> ic_refill);
  MGR_PC_COMMIT_PHASE: assert property (
      $past(rst_n) && $changed(dpc) |-> $past(status inside {ST_STOPPED, ST_UPDATING_PC}));
  MGR_C_UPDATE_PC: cover property (status == ST_UPDATING_PC);
  MGR_END_KILL_INVALIDATE: assert property (
      in_exec_ok && (cls inside {I_END, I_KILL}) |-> ic_inv_req);
  MGR_FAULT_KILL_INVALIDATE: assert property (
      faulting && dbg_valid && decode_op(dbg_insn[7:0]) == I_KILL |-> ic_inv_req);
  MGR_C_END_INVALIDATE: cover property (in_exec_ok && cls == I_END && ic_inv_req);
  MGR_C_KILL_INVALIDATE: cover property (in_exec_ok && cls == I_KILL && ic_inv_req);
endmodule

//------------------------------------------------------------------------------
// Write engine: W data never goes out without a selected burst, and only the
// bytes present in the MFIFO are popped (checked in sva_mfifo).
//------------------------------------------------------------------------------
module sva_wr_engine #(parameter int NUM_CH=4) (
  input logic clk,
  input logic rst_n,
  input logic m_wvalid,
  input logic m_awvalid,
  input logic act_valid,
  input logic [$clog2(NUM_CH>1 ? NUM_CH : 2)-1:0] aw_ch,
  input logic [NUM_CH-1:0] btrk_empty
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  WR_W_NEEDS_BURST:  assert property (m_wvalid  |-> act_valid);
  WR_AW_NEEDS_BURST: assert property (m_awvalid |-> !btrk_empty[aw_ch]);
endmodule
