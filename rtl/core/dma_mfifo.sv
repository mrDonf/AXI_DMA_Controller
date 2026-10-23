//==============================================================================
// dma_mfifo.sv
//------------------------------------------------------------------------------
// Per-channel MFIFO: a byte-stream buffer that decouples the read (load) side
// from the write (store) side of a channel.
//
// Bytes are stored in "stream order", independent of the AXI byte lanes they
// arrived on or will leave on. This is what lets a channel use different
// source/destination alignments, beat sizes and burst lengths.
//
// Organisation: NB = DATA_W/8 byte-wide banks ("lanes") x LINES rows.
// Stream byte position p lives in lane (p % NB), row (p / NB) % LINES.
//
//   push: up to NB bytes per cycle, packed at push_data[7:0] upward
//   pop : up to NB bytes per cycle, returned packed at pop_data[7:0] upward
//
// The caller guarantees push_n <= free space and pop_n <= count (checked by
// assertions); the data path reserves space before issuing any AXI read.
//==============================================================================
module dma_mfifo #(
  parameter int DATA_W = 64,
  parameter int LINES  = 32                       // power of two
) (
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       flush,

  input  logic                       push_en,
  input  logic [$clog2(DATA_W/8):0]  push_n,      // 0 .. NB bytes
  input  logic [DATA_W-1:0]          push_data,

  input  logic                       pop_en,
  input  logic [$clog2(DATA_W/8):0]  pop_n,
  output logic [DATA_W-1:0]          pop_data,

  output logic [$clog2(DATA_W/8*LINES):0] count   // bytes currently stored
);

  localparam int NB     = DATA_W / 8;
  localparam int LANE_W = $clog2(NB);
  localparam int ROW_W  = $clog2(LINES);
  localparam int PTR_W  = LANE_W + ROW_W;
  localparam int CNT_W  = PTR_W + 1;

  logic [7:0]       mem [NB][LINES];
  logic [PTR_W-1:0] wr_ptr, rd_ptr;

  // Split stream pointers into (row, lane offset)
  logic [LANE_W-1:0] wr_off, rd_off;
  logic [ROW_W-1:0]  wr_row, rd_row;
  assign wr_off = wr_ptr[LANE_W-1:0];
  assign wr_row = wr_ptr[PTR_W-1:LANE_W];
  assign rd_off = rd_ptr[LANE_W-1:0];
  assign rd_row = rd_ptr[PTR_W-1:LANE_W];

  //----------------------------------------------------------------------------
  // Write: input byte k goes to lane (wr_off + k) % NB. A lane below wr_off
  // belongs to the next row.
  //----------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (push_en && !flush) begin
      for (int lane = 0; lane < NB; lane++) begin
        logic [LANE_W-1:0] k;                       // stream index within push
        k = LANE_W'(lane) - wr_off;
        if ({1'b0, k} < push_n)
          mem[lane][(LANE_W'(lane) >= wr_off) ? wr_row : wr_row + 1'b1] <= push_data[k*8 +: 8];
      end
    end
  end

  //----------------------------------------------------------------------------
  // Read: fetch the next NB stream bytes (one per lane), then rotate so that
  // stream byte rd_ptr appears at pop_data[7:0].
  //----------------------------------------------------------------------------
  logic [7:0] lane_q [NB];

  always_comb begin
    for (int lane = 0; lane < NB; lane++)
      lane_q[lane] = mem[lane][(LANE_W'(lane) >= rd_off) ? rd_row : rd_row + 1'b1];

    for (int k = 0; k < NB; k++)
      pop_data[k*8 +: 8] = lane_q[LANE_W'(rd_off + LANE_W'(k))];
  end

  //----------------------------------------------------------------------------
  // Pointers and occupancy
  //----------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else if (flush) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else begin
      if (push_en) wr_ptr <= wr_ptr + PTR_W'(push_n);
      if (pop_en)  rd_ptr <= rd_ptr + PTR_W'(pop_n);
      count <= count + (push_en ? CNT_W'(push_n) : '0)
                     - (pop_en  ? CNT_W'(pop_n)  : '0);
    end
  end

endmodule : dma_mfifo
