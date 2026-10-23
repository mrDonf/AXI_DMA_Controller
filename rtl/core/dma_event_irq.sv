//==============================================================================
// dma_event_irq.sv
//------------------------------------------------------------------------------
// Event / interrupt unit.
//
// Each event number e has one flag (visible as INT_EVENT_RIS[e]):
//   * DMASEV e sets the flag.
//   * INTEN[e] = 1 : the flag is an interrupt  -> irq[e]; cleared by INTCLR.
//   * INTEN[e] = 0 : the flag is an event      -> a thread waiting in DMAWFE e
//                    resumes and the flag is cleared. All threads waiting on
//                    the same event in that cycle resume together.
//==============================================================================
module dma_event_irq #(
  parameter int NUM_EVENTS  = 16,
  parameter int NUM_THREADS = 5
) (
  input  logic                   clk,
  input  logic                   rst_n,

  // Thread side
  input  logic [NUM_THREADS-1:0] sev_valid,
  input  logic [4:0]             sev_event [NUM_THREADS],
  input  logic [NUM_THREADS-1:0] wfe_valid,
  input  logic [4:0]             wfe_event [NUM_THREADS],
  output logic [NUM_THREADS-1:0] wfe_hit,

  // Debug DMASEV issued to a channel thread
  input  logic                   dbg_sev_valid,
  input  logic [4:0]             dbg_sev_event,

  // Register interface
  input  logic [NUM_EVENTS-1:0]  inten,
  input  logic                   intclr_we,
  input  logic [NUM_EVENTS-1:0]  intclr_mask,
  output logic [NUM_EVENTS-1:0]  ev_flag,      // INT_EVENT_RIS
  output logic [NUM_EVENTS-1:0]  irq
);

  logic [NUM_EVENTS-1:0] set_mask, clr_mask;

  always_comb begin
    set_mask = '0;
    clr_mask = '0;
    wfe_hit  = '0;

    for (int t = 0; t < NUM_THREADS; t++) begin
      if (sev_valid[t] && int'(sev_event[t]) < NUM_EVENTS)
        set_mask[sev_event[t]] = 1'b1;

      if (wfe_valid[t] && int'(wfe_event[t]) < NUM_EVENTS &&
          ev_flag[wfe_event[t]] && !inten[wfe_event[t]]) begin
        wfe_hit[t]             = 1'b1;
        clr_mask[wfe_event[t]] = 1'b1;
      end
    end

    if (dbg_sev_valid && int'(dbg_sev_event) < NUM_EVENTS)
      set_mask[dbg_sev_event] = 1'b1;

    if (intclr_we)
      clr_mask |= intclr_mask & inten;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ev_flag <= '0;
    else        ev_flag <= (ev_flag & ~clr_mask) | set_mask;   // set wins
  end

  assign irq = ev_flag & inten;

endmodule : dma_event_irq
