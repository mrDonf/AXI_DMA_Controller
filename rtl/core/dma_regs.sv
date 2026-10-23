//==============================================================================
// dma_regs.sv
//------------------------------------------------------------------------------
// APB register file (core clock domain), DMA-330 compatible register map.
//
//   0x000 DSR            RO  manager status
//   0x004 DPC            RO  manager PC
//   0x020 INTEN          RW  event(0)/interrupt(1) select
//   0x024 INT_EVENT_RIS  RO  event / raw interrupt status
//   0x028 INTMIS         RO  masked interrupt status
//   0x02C INTCLR         WO  write 1 to clear interrupt
//   0x030 FSRD           RO  manager fault status
//   0x034 FSRC           RO  channel fault status (bit per channel)
//   0x038 FTRD           RO  manager fault type
//   0x040+4n FTRn        RO  channel fault type
//   0x060+4n FARn        RO  channel bus-error address          (extension)
//   0x100+8n CSRn        RO  channel status
//   0x104+8n CPCn        RO  channel PC
//   0x400+0x20n SARn/DARn/CCRn/LC0_n/LC1_n  RO
//   0xD00 DBGSTATUS      RO  bit0: debug instruction busy
//   0xD04 DBGCMD         WO  write 0 to execute DBGINST0/1
//   0xD08 DBGINST0       RW  [0] thread (0 mgr / 1 ch), [10:8] ch, [31:16] byte0..1
//   0xD0C DBGINST1       RW  bytes 2..5
//   0xE00..0xE14 CR0-4, CRD   RO  configuration
//   0xE80 WD             RW  watchdog: [0] irq_only, [31:16] timeout (x256 clk)
//   0xE84 WDSTAT         W1C channel lock-up detected (bit per channel) (extension)
//   0xFE0..0xFFC         RO  peripheral / component identification
//
// The APB slave is zero-wait-state (PREADY = 1). With APB_SLVERR = 1, an
// access to an unmapped address or a write to a read-only register completes
// with PSLVERR = 1 (and has no effect); with APB_SLVERR = 0 (DMA-330
// behaviour) PSLVERR is never asserted.
//==============================================================================
module dma_regs
  import dma330_pkg::*;
