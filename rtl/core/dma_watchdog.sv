//==============================================================================
// dma_watchdog.sv
//------------------------------------------------------------------------------
// Channel lock-up watchdog.
//
// A channel is "active" while it has work in progress that depends only on the
// DMA and the bus: it is not stopped, not faulting and not legitimately
// waiting for an external event (DMAWFE / DMAWFP), or it still has AXI
// transactions queued or outstanding. While active, every sign of progress
// (an instruction retired, a status change, an AXI handshake with the
// channel's ID, an instruction-cache response) restarts its timer.
//
// The timer counts ticks of a shared prescaler (one tick = 256 clk) up to
// WD.timeout. Reaching it means the channel made no progress for the whole
// timeout, so it is reported once (even if progress resumes that very cycle):
//   lockup_set[ch]   : sets WDSTAT[ch] (sticky, write-1-to-clear)
//   lockup_fault[ch] : WD.irq_only = 0 -> the channel faults with lockup_err
// A new report needs progress or inactivity first. timeout = 0 disables it.
//==============================================================================
module dma_watchdog #(
  parameter int NUM_CH = 4
) (
  input  logic              clk,
  input  logic              rst_n,

  // Configuration (WD register)
  input  logic [15:0]       timeout,      // ticks of 256 clk, 0 = disabled
  input  logic              irq_only,     // 1: report only, do not abort

  // Per-channel activity
  input  logic [NUM_CH-1:0] active,
  input  logic [NUM_CH-1:0] progress,

  output logic [NUM_CH-1:0] lockup_set,
  output logic [NUM_CH-1:0] lockup_fault
);

  localparam int PRESCALE_W = 8;

  logic [PRESCALE_W-1:0] prescaler;
  logic                  tick;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                  prescaler <= '0;
    else if (timeout != 16'd0)   prescaler <= prescaler + 1'b1;
    else                         prescaler <= '0;
  end

  assign tick = (prescaler == '1);

  for (genvar ch = 0; ch < NUM_CH; ch++) begin : g_ch
    logic [15:0] count;
    logic        reported;
    logic        expired;

    assign expired = (timeout != 16'd0) && (count >= timeout) && !reported;
    // (timeout = 0 keeps count at 0, so the first term is what disables it)

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        count    <= '0;
        reported <= 1'b0;
      end else if (!active[ch] || progress[ch] || timeout == 16'd0) begin
        count    <= '0;
        reported <= 1'b0;
      end else begin
        if (tick && count < timeout) count <= count + 1'b1;
        if (expired)             reported <= 1'b1;
      end
    end

    assign lockup_set[ch]   = expired;
    assign lockup_fault[ch] = expired && !irq_only;
  end

endmodule : dma_watchdog
