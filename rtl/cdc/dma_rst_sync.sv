//==============================================================================
// dma_rst_sync.sv
//------------------------------------------------------------------------------
// Reset synchronizer: asynchronous assertion, synchronous de-assertion.
// One instance per clock domain.
//==============================================================================
module dma_rst_sync #(
  parameter int STAGES = 2
) (
  input  logic clk,
  input  logic arst_n,     // asynchronous reset input (active low)
  output logic rst_n       // reset for the 'clk' domain
);

  (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q;

  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) sync_q <= '0;
    else         sync_q <= {sync_q[STAGES-2:0], 1'b1};
  end

  assign rst_n = sync_q[STAGES-1];

endmodule : dma_rst_sync
