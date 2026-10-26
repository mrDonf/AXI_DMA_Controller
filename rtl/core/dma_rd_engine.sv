//==============================================================================
// dma_rd_engine.sv
//------------------------------------------------------------------------------
// AXI read side of the data path.
//
//   channel threads --(DMALD)--> per-channel Read Queue (RQ)
//                                     |
//          i-cache refill ----+       v
//                             +--> AR arbiter --> AR register --> AXI AR
//                                     |
//                                     +--> per-channel Read Tracker (in flight)
//
//   AXI R --> RID == IFETCH_ID ? --> i-cache
//                               : --> lane extraction --> channel MFIFO
//
// * Instruction fetch has priority on AR (a thread is stalled meanwhile).
// * A request whose INCR burst crosses a 4 KB boundary is issued as two AXI
//   bursts (xfer_piece): the queue entry stays at the head until its second
//   piece has been issued. Each piece gets its own tracker entry.
// * Any response other than OKAY (EXOKAY, SLVERR, DECERR) is an error.
// * Data reads use ARID = channel number; R data of one ID returns in order,
//   different IDs may interleave, so each channel keeps its own beat counter.
// * Channel flush (kill/fault) discards queued requests and drops returning
//   data, but the trackers still retire in-flight bursts.
//==============================================================================
module dma_rd_engine
  import dma330_pkg::*;
