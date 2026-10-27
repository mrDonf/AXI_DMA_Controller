//==============================================================================
// dma_wr_engine.sv
//------------------------------------------------------------------------------
// AXI write side of the data path.
//
//   channel threads --(DMAST)--> per-channel Write Queue (WQ)
//                                     |
//                                     v
//        select a channel whose MFIFO already holds the whole burst
//                                     |
//                   +-----------------+-----------------+
//                   v                                   v
//                AXI AW                     AXI W (bytes popped from MFIFO,
//                                           rotated onto the AXI lanes)
//                   |
//                   +--> per-channel B tracker --> AXI B (retire, ack, error)
//
// * A burst is started only when all of its data is already in the MFIFO, so
//   W never stalls waiting for read data and one slow channel cannot block
//   the shared W channel (no head-of-line blocking, no deadlock).
// * AW and W of the active burst are driven concurrently (AXI allows either
//   to lead). One burst is active at a time on W (AXI4: no W interleaving).
// * AWID = channel number. B responses of one ID return in order.
// * A request whose INCR burst crosses a 4 KB boundary is issued as two AXI
//   bursts (xfer_piece): the queue entry stays at the head until its second
//   piece has started. Each piece has its own B tracker entry; only the
//   second one carries the peripheral acknowledge.
// * Any response other than OKAY (EXOKAY, SLVERR, DECERR) is an error.
// * Endian swap (DMAST with CCR.endian_swap != 0): the bytes of every aligned
//   group of g = 2**swap bytes are reversed. The channel guarantees that DAR
//   is aligned to g and that the burst holds whole groups (swap_bad).
//     g <= beat : every beat holds whole groups, they are reversed on W.
//     g >  beat : (INCR only) a group spans g / beat beats. The MFIFO head
//                 shows the whole group (g <= bus width); it is reversed and
//                 each beat takes its slice. The group is popped with its
//                 last beat.
//==============================================================================
module dma_wr_engine
  import dma330_pkg::*;
