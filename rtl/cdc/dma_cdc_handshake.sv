//==============================================================================
// dma_cdc_handshake.sv
//------------------------------------------------------------------------------
// Single-entry valid/ready channel between two asynchronous clock domains,
// using a 2-phase (toggle) request/acknowledge handshake.
//
//   src domain                         dst domain
//   ----------                         ----------
//   src_valid/src_ready  --data_q-->   dst_valid/dst_ready
//                 req_tgl --2FF-->  req_sync
//         ack_sync  <--2FF-- ack_tgl
//
// CDC argument:
//   * Only the toggle bits cross through synchronizers.
//   * data_q is a quasi-static bus: it is written only when the channel is
//     idle (src_ready = 1) and is sampled in the destination domain only after
//     req_tgl has propagated through the synchronizer, i.e. at least two
//     destination clocks after data_q became stable. It stays stable until the
//     destination acknowledges.
//
// Throughput: one transfer every ~2 src + 2 dst clocks. Intended for low-rate
// control traffic (register accesses, peripheral requests).
//==============================================================================
module dma_cdc_handshake #(
  parameter int WIDTH = 8
) (
  // Source domain
  input  logic             src_clk,
  input  logic             src_rst_n,
  input  logic             src_valid,
  output logic             src_ready,
  input  logic [WIDTH-1:0] src_data,

  // Destination domain
  input  logic             dst_clk,
  input  logic             dst_rst_n,
  output logic             dst_valid,
  input  logic             dst_ready,
  output logic [WIDTH-1:0] dst_data
);

  //----------------------------------------------------------------------------
  // Source domain
  //----------------------------------------------------------------------------
  logic             req_tgl;
  logic             ack_sync;
  logic [WIDTH-1:0] data_q;

  assign src_ready = (req_tgl == ack_sync);

  always_ff @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) begin
      req_tgl <= 1'b0;
      data_q  <= '0;
    end else if (src_valid && src_ready) begin
      data_q  <= src_data;
      req_tgl <= ~req_tgl;
    end
  end

  //----------------------------------------------------------------------------
  // Destination domain
  //----------------------------------------------------------------------------
  logic req_sync;
  logic ack_tgl;

  dma_sync_2ff #(.WIDTH(1)) u_req_sync (
    .clk   (dst_clk),
    .rst_n (dst_rst_n),
    .d     (req_tgl),
    .q     (req_sync)
  );

  assign dst_valid = (req_sync != ack_tgl);
  assign dst_data  = data_q;   // quasi-static, see header

  always_ff @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n)                  ack_tgl <= 1'b0;
    else if (dst_valid && dst_ready) ack_tgl <= ~ack_tgl;
  end

  //----------------------------------------------------------------------------
  // Acknowledge back to the source domain
  //----------------------------------------------------------------------------
  dma_sync_2ff #(.WIDTH(1)) u_ack_sync (
    .clk   (src_clk),
    .rst_n (src_rst_n),
    .d     (ack_tgl),
    .q     (ack_sync)
  );

endmodule : dma_cdc_handshake
