//==============================================================================
// dma_manager.sv
//------------------------------------------------------------------------------
// DMA manager thread.
//
// Executes the manager subset of the ISA: DMAGO, DMASEV, DMAWFE, DMAFLUSHP,
// DMAEND, DMAKILL, DMANOP. It runs either
//   * a program from memory (boot_from_pc at reset), or
//   * single instructions written through the debug registers
//     (DBGINST0/1 + DBGCMD) - the usual way a driver starts channels.
//
//   BOOT --boot_from_pc--> FETCH <--> EXEC --> WFE
//     |                      ^         |
//     +--> STOPPED <---------+---------+  (DMAEND / DMAKILL / debug done)
//            |  ^
//            |  +---- FAULTING <--- any fault  (left with debug DMAKILL)
//            +-- debug instruction --> EXEC
//
// DMAGO on a channel that is not stopped is ignored by the channel (NOP), as
// in DMA-330. A non-secure manager cannot start a secure channel (dmago_err).
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

  // Instruction cache
  input  logic                    ic_inv_all,
  output logic                    ic_inv_req,
  output logic                    ic_req,
  output logic [ADDR_W-1:0]       ic_addr,
  output logic                    ic_ns,
  input  logic                    ic_resp_valid,
  input  logic [LINE_BYTES*8-1:0] ic_resp_data,
  input  logic                    ic_resp_err,

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
    M_BOOT, M_STOPPED, M_FETCH, M_EXEC, M_WFE, M_FAULTING
  } mstate_e;

  mstate_e           state;
  logic [ADDR_W-1:0] pc;
  logic              mgr_ns;       // manager security state
  logic              dbg_mode;     // executing a debug instruction
  logic [INSN_W-1:0] dbg_insn_q;
  logic [4:0]        wake_num;

  //============================================================================
  // Instruction fetch
  //============================================================================
  logic              insn_valid, fetch_err, fetch_miss;
  logic [INSN_W-1:0] fetch_insn;

  assign ic_ns = mgr_ns;

  dma_fetch_unit #(.LINE_BYTES(LINE_BYTES)) u_fetch (
    .clk           (clk),
    .rst_n         (rst_n),
    .fetch_req     (state == M_FETCH),
    .pc            (pc),
    .inv           (ic_inv_all),
    .insn_valid    (insn_valid),
    .insn          (fetch_insn),
    .fetch_err     (fetch_err),
    .miss          (fetch_miss),
    .ic_req        (ic_req),
    .ic_addr       (ic_addr),
    .ic_resp_valid (ic_resp_valid),
    .ic_resp_data  (ic_resp_data),
    .ic_resp_err   (ic_resp_err)
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

  logic [31:0] exec_fault;

  always_comb begin
    exec_fault = '0;
    case (cls)
      I_GO: begin
        exec_fault[FTD_OPERAND_INVALID] = (int'(go_ch) >= NUM_CH);
        exec_fault[FTD_DMAGO_ERR]       = mgr_ns && !op[1];   // NS mgr -> secure ch
      end
      I_SEV, I_WFE:
        exec_fault[FTD_MGR_EVNT_ERR]    = (int'(num5) >= NUM_EVENTS);
      I_FLUSHP:
        exec_fault[FTD_OPERAND_INVALID] = (int'(num5) >= NUM_PERIPH);
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
  assign flush_valid  = in_exec_ok && (cls == I_FLUSHP);
  assign flush_periph = num5;

  // DMAGO invalidates the instruction cache so a channel never runs stale
  // code; DMAWFE can request it explicitly.
  assign ic_inv_req   = in_exec_ok && ((cls == I_GO) || (cls == I_WFE && b1[1]));

  // An instruction completes this cycle (used to retire debug instructions)
  logic exec_done;
  assign exec_done = (state == M_EXEC) &&
                     ((exec_fault != '0) || (cls != I_FLUSHP) || flush_ready);

  assign dbg_done = (dbg_mode && exec_done) ||
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
            dbg_insn_q <= dbg_insn;
            state      <= M_EXEC;
          end
        end

        M_FETCH: begin
          dbg_mode <= 1'b0;
          if (insn_valid) state <= M_EXEC;
          if (fetch_err) begin
            ftrd[FTD_INSTR_FETCH_ERR] <= 1'b1;
            state                     <= M_FAULTING;
          end
        end

        M_EXEC: begin
          if (exec_fault != '0) begin
            ftrd     <= ftrd | exec_fault;
            dbg_mode <= 1'b0;
            state    <= M_FAULTING;
          end else if (exec_done) begin
            case (cls)
              I_END, I_KILL: state <= M_STOPPED;
              I_WFE: begin
                wake_num <= num5;
                state    <= M_WFE;
              end
              default: begin                       // GO, SEV, NOP, FLUSHP
                if (dbg_mode) begin
                  state <= M_STOPPED;
                end else begin
                  pc    <= pc + ADDR_W'(insn_len(op));
                  state <= M_FETCH;
                end
              end
            endcase
            dbg_mode <= 1'b0;
          end
        end

        M_WFE: begin
          if (wfe_hit) begin
            pc    <= pc + 2;
            state <= M_FETCH;
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
      M_FETCH:    status = fetch_miss ? ST_CACHE_MISS : ST_EXECUTING;
      M_EXEC:     status = ST_EXECUTING;
      M_WFE:      status = ST_WAIT_EVENT;
      M_FAULTING: status = ST_FAULTING;
      default:    status = ST_STOPPED;
    endcase
  end

  assign dsr      = {22'd0, mgr_ns, wake_num, status};
  assign dpc      = pc;
  assign faulting = (state == M_FAULTING);

endmodule : dma_manager
