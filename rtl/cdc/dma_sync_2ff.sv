//==============================================================================
// dma_sync_2ff.sv
//------------------------------------------------------------------------------
// Multi-stage flip-flop synchronizer for single-bit (or gray-coded / otherwise
// glitch-free) signals crossing into the 'clk' domain.
//
// CDC rule: every bit of 'd' must be independent, OR 'd' must be gray-coded so
// that at most one bit changes per source clock. Never use it for plain
// binary buses.
//==============================================================================
module dma_sync_2ff #(
  parameter int   WIDTH     = 1,
  parameter int   STAGES    = 2,
  parameter logic RESET_VAL = 1'b0
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [WIDTH-1:0] d,      // asynchronous input
  output logic [WIDTH-1:0] q       // synchronized output
);

  // Synthesis attribute hint for implementation tools (keeps flops adjacent).
  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] sync_q [STAGES];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < STAGES; s++) sync_q[s] <= {WIDTH{RESET_VAL}};
    end else begin
      sync_q[0] <= d;
      for (int s = 1; s < STAGES; s++) sync_q[s] <= sync_q[s-1];
    end
  end

  assign q = sync_q[STAGES-1];

endmodule : dma_sync_2ff
