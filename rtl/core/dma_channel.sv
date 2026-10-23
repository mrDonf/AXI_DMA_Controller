//==============================================================================
// dma_channel.sv
//------------------------------------------------------------------------------
// DMA channel thread: executes a DMA-330 instruction program.
//
// Architectural state: PC (CPC), SAR, DAR, CCR, LC0, LC1, request flags,
// fault type (FTR). Loads/stores are *issued* to the data path and complete
// asynchronously; the thread only waits where the ISA requires it
// (barriers, DMAEND, events, peripherals) or when a queue is full.
//
//   STOPPED --DMAGO--> FETCH <--> EXEC --+--> WFE        (DMAWFE)
//                        ^               +--> WFP        (DMAWFP)
//                        |               +--> BARRIER    (DMARMB/DMAWMB)
//                        +---------------+--> COMPLETING (DMAEND) --> STOPPED
//                                        +--> KILLING    (DMAKILL) -> STOPPED
//   any error ------------> FAULT_COMPLETING --> FAULTING --dbg DMAKILL--> KILLING
//
// Protocol protection: a DMALD/DMAST whose INCR burst would cross a 4 KB
// boundary, or a DMAST with an illegal endian-swap setting, faults the channel
// (ch_rdwr_err) instead of putting an illegal transaction on the AXI bus.
// Watchdog: 'wd_fault' (channel made no progress for the programmed time)
// faults the channel with lockup_err.
// FAR keeps the address of the first bus error since DMAGO.
//
// While KILLING / FAULT_* / STOPPED the data path is told to flush this
// channel (queued requests dropped, returning read data discarded).
//==============================================================================
module dma_channel
  import dma330_pkg::*;