#(
  parameter int          NUM_CH      = 4,
  parameter int          NUM_PERIPH  = 4,
  parameter int          NUM_EVENTS  = 16,
  parameter int          DATA_W      = 64,
  parameter int          IC_LINES    = 8,
  parameter int          LINE_BYTES  = 32,
  parameter int          RQ_DEPTH    = 4,
  parameter int          WQ_DEPTH    = 4,
  parameter int          RD_OUT      = 4,
  parameter int          WR_OUT      = 4,
  parameter int          MFIFO_LINES = 32,
  parameter logic [31:0] PERIPH_ID   = 32'h0000_0330,
  parameter bit          APB_SLVERR  = 1'b0
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // APB (core clock)
  input  logic                    psel,
  input  logic                    penable,
  input  logic                    pwrite,
  input  logic [11:0]             paddr,
  input  logic [31:0]             pwdata,
  output logic                    pready,
  output logic [31:0]             prdata,
  output logic                    pslverr,

  // Boot configuration (reported in CR0 / CR2)
  input  logic                    boot_from_pc,
  input  logic [31:0]             boot_addr,
  input  logic                    boot_manager_ns,

  // Manager status
  input  logic [31:0]             dsr,
  input  logic [31:0]             dpc,
  input  logic [31:0]             ftrd,
  input  logic                    mgr_faulting,

  // Channel status
  input  logic [31:0]             ch_csr [NUM_CH],
  input  logic [31:0]             ch_cpc [NUM_CH],
  input  logic [31:0]             ch_sar [NUM_CH],
  input  logic [31:0]             ch_dar [NUM_CH],
  input  logic [31:0]             ch_ccr [NUM_CH],
  input  logic [31:0]             ch_lc0 [NUM_CH],
  input  logic [31:0]             ch_lc1 [NUM_CH],
  input  logic [31:0]             ch_ftr [NUM_CH],
  input  logic [NUM_CH-1:0]       ch_faulting,
  input  logic [31:0]             ch_far [NUM_CH],

  // Watchdog
  output logic [15:0]             wd_timeout,
  output logic                    wd_irq_only,
  input  logic [NUM_CH-1:0]       wd_lockup_set,
  output logic [NUM_CH-1:0]       wd_stat,

  // Event / interrupt unit
  input  logic [NUM_EVENTS-1:0]   ev_flag,
  output logic [NUM_EVENTS-1:0]   inten,
  output logic                    intclr_we,
  output logic [NUM_EVENTS-1:0]   intclr_mask,

  // Debug: manager thread
  output logic                    mgr_dbg_valid,
  output logic [INSN_W-1:0]       mgr_dbg_insn,
  input  logic                    mgr_dbg_done,

  // Debug: channel threads
  output logic [NUM_CH-1:0]       ch_dbg_kill,
  output logic [NUM_CH-1:0]       ch_dbg_fault,
  output logic                    dbg_sev_valid,
  output logic [4:0]              dbg_sev_event,
  output logic                    dbg_busy
);

  //----------------------------------------------------------------------------
  // Register offsets
  //----------------------------------------------------------------------------
  localparam logic [11:0] A_DSR       = 12'h000;
  localparam logic [11:0] A_DPC       = 12'h004;
  localparam logic [11:0] A_INTEN     = 12'h020;
  localparam logic [11:0] A_RIS       = 12'h024;
  localparam logic [11:0] A_INTMIS    = 12'h028;
  localparam logic [11:0] A_INTCLR    = 12'h02C;
  localparam logic [11:0] A_FSRD      = 12'h030;
  localparam logic [11:0] A_FSRC      = 12'h034;
  localparam logic [11:0] A_FTRD      = 12'h038;
  localparam logic [11:0] A_FTR0      = 12'h040;
  localparam logic [11:0] A_FAR0      = 12'h060;
  localparam logic [11:0] A_CSR0      = 12'h100;
  localparam logic [11:0] A_SAR0      = 12'h400;
  localparam logic [11:0] A_DBGSTATUS = 12'hD00;
  localparam logic [11:0] A_DBGCMD    = 12'hD04;
  localparam logic [11:0] A_DBGINST0  = 12'hD08;
  localparam logic [11:0] A_DBGINST1  = 12'hD0C;
  localparam logic [11:0] A_CR0       = 12'hE00;
  localparam logic [11:0] A_CR1       = 12'hE04;
  localparam logic [11:0] A_CR2       = 12'hE08;
  localparam logic [11:0] A_CR3       = 12'hE0C;
  localparam logic [11:0] A_CR4       = 12'hE10;
  localparam logic [11:0] A_CRD       = 12'hE14;
  localparam logic [11:0] A_WD        = 12'hE80;
  localparam logic [11:0] A_WDSTAT    = 12'hE84;
  localparam logic [11:0] A_PERIPH_ID = 12'hFE0;
  localparam logic [11:0] A_PCELL_ID  = 12'hFF0;
  localparam logic [31:0] PCELL_ID    = 32'hB105_F00D;

  //----------------------------------------------------------------------------
  // Access decode
  //----------------------------------------------------------------------------
  logic wr_en;
  logic [11:0] addr;

  logic mapped, writable, acc_err;

  assign addr    = {paddr[11:2], 2'b00};
  assign acc_err = APB_SLVERR && (!mapped || (pwrite && !writable));
  assign wr_en   = psel && penable && pwrite && !acc_err;
  assign pready  = 1'b1;
  assign pslverr = psel && penable && acc_err;

  // Address decode: which offsets exist and which accept writes
  always_comb begin
    mapped   = 1'b0;
    writable = 1'b0;
    case (addr)
      A_DSR, A_DPC, A_RIS, A_INTMIS, A_FSRD, A_FSRC, A_FTRD, A_DBGSTATUS,
      A_CR0, A_CR1, A_CR2, A_CR3, A_CR4, A_CRD:
        mapped = 1'b1;
      A_INTEN, A_INTCLR, A_DBGCMD, A_DBGINST0, A_DBGINST1, A_WD, A_WDSTAT: begin
        mapped   = 1'b1;
        writable = 1'b1;
      end
      default: ;
    endcase
    for (int n = 0; n < NUM_CH; n++) begin
      if (addr == A_FTR0 + 12'(4 * n) || addr == A_FAR0 + 12'(4 * n) ||
          addr == A_CSR0 + 12'(8 * n) || addr == A_CSR0 + 12'(8 * n + 4))
        mapped = 1'b1;
      for (int k = 0; k < 5; k++)
        if (addr == A_SAR0 + 12'(32 * n + 4 * k)) mapped = 1'b1;
    end
    for (int k = 0; k < 4; k++) begin
      if (addr == A_PERIPH_ID + 12'(4 * k) || addr == A_PCELL_ID + 12'(4 * k))
        mapped = 1'b1;
    end
  end

  //----------------------------------------------------------------------------
  // Writable registers
  //----------------------------------------------------------------------------
  logic [31:0] dbg_inst0, dbg_inst1, wd_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      inten     <= '0;
      dbg_inst0 <= '0;
      dbg_inst1 <= '0;
      wd_reg    <= '0;
    end else if (wr_en) begin
      case (addr)
        A_INTEN:    inten     <= pwdata[NUM_EVENTS-1:0];
        // Reserved bits [15:11] and [7:1] are not implemented (read as 0)
        A_DBGINST0: dbg_inst0 <= pwdata & 32'hFFFF_0701;
        A_DBGINST1: dbg_inst1 <= pwdata;
        A_WD:       wd_reg    <= pwdata & 32'hFFFF_0001;
        default: ;
      endcase
    end
  end

  assign wd_timeout  = wd_reg[31:16];
  assign wd_irq_only = wd_reg[0];

  // WDSTAT: set by the watchdog, cleared by writing 1 (set wins)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) wd_stat <= '0;
    else        wd_stat <= (wd_stat & ~((wr_en && addr == A_WDSTAT) ? pwdata[NUM_CH-1:0] : '0))
                           | wd_lockup_set;
  end

  assign intclr_we   = wr_en && (addr == A_INTCLR);
  assign intclr_mask = pwdata[NUM_EVENTS-1:0];

  //----------------------------------------------------------------------------
  // Debug instruction dispatch
  //----------------------------------------------------------------------------
  logic              dbg_go;          // DBGCMD written with "execute"
  logic              dbg_mgr_busy;
  logic              dbg_to_ch;
  logic [2:0]        dbg_ch;
  logic [INSN_W-1:0] dbg_insn;
  insn_e             dbg_cls;

  assign dbg_insn  = {dbg_inst1, dbg_inst0[31:16]};
  assign dbg_ch    = dbg_inst0[10:8];
  assign dbg_to_ch = dbg_inst0[0];
  assign dbg_cls   = decode_op(dbg_insn[7:0]);
  assign dbg_go    = wr_en && (addr == A_DBGCMD) && (pwdata[1:0] == 2'b00) && !dbg_mgr_busy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                        dbg_mgr_busy <= 1'b0;
    else if (dbg_go && !dbg_to_ch)     dbg_mgr_busy <= 1'b1;
    else if (mgr_dbg_done)             dbg_mgr_busy <= 1'b0;
  end

  assign mgr_dbg_valid = dbg_mgr_busy;
  assign dbg_busy      = dbg_mgr_busy;
  assign mgr_dbg_insn  = dbg_insn;

  // Channel-thread debug instructions take effect immediately
  always_comb begin
    ch_dbg_kill   = '0;
    ch_dbg_fault  = '0;
    dbg_sev_valid = 1'b0;
    dbg_sev_event = dbg_insn[15:11];
    if (dbg_go && dbg_to_ch && int'(dbg_ch) < NUM_CH) begin
      case (dbg_cls)
        I_KILL:  ch_dbg_kill[dbg_ch] = 1'b1;
        I_SEV: begin
          if (int'(dbg_sev_event) < NUM_EVENTS) dbg_sev_valid       = 1'b1;
          else                                  ch_dbg_fault[dbg_ch] = 1'b1;
        end
        default: ch_dbg_fault[dbg_ch] = 1'b1;
      endcase
    end
  end

  //----------------------------------------------------------------------------
  // Configuration registers
  //----------------------------------------------------------------------------
  logic [31:0] cr0, cr1, crd;

  assign cr0 = {10'd0,
                5'(NUM_EVENTS - 1),             // [21:17]
                5'(NUM_PERIPH - 1),             // [16:12]
                4'd0,
                4'(NUM_CH - 1),                 // [7:4]
                1'b0,
                boot_manager_ns,                // [2]
                boot_from_pc,                   // [1]
                1'b1};                          // [0] peripheral requests
  assign cr1 = {24'd0, 4'(IC_LINES - 1), 1'b0, 3'($clog2(LINE_BYTES))};
  assign crd = {2'd0,
                10'(NUM_CH * MFIFO_LINES - 1),  // [29:20] data buffer lines
                4'(RQ_DEPTH - 1),               // [19:16]
                1'b0,
                3'(RD_OUT - 1),                 // [14:12]
                4'(WQ_DEPTH - 1),               // [11:8]
                1'b0,
                3'(WR_OUT - 1),                 // [6:4]
                1'b0,
                3'($clog2(DATA_W / 8))};        // [2:0] 2:32b 3:64b 4:128b

  //----------------------------------------------------------------------------
  // Read multiplexer
  //----------------------------------------------------------------------------
  always_comb begin
    prdata = '0;
    case (addr)
      A_DSR:       prdata = dsr;
      A_DPC:       prdata = dpc;
      A_INTEN:     prdata = 32'(inten);
      A_RIS:       prdata = 32'(ev_flag);
      A_INTMIS:    prdata = 32'(ev_flag & inten);
      A_FSRD:      prdata = {31'd0, mgr_faulting};
      A_FSRC:      prdata = 32'(ch_faulting);
      A_FTRD:      prdata = ftrd;
      A_DBGSTATUS: prdata = {31'd0, dbg_mgr_busy};
      A_DBGINST0:  prdata = dbg_inst0;
      A_DBGINST1:  prdata = dbg_inst1;
      A_CR0:       prdata = cr0;
      A_CR1:       prdata = cr1;
      A_CR2:       prdata = boot_addr;
      A_CR3:       prdata = '0;
      A_CR4:       prdata = '0;
      A_CRD:       prdata = crd;
      A_WD:        prdata = wd_reg;
      A_WDSTAT:    prdata = 32'(wd_stat);
      default: ;
    endcase

    // Per-channel registers
    for (int n = 0; n < NUM_CH; n++) begin
      if (addr == A_FTR0 + 12'(4 * n))        prdata = ch_ftr[n];
      if (addr == A_FAR0 + 12'(4 * n))        prdata = ch_far[n];
      if (addr == A_CSR0 + 12'(8 * n))        prdata = ch_csr[n];
      if (addr == A_CSR0 + 12'(8 * n + 4))    prdata = ch_cpc[n];
      if (addr == A_SAR0 + 12'(32 * n))       prdata = ch_sar[n];
      if (addr == A_SAR0 + 12'(32 * n + 4))   prdata = ch_dar[n];
      if (addr == A_SAR0 + 12'(32 * n + 8))   prdata = ch_ccr[n];
      if (addr == A_SAR0 + 12'(32 * n + 12))  prdata = ch_lc0[n];
      if (addr == A_SAR0 + 12'(32 * n + 16))  prdata = ch_lc1[n];
    end

    // Identification: one byte per word
    for (int k = 0; k < 4; k++) begin
      if (addr == A_PERIPH_ID + 12'(4 * k)) prdata = {24'd0, PERIPH_ID[k*8 +: 8]};
      if (addr == A_PCELL_ID  + 12'(4 * k)) prdata = {24'd0, PCELL_ID[k*8 +: 8]};
    end
  end

endmodule : dma_regs
