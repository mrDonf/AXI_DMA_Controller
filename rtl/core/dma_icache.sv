//==============================================================================
// dma_icache.sv
//------------------------------------------------------------------------------
// Instruction cache shared by the manager and all channel threads.
//
//   * Fully associative, NUM_LINES lines of LINE_BEATS x DATA_W bits
//   * Round-robin replacement, one refill at a time, other-thread hits bypass
//   * Requests from the threads' fetch units are served round robin
//   * Each line is tagged with its thread and security state. Threads do not
//     share entries: DMAWFE invalid, DMAEND and DMAKILL invalidate only the
//     issuing thread (TRM 4.3.3, 4.3.6, 4.3.19).
//   * Refill uses one AXI INCR burst with ARID = IFETCH_ID (all ones),
//     privileged instruction access, cacheable write-through read-allocate
//     (TRM Table 2-1)
//   * A refill with a response other than OKAY is returned as an error and is
//     not allocated
//   * inv[t] invalidates thread t, including any lookup/refill in flight.
//     A cancelled refill still drains AXI, then responds with resp_retry so
//     the fetch unit can retry without executing stale bytes or faulting.
//   * Hit-under-miss uses the same response port; refill RLAST has priority.
//
//   IC_IDLE --arbitrate--> IC_LOOKUP --hit--> respond --> IC_IDLE
//                              |miss
//                              v
//                           IC_AR --> IC_R (collect beats) --> respond
//==============================================================================
module dma_icache
  import dma330_pkg::*;
