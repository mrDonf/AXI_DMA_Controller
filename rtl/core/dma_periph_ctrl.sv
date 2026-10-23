//==============================================================================
// dma_periph_ctrl.sv
//------------------------------------------------------------------------------
// Peripheral request controller (core clock domain).
//
// Per peripheral p:
//   * Request latch  : one pending request {burst, last} accepted from the
//                      dr interface (drready = no request pending).
//   * DMAWFP         : the lowest-numbered channel waiting on p consumes the
//                      pending request.
//   * Ack queue      : acknowledges sent on the da interface, in order:
//                        2'b00 single done   (DMALDPS / DMASTPS completed)
//                        2'b01 burst done    (DMALDPB / DMASTPB completed)
//                        2'b10 flush request (DMAFLUSHP)
//   * DMAFLUSHP      : clears the pending request, queues a flush request and
//                      discards dr requests until the peripheral answers with
//                      drtype = 2'b10 (flush acknowledge).
//
// Ack-queue push priority per cycle: flush > read ack > write ack. A source
// that loses arbitration (or finds the queue full) is back-pressured.
//==============================================================================
module dma_periph_ctrl #(
  parameter int NUM_PERIPH  = 4,
  parameter int NUM_CH      = 4,
  parameter int NUM_THREADS = 5,           // channels + manager (flush only)
  parameter int ACKQ_DEPTH  = 4
) (
  input  logic                   clk,
  input  logic                   rst_n,

  // Peripheral interface (core domain)
  input  logic [NUM_PERIPH-1:0]  dr_valid,
  output logic [NUM_PERIPH-1:0]  dr_ready,
  input  logic [1:0]             dr_type [NUM_PERIPH],
  input  logic [NUM_PERIPH-1:0]  dr_last,
  output logic [NUM_PERIPH-1:0]  da_valid,
  input  logic [NUM_PERIPH-1:0]  da_ready,
  output logic [1:0]             da_type [NUM_PERIPH],

  // DMAWFP from channels
  input  logic [NUM_CH-1:0]      wfp_valid,
  input  logic [4:0]             wfp_periph [NUM_CH],
  output logic [NUM_CH-1:0]      wfp_gnt,
  output logic [NUM_CH-1:0]      wfp_burst,
  output logic [NUM_CH-1:0]      wfp_last,

  // DMAFLUSHP from any thread
  input  logic [NUM_THREADS-1:0] flush_valid,
  input  logic [4:0]             flush_periph [NUM_THREADS],
  output logic [NUM_THREADS-1:0] flush_ready,

  // Transfer-complete acknowledges from the data path
  input  logic                   rd_ack_valid,
  output logic                   rd_ack_ready,
  input  logic [4:0]             rd_ack_periph,
  input  logic                   rd_ack_burst,
  input  logic                   wr_ack_valid,
  output logic                   wr_ack_ready,
  input  logic [4:0]             wr_ack_periph,
  input  logic                   wr_ack_burst
);

  localparam logic [1:0] DA_SINGLE = 2'b00;
  localparam logic [1:0] DA_BURST  = 2'b01;
  localparam logic [1:0] DA_FLUSH  = 2'b10;
  localparam logic [1:0] DR_FLUSH_ACK = 2'b10;

  logic [NUM_PERIPH-1:0] req_pend, req_burst, req_last, flushing;

  // Per-peripheral decisions
  logic [NUM_PERIPH-1:0] grant_wfp;     // pending request consumed by a channel
  logic [NUM_PERIPH-1:0] do_flush;
  logic [NUM_PERIPH-1:0] ackq_push, ackq_full, ackq_empty;
  logic [1:0]            ackq_in [NUM_PERIPH];

  //----------------------------------------------------------------------------
  // Arbitration (combinational)
  //----------------------------------------------------------------------------
  always_comb begin
    wfp_gnt      = '0;
    wfp_burst    = '0;
    wfp_last     = '0;
    flush_ready  = '0;
    rd_ack_ready = 1'b0;
    wr_ack_ready = 1'b0;
    grant_wfp    = '0;
    do_flush     = '0;
    ackq_push    = '0;

    for (int p = 0; p < NUM_PERIPH; p++) begin
      logic flush_req, rd_req, wr_req;
      ackq_in[p] = DA_SINGLE;

      // DMAWFP: first waiting channel gets the pending request
      for (int ch = 0; ch < NUM_CH; ch++) begin
        if (!grant_wfp[p] && wfp_valid[ch] && int'(wfp_periph[ch]) == p &&
            req_pend[p] && !flushing[p]) begin
          grant_wfp[p]  = 1'b1;
          wfp_gnt[ch]   = 1'b1;
          wfp_burst[ch] = req_burst[p];
          wfp_last[ch]  = req_last[p];
        end
      end

      // Ack queue: flush > read ack > write ack
      flush_req = 1'b0;
      for (int t = 0; t < NUM_THREADS; t++) begin
        if (!flush_req && flush_valid[t] && int'(flush_periph[t]) == p) begin
          flush_req = 1'b1;
          if (!ackq_full[p]) flush_ready[t] = 1'b1;
        end
      end
      rd_req = rd_ack_valid && int'(rd_ack_periph) == p;
      wr_req = wr_ack_valid && int'(wr_ack_periph) == p;

      if (!ackq_full[p]) begin
        if (flush_req) begin
          do_flush[p]  = 1'b1;
          ackq_push[p] = 1'b1;
          ackq_in[p]   = DA_FLUSH;
        end else if (rd_req) begin
          rd_ack_ready = 1'b1;
          ackq_push[p] = 1'b1;
          ackq_in[p]   = rd_ack_burst ? DA_BURST : DA_SINGLE;
        end else if (wr_req) begin
          wr_ack_ready = 1'b1;
          ackq_push[p] = 1'b1;
          ackq_in[p]   = wr_ack_burst ? DA_BURST : DA_SINGLE;
        end
      end
    end
  end

  //----------------------------------------------------------------------------
  // Per-peripheral state
  //----------------------------------------------------------------------------
  for (genvar p = 0; p < NUM_PERIPH; p++) begin : g_periph

    assign dr_ready[p] = flushing[p] || !req_pend[p];

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        req_pend[p]  <= 1'b0;
        req_burst[p] <= 1'b0;
        req_last[p]  <= 1'b0;
        flushing[p]  <= 1'b0;
      end else if (do_flush[p]) begin
        req_pend[p]  <= 1'b0;
        flushing[p]  <= 1'b1;
      end else begin
        if (grant_wfp[p])
          req_pend[p] <= 1'b0;

        if (dr_valid[p] && dr_ready[p]) begin
          if (flushing[p]) begin
            // Discard everything until the flush acknowledge
            if (dr_type[p] == DR_FLUSH_ACK) flushing[p] <= 1'b0;
          end else if (dr_type[p] != DR_FLUSH_ACK) begin
            req_pend[p]  <= 1'b1;
            req_burst[p] <= dr_type[p][0];
            req_last[p]  <= dr_last[p];
          end
        end
      end
    end

    dma_sync_fifo #(.WIDTH(2), .DEPTH(ACKQ_DEPTH)) u_ackq (
      .clk     (clk),
      .rst_n   (rst_n),
      .flush   (1'b0),
      .push    (ackq_push[p]),
      .wr_data (ackq_in[p]),
      .pop     (da_valid[p] && da_ready[p]),
      .rd_data (da_type[p]),
      .empty   (ackq_empty[p]),
      .full    (ackq_full[p]),
      .count   ()
    );

    assign da_valid[p] = !ackq_empty[p];
  end

endmodule : dma_periph_ctrl
