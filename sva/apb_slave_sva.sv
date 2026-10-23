//==============================================================================
// apb_slave_sva.sv
//------------------------------------------------------------------------------
// APB protocol assertions at the DMA's APB slave port.
//   APB_M_* : requester (master) obligations
//   APB_S_* : completer (DMA) obligations
//==============================================================================
module apb_slave_sva #(
  parameter int ADDR_W      = 12,
  parameter int DATA_W      = 32,
  parameter int MAX_WAIT    = 256,       // bound for PREADY (async bridge)
  parameter bit SLVERR_EN   = 1'b0       // DUT built with APB_SLVERR = 1
) (
  input logic              pclk,
  input logic              presetn,
  input logic              psel,
  input logic              penable,
  input logic              pwrite,
  input logic [ADDR_W-1:0] paddr,
  input logic [DATA_W-1:0] pwdata,
  input logic              pready,
  input logic [DATA_W-1:0] prdata,
  input logic              pslverr
);

  default clocking cb @(posedge pclk); endclocking
  default disable iff (!presetn);

  // SETUP phase is always followed by ACCESS
  APB_M_SETUP_TO_ACCESS: assert property (psel && !penable |=> psel && penable);

  // PENABLE only together with PSEL
  APB_M_ENABLE_NEEDS_SEL: assert property (penable |-> psel);

  // Control/data stable from SETUP until the transfer completes
  APB_M_STABLE: assert property (
      psel && !(penable && pready) |=> $stable({pwrite, paddr, pwdata}));

  // PENABLE de-asserted after the transfer completes
  APB_M_ENABLE_DROP: assert property (psel && penable && pready |=> !penable);

  // Completer answers in bounded time
  APB_S_READY_BOUNDED: assert property (
      psel && !penable |-> ##[1:MAX_WAIT] pready);

  // Read data must be known when returned
  APB_S_RDATA_KNOWN: assert property (
      psel && penable && pready && !pwrite |-> !$isunknown(prdata));

  // PSLVERR is only meaningful in the completing cycle; without APB_SLVERR
  // the DMA never reports errors (DMA-330 behaviour)
  if (!SLVERR_EN) begin : g_no_slverr
    APB_S_NO_SLVERR: assert property (psel && penable && pready |-> !pslverr);
  end else begin : g_slverr
    APB_S_SLVERR_IN_ACCESS: assert property (pslverr |-> psel && penable);
    APB_C_SLVERR:           cover property (psel && penable && pready && pslverr);
  end

  APB_C_WAIT_STATE: cover property (psel && penable && !pready);

endmodule : apb_slave_sva