#(
  parameter int NUM_THREADS = 5,
  parameter int DATA_W      = 64,
  parameter int LINE_BEATS  = 4,
  parameter int NUM_LINES   = 8
) (
  input  logic                          clk,
  input  logic                          rst_n,
  input  logic [NUM_THREADS-1:0]        inv,
  output logic                          idle,       // no lookup / refill in progress

  // Thread fetch units
  input  logic [NUM_THREADS-1:0]        req,
  input  logic [ADDR_W-1:0]             req_addr [NUM_THREADS],
  input  logic [NUM_THREADS-1:0]        req_ns,
  output logic [NUM_THREADS-1:0]        resp_valid,
  output logic [LINE_BEATS*DATA_W-1:0]  resp_data,
  output logic                          resp_err,
  output logic                          resp_retry,
  output logic [NUM_THREADS-1:0]        refill_pending, // true miss, per thread

  // AXI refill (through the read engine)
  output logic                          ar_valid,
  input  logic                          ar_ready,
  output logic [ADDR_W-1:0]             ar_addr,
  output logic [7:0]                    ar_len,
  output logic [2:0]                    ar_size,
  output logic [3:0]                    ar_cache,
  output logic [2:0]                    ar_prot,
  input  logic                          r_valid,
  output logic                          r_ready,
  input  logic [DATA_W-1:0]             r_data,
  input  logic [1:0]                    r_resp,
  input  logic                          r_last
);

  localparam int LINE_BYTES = LINE_BEATS * DATA_W / 8;
  localparam int LINE_W     = LINE_BEATS * DATA_W;
  localparam int LINE_LSB   = $clog2(LINE_BYTES);
  localparam int TAG_W      = ADDR_W - LINE_LSB;
  localparam int TID_W      = $clog2(NUM_THREADS > 1 ? NUM_THREADS : 2);
  localparam int WAY_W      = $clog2(NUM_LINES > 1 ? NUM_LINES : 2);
  localparam int BEAT_W     = $clog2(LINE_BEATS > 1 ? LINE_BEATS : 2);

  typedef enum logic [1:0] {IC_IDLE, IC_LOOKUP, IC_AR, IC_R} icstate_e;
  icstate_e state;

  // Storage
  logic [NUM_LINES-1:0] line_valid;
  logic [TAG_W-1:0]     line_tag  [NUM_LINES];
  logic [NUM_LINES-1:0] line_ns;
  logic [TID_W-1:0]     line_tid [NUM_LINES];
  logic [LINE_W-1:0]    line_data [NUM_LINES];
  logic [WAY_W-1:0]     victim;

  // Current request
  logic [TID_W-1:0]     cur_tid;
  logic [TAG_W-1:0]     cur_tag;
  logic                 cur_ns;
  logic [LINE_W-1:0]    fill_buf;
  logic [BEAT_W-1:0]    fill_beat;
  logic                 fill_err;
  logic                 cur_invalid;
  logic                 cancelled;
  logic                 fill_commit;
  logic                 r_bad; // EXOKAY / SLVERR / DECERR

  assign cancelled = cur_invalid || inv[cur_tid];
  assign fill_commit = (state == IC_R) && r_valid && r_last &&
                       !(fill_err | r_bad) && !cancelled;

  //----------------------------------------------------------------------------
  // Request arbitration
  //----------------------------------------------------------------------------
  logic [NUM_THREADS-1:0] arb_gnt;
  logic [TID_W-1:0]       arb_idx;
  logic                   arb_valid;
  logic                   arb_take;
  logic                   bg_take, bg_active;
  logic [NUM_THREADS-1:0]  bg_hit, arb_req;
  logic [WAY_W-1:0]       bg_way [NUM_THREADS];

  assign arb_take = (state == IC_IDLE) && arb_valid;
  assign bg_active = state == IC_AR || state == IC_R;
  assign bg_take = bg_active && arb_valid && !(state == IC_R && r_valid && r_last);
  assign arb_req = req & ~resp_valid & ~inv &
                   (bg_active ? (bg_hit & ~(NUM_THREADS'(1) << cur_tid)) : '1);

  // A stalled refill must not block another thread's cached instruction.
  // Refill completion owns the shared response port on its final beat.
  always_comb begin
    bg_hit = '0;
    for (int t=0;t<NUM_THREADS;t++) begin
      bg_way[t] = '0;
      for (int w=0;w<NUM_LINES;w++) begin
        if (!bg_hit[t] && line_valid[w] && !inv[line_tid[w]] &&
            line_tid[w] == TID_W'(t) && line_ns[w] == req_ns[t] &&
            line_tag[w] == req_addr[t][ADDR_W-1:LINE_LSB]) begin
          bg_hit[t] = 1'b1;
          bg_way[t] = WAY_W'(w);
        end
      end
    end
  end

  dma_rr_arbiter #(.N(NUM_THREADS)) u_arb (
    .clk       (clk),
    .rst_n     (rst_n),
    .req       (arb_req),
    .advance   (arb_take || bg_take),
    .gnt       (arb_gnt),
    .gnt_idx   (arb_idx),
    .gnt_valid (arb_valid)
  );

  //----------------------------------------------------------------------------
  // Tag lookup
  //----------------------------------------------------------------------------
  logic             hit;
  logic [WAY_W-1:0] hit_way;

  always_comb begin
    hit     = 1'b0;
    hit_way = '0;
    for (int w = 0; w < NUM_LINES; w++) begin
      if (!hit && line_valid[w] && line_tag[w] == cur_tag &&
          line_tid[w] == cur_tid && line_ns[w] == cur_ns) begin
        hit     = 1'b1;
        hit_way = WAY_W'(w);
      end
    end
  end

  //----------------------------------------------------------------------------
  // AXI refill request / data
  //----------------------------------------------------------------------------
  assign r_bad = (r_resp != 2'b00);

  assign ar_valid = (state == IC_AR);
  assign ar_addr  = {cur_tag, {LINE_LSB{1'b0}}};
  assign ar_len   = 8'(LINE_BEATS - 1);
  assign ar_size  = 3'($clog2(DATA_W / 8));
  assign ar_cache = 4'b0110;                       // write-through, allocate on read
  assign ar_prot  = {1'b1, cur_ns, 1'b1};          // instruction, NS, privileged
  assign r_ready  = (state == IC_R);
  assign idle     = (state == IC_IDLE);

  // A front-end line-buffer miss can still hit this shared cache. Report
  // architectural Cache miss only after lookup has selected an AXI refill,
  // including any wait for the refill address to be accepted (TRM 2.3.3).
  always_comb begin
    refill_pending = '0;
    if ((state == IC_AR || state == IC_R) && !cancelled)
      refill_pending[cur_tid] = 1'b1;
  end

  //----------------------------------------------------------------------------
  // Control
  //----------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= IC_IDLE;
      line_valid <= '0;
      line_ns    <= '0;
      victim     <= '0;
      cur_tid    <= '0;
      cur_tag    <= '0;
      cur_ns     <= 1'b0;
      fill_beat  <= '0;
      fill_err   <= 1'b0;
      cur_invalid <= 1'b0;
      resp_valid <= '0;
      resp_err   <= 1'b0;
      resp_retry <= 1'b0;
      for (int w = 0; w < NUM_LINES; w++) line_tid[w] <= '0;
    end else begin
      resp_valid <= '0;
      resp_retry <= 1'b0;
      if (bg_take) begin
        resp_valid[arb_idx] <= 1'b1;
        resp_err <= 1'b0;
      end
      if (state != IC_IDLE && inv[cur_tid]) cur_invalid <= 1'b1;

      case (state)
        IC_IDLE: begin
          if (arb_take) begin
            cur_tid <= arb_idx;
            cur_tag <= req_addr[arb_idx][ADDR_W-1:LINE_LSB];
            cur_ns  <= req_ns[arb_idx];
            cur_invalid <= 1'b0;
            state   <= IC_LOOKUP;
          end
        end

        IC_LOOKUP: begin
          if (cancelled || hit) begin
            resp_valid[cur_tid] <= 1'b1;
            resp_err            <= 1'b0;
            resp_retry          <= cancelled;
            state               <= IC_IDLE;
          end else begin
            fill_beat <= '0;
            fill_err  <= 1'b0;
            state     <= IC_AR;
          end
        end

        IC_AR: begin
          if (ar_ready) state <= IC_R;
        end

        IC_R: begin
          if (r_valid) begin
            fill_beat <= fill_beat + 1'b1;
            fill_err  <= fill_err | r_bad;
            if (r_last) begin
              resp_valid[cur_tid] <= 1'b1;
              resp_err            <= !cancelled && (fill_err | r_bad);
              resp_retry          <= cancelled;
              state               <= IC_IDLE;
              if (!(fill_err | r_bad) && !cancelled) begin
                line_valid[victim] <= 1'b1;
                line_tag[victim]   <= cur_tag;
                line_ns[victim]    <= cur_ns;
                line_tid[victim]   <= cur_tid;
                victim             <= (int'(victim) == NUM_LINES - 1) ? '0 : victim + 1'b1;
              end
            end
          end
        end

        default: state <= IC_IDLE;
      endcase

      for (int w = 0; w < NUM_LINES; w++)
        if (line_valid[w] && inv[line_tid[w]] &&
            !(fill_commit && victim == WAY_W'(w))) line_valid[w] <= 1'b0;
    end
  end

  // Data arrays (no reset needed)
  always_ff @(posedge clk) begin
    if (state == IC_R && r_valid) begin
      fill_buf[fill_beat*DATA_W +: DATA_W] <= r_data;
      if (r_last && !(fill_err | r_bad) && !cancelled)
        line_data[victim] <= fill_buf_with_last();
    end
    if (state == IC_LOOKUP && hit)
      resp_data <= line_data[hit_way];
    else if (state == IC_R && r_valid && r_last)
      resp_data <= fill_buf_with_last();
    else if (bg_take)
      resp_data <= line_data[bg_way[arb_idx]];
  end

  // Fill buffer including the beat being received this cycle
  function automatic logic [LINE_W-1:0] fill_buf_with_last();
    logic [LINE_W-1:0] line;
    line = fill_buf;
    line[fill_beat*DATA_W +: DATA_W] = r_data;
    return line;
  endfunction

endmodule : dma_icache
