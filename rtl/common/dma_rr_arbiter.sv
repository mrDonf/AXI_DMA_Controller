//==============================================================================
// dma_rr_arbiter.sv
//------------------------------------------------------------------------------
// Combinational round-robin arbiter with registered priority pointer.
//   * gnt is one-hot (or zero when no request)
//   * the pointer moves past the granted requester only when 'advance' is set,
//     so a grant that is not consumed keeps its priority.
//==============================================================================
module dma_rr_arbiter #(
  parameter int N = 4
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic [N-1:0]         req,
  input  logic                 advance,     // the current grant was consumed
  output logic [N-1:0]         gnt,
  output logic [$clog2(N > 1 ? N : 2)-1:0] gnt_idx,
  output logic                 gnt_valid
);

  localparam int IDX_W = $clog2(N > 1 ? N : 2);

  logic [IDX_W-1:0] prio;   // highest-priority requester index

  always_comb begin
    gnt       = '0;
    gnt_idx   = '0;
    gnt_valid = 1'b0;
    // Search N positions starting at 'prio'
    for (int k = 0; k < N; k++) begin
      int idx;
      idx = (int'(prio) + k) % N;
      if (!gnt_valid && req[idx]) begin
        gnt_valid    = 1'b1;
        gnt_idx      = IDX_W'(idx);
        gnt[idx]     = 1'b1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      prio <= '0;
    else if (advance && gnt_valid)
      prio <= (int'(gnt_idx) == N - 1) ? '0 : gnt_idx + 1'b1;
  end

endmodule : dma_rr_arbiter
