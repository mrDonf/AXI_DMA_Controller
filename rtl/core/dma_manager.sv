//==============================================================================
// dma_manager.sv
//------------------------------------------------------------------------------
// DMA manager thread.
//
// Executes the manager subset of the ISA: DMAGO, DMASEV, DMAWFE, DMAEND,
// DMAKILL, DMANOP (DMAFLUSHP is a channel-only instruction: undefined here).
// It runs either
//   * a program from memory (boot_from_pc at reset), or
//   * single instructions written through the debug registers
//     (DBGINST0/1 + DBGCMD) - the usual way a driver starts channels.
//
//   BOOT --boot_from_pc--> FETCH --> EXEC --> UPDATING_PC --> FETCH
//     +--> STOPPED                    +--> WFE --event--> UPDATING_PC
//   EXEC --DMAEND/DMAKILL--> STOPPED
//   STOPPED/WFE --debug instruction--> EXEC --debug done--> STOPPED/WFE
//   any fault --> FAULTING --debug DMAKILL--> STOPPED
//
// Debug instructions (DMAGO, DMASEV, DMAKILL) can interrupt program fetch,
// including stalled refills (TRM 2.5.1). Non-kill commands resume the same PC
// or event wait; DMAKILL stops the manager and cancels stale fetch delivery.
// DMAGO on a channel that is not stopped is ignored by the channel (NOP), as
// in DMA-330. A non-secure manager cannot start a secure channel (dmago_err)
// and cannot use a secure event in DMASEV / DMAWFE (mgr_evnt_err). A channel
// or event number the configuration does not have is an invalid operand.
//==============================================================================
module dma_manager
  import dma330_pkg::*;
