//==============================================================================
// dma_qchannel.sv
//------------------------------------------------------------------------------
// AMBA Low Power Interface, Q-Channel device side (clk domain).
//
//   qreqn     in   quiescence request from the clock controller (active low,
//                  asynchronous: synchronized here)
//   qacceptn  out  0: request accepted, the DMA is quiescent (clk may stop)
//   qdeny     out  1: request denied, the DMA is busy
//   qactive   out  (generated at the top level) the DMA has, or is asked
//                  for, work: the controller should restore the clock
//
//   Q_RUN --qreqn=0, idle--> Q_STOPPED --qreqn=1--> Q_RUN
//     |
//     +---qreqn=0, busy--> Q_DENIED --qreqn=1--> Q_RUN
//
// In Q_STOPPED the core takes no new work: APB transfers are held with
// PREADY = 0 and peripheral requests with DRREADY = 0 until Q_RUN. 'idle'
// must cover every source of activity (threads, data path, caches, queues).
//
// Reset state is Q_RUN, so qreqn must be high while the DMA is in reset
// (tie qreqn high if the interface is not used).
//==============================================================================
module dma_qchannel (
  input  logic clk,
  input  logic rst_n,
  input  logic qreqn,          // asynchronous
  input  logic idle,           // the core is quiescent this cycle
  output logic qacceptn,
  output logic qdeny,
  output logic run             // 0 while quiescent: block new work
);

  typedef enum logic [1:0] {Q_RUN, Q_STOPPED, Q_DENIED} qstate_e;
  qstate_e state;
  logic    qreqn_s;

  dma_sync_2ff #(.RESET_VAL(1'b1)) u_qreqn_sync (
    .clk   (clk),
    .rst_n (rst_n),
    .d     (qreqn),
    .q     (qreqn_s)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= Q_RUN;
    end else begin
      case (state)
        Q_RUN:     if (!qreqn_s) state <= idle ? Q_STOPPED : Q_DENIED;
        Q_STOPPED: if (qreqn_s)  state <= Q_RUN;
        Q_DENIED:  if (qreqn_s)  state <= Q_RUN;
        default:                 state <= Q_RUN;
      endcase
    end
  end

  assign qacceptn = (state != Q_STOPPED);
  assign qdeny    = (state == Q_DENIED);
  assign run      = (state != Q_STOPPED);

endmodule : dma_qchannel
