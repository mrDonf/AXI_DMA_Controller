//==============================================================================
// dma_lpi_sva.sv
//------------------------------------------------------------------------------
// AMBA Q-Channel (LPI) protocol checks at the DMA boundary, plus the
// quiescence guarantee: while the request is accepted (qacceptn = 0) the DMA
// starts no bus or peripheral activity.
//   LPI_D_* : device (DMA) obligations
//   LPI_C_* : controller (testbench) obligations
//==============================================================================
module dma_lpi_sva (
  input logic clk,          // free-running reference clock
  input logic rst_n,
  input logic qreqn,
  input logic qacceptn,
  input logic qdeny,
  input logic qactive,
  input logic awvalid,
  input logic wvalid,
  input logic arvalid,
  input logic davalid,
  input logic irq_abort,
  input logic psel,
  input logic penable,
  input logic pready,
  input logic psel_ns,
  input logic penable_ns,
  input logic pready_ns
);

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // Device
  LPI_D_KNOWN:         assert property (!$isunknown({qacceptn, qdeny, qactive}));
  LPI_D_ACCEPT_OR_DENY:assert property (!(!qacceptn && qdeny));
  LPI_D_ACCEPT_ON_REQ: assert property ($fell(qacceptn) |-> !qreqn);
  LPI_D_DENY_ON_REQ:   assert property ($rose(qdeny)    |-> !qreqn);
  LPI_D_EXIT_ON_REQ:   assert property ($rose(qacceptn) |-> qreqn);
  LPI_D_DENY_RELEASE:  assert property ($fell(qdeny)    |-> qreqn);
  LPI_D_QUIESCENT:     assert property (!qacceptn |-> !awvalid && !wvalid && !arvalid && !davalid);
  // No register access completes while quiescent (it waits for the wake-up)
  LPI_D_APB_HELD:      assert property (!qacceptn |-> !(psel && penable && pready));
  LPI_D_APB_NS_HELD:   assert property (!qacceptn |-> !(psel_ns && penable_ns && pready_ns));

  // Controller: qreqn changes only after the device answered the previous step
  LPI_C_REQ_ONLY_RUN:  assert property ($fell(qreqn) |-> $past(qacceptn) && !$past(qdeny));
  LPI_C_EXIT_ANSWERED: assert property ($rose(qreqn) |-> $past(!qacceptn || qdeny));

  // Coverage
  LPI_C_ACCEPTED:      cover property ($fell(qacceptn));
  LPI_C_DENIED:        cover property ($rose(qdeny));
  LPI_C_WAKEUP:        cover property (!qacceptn && qactive);

endmodule : dma_lpi_sva
