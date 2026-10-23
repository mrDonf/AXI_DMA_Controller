//==============================================================================
// dma_periph_sync.sv
//------------------------------------------------------------------------------
// Clock-domain crossing for one DMA-330 style peripheral request interface.
//
//   peripheral (periph_clk)                     DMA core (clk)
//   drvalid/drtype/drlast/drready  ==CDC==>  dr_valid/dr_type/dr_last/dr_ready
//   davalid/datype/daready         <==CDC==  da_valid/da_type/da_ready
//
// Both directions are valid/ready streams carried by a toggle handshake. The
// request direction buffers one request inside the synchronizer, which is
// harmless: the peripheral protocol is already flow-controlled by drready.
//==============================================================================
module dma_periph_sync (
  // Peripheral clock domain
  input  logic       periph_clk,
  input  logic       periph_rst_n,
  input  logic       drvalid,
  output logic       drready,
  input  logic [1:0] drtype,
  input  logic       drlast,
  output logic       davalid,
  input  logic       daready,
  output logic [1:0] datype,

  // DMA core clock domain
  input  logic       clk,
  input  logic       rst_n,
  output logic       dr_valid,
  input  logic       dr_ready,
  output logic [1:0] dr_type,
  output logic       dr_last,
  input  logic       da_valid,
  output logic       da_ready,
  input  logic [1:0] da_type
);

  // Request: peripheral -> core
  dma_cdc_handshake #(.WIDTH(3)) u_dr_cdc (
    .src_clk   (periph_clk),
    .src_rst_n (periph_rst_n),
    .src_valid (drvalid),
    .src_ready (drready),
    .src_data  ({drtype, drlast}),
    .dst_clk   (clk),
    .dst_rst_n (rst_n),
    .dst_valid (dr_valid),
    .dst_ready (dr_ready),
    .dst_data  ({dr_type, dr_last})
  );

  // Acknowledge: core -> peripheral
  dma_cdc_handshake #(.WIDTH(2)) u_da_cdc (
    .src_clk   (clk),
    .src_rst_n (rst_n),
    .src_valid (da_valid),
    .src_ready (da_ready),
    .src_data  (da_type),
    .dst_clk   (periph_clk),
    .dst_rst_n (periph_rst_n),
    .dst_valid (davalid),
    .dst_ready (daready),
    .dst_data  (datype)
  );

endmodule : dma_periph_sync
