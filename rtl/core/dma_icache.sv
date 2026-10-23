//==============================================================================
// dma_icache.sv
//------------------------------------------------------------------------------
// Instruction cache shared by the manager and all channel threads.
//
//   * Fully associative, NUM_LINES lines of LINE_BEATS x DATA_W bits
//   * Round-robin replacement, blocking (one lookup / refill at a time)
//   * Requests from the threads' fetch units are served round robin
//   * Refill uses one AXI INCR burst with ARID = IFETCH_ID (all ones)
//   * A refill with an error response is returned as an error and is not
//     allocated
//   * inv_all clears every valid bit (DMAGO / DMAWFE with invalidate)
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
  input  logic                          inv_all,
  output logic                          idle,       // no lookup / refill in progress

  // Thread fetch units
  input  logic [NUM_THREADS-1:0]        req,
  input  logic [ADDR_W-1:0]             req_addr [NUM_THREADS],
  input  logic [NUM_THREADS-1:0]        req_ns,
  output logic [NUM_THREADS-1:0]        resp_valid,
  output logic [LINE_BEATS*DATA_W-1:0]  resp_data,
  output logic                          resp_err,

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
  logic [LINE_W-1:0]    line_data [NUM_LINES];
  logic [WAY_W-1:0]     victim;

  // Current request
  logic [TID_W-1:0]     cur_tid;
  logic [TAG_W-1:0]     cur_tag;
  logic                 cur_ns;
  logic [LINE_W-1:0]    fill_buf;
  logic [BEAT_W-1:0]    fill_beat;
  logic                 fill_err;

  //----------------------------------------------------------------------------
  // Request arbitration
  //----------------------------------------------------------------------------
  logic [NUM_THREADS-1:0] arb_gnt;
  logic [TID_W-1:0]       arb_idx;
  logic                   arb_valid;
  logic                   arb_take;

  assign arb_take = (state == IC_IDLE) && arb_valid;

  dma_rr_arbiter #(.N(NUM_THREADS)) u_arb (
    .clk       (clk),
    .rst_n     (rst_n),
    .req       (req & ~resp_valid),   // a thread just served is not re-taken
    .advance   (arb_take),
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
      if (!hit && line_valid[w] && line_tag[w] == cur_tag) begin
        hit     = 1'b1;
        hit_way = WAY_W'(w);
      end
    end
  end

  //----------------------------------------------------------------------------
  // AXI refill request / data
  //----------------------------------------------------------------------------
  assign ar_valid = (state == IC_AR);
  assign ar_addr  = {cur_tag, {LINE_LSB{1'b0}}};
  assign ar_len   = 8'(LINE_BEATS - 1);
  assign ar_size  = 3'($clog2(DATA_W / 8));
  assign ar_cache = 4'b0010;                       // normal, non-bufferable
  assign ar_prot  = {1'b1, cur_ns, 1'b0};          // instruction access
  assign r_ready  = (state == IC_R);
  assign idle     = (state == IC_IDLE);

  //----------------------------------------------------------------------------
  // Control
  //----------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= IC_IDLE;
      line_valid <= '0;
      victim     <= '0;
      cur_tid    <= '0;
      cur_tag    <= '0;
      cur_ns     <= 1'b0;
      fill_beat  <= '0;
      fill_err   <= 1'b0;
      resp_valid <= '0;
      resp_err   <= 1'b0;
    end else begin
      resp_valid <= '0;

      case (state)
        IC_IDLE: begin
          if (arb_take) begin
            cur_tid <= arb_idx;
            cur_tag <= req_addr[arb_idx][ADDR_W-1:LINE_LSB];
            cur_ns  <= req_ns[arb_idx];
            state   <= IC_LOOKUP;
          end
        end

        IC_LOOKUP: begin
          if (hit) begin
            resp_valid[cur_tid] <= 1'b1;
            resp_err            <= 1'b0;
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
            fill_err  <= fill_err | r_resp[1];
            if (r_last) begin
              resp_valid[cur_tid] <= 1'b1;
              resp_err            <= fill_err | r_resp[1];
              state               <= IC_IDLE;
              if (!(fill_err | r_resp[1])) begin
                line_valid[victim] <= 1'b1;
                line_tag[victim]   <= cur_tag;
                victim             <= (int'(victim) == NUM_LINES - 1) ? '0 : victim + 1'b1;
              end
            end
          end
        end

        default: state <= IC_IDLE;
      endcase

      if (inv_all) line_valid <= '0;
    end
  end

  // Data arrays (no reset needed)
  always_ff @(posedge clk) begin
    if (state == IC_R && r_valid) begin
      fill_buf[fill_beat*DATA_W +: DATA_W] <= r_data;
      if (r_last && !(fill_err | r_resp[1]))
        line_data[victim] <= fill_buf_with_last();
    end
    if (state == IC_LOOKUP && hit)
      resp_data <= line_data[hit_way];
    else if (state == IC_R && r_valid && r_last)
      resp_data <= fill_buf_with_last();
  end

  // Fill buffer including the beat being received this cycle
  function automatic logic [LINE_W-1:0] fill_buf_with_last();
    logic [LINE_W-1:0] line;
    line = fill_buf;
    line[fill_beat*DATA_W +: DATA_W] = r_data;
    return line;
  endfunction

endmodule : dma_icache
