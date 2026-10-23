//==============================================================================
// dma_async_fifo.sv
//------------------------------------------------------------------------------
// Dual-clock FIFO with gray-coded pointers (Cummings style), valid/ready
// interface on both sides, first-word-fall-through read port.
//
//   * Depth = 2**ADDR_W entries (ADDR_W >= 2)
//   * Pointers are ADDR_W+1 bits (extra wrap bit), exchanged in gray code
//     through 2-flop synchronizers -> only one bit changes per clock.
//   * full/empty are pessimistic: a pointer update is seen by the other side
//     two clocks late, which can only delay a push/pop, never corrupt data.
//   * The storage array is written in the write domain and read
//     (combinationally) in the read domain; an entry is never read until its
//     write pointer increment has been synchronized, so the read is safe.
//==============================================================================
module dma_async_fifo #(
  parameter int WIDTH  = 32,
  parameter int ADDR_W = 3
) (
  // Write side
  input  logic             wr_clk,
  input  logic             wr_rst_n,
  input  logic             wr_valid,
  output logic             wr_ready,
  input  logic [WIDTH-1:0] wr_data,

  // Read side
  input  logic             rd_clk,
  input  logic             rd_rst_n,
  output logic             rd_valid,
  input  logic             rd_ready,
  output logic [WIDTH-1:0] rd_data
);

  localparam int DEPTH = 1 << ADDR_W;
  localparam int PTR_W = ADDR_W + 1;

  function automatic logic [PTR_W-1:0] bin2gray(input logic [PTR_W-1:0] b);
    return b ^ (b >> 1);
  endfunction

  logic [WIDTH-1:0] mem [DEPTH];

  // Write-domain state
  logic [PTR_W-1:0] wbin, wgray, wbin_nxt, wgray_nxt;
  logic [PTR_W-1:0] rgray_wsync;            // read pointer seen in wr domain
  logic             wfull;
  logic             wr_fire;

  // Read-domain state
  logic [PTR_W-1:0] rbin, rgray, rbin_nxt, rgray_nxt;
  logic [PTR_W-1:0] wgray_rsync;            // write pointer seen in rd domain
  logic             rempty;
  logic             rd_fire;

  //----------------------------------------------------------------------------
  // Write domain
  //----------------------------------------------------------------------------

  assign wr_ready  = !wfull;
  assign wr_fire   = wr_valid && !wfull;
  assign wbin_nxt  = wbin + PTR_W'(wr_fire);
  assign wgray_nxt = bin2gray(wbin_nxt);

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wbin  <= '0;
      wgray <= '0;
      wfull <= 1'b0;
    end else begin
      wbin  <= wbin_nxt;
      wgray <= wgray_nxt;
      // Full: next write pointer equals read pointer with the two MSBs inverted
      wfull <= (wgray_nxt == {~rgray_wsync[PTR_W-1 -: 2], rgray_wsync[PTR_W-3:0]});
    end
  end

  always_ff @(posedge wr_clk) begin
    if (wr_fire) mem[wbin[ADDR_W-1:0]] <= wr_data;
  end

  dma_sync_2ff #(.WIDTH(PTR_W)) u_rptr_sync (
    .clk   (wr_clk),
    .rst_n (wr_rst_n),
    .d     (rgray),
    .q     (rgray_wsync)
  );

  //----------------------------------------------------------------------------
  // Read domain
  //----------------------------------------------------------------------------
  assign rd_valid  = !rempty;
  assign rd_fire   = rd_ready && !rempty;
  assign rbin_nxt  = rbin + PTR_W'(rd_fire);
  assign rgray_nxt = bin2gray(rbin_nxt);
  assign rd_data   = mem[rbin[ADDR_W-1:0]];

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rbin   <= '0;
      rgray  <= '0;
      rempty <= 1'b1;
    end else begin
      rbin   <= rbin_nxt;
      rgray  <= rgray_nxt;
      rempty <= (rgray_nxt == wgray_rsync);
    end
  end

  dma_sync_2ff #(.WIDTH(PTR_W)) u_wptr_sync (
    .clk   (rd_clk),
    .rst_n (rd_rst_n),
    .d     (wgray),
    .q     (wgray_rsync)
  );

endmodule : dma_async_fifo
