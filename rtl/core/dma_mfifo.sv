//==============================================================================
// dma_mfifo.sv
//------------------------------------------------------------------------------
// Shared MFIFO: one pool of LINES lines of NB = DATA_W/8 bytes that the
// channels take line by line while they run (dynamic allocation, as in
// DMA-330). A channel alone can use the whole pool.
//
// Each channel still sees a byte stream: bytes are stored in "stream order",
// independent of the AXI byte lanes they arrived on or will leave on. Stream
// byte p of a channel lives in lane (p % NB) of the (p / NB)-th line of the
// channel's line list. The list is linked through the pool:
//
//   hd[c]  : line holding the next byte to pop        nxt[l] : line after l
//   tl[c]  : line holding the last pushed byte        own[l] : line l in use
//
//   push : a push that starts a new line (write offset 0) or spills over the
//          end of the tail line takes the lowest free line and appends it to
//          the list. A push of at most NB bytes never needs two new lines.
//   pop  : a pop that consumes the last byte of the head line returns that
//          line to the pool (pop_frees).
//   flush: every line of the channel returns to the pool and its offsets
//          restart at 0.
//
// The pool never refuses a push: the data path admits a DMALD only after
// reserving the lines its bytes will need (dma_datapath), so a free line
// exists whenever a push asks for one (checked by assertion).
//
// One push (R channel) and one pop (W channel) per cycle, for any channels.
// pop_data always shows the next NB bytes of channel pop_ch (pop_en or not).
//==============================================================================
module dma_mfifo #(
  parameter int NUM_CH = 4,
  parameter int DATA_W = 64,
  parameter int LINES  = 128                      // >= 32, any value
) (
  input  logic                                 clk,
  input  logic                                 rst_n,
  input  logic [NUM_CH-1:0]                    flush,

  input  logic                                 push_en,
  input  logic [$clog2(NUM_CH > 1 ? NUM_CH : 2)-1:0] push_ch,
  input  logic [$clog2(DATA_W/8):0]            push_n,      // 1 .. NB bytes
  input  logic [DATA_W-1:0]                    push_data,   // packed at [7:0] upward

  input  logic                                 pop_en,
  input  logic [$clog2(NUM_CH > 1 ? NUM_CH : 2)-1:0] pop_ch,
  input  logic [$clog2(DATA_W/8):0]            pop_n,
  output logic [DATA_W-1:0]                    pop_data,    // packed at [7:0] upward
  output logic                                 pop_frees,   // this pop releases a line

  output logic [$clog2(DATA_W/8*LINES):0]      count  [NUM_CH],  // bytes stored
  output logic [$clog2(LINES+1)-1:0]           nlines [NUM_CH]   // lines in use
);

  localparam int NB     = DATA_W / 8;
  localparam int LANE_W = $clog2(NB);
  localparam int CH_W   = $clog2(NUM_CH > 1 ? NUM_CH : 2);
  localparam int LIDX_W = $clog2(LINES);
  localparam int LCNT_W = $clog2(LINES + 1);
  localparam int CNT_W  = $clog2(NB * LINES) + 1;

  logic [7:0]        mem [NB][LINES];
  logic [LINES-1:0]  own;
  logic [CH_W-1:0]   own_ch [LINES];
  logic [LIDX_W-1:0] nxt    [LINES];

  logic [LIDX_W-1:0] hd [NUM_CH], tl [NUM_CH];
  logic [LANE_W-1:0] wr_off [NUM_CH], rd_off [NUM_CH];

  //----------------------------------------------------------------------------
  // Free line: lowest index not in use
  //----------------------------------------------------------------------------
  logic [LIDX_W-1:0] free_idx;
  logic              free_any;

  always_comb begin
    free_idx = '0;
    free_any = 1'b0;
    for (int l = LINES - 1; l >= 0; l--) begin
      if (!own[l]) begin
        free_idx = LIDX_W'(l);
        free_any = 1'b1;
      end
    end
  end

  //----------------------------------------------------------------------------
  // Push: lanes at or above the write offset belong to the current line
  // (line0), lanes below it to the next one (line1). line0 is a new line when
  // the offset is 0 (the tail line is full or there is none).
  //----------------------------------------------------------------------------
  logic              do_push, alloc;
  logic [LANE_W-1:0] p_off;
  logic [LIDX_W-1:0] p_line0, p_line1;

  assign do_push = push_en && !flush[push_ch];
  assign p_off   = wr_off[push_ch];
  assign alloc   = do_push && ((p_off == '0) || (int'(p_off) + int'(push_n) > NB));
  assign p_line0 = (p_off == '0) ? free_idx : tl[push_ch];
  assign p_line1 = free_idx;

  always_ff @(posedge clk) begin
    if (do_push) begin
      for (int lane = 0; lane < NB; lane++) begin
        logic [LANE_W-1:0] k;                       // stream index within push
        k = LANE_W'(lane) - p_off;
        if ({1'b0, k} < push_n)
          mem[lane][(LANE_W'(lane) >= p_off) ? p_line0 : p_line1] <= push_data[k*8 +: 8];
      end
    end
  end

  //----------------------------------------------------------------------------
  // Pop: fetch the next NB stream bytes (one per lane) from the head line and
  // the line after it, then rotate so that the next stream byte appears at
  // pop_data[7:0]. Lanes beyond the bytes present are don't-care.
  //----------------------------------------------------------------------------
  logic              do_pop;
  logic [LANE_W-1:0] q_off;
  logic [LIDX_W-1:0] q_line0, q_line1;
  logic [7:0]        lane_q [NB];

  assign do_pop    = pop_en && !flush[pop_ch];
  assign q_off     = rd_off[pop_ch];
  assign q_line0   = hd[pop_ch];
  assign q_line1   = nxt[hd[pop_ch]];
  assign pop_frees = do_pop && (int'(q_off) + int'(pop_n) >= NB);

  always_comb begin
    for (int lane = 0; lane < NB; lane++)
      lane_q[lane] = mem[lane][(LANE_W'(lane) >= q_off) ? q_line0 : q_line1];

    for (int k = 0; k < NB; k++)
      pop_data[k*8 +: 8] = lane_q[LANE_W'(q_off + LANE_W'(k))];
  end

  //----------------------------------------------------------------------------
  // Pool and per-channel list state
  //----------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      own <= '0;
      for (int l = 0; l < LINES; l++) begin
        own_ch[l] <= '0;
        nxt[l]    <= '0;
      end
      for (int c = 0; c < NUM_CH; c++) begin
        hd[c]     <= '0;
        tl[c]     <= '0;
        nlines[c] <= '0;
        wr_off[c] <= '0;
        rd_off[c] <= '0;
        count[c]  <= '0;
      end
    end else begin
      // Lines return to the pool on flush and when fully popped; a push takes
      // a line that is free now, so it never collides with a line being freed
      for (int l = 0; l < LINES; l++)
        if (own[l] && flush[own_ch[l]]) own[l] <= 1'b0;
      if (pop_frees) own[hd[pop_ch]] <= 1'b0;
      if (alloc) begin
        own[free_idx]    <= 1'b1;
        own_ch[free_idx] <= push_ch;
        if (nlines[push_ch] != '0) nxt[tl[push_ch]] <= free_idx;
      end

      for (int c = 0; c < NUM_CH; c++) begin
        logic pu, po, al, fr;
        pu = do_push   && (push_ch == CH_W'(c));
        po = do_pop    && (pop_ch  == CH_W'(c));
        al = alloc     && (push_ch == CH_W'(c));
        fr = pop_frees && (pop_ch  == CH_W'(c));

        if (flush[c]) begin
          nlines[c] <= '0;
          wr_off[c] <= '0;
          rd_off[c] <= '0;
          count[c]  <= '0;
        end else begin
          if (pu) wr_off[c] <= wr_off[c] + LANE_W'(push_n);
          if (po) rd_off[c] <= rd_off[c] + LANE_W'(pop_n);
          count[c]  <= count[c] + (pu ? CNT_W'(push_n) : '0) - (po ? CNT_W'(pop_n) : '0);
          nlines[c] <= nlines[c] + LCNT_W'(al) - LCNT_W'(fr);
          if (al) tl[c] <= free_idx;
          // The new line becomes the head when the list is (or becomes) empty
          if (al && (nlines[c] == '0 || (fr && nlines[c] == LCNT_W'(1))))
            hd[c] <= free_idx;
          else if (fr)
            hd[c] <= nxt[hd[c]];
        end
      end
    end
  end

endmodule : dma_mfifo
