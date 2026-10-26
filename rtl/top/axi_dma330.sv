//==============================================================================
// axi_dma330.sv
//------------------------------------------------------------------------------
// Top level of the AXI DMA controller (DMA-330 / PL330 style).
//
// Clock domains
//   aclk        DMA core (threads, data path, MFIFO, registers) and the AXI4
//               master port: the core runs on the AXI clock, as in DMA-330,
//               so the AXI port needs no clock-domain crossing
//   pclk        both APB configuration ports       (APB_ASYNC = 1)
//   periph_clk  one clock per peripheral interface (PERIPH_ASYNC = 1)
//
// When a *_ASYNC parameter is 0 the corresponding interface is synchronous to
// 'aclk' and its clock/reset inputs are unused (tie them to aclk / aresetn).
//
//             pclk                  aclk
//   APB S  ->[apb_async_bridge]->+-------------+
//   APB NS ->[apb_async_bridge]->| dma330_core |-> AXI4
//                                +-------------+
//                                     ^  |
//   periph_clk[p]: dr/da <->[periph_sync]
//
// Security: the secure APB port controls everything; the non-secure port sees
// and controls only the non-secure manager, channels and events (DSR.DNS,
// CSRn.CNS, CR3). boot_irq_ns / boot_periph_ns (sampled once after reset)
// make an event / a peripheral usable by non-secure threads.
//
// Every asynchronous reset input is synchronized to its own domain
// (asynchronous assert, synchronous de-assert). Each clock-domain crossing
// (APB bridge, peripheral synchronizer) is reset as a whole, on both sides,
// whenever either of its two domains is reset: its toggle handshakes then
// always restart from the same state, and a reset of one side alone can not
// make the other side see a phantom transfer.
//
// Low power: AMBA Q-Channel on 'aclk' (qreqn is synchronized inside).
// qactive = core busy OR an APB transfer is requested; it is an asynchronous
// output intended for the clock controller. Gating 'aclk' of the DMA (not of
// the interconnect) is legal while the Q-Channel is in Q_STOPPED.
//==============================================================================
module axi_dma330 #(
  parameter int          NUM_CH       = 4,
  parameter int          NUM_PERIPH   = 4,
  parameter int          NUM_EVENTS   = 16,
  parameter int          DATA_W       = 64,
  parameter int          ID_W         = 4,
  parameter int          RQ_DEPTH     = 4,
  parameter int          WQ_DEPTH     = 4,
  parameter int          RD_OUT       = 4,
  parameter int          WR_OUT       = 4,
  parameter int          MFIFO_LINES  = 128,       // shared by all channels
  parameter int          IC_LINES     = 8,
  parameter int          IC_BEATS     = 4,
  parameter logic [31:0] PERIPH_ID    = 32'h0034_1330,  // DMA-330 r1p2 (periph_id_3..0)
  // Clock-domain crossing configuration
  parameter bit          APB_ASYNC    = 1'b0,
  parameter bit          PERIPH_ASYNC = 1'b0,
  // PSLVERR on unmapped addresses / writes to read-only registers
  parameter bit          APB_SLVERR   = 1'b0
) (
  // DMA core + AXI clock / reset
  input  logic                        aclk,
  input  logic                        aresetn,
  // APB clock / reset
  input  logic                        pclk,
  input  logic                        presetn,
  // Peripheral clocks / resets
  input  logic [NUM_PERIPH-1:0]       periph_clk,
  input  logic [NUM_PERIPH-1:0]       periph_rst_n,

  // Boot configuration (static)
  input  logic                        boot_from_pc,
  input  logic [31:0]                 boot_addr,
  input  logic                        boot_manager_ns,
  input  logic [NUM_EVENTS-1:0]       boot_irq_ns,      // 1: event / irq usable by NS threads
  input  logic [NUM_PERIPH-1:0]       boot_periph_ns,   // 1: peripheral usable by NS threads

  // APB4 slave, secure (pclk domain)
  input  logic                        psel,
  input  logic                        penable,
  input  logic                        pwrite,
  input  logic [11:0]                 paddr,
  input  logic [31:0]                 pwdata,
  output logic                        pready,
  output logic [31:0]                 prdata,
  output logic                        pslverr,

  // APB4 slave, non-secure (pclk domain)
  input  logic                        psel_ns,
  input  logic                        penable_ns,
  input  logic                        pwrite_ns,
  input  logic [11:0]                 paddr_ns,
  input  logic [31:0]                 pwdata_ns,
  output logic                        pready_ns,
  output logic [31:0]                 prdata_ns,
  output logic                        pslverr_ns,

  // AXI4 master (aclk domain)
  output logic                        m_axi_awvalid,
  input  logic                        m_axi_awready,
  output logic [ID_W-1:0]             m_axi_awid,
  output logic [31:0]                 m_axi_awaddr,
  output logic [7:0]                  m_axi_awlen,
  output logic [2:0]                  m_axi_awsize,
  output logic [1:0]                  m_axi_awburst,
  output logic                        m_axi_awlock,
  output logic [3:0]                  m_axi_awcache,
  output logic [2:0]                  m_axi_awprot,
  output logic                        m_axi_wvalid,
  input  logic                        m_axi_wready,
  output logic [DATA_W-1:0]           m_axi_wdata,
  output logic [DATA_W/8-1:0]         m_axi_wstrb,
  output logic                        m_axi_wlast,
  input  logic                        m_axi_bvalid,
  output logic                        m_axi_bready,
  input  logic [ID_W-1:0]             m_axi_bid,
  input  logic [1:0]                  m_axi_bresp,
  output logic                        m_axi_arvalid,
  input  logic                        m_axi_arready,
  output logic [ID_W-1:0]             m_axi_arid,
  output logic [31:0]                 m_axi_araddr,
  output logic [7:0]                  m_axi_arlen,
  output logic [2:0]                  m_axi_arsize,
  output logic [1:0]                  m_axi_arburst,
  output logic                        m_axi_arlock,
  output logic [3:0]                  m_axi_arcache,
  output logic [2:0]                  m_axi_arprot,
  input  logic                        m_axi_rvalid,
  output logic                        m_axi_rready,
  input  logic [ID_W-1:0]             m_axi_rid,
  input  logic [DATA_W-1:0]           m_axi_rdata,
  input  logic [1:0]                  m_axi_rresp,
  input  logic                        m_axi_rlast,

  // Peripheral request interfaces (periph_clk[p] domain)
  input  logic [NUM_PERIPH-1:0]       drvalid,
  output logic [NUM_PERIPH-1:0]       drready,
  input  logic [NUM_PERIPH-1:0][1:0]  drtype,
  input  logic [NUM_PERIPH-1:0]       drlast,
  output logic [NUM_PERIPH-1:0]       davalid,
  input  logic [NUM_PERIPH-1:0]       daready,
  output logic [NUM_PERIPH-1:0][1:0]  datype,

  // Interrupts (aclk domain, level sensitive)
  output logic [NUM_EVENTS-1:0]       irq,
  output logic                        irq_abort,

  // Low-power Q-Channel (aclk domain; qreqn asynchronous, tie high if unused)
  input  logic                        qreqn,
  output logic                        qacceptn,
  output logic                        qdeny,
  output logic                        qactive
);

  //============================================================================
  // Core reset
  //============================================================================
  logic core_rst_n;
  logic core_busy;

  dma_rst_sync u_core_rst_sync (
    .clk    (aclk),
    .arst_n (aresetn),
    .rst_n  (core_rst_n)
  );

  //============================================================================
  // APB ports: [0] secure, [1] non-secure
  //============================================================================
  logic [1:0]        s_psel, s_penable, s_pwrite, s_pready, s_pslverr;
  logic [1:0][11:0]  s_paddr;
  logic [1:0][31:0]  s_pwdata, s_prdata;
  logic [1:0]        c_psel, c_penable, c_pwrite, c_pready, c_pslverr;
  logic [1:0][11:0]  c_paddr;
  logic [1:0][31:0]  c_pwdata, c_prdata;

  assign s_psel    = {psel_ns,    psel};
  assign s_penable = {penable_ns, penable};
  assign s_pwrite  = {pwrite_ns,  pwrite};
  assign s_paddr   = {paddr_ns,   paddr};
  assign s_pwdata  = {pwdata_ns,  pwdata};
  assign {pready_ns,  pready}  = s_pready;
  assign {prdata_ns,  prdata}  = s_prdata;
  assign {pslverr_ns, pslverr} = s_pslverr;

  if (APB_ASYNC) begin : g_apb_async
    logic apb_rst_n;        // bridge, pclk side
    logic apb_core_rst_n;   // bridge, aclk side

    dma_rst_sync u_apb_rst_sync (
      .clk    (pclk),
      .arst_n (presetn && aresetn),
      .rst_n  (apb_rst_n)
    );

    dma_rst_sync u_apb_core_rst_sync (
      .clk    (aclk),
      .arst_n (presetn && aresetn),
      .rst_n  (apb_core_rst_n)
    );

    for (genvar i = 0; i < 2; i++) begin : g_port
      dma_apb_async_bridge #(.ADDR_W(12), .DATA_W(32)) u_apb_bridge (
        .pclk      (pclk),
        .presetn   (apb_rst_n),
        .s_psel    (s_psel[i]),
        .s_penable (s_penable[i]),
        .s_pwrite  (s_pwrite[i]),
        .s_paddr   (s_paddr[i]),
        .s_pwdata  (s_pwdata[i]),
        .s_pready  (s_pready[i]),
        .s_prdata  (s_prdata[i]),
        .s_pslverr (s_pslverr[i]),
        .clk       (aclk),
        .rst_n     (apb_core_rst_n),
        .m_psel    (c_psel[i]),
        .m_penable (c_penable[i]),
        .m_pwrite  (c_pwrite[i]),
        .m_paddr   (c_paddr[i]),
        .m_pwdata  (c_pwdata[i]),
        .m_pready  (c_pready[i]),
        .m_prdata  (c_prdata[i]),
        .m_pslverr (c_pslverr[i])
      );
    end
  end else begin : g_apb_sync
    assign c_psel    = s_psel;
    assign c_penable = s_penable;
    assign c_pwrite  = s_pwrite;
    assign c_paddr   = s_paddr;
    assign c_pwdata  = s_pwdata;
    assign s_pready  = c_pready;
    assign s_prdata  = c_prdata;
    assign s_pslverr = c_pslverr;
  end

  //============================================================================
  // Peripheral ports
  //============================================================================
  logic [NUM_PERIPH-1:0]      c_dr_valid, c_dr_ready, c_dr_last;
  logic [NUM_PERIPH-1:0][1:0] c_dr_type, c_da_type;
  logic [NUM_PERIPH-1:0]      c_da_valid, c_da_ready;

  for (genvar p = 0; p < NUM_PERIPH; p++) begin : g_periph
    if (PERIPH_ASYNC) begin : g_async
      logic p_rst_n;        // synchronizer, peripheral side
      logic p_core_rst_n;   // synchronizer, aclk side

      dma_rst_sync u_periph_rst_sync (
        .clk    (periph_clk[p]),
        .arst_n (periph_rst_n[p] && aresetn),
        .rst_n  (p_rst_n)
      );

      dma_rst_sync u_periph_core_rst_sync (
        .clk    (aclk),
        .arst_n (periph_rst_n[p] && aresetn),
        .rst_n  (p_core_rst_n)
      );

      dma_periph_sync u_periph_sync (
        .periph_clk   (periph_clk[p]),
        .periph_rst_n (p_rst_n),
        .drvalid      (drvalid[p]),
        .drready      (drready[p]),
        .drtype       (drtype[p]),
        .drlast       (drlast[p]),
        .davalid      (davalid[p]),
        .daready      (daready[p]),
        .datype       (datype[p]),
        .clk          (aclk),
        .rst_n        (p_core_rst_n),
        .dr_valid     (c_dr_valid[p]),
        .dr_ready     (c_dr_ready[p]),
        .dr_type      (c_dr_type[p]),
        .dr_last      (c_dr_last[p]),
        .da_valid     (c_da_valid[p]),
        .da_ready     (c_da_ready[p]),
        .da_type      (c_da_type[p])
      );
    end else begin : g_sync
      assign c_dr_valid[p] = drvalid[p];
      assign drready[p]    = c_dr_ready[p];
      assign c_dr_type[p]  = drtype[p];
      assign c_dr_last[p]  = drlast[p];
      assign davalid[p]    = c_da_valid[p];
      assign c_da_ready[p] = daready[p];
      assign datype[p]     = c_da_type[p];
    end
  end

  //============================================================================
  // DMA core (aclk domain, drives the AXI master port directly)
  //============================================================================
  dma330_core #(
    .NUM_CH      (NUM_CH),
    .NUM_PERIPH  (NUM_PERIPH),
    .NUM_EVENTS  (NUM_EVENTS),
    .DATA_W      (DATA_W),
    .ID_W        (ID_W),
    .RQ_DEPTH    (RQ_DEPTH),
    .WQ_DEPTH    (WQ_DEPTH),
    .RD_OUT      (RD_OUT),
    .WR_OUT      (WR_OUT),
    .MFIFO_LINES (MFIFO_LINES),
    .IC_LINES    (IC_LINES),
    .IC_BEATS    (IC_BEATS),
    .PERIPH_ID   (PERIPH_ID),
    .APB_SLVERR  (APB_SLVERR)
  ) u_core (
    .clk             (aclk),
    .rst_n           (core_rst_n),
    .boot_from_pc    (boot_from_pc),
    .boot_addr       (boot_addr),
    .boot_manager_ns (boot_manager_ns),
    .boot_irq_ns     (boot_irq_ns),
    .boot_periph_ns  (boot_periph_ns),
    .psel            (c_psel[0]),
    .penable         (c_penable[0]),
    .pwrite          (c_pwrite[0]),
    .paddr           (c_paddr[0]),
    .pwdata          (c_pwdata[0]),
    .pready          (c_pready[0]),
    .prdata          (c_prdata[0]),
    .pslverr         (c_pslverr[0]),
    .psel_ns         (c_psel[1]),
    .penable_ns      (c_penable[1]),
    .pwrite_ns       (c_pwrite[1]),
    .paddr_ns        (c_paddr[1]),
    .pwdata_ns       (c_pwdata[1]),
    .pready_ns       (c_pready[1]),
    .prdata_ns       (c_prdata[1]),
    .pslverr_ns      (c_pslverr[1]),
    .m_awvalid       (m_axi_awvalid),
    .m_awready       (m_axi_awready),
    .m_awid          (m_axi_awid),
    .m_awaddr        (m_axi_awaddr),
    .m_awlen         (m_axi_awlen),
    .m_awsize        (m_axi_awsize),
    .m_awburst       (m_axi_awburst),
    .m_awlock        (m_axi_awlock),
    .m_awcache       (m_axi_awcache),
    .m_awprot        (m_axi_awprot),
    .m_wvalid        (m_axi_wvalid),
    .m_wready        (m_axi_wready),
    .m_wdata         (m_axi_wdata),
    .m_wstrb         (m_axi_wstrb),
    .m_wlast         (m_axi_wlast),
    .m_bvalid        (m_axi_bvalid),
    .m_bready        (m_axi_bready),
    .m_bid           (m_axi_bid),
    .m_bresp         (m_axi_bresp),
    .m_arvalid       (m_axi_arvalid),
    .m_arready       (m_axi_arready),
    .m_arid          (m_axi_arid),
    .m_araddr        (m_axi_araddr),
    .m_arlen         (m_axi_arlen),
    .m_arsize        (m_axi_arsize),
    .m_arburst       (m_axi_arburst),
    .m_arlock        (m_axi_arlock),
    .m_arcache       (m_axi_arcache),
    .m_arprot        (m_axi_arprot),
    .m_rvalid        (m_axi_rvalid),
    .m_rready        (m_axi_rready),
    .m_rid           (m_axi_rid),
    .m_rdata         (m_axi_rdata),
    .m_rresp         (m_axi_rresp),
    .m_rlast         (m_axi_rlast),
    .dr_valid        (c_dr_valid),
    .dr_ready        (c_dr_ready),
    .dr_type         (c_dr_type),
    .dr_last         (c_dr_last),
    .da_valid        (c_da_valid),
    .da_ready        (c_da_ready),
    .da_type         (c_da_type),
    .irq             (irq),
    .irq_abort       (irq_abort),
    .qreqn           (qreqn),
    .qacceptn        (qacceptn),
    .qdeny           (qdeny),
    .busy            (core_busy)
  );

  // Work pending in the core, or a register access waiting at an APB port
  assign qactive = core_busy || psel || psel_ns;

endmodule : axi_dma330
