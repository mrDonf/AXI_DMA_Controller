//==============================================================================
// dma_axi_async_bridge.sv
//------------------------------------------------------------------------------
// AXI4 asynchronous bridge: slave port in s_clk domain (DMA core), master port
// in m_clk domain (system interconnect). Each of the five AXI channels is
// carried by an independent dual-clock FIFO, so the bridge is fully
// pipelined and keeps AXI ordering per channel.
//
//   s_clk (core)                                   m_clk (bus)
//   AW  ---------------> [async fifo] ---------------> AW
//   W   ---------------> [async fifo] ---------------> W
//   B   <--------------- [async fifo] <--------------- B
//   AR  ---------------> [async fifo] ---------------> AR
//   R   <--------------- [async fifo] <--------------- R
//==============================================================================
module dma_axi_async_bridge #(
  parameter int ID_W     = 4,
  parameter int ADDR_W   = 32,
  parameter int DATA_W   = 64,
  parameter int FIFO_AW  = 3        // log2(depth) of every channel FIFO
) (
  //--------------------------- slave side (s_clk) ----------------------------
  input  logic                s_clk,
  input  logic                s_rst_n,
  input  logic                s_awvalid,
  output logic                s_awready,
  input  logic [ID_W-1:0]     s_awid,
  input  logic [ADDR_W-1:0]   s_awaddr,
  input  logic [7:0]          s_awlen,
  input  logic [2:0]          s_awsize,
  input  logic [1:0]          s_awburst,
  input  logic                s_awlock,
  input  logic [3:0]          s_awcache,
  input  logic [2:0]          s_awprot,
  input  logic                s_wvalid,
  output logic                s_wready,
  input  logic [DATA_W-1:0]   s_wdata,
  input  logic [DATA_W/8-1:0] s_wstrb,
  input  logic                s_wlast,
  output logic                s_bvalid,
  input  logic                s_bready,
  output logic [ID_W-1:0]     s_bid,
  output logic [1:0]          s_bresp,
  input  logic                s_arvalid,
  output logic                s_arready,
  input  logic [ID_W-1:0]     s_arid,
  input  logic [ADDR_W-1:0]   s_araddr,
  input  logic [7:0]          s_arlen,
  input  logic [2:0]          s_arsize,
  input  logic [1:0]          s_arburst,
  input  logic                s_arlock,
  input  logic [3:0]          s_arcache,
  input  logic [2:0]          s_arprot,
  output logic                s_rvalid,
  input  logic                s_rready,
  output logic [ID_W-1:0]     s_rid,
  output logic [DATA_W-1:0]   s_rdata,
  output logic [1:0]          s_rresp,
  output logic                s_rlast,

  //--------------------------- master side (m_clk) ---------------------------
  input  logic                m_clk,
  input  logic                m_rst_n,
  output logic                m_awvalid,
  input  logic                m_awready,
  output logic [ID_W-1:0]     m_awid,
  output logic [ADDR_W-1:0]   m_awaddr,
  output logic [7:0]          m_awlen,
  output logic [2:0]          m_awsize,
  output logic [1:0]          m_awburst,
  output logic                m_awlock,
  output logic [3:0]          m_awcache,
  output logic [2:0]          m_awprot,
  output logic                m_wvalid,
  input  logic                m_wready,
  output logic [DATA_W-1:0]   m_wdata,
  output logic [DATA_W/8-1:0] m_wstrb,
  output logic                m_wlast,
  input  logic                m_bvalid,
  output logic                m_bready,
  input  logic [ID_W-1:0]     m_bid,
  input  logic [1:0]          m_bresp,
  output logic                m_arvalid,
  input  logic                m_arready,
  output logic [ID_W-1:0]     m_arid,
  output logic [ADDR_W-1:0]   m_araddr,
  output logic [7:0]          m_arlen,
  output logic [2:0]          m_arsize,
  output logic [1:0]          m_arburst,
  output logic                m_arlock,
  output logic [3:0]          m_arcache,
  output logic [2:0]          m_arprot,
  input  logic                m_rvalid,
  output logic                m_rready,
  input  logic [ID_W-1:0]     m_rid,
  input  logic [DATA_W-1:0]   m_rdata,
  input  logic [1:0]          m_rresp,
  input  logic                m_rlast
);

  localparam int AX_W = ID_W + ADDR_W + 8 + 3 + 2 + 1 + 4 + 3;
  localparam int W_W  = DATA_W + DATA_W/8 + 1;
  localparam int B_W  = ID_W + 2;
  localparam int R_W  = ID_W + DATA_W + 2 + 1;

  // AW: core -> bus
  dma_async_fifo #(.WIDTH(AX_W), .ADDR_W(FIFO_AW)) u_aw_fifo (
    .wr_clk   (s_clk),  .wr_rst_n (s_rst_n),
    .wr_valid (s_awvalid), .wr_ready (s_awready),
    .wr_data  ({s_awid, s_awaddr, s_awlen, s_awsize, s_awburst, s_awlock, s_awcache, s_awprot}),
    .rd_clk   (m_clk),  .rd_rst_n (m_rst_n),
    .rd_valid (m_awvalid), .rd_ready (m_awready),
    .rd_data  ({m_awid, m_awaddr, m_awlen, m_awsize, m_awburst, m_awlock, m_awcache, m_awprot})
  );

  // W: core -> bus
  dma_async_fifo #(.WIDTH(W_W), .ADDR_W(FIFO_AW)) u_w_fifo (
    .wr_clk   (s_clk),  .wr_rst_n (s_rst_n),
    .wr_valid (s_wvalid), .wr_ready (s_wready),
    .wr_data  ({s_wdata, s_wstrb, s_wlast}),
    .rd_clk   (m_clk),  .rd_rst_n (m_rst_n),
    .rd_valid (m_wvalid), .rd_ready (m_wready),
    .rd_data  ({m_wdata, m_wstrb, m_wlast})
  );

  // B: bus -> core
  dma_async_fifo #(.WIDTH(B_W), .ADDR_W(FIFO_AW)) u_b_fifo (
    .wr_clk   (m_clk),  .wr_rst_n (m_rst_n),
    .wr_valid (m_bvalid), .wr_ready (m_bready),
    .wr_data  ({m_bid, m_bresp}),
    .rd_clk   (s_clk),  .rd_rst_n (s_rst_n),
    .rd_valid (s_bvalid), .rd_ready (s_bready),
    .rd_data  ({s_bid, s_bresp})
  );

  // AR: core -> bus
  dma_async_fifo #(.WIDTH(AX_W), .ADDR_W(FIFO_AW)) u_ar_fifo (
    .wr_clk   (s_clk),  .wr_rst_n (s_rst_n),
    .wr_valid (s_arvalid), .wr_ready (s_arready),
    .wr_data  ({s_arid, s_araddr, s_arlen, s_arsize, s_arburst, s_arlock, s_arcache, s_arprot}),
    .rd_clk   (m_clk),  .rd_rst_n (m_rst_n),
    .rd_valid (m_arvalid), .rd_ready (m_arready),
    .rd_data  ({m_arid, m_araddr, m_arlen, m_arsize, m_arburst, m_arlock, m_arcache, m_arprot})
  );

  // R: bus -> core
  dma_async_fifo #(.WIDTH(R_W), .ADDR_W(FIFO_AW)) u_r_fifo (
    .wr_clk   (m_clk),  .wr_rst_n (m_rst_n),
    .wr_valid (m_rvalid), .wr_ready (m_rready),
    .wr_data  ({m_rid, m_rdata, m_rresp, m_rlast}),
    .rd_clk   (s_clk),  .rd_rst_n (s_rst_n),
    .rd_valid (s_rvalid), .rd_ready (s_rready),
    .rd_data  ({s_rid, s_rdata, s_rresp, s_rlast})
  );

endmodule : dma_axi_async_bridge