#(
  parameter int NUM_CH   = 4,
  parameter int DATA_W   = 64,
  parameter int ID_W     = 4,
  parameter int WQ_DEPTH = 4,
  parameter int WR_OUT   = 4,
  parameter int MF_CNT_W = 9
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // Channel write requests
  input  logic [NUM_CH-1:0]       wq_push,
  input  xfer_t                   wq_data [NUM_CH],
  output logic [NUM_CH-1:0]       wq_full,
  input  logic [NUM_CH-1:0]       ch_flush,

  // MFIFO pop side (pop_data shows the stream of channel mf_pop_ch)
  input  logic [MF_CNT_W-1:0]     mf_count    [NUM_CH],
  input  logic [DATA_W-1:0]       mf_pop_data,
  output logic [$clog2(NUM_CH > 1 ? NUM_CH : 2)-1:0] mf_pop_ch,
  output logic [NUM_CH-1:0]       mf_pop,
  output logic [$clog2(DATA_W/8):0] mf_pop_n,

  // AXI AW / W / B
  output logic                    m_awvalid,
  input  logic                    m_awready,
  output logic [ID_W-1:0]         m_awid,
  output logic [ADDR_W-1:0]       m_awaddr,
  output logic [7:0]              m_awlen,
  output logic [2:0]              m_awsize,
  output logic [1:0]              m_awburst,
  output logic [3:0]              m_awcache,
  output logic [2:0]              m_awprot,
  output logic                    m_wvalid,
  input  logic                    m_wready,
  output logic [DATA_W-1:0]       m_wdata,
  output logic [DATA_W/8-1:0]     m_wstrb,
  output logic                    m_wlast,
  input  logic                    m_bvalid,
  output logic                    m_bready,
  input  logic [ID_W-1:0]         m_bid,
  input  logic [1:0]              m_bresp,

  // Status
  output logic [NUM_CH-1:0]       wr_busy,        // anything queued / in flight
  output logic [NUM_CH-1:0]       wr_active,      // burst currently on W
  output logic [NUM_CH-1:0]       store_pending,  // stores that will drain MFIFO
  output logic [NUM_CH-1:0]       wr_err,
  output logic [ADDR_W-1:0]       wr_err_addr,     // start address of the burst

  // Peripheral acknowledge for DMASTP (sent with the B response)
  output logic                    ack_valid,
  input  logic                    ack_ready,
  output logic [4:0]              ack_periph,
  output logic                    ack_burst
);

  localparam int NB      = DATA_W / 8;
  localparam int LANE_W  = $clog2(NB);
  localparam int NBYTE_W = LANE_W + 1;
  localparam int CH_W    = $clog2(NUM_CH > 1 ? NUM_CH : 2);
  localparam logic [1:0] BURST_FIXED = 2'b00;
  localparam logic [1:0] BURST_INCR  = 2'b01;

  // Information kept until the B response
  typedef struct packed {
    logic [ADDR_W-1:0] addr;
    logic       periph_ack;
    logic [4:0] periph;
    logic       ack_burst;
  } btrk_t;

  //============================================================================
  // Per-channel Write Queue and B tracker
  //============================================================================
  xfer_t              wq_head  [NUM_CH];
  xfer_t              wq_iss   [NUM_CH];      // AXI burst to start next
  logic [NUM_CH-1:0]  wq_empty, wq_pop;
  logic [NUM_CH-1:0]  wq_cross, wq_split;     // head crosses 4 KB / first piece started
  btrk_t              btrk_head [NUM_CH];
  logic [NUM_CH-1:0]  btrk_empty, btrk_full, btrk_push, btrk_pop;

  // Active burst
  logic               act_valid;
  logic [CH_W-1:0]    act_ch;
  xfer_t              act_x;
  logic               aw_pend, w_pend;
  logic [3:0]         w_beat;

  for (genvar ch = 0; ch < NUM_CH; ch++) begin : g_ch
    btrk_t btrk_in;
    assign wq_cross[ch] = crosses_4k(wq_head[ch].addr, wq_head[ch].size,
                                     wq_head[ch].len, wq_head[ch].inc);
    assign wq_iss[ch]   = xfer_piece(wq_head[ch], wq_split[ch]);
    assign btrk_in = '{addr:       wq_iss[ch].addr,
                       periph_ack: wq_iss[ch].periph_ack,
                       periph:     wq_iss[ch].periph,
                       ack_burst:  wq_iss[ch].ack_burst};

    dma_sync_fifo #(.WIDTH(XFER_W), .DEPTH(WQ_DEPTH)) u_wq (
      .clk     (clk),
      .rst_n   (rst_n),
      .flush   (ch_flush[ch]),
      .push    (wq_push[ch]),
      .wr_data (wq_data[ch]),
      .pop     (wq_pop[ch]),
      .rd_data (wq_head[ch]),
      .empty   (wq_empty[ch]),
      .full    (wq_full[ch]),
      .count   ()
    );

    dma_sync_fifo #(.WIDTH($bits(btrk_t)), .DEPTH(WR_OUT)) u_btrk (
      .clk     (clk),
      .rst_n   (rst_n),
      .flush   (1'b0),
      .push    (btrk_push[ch]),
      .wr_data (btrk_in),
      .pop     (btrk_pop[ch]),
      .rd_data (btrk_head[ch]),
      .empty   (btrk_empty[ch]),
      .full    (btrk_full[ch]),
      .count   ()
    );

    assign wr_active[ch]     = act_valid && (act_ch == CH_W'(ch));
    assign store_pending[ch] = !wq_empty[ch] || wr_active[ch];
    assign wr_busy[ch]       = store_pending[ch] || !btrk_empty[ch];
  end

  //============================================================================
  // Burst selection: round robin over channels whose data is ready
  //============================================================================
  logic [NUM_CH-1:0] cand;
  logic [NUM_CH-1:0] sel_gnt;
  logic [CH_W-1:0]   sel_idx;
  logic              sel_valid;
  logic              start;
  logic              finish;
  logic              aw_fire, w_fire;

  // A replacement can start on the edge the current burst completes, i.e. while
  // its last W beat is on the bus. Those bytes (a whole group for a wide
  // endian swap) are no longer available to the replacement. The amount is
  // known from the burst state alone, so selection does not depend on
  // WREADY/AWREADY: if the last beat is not accepted, 'finish' (and so
  // 'start') is low anyway. Only 'start' itself sees the AXI ready inputs.
  logic [NUM_CH-1:0] last_pop;

  for (genvar ch = 0; ch < NUM_CH; ch++) begin : g_cand
    assign last_pop[ch] = wr_active[ch] && w_pend && m_wlast && !act_x.zero;
    assign cand[ch] = !wq_empty[ch] && !btrk_full[ch] && !ch_flush[ch] &&
                      (wq_iss[ch].zero ||
                       (int'(mf_count[ch]) - (last_pop[ch] ? int'(mf_pop_n) : 0)) >=
                         int'(wq_iss[ch].bytes));
  end

  dma_rr_arbiter #(.N(NUM_CH)) u_wr_arb (
    .clk       (clk),
    .rst_n     (rst_n),
    .req       (cand),
    .advance   (start),
    .gnt       (sel_gnt),
    .gnt_idx   (sel_idx),
    .gnt_valid (sel_valid)
  );

  assign finish    = act_valid && (!aw_pend || aw_fire) &&
                    (!w_pend || (w_fire && m_wlast));
  assign start     = (!act_valid || finish) && sel_valid;
  assign btrk_push = start ? sel_gnt : '0;              // one B tracker entry per AXI burst
  // The queue entry leaves with its last (or only) piece
  assign wq_pop    = btrk_push & (~wq_cross | wq_split);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wq_split <= '0;
    end else begin
      for (int ch = 0; ch < NUM_CH; ch++) begin
        if (ch_flush[ch] || wq_pop[ch]) wq_split[ch] <= 1'b0;
        else if (btrk_push[ch])         wq_split[ch] <= 1'b1;  // first piece started
      end
    end
  end

  //============================================================================
  // AW / W generation for the active burst
  //============================================================================
  logic [ADDR_W-1:0]  w_addr;
  logic [LANE_W-1:0]  w_lane;
  logic [NBYTE_W-1:0] w_nbytes;

  assign w_addr   = beat_addr(act_x.addr, act_x.size, act_x.inc, w_beat);
  assign w_lane   = w_addr[LANE_W-1:0];
  assign w_nbytes = NBYTE_W'(beat_bytes(act_x.addr, act_x.size, act_x.inc, w_beat));

  assign m_awvalid = act_valid && aw_pend;
  assign m_awid    = ID_W'(act_ch);
  assign m_awaddr  = act_x.addr;
  assign m_awlen   = {4'b0, act_x.len};
  assign m_awsize  = act_x.size;
  assign m_awburst = act_x.inc ? BURST_INCR : BURST_FIXED;
  assign m_awcache = act_x.cache;
  assign m_awprot  = act_x.prot;

  // Byte lanes without strobe are driven to zero: the MFIFO bytes behind
  // the popped ones may still be filling, and WDATA must stay stable.
  logic [DATA_W-1:0] w_lane_mask;
  always_comb begin
    for (int k = 0; k < NB; k++) w_lane_mask[k*8 +: 8] = {8{m_wstrb[k]}};
  end

  // Endian swap wider than the beat: beat j of a group of g bytes
  logic               grp_mode, grp_last;
  logic [3:0]         grp_beats_m1, grp_j;
  logic [127:0]       grp_rev;
  logic [DATA_W-1:0]  grp_slice;

  assign grp_mode     = (act_x.swap != 3'd0) && (act_x.swap > act_x.size);
  assign grp_beats_m1 = 4'((5'd1 << (act_x.swap - act_x.size)) - 5'd1);
  assign grp_j        = w_beat & grp_beats_m1;
  assign grp_last     = (grp_j == grp_beats_m1);
  assign grp_rev      = endian_swap(128'(mf_pop_data), act_x.swap);
  assign grp_slice    = DATA_W'(grp_rev >> ((32'(grp_j) << act_x.size) * 8));

  assign m_wvalid  = act_valid && w_pend;
  assign m_wstrb   = NB'(((1 << w_nbytes) - 1) << w_lane);
  logic [DATA_W-1:0] w_data_lanes;
  assign mf_pop_ch    = act_ch;
  assign w_data_lanes = ((grp_mode ? grp_slice : mf_pop_data) << (w_lane * 8)) & w_lane_mask;
  assign m_wdata   = act_x.zero ? '0 :
                     grp_mode   ? w_data_lanes :
                                  DATA_W'(endian_swap(128'(w_data_lanes), act_x.swap));
  assign m_wlast   = (w_beat == act_x.len);

  assign aw_fire   = m_awvalid && m_awready;
  assign w_fire    = m_wvalid  && m_wready;

  always_comb begin
    mf_pop = '0;
    mf_pop[act_ch] = w_fire && !act_x.zero && (!grp_mode || grp_last);
  end
  assign mf_pop_n = grp_mode ? NBYTE_W'(5'd1 << act_x.swap) : w_nbytes;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      act_valid <= 1'b0;
      act_ch    <= '0;
      act_x     <= '0;
      aw_pend   <= 1'b0;
      w_pend    <= 1'b0;
      w_beat    <= '0;
    end else if (start) begin
      act_valid <= 1'b1;
      act_ch    <= sel_idx;
      act_x     <= wq_iss[sel_idx];
      aw_pend   <= 1'b1;
      w_pend    <= 1'b1;
      w_beat    <= '0;
    end else if (act_valid) begin
      if (aw_fire)            aw_pend <= 1'b0;
      if (w_fire)             w_beat  <= w_beat + 4'd1;
      if (w_fire && m_wlast)  w_pend  <= 1'b0;
      // Burst finished once both the address and the last beat are accepted
      if (finish)
        act_valid <= 1'b0;
    end
  end

  //============================================================================
  // B channel
  //============================================================================
  logic [CH_W-1:0] b_ch;
  btrk_t           b_head;
  logic            b_ack_needed;
  logic            b_fire;

  assign b_ch         = CH_W'(m_bid);
  assign b_head       = btrk_head[b_ch];
  // Only look at the tracker head when a response is actually present
  assign b_ack_needed = m_bvalid && !btrk_empty[b_ch] &&
                        b_head.periph_ack && !ch_flush[b_ch];

  assign m_bready   = !b_ack_needed || ack_ready;
  assign b_fire     = m_bvalid && m_bready;
  assign ack_valid  = m_bvalid && b_ack_needed;
  assign ack_periph = b_head.periph;
  assign wr_err_addr = b_head.addr;
  assign ack_burst  = b_head.ack_burst;

  always_comb begin
    btrk_pop = '0;
    wr_err   = '0;
    if (b_fire) begin
      btrk_pop[b_ch] = 1'b1;
      wr_err[b_ch]   = (m_bresp != 2'b00);    // EXOKAY / SLVERR / DECERR
    end
  end

endmodule : dma_wr_engine
