//==============================================================================
// dma_datapath.sv
//------------------------------------------------------------------------------
// Data path shared by all channel threads:
//
//            +------------------- dma_datapath --------------------+
//  DMALD --->| MFIFO space check -> dma_rd_engine --AR/R--> AXI    |
//            |                          | push                     |
//            |                     dma_mfifo[ch]  (byte stream)    |
//            |                          | pop                      |
//  DMAST --->| data-available check -> dma_wr_engine --AW/W/B-> AXI|
//            +-----------------------------------------------------+
//
// Per-channel MFIFO bookkeeping (in bytes):
//   reserved  : space promised to issued loads and not yet freed by stores
//               (+ DMALD bytes when accepted, - bytes popped onto W)
//   unclaimed : data loaded (or in flight) that no DMAST has claimed yet
//               (+ DMALD bytes, - DMAST bytes when accepted)
//
//   DMALD accepted   when reserved + bytes <= capacity
//   DMALD lock-up    when it does not fit and no store is pending that could
//                    ever free space   -> channel fault (mfifo_err)
//   DMAST data short when bytes > unclaimed -> channel fault
//                    (st_data_unavailable); DMASTZ needs no data.
//==============================================================================
module dma_datapath
  import dma330_pkg::*;
#(
  parameter int NUM_CH      = 4,
  parameter int DATA_W      = 64,
  parameter int ID_W        = 4,
  parameter int RQ_DEPTH    = 4,
  parameter int WQ_DEPTH    = 4,
  parameter int RD_OUT      = 4,
  parameter int WR_OUT      = 4,
  parameter int MFIFO_LINES = 32
) (
  input  logic                clk,
  input  logic                rst_n,

  // Channel thread interface
  input  logic [NUM_CH-1:0]   ld_valid,
  input  xfer_t               ld_xfer [NUM_CH],
  output logic [NUM_CH-1:0]   ld_ready,
  output logic [NUM_CH-1:0]   ld_lockup,
  input  logic [NUM_CH-1:0]   st_valid,
  input  xfer_t               st_xfer [NUM_CH],
  output logic [NUM_CH-1:0]   st_ready,
  output logic [NUM_CH-1:0]   st_short,
  input  logic [NUM_CH-1:0]   ch_flush,
  output logic [NUM_CH-1:0]   rd_busy,
  output logic [NUM_CH-1:0]   wr_busy,
  output logic [NUM_CH-1:0]   rd_err,
  output logic [NUM_CH-1:0]   wr_err,
  output logic [ADDR_W-1:0]   rd_err_addr,
  output logic [ADDR_W-1:0]   wr_err_addr,

  // Instruction-cache refill port
  input  logic                ic_ar_valid,
  output logic                ic_ar_ready,
  input  logic [ADDR_W-1:0]   ic_ar_addr,
  input  logic [7:0]          ic_ar_len,
  input  logic [2:0]          ic_ar_size,
  input  logic [3:0]          ic_ar_cache,
  input  logic [2:0]          ic_ar_prot,
  output logic                ic_r_valid,
  input  logic                ic_r_ready,
  output logic [DATA_W-1:0]   ic_r_data,
  output logic [1:0]          ic_r_resp,
  output logic                ic_r_last,

  // AXI master
  output logic                m_awvalid,
  input  logic                m_awready,
  output logic [ID_W-1:0]     m_awid,
  output logic [ADDR_W-1:0]   m_awaddr,
  output logic [7:0]          m_awlen,
  output logic [2:0]          m_awsize,
  output logic [1:0]          m_awburst,
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
  output logic [3:0]          m_arcache,
  output logic [2:0]          m_arprot,
  input  logic                m_rvalid,
  output logic                m_rready,
  input  logic [ID_W-1:0]     m_rid,
  input  logic [DATA_W-1:0]   m_rdata,
  input  logic [1:0]          m_rresp,
  input  logic                m_rlast,

  // Peripheral acknowledges (DMALDP from R, DMASTP from B)
  output logic                rd_ack_valid,
  input  logic                rd_ack_ready,
  output logic [4:0]          rd_ack_periph,
  output logic                rd_ack_burst,
  output logic                wr_ack_valid,
  input  logic                wr_ack_ready,
  output logic [4:0]          wr_ack_periph,
  output logic                wr_ack_burst
);

  localparam int NB       = DATA_W / 8;
  localparam int NBYTE_W  = $clog2(NB) + 1;
  localparam int MF_CAP   = NB * MFIFO_LINES;        // bytes per channel
  localparam int MF_CNT_W = $clog2(MF_CAP) + 1;

  //============================================================================
  // MFIFO per channel
  //============================================================================
  logic [NUM_CH-1:0]   mf_push, mf_pop, mf_flush;
  logic [NBYTE_W-1:0]  mf_push_n, mf_pop_n;
  logic [DATA_W-1:0]   mf_push_data;
  logic [DATA_W-1:0]   mf_pop_data [NUM_CH];
  logic [MF_CNT_W-1:0] mf_count    [NUM_CH];
  logic [NUM_CH-1:0]   wr_active, store_pending;

  for (genvar ch = 0; ch < NUM_CH; ch++) begin : g_mfifo
    // A flushed channel keeps its MFIFO until an already started write burst
    // has drained its (already present) data onto W.
    assign mf_flush[ch] = ch_flush[ch] && !wr_active[ch];

    dma_mfifo #(.DATA_W(DATA_W), .LINES(MFIFO_LINES)) u_mfifo (
      .clk       (clk),
      .rst_n     (rst_n),
      .flush     (mf_flush[ch]),
      .push_en   (mf_push[ch]),
      .push_n    (mf_push_n),
      .push_data (mf_push_data),
      .pop_en    (mf_pop[ch]),
      .pop_n     (mf_pop_n),
      .pop_data  (mf_pop_data[ch]),
      .count     (mf_count[ch])
    );
  end

  //============================================================================
  // Admission control: MFIFO reservation / data-claim bookkeeping
  //============================================================================
  logic [MF_CNT_W-1:0] reserved  [NUM_CH];
  logic [MF_CNT_W-1:0] unclaimed [NUM_CH];
  logic [NUM_CH-1:0]   rq_push, rq_full, wq_push, wq_full;
  logic [NUM_CH-1:0]   space_ok;

  for (genvar ch = 0; ch < NUM_CH; ch++) begin : g_admit
    assign space_ok[ch]  = (int'(reserved[ch]) + int'(ld_xfer[ch].bytes)) <= MF_CAP;
    assign ld_ready[ch]  = !rq_full[ch] && space_ok[ch] && !ch_flush[ch];
    assign ld_lockup[ch] = !space_ok[ch] && !store_pending[ch];
    assign rq_push[ch]   = ld_valid[ch] && ld_ready[ch];

    assign st_short[ch]  = !st_xfer[ch].zero &&
                           (int'(st_xfer[ch].bytes) > int'(unclaimed[ch]));
    assign st_ready[ch]  = !wq_full[ch] && !ch_flush[ch];
    assign wq_push[ch]   = st_valid[ch] && st_ready[ch];

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        reserved[ch]  <= '0;
        unclaimed[ch] <= '0;
      end else if (mf_flush[ch]) begin
        reserved[ch]  <= '0;
        unclaimed[ch] <= '0;
      end else begin
        reserved[ch]  <= reserved[ch]
                       + (rq_push[ch] ? MF_CNT_W'(ld_xfer[ch].bytes) : '0)
                       - (mf_pop[ch]  ? MF_CNT_W'(mf_pop_n)          : '0);
        unclaimed[ch] <= unclaimed[ch]
                       + (rq_push[ch] ? MF_CNT_W'(ld_xfer[ch].bytes) : '0)
                       - ((wq_push[ch] && !st_xfer[ch].zero) ? MF_CNT_W'(st_xfer[ch].bytes) : '0);
      end
    end
  end

  //============================================================================
  // Read engine
  //============================================================================
  dma_rd_engine #(
    .NUM_CH   (NUM_CH),
    .DATA_W   (DATA_W),
    .ID_W     (ID_W),
    .RQ_DEPTH (RQ_DEPTH),
    .RD_OUT   (RD_OUT)
  ) u_rd_engine (
    .clk          (clk),
    .rst_n        (rst_n),
    .rq_push      (rq_push),
    .rq_data      (ld_xfer),
    .rq_full      (rq_full),
    .ch_flush     (ch_flush),
    .ic_ar_valid  (ic_ar_valid),
    .ic_ar_ready  (ic_ar_ready),
    .ic_ar_addr   (ic_ar_addr),
    .ic_ar_len    (ic_ar_len),
    .ic_ar_size   (ic_ar_size),
    .ic_ar_cache  (ic_ar_cache),
    .ic_ar_prot   (ic_ar_prot),
    .ic_r_valid   (ic_r_valid),
    .ic_r_ready   (ic_r_ready),
    .ic_r_data    (ic_r_data),
    .ic_r_resp    (ic_r_resp),
    .ic_r_last    (ic_r_last),
    .m_arvalid    (m_arvalid),
    .m_arready    (m_arready),
    .m_arid       (m_arid),
    .m_araddr     (m_araddr),
    .m_arlen      (m_arlen),
    .m_arsize     (m_arsize),
    .m_arburst    (m_arburst),
    .m_arcache    (m_arcache),
    .m_arprot     (m_arprot),
    .m_rvalid     (m_rvalid),
    .m_rready     (m_rready),
    .m_rid        (m_rid),
    .m_rdata      (m_rdata),
    .m_rresp      (m_rresp),
    .m_rlast      (m_rlast),
    .mf_push      (mf_push),
    .mf_push_n    (mf_push_n),
    .mf_push_data (mf_push_data),
    .rd_busy      (rd_busy),
    .rd_err       (rd_err),
    .rd_err_addr  (rd_err_addr),
    .ack_valid    (rd_ack_valid),
    .ack_ready    (rd_ack_ready),
    .ack_periph   (rd_ack_periph),
    .ack_burst    (rd_ack_burst)
  );

  //============================================================================
  // Write engine
  //============================================================================
  dma_wr_engine #(
    .NUM_CH   (NUM_CH),
    .DATA_W   (DATA_W),
    .ID_W     (ID_W),
    .WQ_DEPTH (WQ_DEPTH),
    .WR_OUT   (WR_OUT),
    .MF_CNT_W (MF_CNT_W)
  ) u_wr_engine (
    .clk           (clk),
    .rst_n         (rst_n),
    .wq_push       (wq_push),
    .wq_data       (st_xfer),
    .wq_full       (wq_full),
    .ch_flush      (ch_flush),
    .mf_count      (mf_count),
    .mf_pop_data   (mf_pop_data),
    .mf_pop        (mf_pop),
    .mf_pop_n      (mf_pop_n),
    .m_awvalid     (m_awvalid),
    .m_awready     (m_awready),
    .m_awid        (m_awid),
    .m_awaddr      (m_awaddr),
    .m_awlen       (m_awlen),
    .m_awsize      (m_awsize),
    .m_awburst     (m_awburst),
    .m_awcache     (m_awcache),
    .m_awprot      (m_awprot),
    .m_wvalid      (m_wvalid),
    .m_wready      (m_wready),
    .m_wdata       (m_wdata),
    .m_wstrb       (m_wstrb),
    .m_wlast       (m_wlast),
    .m_bvalid      (m_bvalid),
    .m_bready      (m_bready),
    .m_bid         (m_bid),
    .m_bresp       (m_bresp),
    .wr_busy       (wr_busy),
    .wr_active     (wr_active),
    .store_pending (store_pending),
    .wr_err        (wr_err),
    .wr_err_addr   (wr_err_addr),
    .ack_valid     (wr_ack_valid),
    .ack_ready     (wr_ack_ready),
    .ack_periph    (wr_ack_periph),
    .ack_burst     (wr_ack_burst)
  );

endmodule : dma_datapath