#(
  parameter int NUM_CH   = 4,
  parameter int DATA_W   = 64,
  parameter int ID_W     = 4,
  parameter int RQ_DEPTH = 4,
  parameter int RD_OUT   = 4
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // Channel read requests (already checked for MFIFO space)
  input  logic [NUM_CH-1:0]       rq_push,
  input  xfer_t                   rq_data [NUM_CH],
  output logic [NUM_CH-1:0]       rq_full,
  input  logic [NUM_CH-1:0]       ch_flush,

  // Instruction cache refill port
  input  logic                    ic_ar_valid,
  output logic                    ic_ar_ready,
  input  logic [ADDR_W-1:0]       ic_ar_addr,
  input  logic [7:0]              ic_ar_len,
  input  logic [2:0]              ic_ar_size,
  input  logic [3:0]              ic_ar_cache,
  input  logic [2:0]              ic_ar_prot,
  output logic                    ic_r_valid,
  input  logic                    ic_r_ready,
  output logic [DATA_W-1:0]       ic_r_data,
  output logic [1:0]              ic_r_resp,
  output logic                    ic_r_last,

  // AXI AR / R
  output logic                    m_arvalid,
  input  logic                    m_arready,
  output logic [ID_W-1:0]         m_arid,
  output logic [ADDR_W-1:0]       m_araddr,
  output logic [7:0]              m_arlen,
  output logic [2:0]              m_arsize,
  output logic [1:0]              m_arburst,
  output logic [3:0]              m_arcache,
  output logic [2:0]              m_arprot,
  input  logic                    m_rvalid,
  output logic                    m_rready,
  input  logic [ID_W-1:0]         m_rid,
  input  logic [DATA_W-1:0]       m_rdata,
  input  logic [1:0]              m_rresp,
  input  logic                    m_rlast,

  // MFIFO push (one channel per cycle)
  output logic [NUM_CH-1:0]       mf_push,
  output logic [$clog2(DATA_W/8):0] mf_push_n,
  output logic [DATA_W-1:0]       mf_push_data,

  // Status
  output logic [NUM_CH-1:0]       rd_busy,
  output logic [NUM_CH-1:0]       rd_err,
  output logic [ADDR_W-1:0]       rd_err_addr,     // address of the erroring beat

  // Peripheral acknowledge for DMALDP (sent when the last beat arrives)
  output logic                    ack_valid,
  input  logic                    ack_ready,
  output logic [4:0]              ack_periph,
  output logic                    ack_burst
);

  localparam int NB        = DATA_W / 8;
  localparam int LANE_W    = $clog2(NB);
  localparam int NBYTE_W   = LANE_W + 1;      // 0 .. NB bytes
  localparam int CH_W     = $clog2(NUM_CH > 1 ? NUM_CH : 2);
  localparam logic [ID_W-1:0] IFETCH_ID = '1;
  localparam logic [1:0] BURST_FIXED = 2'b00;
  localparam logic [1:0] BURST_INCR  = 2'b01;

  //============================================================================
  // Per-channel Read Queue and Read Tracker
  //============================================================================
  xfer_t              rq_head  [NUM_CH];
  xfer_t              rq_iss   [NUM_CH];      // AXI burst to issue next
  logic [NUM_CH-1:0]  rq_empty, rq_pop;
  logic [NUM_CH-1:0]  rq_cross, rq_split;     // head crosses 4 KB / first piece issued
  xfer_t              trk_head [NUM_CH];
  logic [NUM_CH-1:0]  trk_empty, trk_full, trk_push, trk_pop;
  logic [3:0]         beat_cnt [NUM_CH];

  for (genvar ch = 0; ch < NUM_CH; ch++) begin : g_ch

    dma_sync_fifo #(.WIDTH(XFER_W), .DEPTH(RQ_DEPTH)) u_rq (
      .clk     (clk),
      .rst_n   (rst_n),
      .flush   (ch_flush[ch]),
      .push    (rq_push[ch]),
      .wr_data (rq_data[ch]),
      .pop     (rq_pop[ch]),
      .rd_data (rq_head[ch]),
      .empty   (rq_empty[ch]),
      .full    (rq_full[ch]),
      .count   ()
    );

    assign rq_cross[ch] = crosses_4k(rq_head[ch].addr, rq_head[ch].size,
                                     rq_head[ch].len, rq_head[ch].inc);
    assign rq_iss[ch]   = xfer_piece(rq_head[ch], rq_split[ch]);

    // Not flushed: in-flight bursts must always be retired.
    dma_sync_fifo #(.WIDTH(XFER_W), .DEPTH(RD_OUT)) u_trk (
      .clk     (clk),
      .rst_n   (rst_n),
      .flush   (1'b0),
      .push    (trk_push[ch]),
      .wr_data (rq_iss[ch]),
      .pop     (trk_pop[ch]),
      .rd_data (trk_head[ch]),
      .empty   (trk_empty[ch]),
      .full    (trk_full[ch]),
      .count   ()
    );

    assign rd_busy[ch] = !rq_empty[ch] || !trk_empty[ch];
  end

  //============================================================================
  // AR arbitration and output register
  //============================================================================
  logic [NUM_CH-1:0] ch_ar_req;
  logic [NUM_CH-1:0] ch_gnt;
  logic [CH_W-1:0]   ch_gnt_idx;
  logic              ch_gnt_valid;
  logic              ar_load;          // AR register can take a new request
  logic              take_ic, take_ch;

  for (genvar ch = 0; ch < NUM_CH; ch++) begin : g_ar_req
    assign ch_ar_req[ch] = !rq_empty[ch] && !trk_full[ch] && !ch_flush[ch];
  end

  dma_rr_arbiter #(.N(NUM_CH)) u_ar_arb (
    .clk       (clk),
    .rst_n     (rst_n),
    .req       (ch_ar_req),
    .advance   (take_ch),
    .gnt       (ch_gnt),
    .gnt_idx   (ch_gnt_idx),
    .gnt_valid (ch_gnt_valid)
  );

  assign ar_load     = !m_arvalid || m_arready;
  assign take_ic     = ar_load && ic_ar_valid;                     // fetch first
  assign take_ch     = ar_load && !ic_ar_valid && ch_gnt_valid;
  assign ic_ar_ready = take_ic;
  assign trk_push    = take_ch ? ch_gnt : '0;           // each AXI burst is tracked
  // The queue entry leaves with its last (or only) piece
  assign rq_pop      = trk_push & (~rq_cross | rq_split);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rq_split <= '0;
    end else begin
      for (int ch = 0; ch < NUM_CH; ch++) begin
        if (ch_flush[ch] || rq_pop[ch]) rq_split[ch] <= 1'b0;
        else if (trk_push[ch])          rq_split[ch] <= 1'b1;   // first piece issued
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_arvalid <= 1'b0;
      m_arid    <= '0;
      m_araddr  <= '0;
      m_arlen   <= '0;
      m_arsize  <= '0;
      m_arburst <= '0;
      m_arcache <= '0;
      m_arprot  <= '0;
    end else if (ar_load) begin
      if (take_ic) begin
        m_arvalid <= 1'b1;
        m_arid    <= IFETCH_ID;
        m_araddr  <= ic_ar_addr;
        m_arlen   <= ic_ar_len;
        m_arsize  <= ic_ar_size;
        m_arburst <= BURST_INCR;
        m_arcache <= ic_ar_cache;
        m_arprot  <= ic_ar_prot;
      end else if (take_ch) begin
        m_arvalid <= 1'b1;
        m_arid    <= ID_W'(ch_gnt_idx);
        m_araddr  <= rq_iss[ch_gnt_idx].addr;
        m_arlen   <= {4'b0, rq_iss[ch_gnt_idx].len};
        m_arsize  <= rq_iss[ch_gnt_idx].size;
        m_arburst <= rq_iss[ch_gnt_idx].inc ? BURST_INCR : BURST_FIXED;
        m_arcache <= rq_iss[ch_gnt_idx].cache;
        m_arprot  <= rq_iss[ch_gnt_idx].prot;
      end else begin
        m_arvalid <= 1'b0;
      end
    end
  end

  //============================================================================
  // R channel
  //============================================================================
  logic            r_is_ic;
  logic [CH_W-1:0] r_ch;
  xfer_t           r_head;
  logic [3:0]      r_beat;
  logic [ADDR_W-1:0] r_addr;
  logic [LANE_W-1:0] r_lane;
  logic            r_ack_needed;
  logic            r_fire;

  assign r_is_ic      = (m_rid == IFETCH_ID);
  assign r_ch         = CH_W'(m_rid);
  assign r_head       = trk_head[r_ch];
  assign r_beat       = beat_cnt[r_ch];
  assign r_addr       = beat_addr(r_head.addr, r_head.size, r_head.inc, r_beat);
  assign r_lane       = r_addr[LANE_W-1:0];
  // Only look at the tracker head when a data beat is actually present
  assign r_ack_needed = m_rvalid && !r_is_ic && m_rlast && !trk_empty[r_ch] &&
                        r_head.periph_ack && !ch_flush[r_ch];

  // Instruction fetch data goes straight to the i-cache
  assign ic_r_valid = m_rvalid && r_is_ic;
  assign ic_r_data  = m_rdata;
  assign ic_r_resp  = m_rresp;
  assign ic_r_last  = m_rlast;

  assign m_rready = r_is_ic ? ic_r_ready : (!r_ack_needed || ack_ready);
  assign r_fire   = m_rvalid && m_rready;

  // Data beat: move valid lanes down to byte 0 and push into the MFIFO
  assign mf_push_data = m_rdata >> (r_lane * 8);
  assign mf_push_n    = NBYTE_W'(beat_bytes(r_head.addr, r_head.size, r_head.inc, r_beat));

  // Peripheral acknowledge for DMALDP
  assign rd_err_addr = r_addr;

  assign ack_valid  = m_rvalid && r_ack_needed;
  assign ack_periph = r_head.periph;
  assign ack_burst  = r_head.ack_burst;

  always_comb begin
    mf_push = '0;
    trk_pop = '0;
    rd_err  = '0;
    if (r_fire && !r_is_ic) begin
      mf_push[r_ch] = !ch_flush[r_ch];
      trk_pop[r_ch] = m_rlast;
      rd_err[r_ch]  = (m_rresp != 2'b00);     // EXOKAY / SLVERR / DECERR
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int ch = 0; ch < NUM_CH; ch++) beat_cnt[ch] <= '0;
    end else if (r_fire && !r_is_ic) begin
      beat_cnt[r_ch] <= m_rlast ? 4'd0 : beat_cnt[r_ch] + 4'd1;
    end
  end

endmodule : dma_rd_engine
