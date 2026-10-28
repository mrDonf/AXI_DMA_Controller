//==============================================================================
// dma_datapath.sv
//------------------------------------------------------------------------------
// Data path shared by all channel threads:
//
//            +------------------- dma_datapath --------------------+
//  DMALD --->| MFIFO line reservation -> dma_rd_engine --AR/R--> AXI|
//            |                          | push                     |
//            |            dma_mfifo (shared pool, per-channel      |
//            |                       byte streams)                 |
//            |                          | pop                      |
//  DMAST --->| data-available check -> dma_wr_engine --AW/W/B-> AXI|
//            +-----------------------------------------------------+
//
// The MFIFO is one pool of MFIFO_LINES lines shared by all channels. A DMALD
// reserves the lines its bytes will occupy when it is accepted; the lines go
// back to the pool as the bytes are popped onto W.
//
// Per-channel bookkeeping:
//   held      : lines reserved (accepted loads) and not yet freed by pops
//   res_off   : byte offset, inside its line, of the next reserved byte
//   reserved  : bytes reserved and not yet popped
//   unclaimed : data loaded (or in flight) that no DMAST has claimed yet
//               (+ DMALD bytes, - DMAST bytes when accepted)
//
//   need      = lines a DMALD of 'bytes' adds:
//               ceil((res_off + bytes) / NB) - (res_off != 0)
//   DMALD accepted   when sum(held) + need <= MFIFO_LINES and the channel may
//                    load (load-lock below); one DMALD per cycle, round robin
//                    over the channels whose load is admissible
//   DMAST data short when bytes > unclaimed -> channel fault
//                    (st_data_unavailable); DMASTZ needs no data.
//
// A channel whose stream is empty (reserved = 0) gives its last, partly used
// line back at once and restarts at offset 0, so an idle channel holds no line.
//
// Load-lock (TRM 2.11.4): only the owner of the load-lock may load. A channel
// takes the free lock when one of its DMALDs is accepted and keeps it until
// it gives it up (ll_release: DMAST*, DMARMB/DMAWMB, DMAWFP/DMAWFE, DMAEND,
// abort). Other channels pause at their DMALD meanwhile. A program set whose
// static + largest dynamic MFIFO requirement fits the pool never locks up.
//
// Lock-up of a DMALD that cannot be accepted (no space, or another channel
// owns the lock), while the channel has no store pending that could free its
// own lines ("stuck"):
//   * self lock-up (ld_lockup -> mfifo_err): held + need > MFIFO_LINES, the
//                    load would not fit even in an otherwise empty pool
//   * dead-lock    (ld_dlock -> lockup_err, precise lock-up detection): every
//                    channel holding lines is stuck, so no line can ever be
//                    freed. The stuck channels that hold lines are the
//                    contributing ones; with WD.irq_only = 0 they abort and
//                    their lines return to the pool.
// A load blocked only by lines or the lock held by other channels just waits.
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
  parameter int MFIFO_LINES = 128
) (
  input  logic                clk,
  input  logic                rst_n,

  // Channel thread interface
  input  logic [NUM_CH-1:0]   ld_req,       // executing a DMALD (no other fault)
  input  logic [NUM_CH-1:0]   ld_valid,
  input  xfer_t               ld_xfer [NUM_CH],
  output logic [NUM_CH-1:0]   ld_ready,
  output logic [NUM_CH-1:0]   ld_lockup,    // self lock-up (load never fits)
  output logic [NUM_CH-1:0]   ld_dlock,     // contributes to an MFIFO dead-lock
  input  logic [NUM_CH-1:0]   ll_release,   // channel gives the load-lock up
  input  logic [NUM_CH-1:0]   st_valid,
  input  xfer_t               st_xfer [NUM_CH],
  output logic [NUM_CH-1:0]   st_ready,
  output logic [NUM_CH-1:0]   st_short,
  input  logic [NUM_CH-1:0]   ch_flush,
  input  logic [NUM_CH-1:0]   ch_running,
  output logic [NUM_CH-1:0]   rd_busy,
  output logic [NUM_CH-1:0]   wr_busy,
  output logic [NUM_CH-1:0]   wr_beat,
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
  localparam int LANE_W   = $clog2(NB);
  localparam int NBYTE_W  = LANE_W + 1;
  localparam int CH_W     = $clog2(NUM_CH > 1 ? NUM_CH : 2);
  localparam int MF_CAP   = NB * MFIFO_LINES;        // bytes in the whole pool
  localparam int MF_CNT_W = $clog2(MF_CAP) + 1;
  localparam int LCNT_W   = $clog2(MFIFO_LINES + 1);
  localparam int USED_W   = LCNT_W + 4;              // sum over up to 8 channels

  // One-hot (at most one bit set) to index
  function automatic logic [CH_W-1:0] onehot_idx(input logic [NUM_CH-1:0] v);
    onehot_idx = '0;
    for (int c = 0; c < NUM_CH; c++) if (v[c]) onehot_idx = CH_W'(c);
  endfunction

  //============================================================================
  // Shared MFIFO
  //============================================================================
  logic [NUM_CH-1:0]   mf_push, mf_pop, mf_flush;
  logic [NBYTE_W-1:0]  mf_push_n, mf_pop_n;
  logic [CH_W-1:0]     mf_pop_ch;
  logic [DATA_W-1:0]   mf_push_data, mf_pop_data;
  logic                mf_pop_frees;
  logic [MF_CNT_W-1:0] mf_count  [NUM_CH];
  logic [LCNT_W-1:0]   mf_nlines [NUM_CH];
  logic [NUM_CH-1:0]   wr_active, store_pending, release_ch;

  // A flushed channel keeps its MFIFO data until an already started write
  // burst has drained its (already present) data onto W. A channel with an
  // empty stream releases its last line.
  assign mf_flush = (ch_flush & ~wr_active) | release_ch;

  dma_mfifo #(.NUM_CH(NUM_CH), .DATA_W(DATA_W), .LINES(MFIFO_LINES)) u_mfifo (
    .clk       (clk),
    .rst_n     (rst_n),
    .flush     (mf_flush),
    .push_en   (|mf_push),
    .push_ch   (onehot_idx(mf_push)),
    .push_n    (mf_push_n),
    .push_data (mf_push_data),
    .pop_en    (|mf_pop),
    .pop_ch    (mf_pop_ch),
    .pop_n     (mf_pop_n),
    .pop_data  (mf_pop_data),
    .pop_frees (mf_pop_frees),
    .count     (mf_count),
    .nlines    (mf_nlines)
  );

  //============================================================================
  // Admission control: line reservation / data-claim bookkeeping
  //============================================================================
  logic [LCNT_W-1:0]   held      [NUM_CH];
  logic [LANE_W-1:0]   res_off   [NUM_CH];
  logic [MF_CNT_W-1:0] reserved  [NUM_CH];
  logic [MF_CNT_W-1:0] unclaimed [NUM_CH];
  logic [5:0]          need      [NUM_CH];
  logic [USED_W-1:0]   used;
  logic [NUM_CH-1:0]   rq_push, rq_full, wq_push, wq_full;
  logic [NUM_CH-1:0]   fits, adm_req, adm_gnt, stuck, holder, self_lock, may_load;
  logic                deadlock;
  logic                lock_valid;
  logic [CH_W-1:0]     lock_owner;

  always_comb begin
    used = '0;
    for (int c = 0; c < NUM_CH; c++) used += USED_W'(held[c]);
  end

  for (genvar ch = 0; ch < NUM_CH; ch++) begin : g_admit
    assign need[ch] = 6'(((int'(res_off[ch]) + int'(ld_xfer[ch].bytes) + NB - 1) >> LANE_W) -
                         int'(res_off[ch] != '0));
    assign fits[ch] = (int'(used) + int'(need[ch])) <= MFIFO_LINES;

    // An empty stream gives back its partly used line (no load is accepted
    // for the channel in that cycle, it is retried in the next one)
    assign release_ch[ch] = (reserved[ch] == '0) && (held[ch] != '0);
    assign may_load[ch]   = !lock_valid || (lock_owner == CH_W'(ch));
    assign adm_req[ch]    = ld_valid[ch] && fits[ch] && may_load[ch] && !rq_full[ch] &&
                            !ch_flush[ch] && !release_ch[ch];

    assign stuck[ch]     = ld_req[ch] && (!fits[ch] || !may_load[ch]) && !store_pending[ch];
    assign holder[ch]    = (held[ch] != '0) && !release_ch[ch];
    assign self_lock[ch] = (int'(held[ch]) + int'(need[ch])) > MFIFO_LINES;
    assign ld_lockup[ch] = ld_req[ch] && !fits[ch] && !store_pending[ch] && self_lock[ch];
    assign ld_dlock[ch]  = stuck[ch] && deadlock && holder[ch] && !ld_lockup[ch];

    assign st_short[ch]  = !st_xfer[ch].zero &&
                           (int'(st_xfer[ch].bytes) > int'(unclaimed[ch]));
    assign st_ready[ch]  = !wq_full[ch] && !ch_flush[ch];
    assign wq_push[ch]   = st_valid[ch] && st_ready[ch];

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        held[ch]      <= '0;
        res_off[ch]   <= '0;
        reserved[ch]  <= '0;
        unclaimed[ch] <= '0;
      end else if (mf_flush[ch]) begin
        held[ch]      <= '0;
        res_off[ch]   <= '0;
        reserved[ch]  <= '0;
        unclaimed[ch] <= '0;
      end else begin
        held[ch]      <= held[ch]
                       + (rq_push[ch] ? LCNT_W'(need[ch]) : '0)
                       - LCNT_W'(mf_pop_frees && mf_pop_ch == CH_W'(ch));
        res_off[ch]   <= res_off[ch] + (rq_push[ch] ? LANE_W'(ld_xfer[ch].bytes) : '0);
        reserved[ch]  <= reserved[ch]
                       + (rq_push[ch] ? MF_CNT_W'(ld_xfer[ch].bytes) : '0)
                       - (mf_pop[ch]  ? MF_CNT_W'(mf_pop_n)          : '0);
        unclaimed[ch] <= unclaimed[ch]
                       + (rq_push[ch] ? MF_CNT_W'(ld_xfer[ch].bytes) : '0)
                       - ((wq_push[ch] && !st_xfer[ch].zero) ? MF_CNT_W'(st_xfer[ch].bytes) : '0);
      end
    end
  end

  // No line can ever be freed: some stuck channel holds lines, every channel
  // that holds lines is stuck, and no channel is releasing its last line
  // TRM 2.8.3: queues drained and every running channel blocked at DMALD.
  // A legitimate external wait in any running thread defers detection.
  assign deadlock = |(stuck & holder) && ((ch_running & ~stuck) == '0) &&
                    !(|rd_busy) && !(|wr_busy) && (release_ch == '0);

  // One load accepted per cycle (the reservation uses the sum of all channels)
  dma_rr_arbiter #(.N(NUM_CH)) u_adm_arb (
    .clk       (clk),
    .rst_n     (rst_n),
    .req       (adm_req),
    .advance   (|adm_req),
    .gnt       (adm_gnt),
    .gnt_idx   (),
    .gnt_valid ()
  );

  assign ld_ready = adm_gnt;
  assign rq_push  = adm_gnt;            // a grant implies ld_valid

  // Load-lock: taken by an accepted load, given up on ll_release
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lock_valid <= 1'b0;
      lock_owner <= '0;
    end else if (|adm_gnt) begin
      lock_valid <= 1'b1;
      lock_owner <= onehot_idx(adm_gnt);
    end else if (lock_valid && ll_release[lock_owner]) begin
      lock_valid <= 1'b0;
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
    .mf_pop_ch     (mf_pop_ch),
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
    .wr_beat       (wr_beat),
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