#(
  parameter int NUM_CH     = 4,
  parameter int NUM_PERIPH = 4,
  parameter int NUM_EVENTS = 16,
  parameter int LINE_BYTES = 32
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // Boot configuration (static, sampled once after reset)
  input  logic                    boot_from_pc,
  input  logic [ADDR_W-1:0]       boot_addr,
  input  logic                    boot_manager_ns,

  // Security of each event / peripheral (1: non-secure), CR3 / CR4
  input  logic [NUM_EVENTS-1:0]   irq_ns,
  input  logic [NUM_PERIPH-1:0]   periph_ns,

  // Instruction cache
  input  logic                    ic_inv,
  output logic                    ic_inv_req,
  output logic                    ic_req,
  output logic [ADDR_W-1:0]       ic_addr,
  output logic                    ic_ns,
  input  logic                    ic_resp_valid,
  input  logic [LINE_BYTES*8-1:0] ic_resp_data,
  input  logic                    ic_resp_err,
  input  logic                    ic_resp_retry,
  input  logic                    ic_refill,

  // Channel start
  output logic [NUM_CH-1:0]       go_valid,
  output logic [ADDR_W-1:0]       go_pc,
  output logic                    go_ns,

  // Events
  output logic                    sev_valid,
  output logic [4:0]              sev_event,
  output logic                    wfe_valid,
  output logic [4:0]              wfe_event,
  input  logic                    wfe_hit,

  // Peripheral flush
  output logic                    flush_valid,
  output logic [4:0]              flush_periph,
  input  logic                    flush_ready,

  // Debug instruction
  input  logic                    dbg_valid,
  input  logic [INSN_W-1:0]       dbg_insn,
  output logic                    dbg_done,

  // Status
  output logic [31:0]             dsr,
  output logic [31:0]             dpc,
  output logic [31:0]             ftrd,
  output logic                    faulting
);

  typedef enum logic [2:0] {
    M_BOOT, M_STOPPED, M_FETCH, M_EXEC, M_WFE, M_FAULTING, M_UPDATING_PC
  } mstate_e;

  mstate_e           state;
  logic [ADDR_W-1:0] pc;
  logic              mgr_ns;       // manager security state
  logic              dbg_mode;     // executing a debug instruction
  logic              dbg_ret_wfe;  // ... taken while waiting for an event
  logic              dbg_ret_fetch;
  logic [INSN_W-1:0] dbg_insn_q;
  logic [4:0]        wake_num;

  //============================================================================
  // Instruction fetch
  //============================================================================
  logic              insn_valid, fetch_err;
  logic [INSN_W-1:0] fetch_insn;
  logic [ADDR_W-1:0] fetch_pc;

  assign ic_ns = mgr_ns;

  dma_fetch_unit #(.LINE_BYTES(LINE_BYTES)) u_fetch (
    .clk           (clk),
    .rst_n         (rst_n),
    .fetch_req     ((state == M_FETCH) || (state == M_UPDATING_PC)),
    .pc            (fetch_pc),
    .inv           (ic_inv),
    .insn_valid    (insn_valid),
    .insn          (fetch_insn),
    .fetch_err     (fetch_err),
    .miss          (), // front-end pending is not architectural Cache miss
    .fast_hit      (), // manager timing is unchanged
    .ic_req        (ic_req),
    .ic_addr       (ic_addr),
    .ic_resp_valid (ic_resp_valid),
    .ic_resp_data  (ic_resp_data),
    .ic_resp_err   (ic_resp_err),
    .ic_resp_retry (ic_resp_retry)
  );

  //============================================================================
  // Decode
  //============================================================================
  logic [INSN_W-1:0] insn;
  insn_e             cls;
  logic [7:0]        op, b1;
  logic [4:0]        num5;
  logic [2:0]        go_ch;

  assign insn  = dbg_mode ? dbg_insn_q : fetch_insn;
  assign op    = insn[7:0];
  assign b1    = insn[15:8];
  assign num5  = b1[7:3];
  assign go_ch = b1[2:0];
  assign cls   = decode_op(op);
  // Overlap PC calculation with the next fetch; debug instructions leave
  // the program PC untouched and never enter M_UPDATING_PC.
  assign fetch_pc = (state == M_UPDATING_PC) ? pc + ADDR_W'(insn_len(op)) : pc;

  logic [31:0] exec_fault;
  logic [31:0] irq_ns32, periph_ns32;

  assign irq_ns32    = 32'(irq_ns);
  assign periph_ns32 = 32'(periph_ns);

  always_comb begin
    exec_fault = '0;
    case (cls)
      I_GO: begin
        exec_fault[FTD_OPERAND_INVALID] = (int'(go_ch) >= NUM_CH);
        exec_fault[FTD_DMAGO_ERR]       = mgr_ns && !op[1];   // NS mgr -> secure ch
      end
      I_SEV, I_WFE: begin
        exec_fault[FTD_OPERAND_INVALID] = (int'(num5) >= NUM_EVENTS);
        exec_fault[FTD_MGR_EVNT_ERR]    = (int'(num5) < NUM_EVENTS) &&
                                          mgr_ns && !irq_ns32[num5];
      end
      I_END, I_KILL, I_NOP: ;
      default:
        exec_fault[FTD_UNDEF_INSTR]     = 1'b1;
    endcase
    // Only DMAGO, DMASEV, DMAKILL (and DMANOP) may be issued by the debugger
    if (dbg_mode && !(cls inside {I_GO, I_SEV, I_KILL, I_NOP})) begin
      exec_fault[FTD_UNDEF_INSTR] = 1'b1;
    end
    if (dbg_mode && exec_fault != '0)
      exec_fault[FTD_DBG_INSTR] = 1'b1;
  end

  //============================================================================
  // Outputs
  //============================================================================
  logic in_exec_ok;
  assign in_exec_ok = (state == M_EXEC) && (exec_fault == '0);

  always_comb begin
    go_valid = '0;
    if (in_exec_ok && cls == I_GO) go_valid[go_ch] = 1'b1;
  end
  assign go_pc        = insn[47:16];
  assign go_ns        = op[1];

  assign sev_valid    = in_exec_ok && (cls == I_SEV);
  assign sev_event    = num5;
  assign wfe_valid    = (state == M_WFE);
  assign wfe_event    = wake_num;
  assign flush_valid  = 1'b0;                     // DMAFLUSHP is channel only
  assign flush_periph = num5;

  // Only this manager's entries are maintained here. Channel start/end/kill
  // maintenance is generated by the target channel.
  assign ic_inv_req   = (in_exec_ok && ((cls inside {I_END, I_KILL}) ||
                                      (cls == I_WFE && b1[1]))) ||
                        (state == M_FAULTING && dbg_valid &&
                         decode_op(dbg_insn[7:0]) == I_KILL);

  // Every manager instruction completes in the cycle it executes (the debug
  // instruction is retired then)
  assign dbg_done = (dbg_mode && state == M_EXEC) ||
                    (state == M_FAULTING && dbg_valid);

  //============================================================================
  // State machine
  //============================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= M_BOOT;
      pc         <= '0;
      mgr_ns     <= 1'b0;
      dbg_mode   <= 1'b0;
      dbg_ret_wfe <= 1'b0;
      dbg_ret_fetch <= 1'b0;
      dbg_insn_q <= '0;
      wake_num   <= '0;
      ftrd       <= '0;
    end else begin
      case (state)
        M_BOOT: begin
          mgr_ns <= boot_manager_ns;
          pc     <= boot_addr;
          state  <= boot_from_pc ? M_FETCH : M_STOPPED;
        end

        M_STOPPED: begin
          if (dbg_valid) begin
            dbg_mode   <= 1'b1;
            dbg_ret_fetch <= 1'b0;
            dbg_insn_q <= dbg_insn;
            state      <= M_EXEC;
          end
        end

        M_FETCH: begin
          dbg_mode <= 1'b0;
          // Real-time debug preempts a fetch, including a stalled refill.
          // Dropping fetch_req while the debug instruction executes drains
          // and suppresses the old fetch; resuming retries the unchanged PC.
          if (dbg_valid) begin
            dbg_mode <= 1'b1;
            dbg_ret_fetch <= 1'b1;
            dbg_insn_q <= dbg_insn;
            state <= M_EXEC;
          end else if (fetch_err) begin
            ftrd[FTD_INSTR_FETCH_ERR] <= 1'b1;
            state                     <= M_FAULTING;
          end else if (insn_valid) state <= M_EXEC;
        end

        M_EXEC: begin
          if (exec_fault != '0) begin
            ftrd     <= ftrd | exec_fault;
            dbg_mode <= 1'b0;
            dbg_ret_wfe <= 1'b0;
            dbg_ret_fetch <= 1'b0;
            state    <= M_FAULTING;
          end else begin
            case (cls)
              I_END, I_KILL: state <= M_STOPPED;
              I_WFE: begin
                wake_num <= num5;
                state    <= M_WFE;
              end
              default: begin                       // GO, SEV, NOP
                if (dbg_mode) begin
                  state <= dbg_ret_wfe ? M_WFE : dbg_ret_fetch ? M_FETCH : M_STOPPED;
                end else begin
                  state <= M_UPDATING_PC;
                end
              end
            endcase
            dbg_mode    <= 1'b0;
            dbg_ret_wfe <= 1'b0;
            dbg_ret_fetch <= 1'b0;
          end
        end

        M_UPDATING_PC: begin
          pc    <= pc + ADDR_W'(insn_len(op));
          state <= M_FETCH;
        end

        M_WFE: begin
          if (wfe_hit) begin
            state <= M_UPDATING_PC;
          end else if (dbg_valid) begin           // debug instruction while waiting
            dbg_mode    <= 1'b1;
            dbg_ret_wfe <= 1'b1;
            dbg_ret_fetch <= 1'b0;
            dbg_insn_q  <= dbg_insn;
            state       <= M_EXEC;
          end
        end

        M_FAULTING: begin
          // Only a debug DMAKILL leaves the faulting state
          if (dbg_valid && decode_op(dbg_insn[7:0]) == I_KILL) begin
            ftrd  <= '0;
            state <= M_STOPPED;
          end
        end

        default: state <= M_STOPPED;
      endcase
    end
  end

  //============================================================================
  // Status
  //============================================================================
  logic [3:0] status;

  always_comb begin
    case (state)
      M_FETCH:    status = ic_refill ? ST_CACHE_MISS : ST_EXECUTING;
      M_EXEC:     status = ST_EXECUTING;
      M_UPDATING_PC: status = ST_UPDATING_PC;
      M_WFE:      status = ST_WAIT_EVENT;
      M_FAULTING: status = ST_FAULTING;
      default:    status = ST_STOPPED;
    endcase
  end

  assign dsr      = {22'd0, mgr_ns, wake_num, status};
  assign dpc      = pc;
  assign faulting = (state == M_FAULTING);

endmodule : dma_manager
