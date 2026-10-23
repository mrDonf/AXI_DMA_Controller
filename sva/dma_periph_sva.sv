//==============================================================================
// dma_periph_sva.sv
//------------------------------------------------------------------------------
// Peripheral request interface (DMA-330 style dr/da handshakes), checked in
// the peripheral clock domain.
//==============================================================================
module dma_periph_sva (
  input logic       clk,
  input logic       rst_n,
  input logic       drvalid,
  input logic       drready,
  input logic [1:0] drtype,
  input logic       drlast,
  input logic       davalid,
  input logic       daready,
  input logic [1:0] datype
);

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // Peripheral side: request held until accepted
  PER_M_DR_STABLE: assert property (
      drvalid && !drready |=> drvalid && $stable({drtype, drlast}));
  PER_M_DR_TYPE:   assert property (drvalid |-> drtype != 2'b11);

  // DMA side: acknowledge held until accepted, legal encoding
  PER_S_DA_STABLE: assert property (
      davalid && !daready |=> davalid && $stable(datype));
  PER_S_DA_TYPE:   assert property (davalid |-> datype != 2'b11);
  PER_S_DA_KNOWN:  assert property (!$isunknown({davalid, drready}));

  PER_C_FLUSH:     cover property (davalid && daready && datype == 2'b10);
  PER_C_BURST_ACK: cover property (davalid && daready && datype == 2'b01);
  PER_C_SINGLE_ACK:cover property (davalid && daready && datype == 2'b00);

endmodule : dma_periph_sva
