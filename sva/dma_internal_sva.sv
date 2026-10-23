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
// MFIFO byte buffer: the data path must reserve space before pushing and only
// pop bytes that are present.
//------------------------------------------------------------------------------
module sva_mfifo #(
  parameter int DATA_W = 64,
  parameter int LINES  = 32
) (
  input logic                              clk,
  input logic                              rst_n,
  input logic                              flush,
  input logic                              push_en,
  input logic [$clog2(DATA_W/8):0]         push_n,
  input logic                              pop_en,
  input logic [$clog2(DATA_W/8):0]         pop_n,
  input logic [$clog2(DATA_W/8*LINES):0]   count
);
  localparam int CAP = DATA_W / 8 * LINES;

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n || flush);

  MFIFO_NO_OVERFLOW:  assert property (push_en |-> int'(count) + int'(push_n) <= CAP);
  MFIFO_NO_UNDERFLOW: assert property (pop_en  |-> int'(pop_n) <= int'(count));
  MFIFO_PUSH_NONZERO: assert property (push_en |-> push_n != 0);
  MFIFO_C_FULLISH:    cover  property (int'(count) > CAP / 2);
endmodule

//------------------------------------------------------------------------------
// Dual-clock FIFO: gray pointers change by at most one bit per clock, no
// write when full, no read when empty.
//------------------------------------------------------------------------------
module sva_async_fifo #(
  parameter int ADDR_W = 3
) (
  input logic              wr_clk,
  input logic              wr_rst_n,
  input logic              rd_clk,
  input logic              rd_rst_n,
  input logic [ADDR_W:0]   wgray,
  input logic [ADDR_W:0]   rgray,
  input logic              wr_valid,
  input logic              wr_ready,
  input logic              rd_valid,
  input logic              rd_ready
);
  AFIFO_WGRAY_ONEHOT: assert property (@(posedge wr_clk) disable iff (!wr_rst_n)
      $onehot0(wgray ^ $past(wgray)));
  AFIFO_RGRAY_ONEHOT: assert property (@(posedge rd_clk) disable iff (!rd_rst_n)
      $onehot0(rgray ^ $past(rgray)));
  AFIFO_C_FULL:       cover property (@(posedge wr_clk) disable iff (!wr_rst_n)
      wr_valid && !wr_ready);
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
module sva_channel (
  input logic clk,
  input logic rst_n,
  input logic ld_valid,
  input logic st_valid,
  input logic sev_valid,
  input logic flush_valid,
  input logic dp_flush,
  input logic faulting
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  CH_ONE_REQ:          assert property (!(ld_valid && st_valid));
  CH_NO_REQ_FLUSHING:  assert property ((ld_valid || st_valid) |-> !dp_flush);
  CH_FAULT_FLUSHES:    assert property (faulting |-> dp_flush);
  CH_C_LD_ST:          cover  property (ld_valid ##[1:20] st_valid);
endmodule

//------------------------------------------------------------------------------
// Write engine: W data never goes out without a selected burst, and only the
// bytes present in the MFIFO are popped (checked in sva_mfifo).
//------------------------------------------------------------------------------
module sva_wr_engine (
  input logic clk,
  input logic rst_n,
  input logic m_wvalid,
  input logic m_awvalid,
  input logic act_valid
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  WR_W_NEEDS_BURST:  assert property (m_wvalid  |-> act_valid);
  WR_AW_NEEDS_BURST: assert property (m_awvalid |-> act_valid);
endmodule
