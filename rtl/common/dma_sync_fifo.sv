//==============================================================================
// dma_sync_fifo.sv
//------------------------------------------------------------------------------
// Single-clock first-word-fall-through FIFO.
//   * rd_data shows the head entry whenever empty == 0
//   * push while full / pop while empty are ignored (and flagged by SVA)
//   * flush empties the FIFO synchronously (has priority over push/pop)
//==============================================================================
module dma_sync_fifo #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 4                 // any value >= 1
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             flush,

  input  logic             push,
  input  logic [WIDTH-1:0] wr_data,
  input  logic             pop,
  output logic [WIDTH-1:0] rd_data,

  output logic             empty,
  output logic             full,
  output logic [$clog2(DEPTH+1)-1:0] count
);

  localparam int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int CNT_W = $clog2(DEPTH+1);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [PTR_W-1:0] wr_ptr, rd_ptr;

  logic do_push, do_pop;
  assign do_push = push && !full;
  assign do_pop  = pop  && !empty;

  assign empty   = (count == '0);
  assign full    = (count == CNT_W'(DEPTH));
  assign rd_data = mem[rd_ptr];

  function automatic logic [PTR_W-1:0] ptr_inc(input logic [PTR_W-1:0] p);
    return (p == PTR_W'(DEPTH - 1)) ? '0 : p + 1'b1;
  endfunction

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
      if (do_push) wr_ptr <= ptr_inc(wr_ptr);
      if (do_pop)  rd_ptr <= ptr_inc(rd_ptr);
      count <= count + do_push - do_pop;
    end
  end

  always_ff @(posedge clk) begin
    if (do_push && !flush) mem[wr_ptr] <= wr_data;
  end

endmodule : dma_sync_fifo
