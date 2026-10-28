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
//   STOPPED --DMAGO--> FETCH --> EXEC --> UPDATING_PC --> FETCH
//   EXEC --> WFE / WFP / BARRIER --wake/complete--> UPDATING_PC
//   EXEC --> COMPLETING (DMAEND) --> STOPPED
//   EXEC --> KILLING (DMAKILL) --> STOPPED
//   any error ------------> FAULT_COMPLETING --> FAULTING --dbg DMAKILL--> KILLING
//
// Security: a non-secure thread (DMAGO ns = 1) may only use the events and
// peripherals that are non-secure in CR3 / CR4 (boot_irq_ns / boot_periph_ns).
// DMASEV / DMAWFE of a secure event faults with ch_evnt_err; DMAWFP,
// DMAFLUSHP, DMALDP, DMASTP of a secure peripheral with ch_periph_err. Its
// DMAMOV CCR faults with ch_rdwr_err when its immediate asks for a secure
// access (src/dst_prot[1] = 0). An event or peripheral number the configuration
// does not have is an invalid operand (operand_invalid).
//
// Bursts: DMALD/DMAST S and DMALDPS/DMASTPS move one beat (AxLEN = 0, the
// burst length of CCR is ignored); the other forms use the CCR burst. An INCR
// burst that crosses 4 KB is split into two AXI bursts by the data path.
// A DMAST with an endian-swap setting the data path cannot honour faults with
// ch_rdwr_err (see swap_bad).
// DMAWFP single / burst set request_type to single / burst and request_last
// to 0; DMAWFP periph copies both from the request (TRM 2.6.4).
// DMAFLUSHP waits at a barrier until the channel's reads and writes (and so
// their peripheral acknowledges) are complete, then sends the flush.
// Load-lock (TRM 2.11.4): ll_release tells the data path that this channel
// gives the load-lock up (store, barrier, wait, end, abort).
// Lock-up: 'ld_lockup' (the load can never fit the MFIFO) faults with
// mfifo_err; 'ld_dlock' (MFIFO dead-lock between channels, precise lock-up
// detection) and 'wd_fault' (no progress for the programmed time) fault with
// lockup_err.
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
  input  logic                    dbg_evnt_fault, // debug DMASEV of a secure event
  input  logic                    dbg_opnd_fault, // debug DMASEV of a missing event
  input  logic                    wd_fault,       // watchdog lock-up

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

  // Events
  output logic                    sev_valid,
  output logic [4:0]              sev_event,
  output logic                    wfe_valid,
  output logic [4:0]              wfe_event,
  input  logic                    wfe_hit,

  // Peripheral request interface
  output logic                    wfp_valid,
  output logic [4:0]              wfp_periph,
  output logic [1:0]              wfp_kind,       // {burst, periph}: 00 single, 01 periph, 10 burst
  input  logic                    wfp_gnt,
  input  logic                    wfp_burst,
  input  logic                    wfp_last,
  output logic                    flush_valid,
  output logic [4:0]              flush_periph,
  input  logic                    flush_ready,

  // Data path
  output logic                    ld_req,         // DMALD in EXEC, no other fault
  output logic                    ld_valid,
  output xfer_t                   ld_xfer,
  input  logic                    ld_ready,
  input  logic                    ld_lockup,      // load can never fit: mfifo_err
  input  logic                    ld_dlock,       // MFIFO dead-lock: lockup_err
  output logic                    ll_release,     // give the load-lock up
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
    C_COMPLETING, C_KILLING, C_FAULT_COMPLETING, C_FAULTING, C_UPDATING_PC,
    C_RECONFIG
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
  logic              reconfig_dst;
  logic              barrier_fl;   // DMAFLUSHP: wait for reads and writes
  logic [4:0]        flush_num;    // peripheral of the pending DMAFLUSHP
  logic              wfp_is_burst, wfp_is_periph;
  logic              far_valid;    // FAR holds an error address
  logic              wd_can_fault; // states in which a watchdog lock-up aborts
  logic              pc_branch;    // selected by EXEC, applied in UPDATING_PC

  //============================================================================
  // Instruction fetch
  //============================================================================
  logic              fetch_req, insn_valid, fetch_err;
  logic [INSN_W-1:0] insn;
  logic [ADDR_W-1:0] fetch_pc;

  // Start the cache access while calculating/committing its PC. This exposes
  // Updating PC without adding an idle cycle to the instruction pipeline.
  assign fetch_req = (state == C_FETCH) || (state == C_UPDATING_PC);
  assign ic_ns     = ns;

  dma_fetch_unit #(.LINE_BYTES(LINE_BYTES)) u_fetch (
    .clk           (clk),
    .rst_n         (rst_n),
    .fetch_req     (fetch_req),
    .pc            (fetch_pc),
    .inv           (ic_inv),
    .insn_valid    (insn_valid),
    .insn          (insn),
    .fetch_err     (fetch_err),
    .miss          (), // front-end pending is not architectural Cache miss
    .ic_req        (ic_req),
    .ic_addr       (ic_addr),
    .ic_resp_valid (ic_resp_valid),
    .ic_resp_data  (ic_resp_data),
    .ic_resp_err   (ic_resp_err),
    .ic_resp_retry (ic_resp_retry)
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
  assign fetch_pc = (state == C_UPDATING_PC) ?
                    (pc_branch ? pc - ADDR_W'(b1) : pc_next) : pc;
  assign cond_ok = !op[0] || (op[1] == req_burst);

  // TRM 2.11.3: commit a discontinuous MOV only after its implicit barrier.
  // Destination discontinuities also discard the old, destination-formatted
  // stream. Burst length alone and incrementing destination size do not do so.
  ccr_t mov_ccr;
  logic mov_src_disc, mov_dst_disc;
  assign mov_ccr = ccr_t'(imm32);
  assign mov_src_disc = cls == I_MOV &&
      ((b1 == 0 && sar[MAX_SIZE-1:0] != imm32[MAX_SIZE-1:0]) ||
       (b1 == 1 && (ccr.src_inc != mov_ccr.src_inc ||
                    ccr.src_burst_size != mov_ccr.src_burst_size)));
  assign mov_dst_disc = cls == I_MOV &&
      ((b1 == 2 && dar[MAX_SIZE-1:0] != imm32[MAX_SIZE-1:0]) ||
       (b1 == 1 && (ccr.endian_swap != mov_ccr.endian_swap ||
                    ccr.dst_inc != mov_ccr.dst_inc ||
                    (!ccr.dst_inc && ccr.dst_burst_size != mov_ccr.dst_burst_size))));

  // DMALD/DMAST with the S suffix and DMALDPS/DMASTPS (op[1:0] = 01) move a
  // single beat: the CCR burst length is ignored (TRM 2.6.4, 4.3.7, 4.3.16)
  logic       xfer_single;
  logic [3:0] ld_len, st_len;

  assign xfer_single = (op[1:0] == 2'b01);
  assign ld_len      = xfer_single ? 4'd0 : ccr.src_burst_len;
  assign st_len      = xfer_single ? 4'd0 : ccr.dst_burst_len;

  // Burst descriptors for DMALD / DMAST
  always_comb begin
    ld_xfer            = '0;
    ld_xfer.addr       = sar;
    ld_xfer.len        = ld_len;
    ld_xfer.size       = ccr.src_burst_size;
    ld_xfer.inc        = ccr.src_inc;
    ld_xfer.cache      = {1'b0, ccr.src_cache};                       // ARCACHE[2:0]
    ld_xfer.prot       = ccr.src_prot;
    ld_xfer.bytes      = burst_bytes(sar, ccr.src_burst_size, ld_len, ccr.src_inc);
    ld_xfer.periph_ack = (cls == I_LDP);
    ld_xfer.periph     = num5;
    ld_xfer.ack_burst  = op[1];

    st_xfer            = '0;
    st_xfer.addr       = dar;
    st_xfer.len        = st_len;
    st_xfer.size       = ccr.dst_burst_size;
    st_xfer.inc        = ccr.dst_inc;
    st_xfer.cache      = {ccr.dst_cache[2], 1'b0, ccr.dst_cache[1:0]}; // AWCACHE[3,1,0]
    st_xfer.prot       = ccr.dst_prot;
    st_xfer.bytes      = burst_bytes(dar, ccr.dst_burst_size, st_len, ccr.dst_inc);
    st_xfer.zero       = (cls == I_STZ);
    st_xfer.periph_ack = (cls == I_STP);
    st_xfer.periph     = num5;
    st_xfer.ack_burst  = op[1];
    st_xfer.swap       = (cls == I_STZ) ? 3'd0 : ccr.endian_swap;
  end

  // Store-side endian swap legality (TRM 2.11.2). Swap groups of g bytes:
  //   * g <= 16 and DAR is aligned to g; groups wider than the bus are staged
  //   * INCR : the burst must hold whole groups (len x size multiple of g); a
  //     group may then span several beats narrower than g
  //   * FIXED: every beat must hold whole groups (dst_burst_size >= swap)
  logic       swap_bad;
  logic [3:0] swap_mask;

  assign swap_mask = 4'((5'd1 << ccr.endian_swap) - 5'd1);

  always_comb begin
    swap_bad = 1'b0;
    if (ccr.endian_swap != 3'd0 && cls != I_STZ) begin
      swap_bad = (ccr.endian_swap > 3'd4) ||
                 ((dar[3:0] & swap_mask) != 4'd0) ||
                 (ccr.dst_inc ? ((st_xfer.bytes[3:0] & swap_mask) != 4'd0)
                              : (ccr.endian_swap > ccr.dst_burst_size));
    end
  end

  //----------------------------------------------------------------------------
  // Execute-time fault detection (all combinational on the current insn)
  //----------------------------------------------------------------------------
  logic        is_load, is_store, do_xfer;
  logic        ev_range_bad, ev_sec_bad, pe_range_bad, pe_sec_bad;
  logic [31:0] irq_ns32, periph_ns32;
  logic [31:0] exec_fault_base, exec_fault;

  assign is_load  = (cls == I_LD)  || (cls == I_LDP);
  assign is_store = (cls == I_ST)  || (cls == I_STP) || (cls == I_STZ);
  // DMASTZ is unconditional (op[0] = 0)
  assign do_xfer  = (is_load || is_store) && cond_ok;

  // Event / peripheral number missing from the configuration (invalid
  // operand), or secure for a non-secure thread (security fault)
  assign irq_ns32     = 32'(irq_ns);
  assign periph_ns32  = 32'(periph_ns);
  assign ev_range_bad = (int'(num5) >= NUM_EVENTS);
  assign pe_range_bad = (int'(num5) >= NUM_PERIPH);
  assign ev_sec_bad   = !ev_range_bad && ns && !irq_ns32[num5];
  assign pe_sec_bad   = !pe_range_bad && ns && !periph_ns32[num5];

  // Every execute-time fault except the MFIFO lock-ups, which the data path
  // decides from ld_req (so they never depend on themselves)
  always_comb begin
    exec_fault_base = '0;
    case (cls)
      I_UNDEF, I_GO:
        exec_fault_base[FTC_UNDEF_INSTR] = 1'b1;
      I_MOV: begin
        exec_fault_base[FTC_OPERAND_INVALID] = (b1 > 8'd2);
        exec_fault_base[FTC_CH_RDWR_ERR] = b1 == 1 && ns &&
                                          (!mov_ccr.src_prot[1] || !mov_ccr.dst_prot[1]);
      end
      I_SEV, I_WFE: begin
        exec_fault_base[FTC_OPERAND_INVALID] = ev_range_bad;
        exec_fault_base[FTC_CH_EVNT_ERR]     = ev_sec_bad;
      end
      I_WFP, I_FLUSHP: begin
        exec_fault_base[FTC_OPERAND_INVALID] = pe_range_bad;
        exec_fault_base[FTC_CH_PERIPH_ERR]   = pe_sec_bad;
      end
      default: ;
    endcase

    if (do_xfer) begin
      if (cls == I_LDP || cls == I_STP) begin
        exec_fault_base[FTC_OPERAND_INVALID] = pe_range_bad;
        exec_fault_base[FTC_CH_PERIPH_ERR]   = pe_sec_bad;
      end
      if (is_load) begin
        exec_fault_base[FTC_CH_RDWR_ERR] = (ccr.src_burst_size > MAX_SIZE) ||
                                           (ns && !ccr.src_prot[1]);
      end else begin
        exec_fault_base[FTC_CH_RDWR_ERR]     = (ccr.dst_burst_size > MAX_SIZE) || swap_bad ||
                                               (ns && !ccr.dst_prot[1]);
        exec_fault_base[FTC_ST_DATA_UNAVAIL] = st_short;
      end
    end
  end

  assign ld_req = (state == C_EXEC) && do_xfer && is_load && (exec_fault_base == '0);

  always_comb begin
    exec_fault                 = exec_fault_base;
    exec_fault[FTC_MFIFO_ERR]  = ld_req && ld_lockup;
    exec_fault[FTC_LOCKUP_ERR] = ld_req && ld_dlock;
  end

  //============================================================================
  // Outputs to the data path, event unit and peripheral controller
  //============================================================================
  logic in_exec_ok;
  logic dp_idle;
  assign in_exec_ok = (state == C_EXEC) && (exec_fault == '0);

  assign ld_valid     = in_exec_ok && do_xfer && is_load;
  assign st_valid     = in_exec_ok && do_xfer && is_store;

  assign sev_valid    = in_exec_ok && (cls == I_SEV);
  assign sev_event    = num5;
  // Thread-local maintenance. A start also discards a late fetch left by a
  // previous kill; a DMAGO to a running channel remains a complete NOP.
  assign ic_inv_req   = (in_exec_ok && (cls == I_WFE) && b1[1]) ||
                        (state == C_STOPPED && go_valid) ||
                        ((state == C_COMPLETING || state == C_KILLING) && dp_idle);

  assign wfe_valid    = (state == C_WFE);
  assign wfe_event    = wake_num;

  assign wfp_valid    = (state == C_WFP);
  assign wfp_periph   = wake_num;
  assign wfp_kind     = {wfp_is_burst, wfp_is_periph};

  assign dp_flush     = (state == C_STOPPED)          || (state == C_KILLING) ||
                        (state == C_FAULT_COMPLETING) || (state == C_FAULTING) ||
                        (state == C_RECONFIG && reconfig_dst && dp_idle);

  assign dp_idle = !rd_busy && !wr_busy;

  // DMAFLUSHP: the flush request is sent once every earlier transfer (and its
  // acknowledge) is done, so it can never overtake a DMALDP/DMASTP acknowledge
  assign flush_valid  = (state == C_BARRIER) && barrier_fl && dp_idle;
  assign flush_periph = flush_num;

  // Load-lock release: DMAST*, barriers, waits, DMAEND, DMAKILL, any abort
  assign ll_release   = dp_flush ||
                        (in_exec_ok &&
                         ((is_store && cond_ok) || mov_src_disc || mov_dst_disc ||
                          (cls inside {I_RMB, I_WMB, I_FLUSHP, I_WFP, I_WFE, I_END, I_KILL})));

  //============================================================================
  // Thread state machine
  //============================================================================

  // A watchdog lock-up aborts a running program; a channel that is already
  // being killed or faulted is only reported (WDSTAT)
  assign wd_can_fault = (state == C_FETCH) || (state == C_EXEC) || (state == C_UPDATING_PC) || (state == C_WFE) ||
                        (state == C_WFP) || (state == C_BARRIER) || (state == C_RECONFIG) ||
                        (state == C_COMPLETING);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state         <= C_STOPPED;
      pc            <= '0;
      sar           <= '0;
      dar           <= '0;
      ccr           <= ccr_t'(32'h0080_0200);  // TRM reset value (non-secure accesses)
      lc0           <= '0;
      lc1           <= '0;
      ns            <= 1'b0;
      req_burst     <= 1'b0;
      req_last      <= 1'b0;
      wake_num      <= '0;
      barrier_wr    <= 1'b0;
      reconfig_dst  <= 1'b0;
      barrier_fl    <= 1'b0;
      flush_num     <= '0;
      wfp_is_burst  <= 1'b0;
      wfp_is_periph <= 1'b0;
      ftr           <= '0;
      far           <= '0;
      far_valid     <= 1'b0;
      pc_branch     <= 1'b0;
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
            pc_branch <= 1'b0;
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
          pc_branch <= 1'b0;
          if (exec_fault != '0) begin
            ftr   <= ftr | exec_fault;
            state <= C_FAULT_COMPLETING;
          end else begin
            case (cls)
              I_END:  state <= C_COMPLETING;
              I_KILL: state <= C_KILLING;

              I_NOP, I_SEV: begin
                state <= C_UPDATING_PC;
              end

              I_RMB, I_WMB: begin
                barrier_wr <= (cls == I_WMB);
                barrier_fl <= 1'b0;
                state      <= C_BARRIER;
              end

              I_LD, I_LDP: begin
                if (!cond_ok) begin
                  state <= C_UPDATING_PC;           // condition false: NOP
                end else if (ld_ready) begin
                  if (ccr.src_inc) sar <= sar + ADDR_W'(ld_xfer.bytes);
                  state <= C_UPDATING_PC;
                end
              end

              I_ST, I_STP, I_STZ: begin
                if (!cond_ok) begin
                  state <= C_UPDATING_PC;
                end else if (st_ready) begin
                  if (ccr.dst_inc) dar <= dar + ADDR_W'(st_xfer.bytes);
                  state <= C_UPDATING_PC;
                end
              end

              I_LP: begin
                if (op[1]) lc1 <= b1;
                else       lc0 <= b1;
                state <= C_UPDATING_PC;
              end

              I_LPEND: begin
                state <= C_UPDATING_PC;
                if (cond_ok && op[4]) begin         // finite loop (DMALPEND)
                  if (op[2]) begin
                    if (lc1 != 8'd0) begin lc1 <= lc1 - 8'd1; pc_branch <= 1'b1; end
                  end else begin
                    if (lc0 != 8'd0) begin lc0 <= lc0 - 8'd1; pc_branch <= 1'b1; end
                  end
                end else if (cond_ok) begin         // forever loop (DMALPFE)
                  pc_branch <= !req_last;
                end
              end

              I_WFP: begin
                wake_num      <= num5;
                wfp_is_burst  <= (op[1:0] == 2'b10);
                wfp_is_periph <= (op[1:0] == 2'b01);
                state         <= C_WFP;
              end

              I_FLUSHP: begin
                barrier_fl <= 1'b1;
                flush_num  <= num5;
                state      <= C_BARRIER;
              end

              I_WFE: begin
                wake_num <= num5;
                state    <= C_WFE;
              end

              I_ADDH, I_ADNH: begin
                if (op[1]) dar <= dar + {(cls == I_ADNH) ? 16'hFFFF : 16'h0000, imm16};
                else       sar <= sar + {(cls == I_ADNH) ? 16'hFFFF : 16'h0000, imm16};
                state <= C_UPDATING_PC;
              end

              I_MOV: begin
                if (mov_src_disc || mov_dst_disc) begin
                  reconfig_dst <= mov_dst_disc;
                  state <= C_RECONFIG;
                end else begin
                  case (b1[1:0])
                    2'd0:    sar <= imm32;
                    2'd1:    ccr <= mov_ccr;
                    default: dar <= imm32;
                  endcase
                  state <= C_UPDATING_PC;
                end
              end

              default: ;   // I_UNDEF / I_GO are caught by exec_fault
            endcase
          end
        end

        //----------------------------------------------------------------------
        // PC arithmetic and commit occur in their own architectural state
        // (TRM 2.3.4). No instruction is reissued during this phase.
        C_UPDATING_PC: begin
          pc        <= pc_branch ? pc - ADDR_W'(b1) : pc_next;
          pc_branch <= 1'b0;
          state     <= C_FETCH;
        end

        C_WFE: begin
          if (wfe_hit) begin
            state <= C_UPDATING_PC;
          end
        end

        C_WFP: begin
          if (wfp_gnt) begin
            req_burst <= wfp_is_periph ? wfp_burst : wfp_is_burst;
            req_last  <= wfp_is_periph && wfp_last;
            state     <= C_UPDATING_PC;
          end
        end

        C_BARRIER: begin
          if (barrier_fl) begin
            if (flush_valid && flush_ready) begin
              req_burst  <= 1'b0;
              req_last   <= 1'b0;
              barrier_fl <= 1'b0;
              state      <= C_UPDATING_PC;
            end
          end else if (barrier_wr ? !wr_busy : !rd_busy) begin
            state <= C_UPDATING_PC;
          end
        end

        C_RECONFIG: begin
          if (reconfig_dst ? dp_idle : !rd_busy) begin
            case (b1[1:0])
              2'd0:    sar <= imm32;
              2'd1:    ccr <= mov_ccr;
              default: dar <= imm32;
            endcase
            state <= C_UPDATING_PC;
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

      if ((dbg_fault || dbg_evnt_fault || dbg_opnd_fault) &&
          state != C_FAULT_COMPLETING && state != C_FAULTING) begin
        if (dbg_fault)      ftr[FTC_UNDEF_INSTR]     <= 1'b1;
        if (dbg_evnt_fault) ftr[FTC_CH_EVNT_ERR]     <= 1'b1;
        if (dbg_opnd_fault) ftr[FTC_OPERAND_INVALID] <= 1'b1;
        ftr[FTC_DBG_INSTR] <= 1'b1;
        state              <= C_FAULT_COMPLETING;
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
      C_FETCH:            status = ic_refill ? ST_CACHE_MISS : ST_EXECUTING;
      C_EXEC:             status = ST_EXECUTING;
      C_UPDATING_PC:      status = ST_UPDATING_PC;
      C_WFE:              status = ST_WAIT_EVENT;
      C_WFP:              status = ST_WAIT_PERIPH;
      C_BARRIER:          status = ST_AT_BARRIER;
      C_RECONFIG:         status = ST_AT_BARRIER;
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
