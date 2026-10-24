//==============================================================================
// dma_ctrl_if.sv - side-band signals: interrupts (observed), boot pins, reset,
// and a Q-Channel clock controller model (clock gating of the DMA core clock)
//==============================================================================
interface dma_ctrl_if #(
  parameter int NUM_EVENTS = 16
) (
  input logic clk,
  input logic rst_n
);

  logic [NUM_EVENTS-1:0] irq;
  logic                  irq_abort;
  logic                  boot_from_pc;
  logic [31:0]           boot_addr;
  logic                  boot_manager_ns;
  logic [NUM_EVENTS-1:0] boot_irq_ns;       // CR3: events usable by non-secure threads
  logic [31:0]           boot_periph_ns;    // CR4: peripherals usable by non-secure threads
  logic                  sw_rst_n;          // test-controlled reset (ANDed into rst_n)

  // Q-Channel (controller side) and core clock enable
  logic                  qreqn;
  logic                  qacceptn;
  logic                  qdeny;
  logic                  qactive;
  logic                  clk_en;            // 0: DMA core clock gated

  initial begin
    boot_from_pc    = 1'b0;
    boot_addr       = '0;
    boot_manager_ns = 1'b0;
    boot_irq_ns     = '1;                   // default: every event / peripheral
    boot_periph_ns  = '1;                   // usable by both worlds
    sw_rst_n        = 1'b1;
    qreqn           = 1'b1;
    clk_en          = 1'b1;
  end

  // Request quiescence; returns 1 if accepted, 0 if denied
  task automatic q_request(output bit accepted);
    @(posedge clk);
    qreqn = 1'b0;
    wait (qacceptn === 1'b0 || qdeny === 1'b1);
    accepted = (qacceptn === 1'b0);
  endtask

  // Leave Q_STOPPED / Q_DENIED (restores the clock first)
  task automatic q_release();
    clk_en = 1'b1;
    repeat (2) @(posedge clk);
    qreqn = 1'b1;
    wait (qacceptn === 1'b1 && qdeny === 1'b0);
  endtask

  // Gate / ungate the DMA core clock (only legal while Q_STOPPED)
  task automatic gate_clock();
    @(negedge clk);
    clk_en = 1'b0;
  endtask

  // Pulse the system reset for 'n' core clocks
  task automatic pulse_reset(int unsigned n);
    @(posedge clk);
    #1 sw_rst_n = 1'b0;
    repeat (n) @(posedge clk);
    #1 sw_rst_n = 1'b1;
  endtask

  // Wait for 'n' core clocks
  task automatic wait_clks(int unsigned n);
    repeat (n) @(posedge clk);
  endtask

endinterface : dma_ctrl_if