#(
  parameter int CH_ID      = 0,
  parameter int NUM_PERIPH = 4,
  parameter int NUM_EVENTS = 16,
  parameter int DATA_W     = 64,
  parameter int LINE_BYTES = 32
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // Control from the manager / debug interface
  input  logic                    go_valid,
  input  logic [ADDR_W-1:0]       go_pc,
  input  logic                    go_ns,
  input  logic                    dbg_kill,
  input  logic                    dbg_fault,
  input  logic                    wd_fault,       // watchdog lock-up

  // Instruction cache
  input  logic                    ic_inv_all,
  output logic                    ic_inv_req,
  output logic                    ic_req,
  output logic [ADDR_W-1:0]       ic_addr,
  output logic                    ic_ns,
  input  logic                    ic_resp_valid,
  input  logic [LINE_BYTES*8-1:0] ic_resp_data,
  input  logic                    ic_resp_err,

  // Events
  output logic                    sev_valid,
  output logic [4:0]              sev_event,
  output logic                    wfe_valid,
  output logic [4:0]              wfe_event,
  input  logic                    wfe_hit,

  // Peripheral request interface
  output logic                    wfp_valid,
  output logic [4:0]              wfp_periph,
  input  logic                    wfp_gnt,
  input  logic                    wfp_burst,
  input  logic                    wfp_last,
  output logic                    flush_valid,
  output logic [4:0]              flush_periph,
  input  logic                    flush_ready,

  // Data path
  output logic                    ld_valid,
  output xfer_t                   ld_xfer,
  input  logic                    ld_ready,
  input  logic                    ld_lockup,
  output logic                    st_valid,
  output xfer_t                   st_xfer,
  input  logic                    st_ready,
  input  logic                    st_short,
  input  logic                    rd_busy,
  input  logic                    wr_busy,
  input  logic                    rd_err,
  input  logic                    wr_err,
  input  logic [ADDR_W-1:0]       rd_err_addr,    // beat address of rd_err
  input  logic [ADDR_W-1:0]       wr_err_addr,    // burst address of wr_err
  output logic                    dp_flush,

  // Status registers
  output logic [31:0]             csr,
  output logic [31:0]             cpc,
  output logic [31:0]             sar_o,
  output logic [31:0]             dar_o,
  output logic [31:0]             ccr_o,
  output logic [31:0]             lc0_o,
  output logic [31:0]             lc1_o,
  output logic [31:0]             ftr,
  output logic [31:0]             far,            // first bus-error address
  output logic                    faulting
);

  localparam logic [2:0] MAX_SIZE = 3'($clog2(DATA_W / 8));

  typedef enum logic [3:0] {
    C_STOPPED, C_FETCH, C_EXEC, C_WFE, C_WFP, C_BARRIER,
    C_COMPLETING, C_KILLING, C_FAULT_COMPLETING, C_FAULTING
  } cstate_e;

  //============================================================================
  // Architectural state
  //============================================================================
  cstate_e           state;
  logic [ADDR_W-1:0] pc, sar, dar;
  ccr_t              ccr;
  logic [7:0]        lc0, lc1;
  logic              ns;
  logic              req_burst;    // request_type flag: 0 single, 1 burst
  logic              req_last;     // peripheral signalled its last request
  logic [4:0]        wake_num;     // event / peripheral being waited for
  logic              barrier_wr;   // 1: DMAWMB, 0: DMARMB
  logic              wfp_is_burst, wfp_is_periph;
  logic              far_valid;    // FAR holds an error address
  logic              wd_can_fault; // states in which a watchdog lock-up aborts

  //============================================================================
  // Instruction fetch
  //============================================================================
  logic              fetch_req, insn_valid, fetch_err, fetch_miss;
  logic [INSN_W-1:0] insn;

  assign fetch_req = (state == C_FETCH);
  assign ic_ns     = ns;

  dma_fetch_unit #(.LINE_BYTES(LINE_BYTES)) u_fetch (
    .clk           (clk),
    .rst_n         (rst_n),
    .fetch_req     (fetch_req),
    .pc            (pc),
    .inv           (ic_inv_all),
    .insn_valid    (insn_valid),
    .insn          (insn),
    .fetch_err     (fetch_err),
    .miss          (fetch_miss),
    .ic_req        (ic_req),
    .ic_addr       (ic_addr),
    .ic_resp_valid (ic_resp_valid),
    .ic_resp_data  (ic_resp_data),
    .ic_resp_err   (ic_resp_err)
  );

  //============================================================================
  // Decode (instruction register = fetch unit output, stable during EXEC)
  //============================================================================
  insn_e             cls;
  logic [7:0]        op, b1;
  logic [15:0]       imm16;
  logic [31:0]       imm32;
  logic [ADDR_W-1:0] pc_next;
  logic [4:0]        num5;        // event or peripheral number, byte1[7:3]
  logic              cond_ok;     // [S|B] condition against request_type

  assign op      = insn[7:0];
  assign b1      = insn[15:8];
  assign imm16   = insn[23:8];
  assign imm32   = insn[47:16];
  assign num5    = b1[7:3];
  assign cls     = decode_op(op);
  assign pc_next = pc + ADDR_W'(insn_len(op));
  assign cond_ok = !op[0] || (op[1] == req_burst);

  // Burst descriptors for DMALD / DMAST
  always_comb begin
    ld_xfer            = '0;
    ld_xfer.addr       = sar;
    ld_xfer.len        = ccr.src_burst_len;
    ld_xfer.size       = ccr.src_burst_size;
    ld_xfer.inc        = ccr.src_inc;
    ld_xfer.cache      = {1'b0, ccr.src_cache};
    ld_xfer.prot       = ccr.src_prot | {1'b0, ns, 1'b0};
    ld_xfer.bytes      = burst_bytes(sar, ccr.src_burst_size, ccr.src_burst_len, ccr.src_inc);
    ld_xfer.periph_ack = (cls == I_LDP);
    ld_xfer.periph     = num5;
    ld_xfer.ack_burst  = op[1];

    st_xfer            = '0;
    st_xfer.addr       = dar;
    st_xfer.len        = ccr.dst_burst_len;
    st_xfer.size       = ccr.dst_burst_size;
    st_xfer.inc        = ccr.dst_inc;
    st_xfer.cache      = {1'b0, ccr.dst_cache};
    st_xfer.prot       = ccr.dst_prot | {1'b0, ns, 1'b0};
    st_xfer.bytes      = burst_bytes(dar, ccr.dst_burst_size, ccr.dst_burst_len, ccr.dst_inc);
    st_xfer.zero       = (cls == I_STZ);
    st_xfer.periph_ack = (cls == I_STP);
    st_xfer.periph     = num5;
    st_xfer.ack_burst  = op[1];
    st_xfer.swap       = (cls == I_STZ) ? 3'd0 : ccr.endian_swap;
  end

  // Store-side endian swap legality: the swap size may not exceed the beat
  // size (so every beat carries whole groups) and DAR must be aligned to it.
  logic swap_bad;
  always_comb begin
    swap_bad = 1'b0;
    if (ccr.endian_swap != 3'd0 && cls != I_STZ) begin
      swap_bad = (ccr.endian_swap > 3'd4) ||
                 (ccr.endian_swap > ccr.dst_burst_size) ||
                 ((dar[3:0] & 4'((1 << ccr.endian_swap) - 1)) != 4'd0);
    end
  end

  //----------------------------------------------------------------------------
  // Execute-time fault detection (all combinational on the current insn)
  //----------------------------------------------------------------------------
  logic        is_load, is_store, do_xfer;
  logic [31:0] exec_fault;

  assign is_load  = (cls == I_LD)  || (cls == I_LDP);
  assign is_store = (cls == I_ST)  || (cls == I_STP) || (cls == I_STZ);
  // DMASTZ is unconditional (op[0] = 0)
  assign do_xfer  = (is_load || is_store) && cond_ok;

  always_comb begin
    exec_fault = '0;
    case (cls)
      I_UNDEF, I_GO:
        exec_fault[FTC_UNDEF_INSTR] = 1'b1;
      I_MOV:
        exec_fault[FTC_OPERAND_INVALID] = (b1 > 8'd2);
      I_SEV, I_WFE:
        exec_fault[FTC_CH_EVNT_ERR] = (int'(num5) >= NUM_EVENTS);
      I_WFP, I_FLUSHP:
        exec_fault[FTC_CH_PERIPH_ERR] = (int'(num5) >= NUM_PERIPH);
      default: ;
    endcase

    if (do_xfer) begin
      if ((cls == I_LDP || cls == I_STP) && int'(num5) >= NUM_PERIPH)
        exec_fault[FTC_CH_PERIPH_ERR] = 1'b1;
      if (is_load) begin
        exec_fault[FTC_CH_RDWR_ERR] = (ccr.src_burst_size > MAX_SIZE) ||
                                      crosses_4k(sar, ccr.src_burst_size, ccr.src_burst_len, ccr.src_inc);
        exec_fault[FTC_MFIFO_ERR]   = ld_lockup;
      end else begin
        exec_fault[FTC_CH_RDWR_ERR]     = (ccr.dst_burst_size > MAX_SIZE) || swap_bad ||
                                          crosses_4k(dar, ccr.dst_burst_size, ccr.dst_burst_len, ccr.dst_inc);
        exec_fault[FTC_ST_DATA_UNAVAIL] = st_short;
      end
    end
  end

  //============================================================================
  // Outputs to the data path, event unit and peripheral controller
  //============================================================================
  logic in_exec_ok;
  assign in_exec_ok = (state == C_EXEC) && (exec_fault == '0);

  assign ld_valid     = in_exec_ok && do_xfer && is_load;
  assign st_valid     = in_exec_ok && do_xfer && is_store;

  assign sev_valid    = in_exec_ok && (cls == I_SEV);
  assign sev_event    = num5;
  assign ic_inv_req   = in_exec_ok && (cls == I_WFE) && b1[1];

  assign wfe_valid    = (state == C_WFE);
  assign wfe_event    = wake_num;

  assign wfp_valid    = (state == C_WFP);
  assign wfp_periph   = wake_num;
  assign flush_valid  = in_exec_ok && (cls == I_FLUSHP);
  assign flush_periph = num5;

  assign dp_flush     = (state == C_STOPPED)          || (state == C_KILLING) ||
                        (state == C_FAULT_COMPLETING) || (state == C_FAULTING);

  //============================================================================
  // Thread state machine
  //============================================================================
  logic dp_idle;
  assign dp_idle = !rd_busy && !wr_busy;

  // A watchdog lock-up aborts a running program; a channel that is already
  // being killed or faulted is only reported (WDSTAT)
  assign wd_can_fault = (state == C_FETCH) || (state == C_EXEC) || (state == C_WFE) ||
                        (state == C_WFP) || (state == C_BARRIER) || (state == C_COMPLETING);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state         <= C_STOPPED;
      pc            <= '0;
      sar           <= '0;
      dar           <= '0;
      ccr           <= '0;
      lc0           <= '0;
      lc1           <= '0;
      ns            <= 1'b0;
      req_burst     <= 1'b0;
      req_last      <= 1'b0;
      wake_num      <= '0;
      barrier_wr    <= 1'b0;
      wfp_is_burst  <= 1'b0;
      wfp_is_periph <= 1'b0;
      ftr           <= '0;
      far           <= '0;
      far_valid     <= 1'b0;
    end else begin
      case (state)
        //----------------------------------------------------------------------
        C_STOPPED: begin
          if (go_valid) begin
            pc        <= go_pc;
            ns        <= go_ns;
            req_burst <= 1'b0;
            req_last  <= 1'b0;
            ftr       <= '0;
            far       <= '0;
            far_valid <= 1'b0;
            state     <= C_FETCH;
          end
        end

        //----------------------------------------------------------------------
        C_FETCH: begin
          if (insn_valid) state <= C_EXEC;
          if (fetch_err) begin
            ftr[FTC_INSTR_FETCH_ERR] <= 1'b1;
            state                    <= C_FAULT_COMPLETING;
            far                      <= pc;        // no earlier error in FETCH
            far_valid                <= 1'b1;
          end
        end

        //----------------------------------------------------------------------
        C_EXEC: begin
          if (exec_fault != '0) begin
            ftr   <= ftr | exec_fault;
            state <= C_FAULT_COMPLETING;
          end else begin
            case (cls)
              I_END:  state <= C_COMPLETING;
              I_KILL: state <= C_KILLING;

              I_NOP, I_SEV: begin
                pc    <= pc_next;
                state <= C_FETCH;
              end

              I_RMB, I_WMB: begin
                barrier_wr <= (cls == I_WMB);
                state      <= C_BARRIER;
              end

              I_LD, I_LDP: begin
                if (!cond_ok) begin
                  pc    <= pc_next;                 // condition false: NOP
                  state <= C_FETCH;
                end else if (ld_ready) begin
                  if (ccr.src_inc) sar <= sar + ADDR_W'(ld_xfer.bytes);
                  pc    <= pc_next;
                  state <= C_FETCH;
                end
              end

              I_ST, I_STP, I_STZ: begin
                if (!cond_ok) begin
                  pc    <= pc_next;
                  state <= C_FETCH;
                end else if (st_ready) begin
                  if (ccr.dst_inc) dar <= dar + ADDR_W'(st_xfer.bytes);
                  pc    <= pc_next;
                  state <= C_FETCH;
                end
              end

              I_LP: begin
                if (op[1]) lc1 <= b1;
                else       lc0 <= b1;
                pc    <= pc_next;
                state <= C_FETCH;
              end

              I_LPEND: begin
                state <= C_FETCH;
                if (!cond_ok) begin
                  pc <= pc_next;
                end else if (op[4]) begin           // finite loop (DMALPEND)
                  if (op[2]) begin
                    if (lc1 != 8'd0) begin lc1 <= lc1 - 8'd1; pc <= pc - ADDR_W'(b1); end
                    else             pc  <= pc_next;
                  end else begin
                    if (lc0 != 8'd0) begin lc0 <= lc0 - 8'd1; pc <= pc - ADDR_W'(b1); end
                    else             pc  <= pc_next;
                  end
                end else begin                      // forever loop (DMALPFE)
                  pc <= req_last ? pc_next : pc - ADDR_W'(b1);
                end
              end

              I_WFP: begin
                wake_num      <= num5;
                wfp_is_burst  <= (op[1:0] == 2'b10);
                wfp_is_periph <= (op[1:0] == 2'b01);
                state         <= C_WFP;
              end

              I_FLUSHP: begin
                if (flush_ready) begin
                  req_burst <= 1'b0;
                  req_last  <= 1'b0;
                  pc        <= pc_next;
                  state     <= C_FETCH;
                end
              end

              I_WFE: begin
                wake_num <= num5;
                state    <= C_WFE;
              end

              I_ADDH, I_ADNH: begin
                if (op[1]) dar <= dar + {(cls == I_ADNH) ? 16'hFFFF : 16'h0000, imm16};
                else       sar <= sar + {(cls == I_ADNH) ? 16'hFFFF : 16'h0000, imm16};
                pc    <= pc_next;
                state <= C_FETCH;
              end

              I_MOV: begin
                case (b1[1:0])
                  2'd0:    sar <= imm32;
                  2'd1:    ccr <= ccr_t'(imm32);
                  default: dar <= imm32;
                endcase
                pc    <= pc_next;
                state <= C_FETCH;
              end

              default: ;   // I_UNDEF / I_GO are caught by exec_fault
            endcase
          end
        end

        //----------------------------------------------------------------------
        C_WFE: begin
          if (wfe_hit) begin
            pc    <= pc_next;
            state <= C_FETCH;
          end
        end

        C_WFP: begin
          if (wfp_gnt) begin
            req_burst <= wfp_is_periph ? wfp_burst : wfp_is_burst;
            req_last  <= wfp_last;
            pc        <= pc_next;
            state     <= C_FETCH;
          end
        end

        C_BARRIER: begin
          if (barrier_wr ? !wr_busy : !rd_busy) begin
            pc    <= pc_next;
            state <= C_FETCH;
          end
        end

        //----------------------------------------------------------------------
        C_COMPLETING:       if (dp_idle) state <= C_STOPPED;
        C_FAULT_COMPLETING: if (dp_idle) state <= C_FAULTING;
        C_KILLING: begin
          if (dp_idle) begin
            ftr   <= '0;
            state <= C_STOPPED;
          end
        end
        C_FAULTING: ;      // wait for DMAKILL from the debug interface

        default: state <= C_STOPPED;
      endcase

      //------------------------------------------------------------------------
      // Asynchronous events (override the normal flow)
      //------------------------------------------------------------------------
      if (state != C_STOPPED && state != C_KILLING) begin
        if (rd_err) ftr[FTC_DATA_READ_ERR]  <= 1'b1;
        if (wr_err) ftr[FTC_DATA_WRITE_ERR] <= 1'b1;
        if ((rd_err || wr_err) && !far_valid) begin
          far       <= rd_err ? rd_err_addr : wr_err_addr;
          far_valid <= 1'b1;
        end
        if ((rd_err || wr_err) &&
            state != C_FAULT_COMPLETING && state != C_FAULTING)
          state <= C_FAULT_COMPLETING;
      end

      if (dbg_fault && state != C_FAULT_COMPLETING && state != C_FAULTING) begin
        ftr[FTC_UNDEF_INSTR] <= 1'b1;
        ftr[FTC_DBG_INSTR]   <= 1'b1;
        state                <= C_FAULT_COMPLETING;
      end

      if (wd_fault && wd_can_fault) begin
        ftr[FTC_LOCKUP_ERR] <= 1'b1;
        state               <= C_FAULT_COMPLETING;
      end

      if (dbg_kill && state != C_STOPPED)
        state <= C_KILLING;
    end
  end

  //============================================================================
  // Status registers
  //============================================================================
  logic [3:0] status;

  always_comb begin
    case (state)
      C_STOPPED:          status = ST_STOPPED;
      C_FETCH:            status = fetch_miss ? ST_CACHE_MISS : ST_EXECUTING;
      C_EXEC:             status = ST_EXECUTING;
      C_WFE:              status = ST_WAIT_EVENT;
      C_WFP:              status = ST_WAIT_PERIPH;
      C_BARRIER:          status = ST_AT_BARRIER;
      C_COMPLETING:       status = ST_COMPLETING;
      C_KILLING:          status = ST_KILLING;
      C_FAULT_COMPLETING: status = ST_FAULT_COMPLETING;
      C_FAULTING:         status = ST_FAULTING;
      default:            status = ST_STOPPED;
    endcase
  end

  assign csr = {10'd0, ns, 5'd0,
                (state == C_WFP) && wfp_is_periph,
                (state == C_WFP) && wfp_is_burst,
                5'd0, wake_num, status};
  assign cpc      = pc;
  assign sar_o    = sar;
  assign dar_o    = dar;
  assign ccr_o    = ccr;
  assign lc0_o    = {24'd0, lc0};
  assign lc1_o    = {24'd0, lc1};
  assign faulting = (state == C_FAULT_COMPLETING) || (state == C_FAULTING);

endmodule : dma_channel
