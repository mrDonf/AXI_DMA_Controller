//==============================================================================
// dma330_core.sv
//------------------------------------------------------------------------------
// Single-clock DMA controller core (everything in the 'clk' domain).
//
//            APB                      AXI4 master
//             |                           ^
//        +----v-----+   +-----------------+------------------+
//        | dma_regs |   |            dma_datapath            |
//        +----+-----+   |  rd_engine   mfifo[ch]   wr_engine |
//             | debug   +--^-----------------^----------^----+
//        +----v------+     | ld/st           | i-fetch  | acks
//        | manager   |--+  |                 |          |
//        +-----------+  |  |            +----+------+   |
//         DMAGO ------> channel[0..N-1]-| dma_icache|   |
//                       |  |            +-----------+   |
//        +-------------+   |      +-----------------+   |
//        |dma_event_irq|<--+----->| dma_periph_ctrl |<--+
//        +------+------+          +--------+--------+
//               v irq                      v dr/da
//
// Thread index convention: channels 0..NUM_CH-1, manager = NUM_CH.
//==============================================================================
module dma330_core
  import dma330_pkg::*;
#(
  parameter int          NUM_CH      = 4,       // 1..8
  parameter int          NUM_PERIPH  = 4,       // 1..32
  parameter int          NUM_EVENTS  = 16,      // 1..32
  parameter int          DATA_W      = 64,      // 32, 64, 128
  parameter int          ID_W        = 4,       // must encode NUM_CH and all-ones
  parameter int          RQ_DEPTH    = 4,       // per-channel read queue
  parameter int          WQ_DEPTH    = 4,       // per-channel write queue
  parameter int          RD_OUT      = 4,       // per-channel outstanding reads
  parameter int          WR_OUT      = 4,       // per-channel outstanding writes
  parameter int          MFIFO_LINES = 32,      // per-channel MFIFO lines (pow2)
  parameter int          IC_LINES    = 8,       // instruction cache lines
  parameter int          IC_BEATS    = 4,       // beats per cache line
  parameter logic [31:0] PERIPH_ID   = 32'h0000_0330,
  parameter bit          APB_SLVERR  = 1'b0     // PSLVERR on illegal accesses
) (
  input  logic                         clk,
  input  logic                         rst_n,

  // Boot configuration
  input  logic                         boot_from_pc,
  input  logic [31:0]                  boot_addr,
  input  logic                         boot_manager_ns,

  // APB slave
  input  logic                         psel,
  input  logic                         penable,
  input  logic                         pwrite,
  input  logic [11:0]                  paddr,
  input  logic [31:0]                  pwdata,
  output logic                         pready,
  output logic [31:0]                  prdata,
  output logic                         pslverr,

  // AXI4 master
  output logic                         m_awvalid,
  input  logic                         m_awready,
  output logic [ID_W-1:0]              m_awid,
  output logic [31:0]                  m_awaddr,
  output logic [7:0]                   m_awlen,
  output logic [2:0]                   m_awsize,
  output logic [1:0]                   m_awburst,
  output logic                         m_awlock,
  output logic [3:0]                   m_awcache,
  output logic [2:0]                   m_awprot,
  output logic                         m_wvalid,
  input  logic                         m_wready,
  output logic [DATA_W-1:0]            m_wdata,
  output logic [DATA_W/8-1:0]          m_wstrb,
  output logic                         m_wlast,
  input  logic                         m_bvalid,
  output logic                         m_bready,
  input  logic [ID_W-1:0]              m_bid,
  input  logic [1:0]                   m_bresp,
  output logic                         m_arvalid,
  input  logic                         m_arready,
  output logic [ID_W-1:0]              m_arid,
  output logic [31:0]                  m_araddr,
  output logic [7:0]                   m_arlen,
  output logic [2:0]                   m_arsize,
  output logic [1:0]                   m_arburst,
  output logic                         m_arlock,
  output logic [3:0]                   m_arcache,
  output logic [2:0]                   m_arprot,
  input  logic                         m_rvalid,
  output logic                         m_rready,
  input  logic [ID_W-1:0]              m_rid,
  input  logic [DATA_W-1:0]            m_rdata,
  input  logic [1:0]                   m_rresp,
  input  logic                         m_rlast,

  // Peripheral request interface (core clock domain)
  input  logic [NUM_PERIPH-1:0]        dr_valid,
  output logic [NUM_PERIPH-1:0]        dr_ready,
  input  logic [NUM_PERIPH-1:0][1:0]   dr_type,
  input  logic [NUM_PERIPH-1:0]        dr_last,
  output logic [NUM_PERIPH-1:0]        da_valid,
  input  logic [NUM_PERIPH-1:0]        da_ready,
  output logic [NUM_PERIPH-1:0][1:0]   da_type,

  // Interrupts
  output logic [NUM_EVENTS-1:0]        irq,
  output logic                         irq_abort,

  // Low-power Q-Channel (qreqn asynchronous, others clk domain)
  input  logic                         qreqn,
  output logic                         qacceptn,
  output logic                         qdeny,
  output logic                         busy          // core not quiescent
);

  localparam int NUM_THREADS = NUM_CH + 1;
  localparam int MGR         = NUM_CH;               // manager thread index
  localparam int LINE_BYTES  = IC_BEATS * DATA_W / 8;
  localparam int LINE_W      = LINE_BYTES * 8;

  //============================================================================
  // Interconnect signals
  //============================================================================
  // Instruction cache
  logic [NUM_THREADS-1:0] ic_req, ic_ns, ic_inv_req, ic_resp_valid;
  logic [ADDR_W-1:0]      ic_addr [NUM_THREADS];
  logic [LINE_W-1:0]      ic_resp_data;
  logic                   ic_resp_err;
  logic                   ic_inv_all;

  // Events
  logic [NUM_THREADS-1:0] sev_valid, wfe_valid, wfe_hit;
  logic [4:0]             sev_event [NUM_THREADS];
  logic [4:0]             wfe_event [NUM_THREADS];
  logic [NUM_EVENTS-1:0]  inten, ev_flag, intclr_mask;
  logic                   intclr_we;
  logic                   dbg_sev_valid;
  logic [4:0]             dbg_sev_event;

  // Peripheral
  logic [NUM_THREADS-1:0] flush_valid, flush_ready;
  logic [4:0]             flush_periph [NUM_THREADS];
  logic [NUM_CH-1:0]      wfp_valid, wfp_gnt, wfp_burst, wfp_last;
  logic [4:0]             wfp_periph [NUM_CH];
  logic                   rd_ack_valid, rd_ack_ready, rd_ack_burst;
  logic                   wr_ack_valid, wr_ack_ready, wr_ack_burst;
  logic [4:0]             rd_ack_periph, wr_ack_periph;

  // Manager -> channels
  logic [NUM_CH-1:0]      go_valid;
  logic [ADDR_W-1:0]      go_pc;
  logic                   go_ns;

  // Debug
  logic                   mgr_dbg_valid, mgr_dbg_done;
  logic [INSN_W-1:0]      mgr_dbg_insn;
  logic [NUM_CH-1:0]      ch_dbg_kill, ch_dbg_fault;

  // Channels <-> data path
  logic [NUM_CH-1:0]      ld_valid, ld_ready, ld_lockup;
  logic [NUM_CH-1:0]      st_valid, st_ready, st_short;
  xfer_t                  ld_xfer [NUM_CH];
  xfer_t                  st_xfer [NUM_CH];
  logic [NUM_CH-1:0]      ch_flush, rd_busy, wr_busy, rd_err, wr_err;

  // Status
  logic [31:0]            dsr, dpc, ftrd;
  logic                   mgr_faulting;
  logic [31:0]            ch_csr [NUM_CH], ch_cpc [NUM_CH], ch_sar [NUM_CH], ch_dar [NUM_CH];
  logic [31:0]            ch_ccr [NUM_CH], ch_lc0 [NUM_CH], ch_lc1 [NUM_CH], ch_ftr [NUM_CH];
  logic [NUM_CH-1:0]      ch_faulting;
  logic [31:0]            ch_far [NUM_CH];
  logic [ADDR_W-1:0]      rd_err_addr, wr_err_addr;

  // Watchdog
  logic [15:0]            wd_timeout;
  logic                   wd_irq_only;
  logic [NUM_CH-1:0]      wd_active, wd_progress, wd_lockup_set, wd_lockup_fault, wd_stat;

  // Low power
  logic                   q_run, core_idle, ic_idle, dbg_busy;
  logic                   r_psel, r_pready, r_pslverr;
  logic [NUM_PERIPH-1:0]  pc_dr_valid, pc_dr_ready;

  // i-cache refill path
  logic                   icr_ar_valid, icr_ar_ready, icr_r_valid, icr_r_ready, icr_r_last;
  logic [ADDR_W-1:0]      icr_ar_addr;
  logic [7:0]             icr_ar_len;
  logic [2:0]             icr_ar_size, icr_ar_prot;
  logic [3:0]             icr_ar_cache;
  logic [DATA_W-1:0]      icr_r_data;
  logic [1:0]             icr_r_resp;

  assign ic_inv_all = |ic_inv_req;
  assign m_awlock   = 1'b0;
  assign m_arlock   = 1'b0;

  //============================================================================
  // Register file
  //============================================================================
  dma_regs #(
    .NUM_CH      (NUM_CH),
    .NUM_PERIPH  (NUM_PERIPH),
    .NUM_EVENTS  (NUM_EVENTS),
    .DATA_W      (DATA_W),
    .IC_LINES    (IC_LINES),
    .LINE_BYTES  (LINE_BYTES),
    .RQ_DEPTH    (RQ_DEPTH),
    .WQ_DEPTH    (WQ_DEPTH),
    .RD_OUT      (RD_OUT),
    .WR_OUT      (WR_OUT),
    .MFIFO_LINES (MFIFO_LINES),
    .PERIPH_ID   (PERIPH_ID),
    .APB_SLVERR  (APB_SLVERR)
  ) u_regs (
    .clk             (clk),
    .rst_n           (rst_n),
    .psel            (r_psel),
    .penable         (penable),
    .pwrite          (pwrite),
    .paddr           (paddr),
    .pwdata          (pwdata),
    .pready          (r_pready),
    .prdata          (prdata),
    .pslverr         (r_pslverr),
    .boot_from_pc    (boot_from_pc),
    .boot_addr       (boot_addr),
    .boot_manager_ns (boot_manager_ns),
    .dsr             (dsr),
    .dpc             (dpc),
    .ftrd            (ftrd),
    .mgr_faulting    (mgr_faulting),
    .ch_csr          (ch_csr),
    .ch_cpc          (ch_cpc),
    .ch_sar          (ch_sar),
    .ch_dar          (ch_dar),
    .ch_ccr          (ch_ccr),
    .ch_lc0          (ch_lc0),
    .ch_lc1          (ch_lc1),
    .ch_ftr          (ch_ftr),
    .ch_faulting     (ch_faulting),
    .ch_far          (ch_far),
    .wd_timeout      (wd_timeout),
    .wd_irq_only     (wd_irq_only),
    .wd_lockup_set   (wd_lockup_set),
    .wd_stat         (wd_stat),
    .ev_flag         (ev_flag),
    .inten           (inten),
    .intclr_we       (intclr_we),
    .intclr_mask     (intclr_mask),
    .mgr_dbg_valid   (mgr_dbg_valid),
    .mgr_dbg_insn    (mgr_dbg_insn),
    .mgr_dbg_done    (mgr_dbg_done),
    .ch_dbg_kill     (ch_dbg_kill),
    .ch_dbg_fault    (ch_dbg_fault),
    .dbg_sev_valid   (dbg_sev_valid),
    .dbg_sev_event   (dbg_sev_event),
    .dbg_busy        (dbg_busy)
  );

  //============================================================================
  // Manager thread
  //============================================================================
  dma_manager #(
    .NUM_CH     (NUM_CH),
    .NUM_PERIPH (NUM_PERIPH),
    .NUM_EVENTS (NUM_EVENTS),
    .LINE_BYTES (LINE_BYTES)
  ) u_manager (
    .clk             (clk),
    .rst_n           (rst_n),
    .boot_from_pc    (boot_from_pc),
    .boot_addr       (boot_addr),
    .boot_manager_ns (boot_manager_ns),
    .ic_inv_all      (ic_inv_all),
    .ic_inv_req      (ic_inv_req[MGR]),
    .ic_req          (ic_req[MGR]),
    .ic_addr         (ic_addr[MGR]),
    .ic_ns           (ic_ns[MGR]),
    .ic_resp_valid   (ic_resp_valid[MGR]),
    .ic_resp_data    (ic_resp_data),
    .ic_resp_err     (ic_resp_err),
    .go_valid        (go_valid),
    .go_pc           (go_pc),
    .go_ns           (go_ns),
    .sev_valid       (sev_valid[MGR]),
    .sev_event       (sev_event[MGR]),
    .wfe_valid       (wfe_valid[MGR]),
    .wfe_event       (wfe_event[MGR]),
    .wfe_hit         (wfe_hit[MGR]),
    .flush_valid     (flush_valid[MGR]),
    .flush_periph    (flush_periph[MGR]),
    .flush_ready     (flush_ready[MGR]),
    .dbg_valid       (mgr_dbg_valid),
    .dbg_insn        (mgr_dbg_insn),
    .dbg_done        (mgr_dbg_done),
    .dsr             (dsr),
    .dpc             (dpc),
    .ftrd            (ftrd),
    .faulting        (mgr_faulting)
  );

  //============================================================================
  // Channel threads
  //============================================================================
  for (genvar ch = 0; ch < NUM_CH; ch++) begin : g_ch
    dma_channel #(
      .CH_ID      (ch),
      .NUM_PERIPH (NUM_PERIPH),
      .NUM_EVENTS (NUM_EVENTS),
      .DATA_W     (DATA_W),
      .LINE_BYTES (LINE_BYTES)
    ) u_channel (
      .clk           (clk),
      .rst_n         (rst_n),
      .go_valid      (go_valid[ch]),
      .go_pc         (go_pc),
      .go_ns         (go_ns),
      .dbg_kill      (ch_dbg_kill[ch]),
      .dbg_fault     (ch_dbg_fault[ch]),
      .wd_fault      (wd_lockup_fault[ch]),
      .ic_inv_all    (ic_inv_all),
      .ic_inv_req    (ic_inv_req[ch]),
      .ic_req        (ic_req[ch]),
      .ic_addr       (ic_addr[ch]),
      .ic_ns         (ic_ns[ch]),
      .ic_resp_valid (ic_resp_valid[ch]),
      .ic_resp_data  (ic_resp_data),
      .ic_resp_err   (ic_resp_err),
      .sev_valid     (sev_valid[ch]),
      .sev_event     (sev_event[ch]),
      .wfe_valid     (wfe_valid[ch]),
      .wfe_event     (wfe_event[ch]),
      .wfe_hit       (wfe_hit[ch]),
      .wfp_valid     (wfp_valid[ch]),
      .wfp_periph    (wfp_periph[ch]),
      .wfp_gnt       (wfp_gnt[ch]),
      .wfp_burst     (wfp_burst[ch]),
      .wfp_last      (wfp_last[ch]),
      .flush_valid   (flush_valid[ch]),
      .flush_periph  (flush_periph[ch]),
      .flush_ready   (flush_ready[ch]),
      .ld_valid      (ld_valid[ch]),
      .ld_xfer       (ld_xfer[ch]),
      .ld_ready      (ld_ready[ch]),
      .ld_lockup     (ld_lockup[ch]),
      .st_valid      (st_valid[ch]),
      .st_xfer       (st_xfer[ch]),
      .st_ready      (st_ready[ch]),
      .st_short      (st_short[ch]),
      .rd_busy       (rd_busy[ch]),
      .wr_busy       (wr_busy[ch]),
      .rd_err        (rd_err[ch]),
      .wr_err        (wr_err[ch]),
      .rd_err_addr   (rd_err_addr),
      .wr_err_addr   (wr_err_addr),
      .dp_flush      (ch_flush[ch]),
      .csr           (ch_csr[ch]),
      .cpc           (ch_cpc[ch]),
      .sar_o         (ch_sar[ch]),
      .dar_o         (ch_dar[ch]),
      .ccr_o         (ch_ccr[ch]),
      .lc0_o         (ch_lc0[ch]),
      .lc1_o         (ch_lc1[ch]),
      .ftr           (ch_ftr[ch]),
      .far           (ch_far[ch]),
      .faulting      (ch_faulting[ch])
    );
  end

  //============================================================================
  // Instruction cache
  //============================================================================
  dma_icache #(
    .NUM_THREADS (NUM_THREADS),
    .DATA_W      (DATA_W),
    .LINE_BEATS  (IC_BEATS),
    .NUM_LINES   (IC_LINES)
  ) u_icache (
    .clk        (clk),
    .rst_n      (rst_n),
    .inv_all    (ic_inv_all),
    .idle       (ic_idle),
    .req        (ic_req),
    .req_addr   (ic_addr),
    .req_ns     (ic_ns),
    .resp_valid (ic_resp_valid),
    .resp_data  (ic_resp_data),
    .resp_err   (ic_resp_err),
    .ar_valid   (icr_ar_valid),
    .ar_ready   (icr_ar_ready),
    .ar_addr    (icr_ar_addr),
    .ar_len     (icr_ar_len),
    .ar_size    (icr_ar_size),
    .ar_cache   (icr_ar_cache),
    .ar_prot    (icr_ar_prot),
    .r_valid    (icr_r_valid),
    .r_ready    (icr_r_ready),
    .r_data     (icr_r_data),
    .r_resp     (icr_r_resp),
    .r_last     (icr_r_last)
  );

  //============================================================================
  // Event / interrupt unit
  //============================================================================
  dma_event_irq #(
    .NUM_EVENTS  (NUM_EVENTS),
    .NUM_THREADS (NUM_THREADS)
  ) u_event_irq (
    .clk           (clk),
    .rst_n         (rst_n),
    .sev_valid     (sev_valid),
    .sev_event     (sev_event),
    .wfe_valid     (wfe_valid),
    .wfe_event     (wfe_event),
    .wfe_hit       (wfe_hit),
    .dbg_sev_valid (dbg_sev_valid),
    .dbg_sev_event (dbg_sev_event),
    .inten         (inten),
    .intclr_we     (intclr_we),
    .intclr_mask   (intclr_mask),
    .ev_flag       (ev_flag),
    .irq           (irq)
  );

  // Abort interrupt: a thread is faulting, or the watchdog reported a lock-up
  assign irq_abort = mgr_faulting || (|ch_faulting) || (|wd_stat);

  //============================================================================
  // Peripheral request controller
  //============================================================================
  logic [1:0] dr_type_a [NUM_PERIPH];
  logic [1:0] da_type_a [NUM_PERIPH];

  for (genvar p = 0; p < NUM_PERIPH; p++) begin : g_periph_map
    assign dr_type_a[p] = dr_type[p];
    assign da_type[p]   = da_type_a[p];
  end

  dma_periph_ctrl #(
    .NUM_PERIPH  (NUM_PERIPH),
    .NUM_CH      (NUM_CH),
    .NUM_THREADS (NUM_THREADS)
  ) u_periph_ctrl (
    .clk           (clk),
    .rst_n         (rst_n),
    .dr_valid      (pc_dr_valid),
    .dr_ready      (pc_dr_ready),
    .dr_type       (dr_type_a),
    .dr_last       (dr_last),
    .da_valid      (da_valid),
    .da_ready      (da_ready),
    .da_type       (da_type_a),
    .wfp_valid     (wfp_valid),
    .wfp_periph    (wfp_periph),
    .wfp_gnt       (wfp_gnt),
    .wfp_burst     (wfp_burst),
    .wfp_last      (wfp_last),
    .flush_valid   (flush_valid),
    .flush_periph  (flush_periph),
    .flush_ready   (flush_ready),
    .rd_ack_valid  (rd_ack_valid),
    .rd_ack_ready  (rd_ack_ready),
    .rd_ack_periph (rd_ack_periph),
    .rd_ack_burst  (rd_ack_burst),
    .wr_ack_valid  (wr_ack_valid),
    .wr_ack_ready  (wr_ack_ready),
    .wr_ack_periph (wr_ack_periph),
    .wr_ack_burst  (wr_ack_burst)
  );

  //============================================================================
  // Data path
  //============================================================================
  dma_datapath #(
    .NUM_CH      (NUM_CH),
    .DATA_W      (DATA_W),
    .ID_W        (ID_W),
    .RQ_DEPTH    (RQ_DEPTH),
    .WQ_DEPTH    (WQ_DEPTH),
    .RD_OUT      (RD_OUT),
    .WR_OUT      (WR_OUT),
    .MFIFO_LINES (MFIFO_LINES)
  ) u_datapath (
    .clk           (clk),
    .rst_n         (rst_n),
    .ld_valid      (ld_valid),
    .ld_xfer       (ld_xfer),
    .ld_ready      (ld_ready),
    .ld_lockup     (ld_lockup),
    .st_valid      (st_valid),
    .st_xfer       (st_xfer),
    .st_ready      (st_ready),
    .st_short      (st_short),
    .ch_flush      (ch_flush),
    .rd_busy       (rd_busy),
    .wr_busy       (wr_busy),
    .rd_err        (rd_err),
    .wr_err        (wr_err),
    .rd_err_addr   (rd_err_addr),
    .wr_err_addr   (wr_err_addr),
    .ic_ar_valid   (icr_ar_valid),
    .ic_ar_ready   (icr_ar_ready),
    .ic_ar_addr    (icr_ar_addr),
    .ic_ar_len     (icr_ar_len),
    .ic_ar_size    (icr_ar_size),
    .ic_ar_cache   (icr_ar_cache),
    .ic_ar_prot    (icr_ar_prot),
    .ic_r_valid    (icr_r_valid),
    .ic_r_ready    (icr_r_ready),
    .ic_r_data     (icr_r_data),
    .ic_r_resp     (icr_r_resp),
    .ic_r_last     (icr_r_last),
    .m_awvalid     (m_awvalid),
    .m_awready     (m_awready),
    .m_awid        (m_awid),
    .m_awaddr      (m_awaddr),
    .m_awlen       (m_awlen),
    .m_awsize      (m_awsize),
    .m_awburst     (m_awburst),
    .m_awcache     (m_awcache),
    .m_awprot      (m_awprot),
    .m_wvalid      (m_wvalid),
    .m_wready      (m_wready),
    .m_wdata       (m_wdata),
    .m_wstrb       (m_wstrb),
    .m_wlast       (m_wlast),
    .m_bvalid      (m_bvalid),
    .m_bready      (m_bready),
    .m_bid         (m_bid),
    .m_bresp       (m_bresp),
    .m_arvalid     (m_arvalid),
    .m_arready     (m_arready),
    .m_arid        (m_arid),
    .m_araddr      (m_araddr),
    .m_arlen       (m_arlen),
    .m_arsize      (m_arsize),
    .m_arburst     (m_arburst),
    .m_arcache     (m_arcache),
    .m_arprot      (m_arprot),
    .m_rvalid      (m_rvalid),
    .m_rready      (m_rready),
    .m_rid         (m_rid),
    .m_rdata       (m_rdata),
    .m_rresp       (m_rresp),
    .m_rlast       (m_rlast),
    .rd_ack_valid  (rd_ack_valid),
    .rd_ack_ready  (rd_ack_ready),
    .rd_ack_periph (rd_ack_periph),
    .rd_ack_burst  (rd_ack_burst),
    .wr_ack_valid  (wr_ack_valid),
    .wr_ack_ready  (wr_ack_ready),
    .wr_ack_periph (wr_ack_periph),
    .wr_ack_burst  (wr_ack_burst)
  );

  //============================================================================
  // Watchdog: per-channel activity and progress
  //============================================================================
  for (genvar ch = 0; ch < NUM_CH; ch++) begin : g_wd
    logic [3:0]  st, st_q;
    logic [31:0] cpc_q;
    logic [ID_W-1:0] id;
    logic        axi_hs;

    assign st = ch_csr[ch][3:0];
    assign id = ID_W'(ch);

    // Legitimate unbounded waits (event / peripheral) and stopped / faulting
    // states are not watched, unless AXI work is still queued or in flight.
    assign wd_active[ch] = !(st inside {ST_STOPPED, ST_WAIT_EVENT, ST_WAIT_PERIPH, ST_FAULTING}) ||
                           rd_busy[ch] || wr_busy[ch];

    assign axi_hs = (m_arvalid && m_arready && m_arid == id) ||
                    (m_rvalid  && m_rready  && m_rid  == id) ||
                    (m_awvalid && m_awready && m_awid == id) ||
                    (m_wvalid  && m_wready  && m_awid == id) ||   // AWID = active W burst
                    (m_bvalid  && m_bready  && m_bid  == id);

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        st_q  <= ST_STOPPED;
        cpc_q <= '0;
      end else begin
        st_q  <= st;
        cpc_q <= ch_cpc[ch];
      end
    end

    assign wd_progress[ch] = axi_hs || ic_resp_valid[ch] || (st != st_q) || (ch_cpc[ch] != cpc_q);
  end

  dma_watchdog #(.NUM_CH(NUM_CH)) u_watchdog (
    .clk          (clk),
    .rst_n        (rst_n),
    .timeout      (wd_timeout),
    .irq_only     (wd_irq_only),
    .active       (wd_active),
    .progress     (wd_progress),
    .lockup_set   (wd_lockup_set),
    .lockup_fault (wd_lockup_fault)
  );

  //============================================================================
  // Low-power Q-Channel
  //============================================================================
  // Quiescent: every thread stopped or faulting, no data-path work, no
  // instruction fetch, no pending acknowledge or debug instruction, no APB
  // transfer.
  always_comb begin
    core_idle = (dsr[3:0] inside {ST_STOPPED, ST_FAULTING}) && ic_idle && !dbg_busy &&
                !(|rd_busy) && !(|wr_busy) && !(|da_valid) && !psel;
    for (int ch = 0; ch < NUM_CH; ch++)
      if (!(ch_csr[ch][3:0] inside {ST_STOPPED, ST_FAULTING})) core_idle = 1'b0;
  end

  dma_qchannel u_qchannel (
    .clk      (clk),
    .rst_n    (rst_n),
    .qreqn    (qreqn),
    .idle     (core_idle),
    .qacceptn (qacceptn),
    .qdeny    (qdeny),
    .run      (q_run)
  );

  assign busy = !core_idle;

  // While quiescent, APB transfers wait (PREADY = 0) and peripheral requests
  // are not accepted (DRREADY = 0).
  // (the register file is zero-wait-state: r_pready is always 1, and it sees
  // no transfer, hence reports no error, while quiescent)
  assign r_psel      = psel && q_run;
  assign pready      = q_run;
  assign pslverr     = r_pslverr;
  assign pc_dr_valid = dr_valid & {NUM_PERIPH{q_run}};
  assign dr_ready    = pc_dr_ready & {NUM_PERIPH{q_run}};

  //============================================================================
  // Elaboration-time parameter checks
  //============================================================================
  initial begin
    if (NUM_CH < 1 || NUM_CH > 8)
      $fatal(1, "dma330_core: NUM_CH must be 1..8");
    if (NUM_PERIPH < 1 || NUM_PERIPH > 32)
      $fatal(1, "dma330_core: NUM_PERIPH must be 1..32");
    if (NUM_EVENTS < 1 || NUM_EVENTS > 32)
      $fatal(1, "dma330_core: NUM_EVENTS must be 1..32");
    if (!(DATA_W inside {32, 64, 128}))
      $fatal(1, "dma330_core: DATA_W must be 32, 64 or 128");
    if ((1 << ID_W) - 1 <= NUM_CH)
      $fatal(1, "dma330_core: ID_W too small (needs channel IDs + IFETCH ID)");
    if (MFIFO_LINES * DATA_W / 8 < 2 * 16 * DATA_W / 8)
      $fatal(1, "dma330_core: MFIFO_LINES must hold two max-length bursts");
    if ((MFIFO_LINES & (MFIFO_LINES - 1)) != 0 || NUM_CH * MFIFO_LINES > 1024)
      $fatal(1, "dma330_core: MFIFO_LINES must be a power of two, NUM_CH*MFIFO_LINES <= 1024");
    if ((IC_BEATS & (IC_BEATS - 1)) != 0 || IC_BEATS * DATA_W / 8 < 8 || IC_LINES < 1 || IC_LINES > 16)
      $fatal(1, "dma330_core: IC_BEATS must be a power of two (line >= 8 bytes), IC_LINES 1..16");
    if (RQ_DEPTH > 16 || WQ_DEPTH > 16 || RD_OUT > 8 || WR_OUT > 8)
      $fatal(1, "dma330_core: RQ/WQ_DEPTH must be <= 16, RD/WR_OUT <= 8 (CRD fields)");
  end

endmodule : dma330_core
