//==============================================================================
// axi_dma330.sv
//------------------------------------------------------------------------------
// Top level of the AXI DMA controller (DMA-330 / PL330 style).
//
// Clock domains
//   clk         DMA core (threads, data path, MFIFO, registers)
//   pclk        APB configuration port            (APB_ASYNC = 1)
//   aclk        AXI4 master port / interconnect    (AXI_ASYNC = 1)
//   periph_clk  one clock per peripheral interface (PERIPH_ASYNC = 1)
//
// When a *_ASYNC parameter is 0 the corresponding interface is synchronous to
// 'clk' and its clock/reset inputs are unused (tie them to clk / rst_n).
//
//             pclk              clk                          aclk
//   APB ->[apb_async_bridge]->[ dma330_core ]->[axi_async_bridge]-> AXI4
//                                   ^  |
//   periph_clk[p]: dr/da <->[periph_sync]
//
// Every asynchronous reset input is synchronized to its own domain
// (asynchronous assert, synchronous de-assert).
//
// Low power: AMBA Q-Channel on 'clk' (qreqn is synchronized inside).
// qactive = core busy OR an APB transfer is requested; it is an asynchronous
// output intended for the clock controller.
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
  parameter int          MFIFO_LINES  = 32,
  parameter int          IC_LINES     = 8,
  parameter int          IC_BEATS     = 4,
  parameter logic [31:0] PERIPH_ID    = 32'h0000_0330,
  // Clock-domain crossing configuration
  parameter bit          APB_ASYNC    = 1'b0,
  parameter bit          AXI_ASYNC    = 1'b0,
  parameter bit          PERIPH_ASYNC = 1'b0,
  parameter int          AFIFO_AW     = 3,         // AXI bridge FIFO depth = 2**AFIFO_AW
  // PSLVERR on unmapped addresses / writes to read-only registers
  parameter bit          APB_SLVERR   = 1'b0
) (
  // DMA core clock / reset
  input  logic                        clk,
  input  logic                        rst_n,
  // APB clock / reset
  input  logic                        pclk,
  input  logic                        presetn,
  // AXI clock / reset
  input  logic                        aclk,
  input  logic                        aresetn,
  // Peripheral clocks / resets
  input  logic [NUM_PERIPH-1:0]       periph_clk,
  input  logic [NUM_PERIPH-1:0]       periph_rst_n,

  // Boot configuration (static)
  input  logic                        boot_from_pc,
  input  logic [31:0]                 boot_addr,
  input  logic                        boot_manager_ns,

  // APB4 slave (pclk domain)
  input  logic                        psel,
  input  logic                        penable,
  input  logic                        pwrite,
  input  logic [11:0]                 paddr,
  input  logic [31:0]                 pwdata,
  output logic                        pready,
  output logic [31:0]                 prdata,
  output logic                        pslverr,

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

  // Interrupts (clk domain, level sensitive)
  output logic [NUM_EVENTS-1:0]       irq,
  output logic                        irq_abort,

  // Low-power Q-Channel (clk domain; qreqn asynchronous, tie high if unused)
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
    .clk    (clk),
    .arst_n (rst_n),
    .rst_n  (core_rst_n)
  );

  //============================================================================
  // APB port
  //============================================================================
  logic        c_psel, c_penable, c_pwrite, c_pready, c_pslverr;
  logic [11:0] c_paddr;
  logic [31:0] c_pwdata, c_prdata;

  if (APB_ASYNC) begin : g_apb_async
    logic apb_rst_n;

    dma_rst_sync u_apb_rst_sync (
      .clk    (pclk),
      .arst_n (presetn),
      .rst_n  (apb_rst_n)
    );

    dma_apb_async_bridge #(.ADDR_W(12), .DATA_W(32)) u_apb_bridge (
      .pclk      (pclk),
      .presetn   (apb_rst_n),
      .s_psel    (psel),
      .s_penable (penable),
      .s_pwrite  (pwrite),
      .s_paddr   (paddr),
      .s_pwdata  (pwdata),
      .s_pready  (pready),
      .s_prdata  (prdata),
      .s_pslverr (pslverr),
      .clk       (clk),
      .rst_n     (core_rst_n),
      .m_psel    (c_psel),
      .m_penable (c_penable),
      .m_pwrite  (c_pwrite),
      .m_paddr   (c_paddr),
      .m_pwdata  (c_pwdata),
      .m_pready  (c_pready),
      .m_prdata  (c_prdata),
      .m_pslverr (c_pslverr)
    );
  end else begin : g_apb_sync
    assign c_psel    = psel;
    assign c_penable = penable;
    assign c_pwrite  = pwrite;
    assign c_paddr   = paddr;
    assign c_pwdata  = pwdata;
    assign pready    = c_pready;
    assign prdata    = c_prdata;
    assign pslverr   = c_pslverr;
  end

  //============================================================================
  // Peripheral ports
  //============================================================================
  logic [NUM_PERIPH-1:0]      c_dr_valid, c_dr_ready, c_dr_last;
  logic [NUM_PERIPH-1:0][1:0] c_dr_type, c_da_type;
  logic [NUM_PERIPH-1:0]      c_da_valid, c_da_ready;

  for (genvar p = 0; p < NUM_PERIPH; p++) begin : g_periph
    if (PERIPH_ASYNC) begin : g_async
      logic p_rst_n;

      dma_rst_sync u_periph_rst_sync (
        .clk    (periph_clk[p]),
        .arst_n (periph_rst_n[p]),
        .rst_n  (p_rst_n)
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
        .clk          (clk),
        .rst_n        (core_rst_n),
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
  // AXI port (core side signals)
  //============================================================================
  logic                c_awvalid, c_awready, c_awlock;
  logic [ID_W-1:0]     c_awid;
  logic [31:0]         c_awaddr;
  logic [7:0]          c_awlen;
  logic [2:0]          c_awsize, c_awprot;
  logic [1:0]          c_awburst;
  logic [3:0]          c_awcache;
  logic                c_wvalid, c_wready, c_wlast;
  logic [DATA_W-1:0]   c_wdata;
  logic [DATA_W/8-1:0] c_wstrb;
  logic                c_bvalid, c_bready;
  logic [ID_W-1:0]     c_bid;
  logic [1:0]          c_bresp;
  logic                c_arvalid, c_arready, c_arlock;
  logic [ID_W-1:0]     c_arid;
  logic [31:0]         c_araddr;
  logic [7:0]          c_arlen;
  logic [2:0]          c_arsize, c_arprot;
  logic [1:0]          c_arburst;
  logic [3:0]          c_arcache;
  logic                c_rvalid, c_rready, c_rlast;
  logic [ID_W-1:0]     c_rid;
  logic [DATA_W-1:0]   c_rdata;
  logic [1:0]          c_rresp;

  if (AXI_ASYNC) begin : g_axi_async
    logic axi_rst_n;

    dma_rst_sync u_axi_rst_sync (
      .clk    (aclk),
      .arst_n (aresetn),
      .rst_n  (axi_rst_n)
    );

    dma_axi_async_bridge #(
      .ID_W    (ID_W),
      .ADDR_W  (32),
      .DATA_W  (DATA_W),
      .FIFO_AW (AFIFO_AW)
    ) u_axi_bridge (
      .s_clk     (clk),            .s_rst_n   (core_rst_n),
      .s_awvalid (c_awvalid),      .s_awready (c_awready),
      .s_awid    (c_awid),         .s_awaddr  (c_awaddr),
      .s_awlen   (c_awlen),        .s_awsize  (c_awsize),
      .s_awburst (c_awburst),      .s_awlock  (c_awlock),
      .s_awcache (c_awcache),      .s_awprot  (c_awprot),
      .s_wvalid  (c_wvalid),       .s_wready  (c_wready),
      .s_wdata   (c_wdata),        .s_wstrb   (c_wstrb),
      .s_wlast   (c_wlast),
      .s_bvalid  (c_bvalid),       .s_bready  (c_bready),
      .s_bid     (c_bid),          .s_bresp   (c_bresp),
      .s_arvalid (c_arvalid),      .s_arready (c_arready),
      .s_arid    (c_arid),         .s_araddr  (c_araddr),
      .s_arlen   (c_arlen),        .s_arsize  (c_arsize),
      .s_arburst (c_arburst),      .s_arlock  (c_arlock),
      .s_arcache (c_arcache),      .s_arprot  (c_arprot),
      .s_rvalid  (c_rvalid),       .s_rready  (c_rready),
      .s_rid     (c_rid),          .s_rdata   (c_rdata),
      .s_rresp   (c_rresp),        .s_rlast   (c_rlast),

      .m_clk     (aclk),           .m_rst_n   (axi_rst_n),
      .m_awvalid (m_axi_awvalid),  .m_awready (m_axi_awready),
      .m_awid    (m_axi_awid),     .m_awaddr  (m_axi_awaddr),
      .m_awlen   (m_axi_awlen),    .m_awsize  (m_axi_awsize),
      .m_awburst (m_axi_awburst),  .m_awlock  (m_axi_awlock),
      .m_awcache (m_axi_awcache),  .m_awprot  (m_axi_awprot),
      .m_wvalid  (m_axi_wvalid),   .m_wready  (m_axi_wready),
      .m_wdata   (m_axi_wdata),    .m_wstrb   (m_axi_wstrb),
      .m_wlast   (m_axi_wlast),
      .m_bvalid  (m_axi_bvalid),   .m_bready  (m_axi_bready),
      .m_bid     (m_axi_bid),      .m_bresp   (m_axi_bresp),
      .m_arvalid (m_axi_arvalid),  .m_arready (m_axi_arready),
      .m_arid    (m_axi_arid),     .m_araddr  (m_axi_araddr),
      .m_arlen   (m_axi_arlen),    .m_arsize  (m_axi_arsize),
      .m_arburst (m_axi_arburst),  .m_arlock  (m_axi_arlock),
      .m_arcache (m_axi_arcache),  .m_arprot  (m_axi_arprot),
      .m_rvalid  (m_axi_rvalid),   .m_rready  (m_axi_rready),
      .m_rid     (m_axi_rid),      .m_rdata   (m_axi_rdata),
      .m_rresp   (m_axi_rresp),    .m_rlast   (m_axi_rlast)
    );
  end else begin : g_axi_sync
    assign m_axi_awvalid = c_awvalid;   assign c_awready = m_axi_awready;
    assign m_axi_awid    = c_awid;      assign m_axi_awaddr  = c_awaddr;
    assign m_axi_awlen   = c_awlen;     assign m_axi_awsize  = c_awsize;
    assign m_axi_awburst = c_awburst;   assign m_axi_awlock  = c_awlock;
    assign m_axi_awcache = c_awcache;   assign m_axi_awprot  = c_awprot;
    assign m_axi_wvalid  = c_wvalid;    assign c_wready = m_axi_wready;
    assign m_axi_wdata   = c_wdata;     assign m_axi_wstrb   = c_wstrb;
    assign m_axi_wlast   = c_wlast;
    assign c_bvalid      = m_axi_bvalid; assign m_axi_bready = c_bready;
    assign c_bid         = m_axi_bid;    assign c_bresp      = m_axi_bresp;
    assign m_axi_arvalid = c_arvalid;   assign c_arready = m_axi_arready;
    assign m_axi_arid    = c_arid;      assign m_axi_araddr  = c_araddr;
    assign m_axi_arlen   = c_arlen;     assign m_axi_arsize  = c_arsize;
    assign m_axi_arburst = c_arburst;   assign m_axi_arlock  = c_arlock;
    assign m_axi_arcache = c_arcache;   assign m_axi_arprot  = c_arprot;
    assign c_rvalid      = m_axi_rvalid; assign m_axi_rready = c_rready;
    assign c_rid         = m_axi_rid;    assign c_rdata      = m_axi_rdata;
    assign c_rresp       = m_axi_rresp;  assign c_rlast      = m_axi_rlast;
  end

  //============================================================================
  // DMA core
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
    .clk             (clk),
    .rst_n           (core_rst_n),
    .boot_from_pc    (boot_from_pc),
    .boot_addr       (boot_addr),
    .boot_manager_ns (boot_manager_ns),
    .psel            (c_psel),
    .penable         (c_penable),
    .pwrite          (c_pwrite),
    .paddr           (c_paddr),
    .pwdata          (c_pwdata),
    .pready          (c_pready),
    .prdata          (c_prdata),
    .pslverr         (c_pslverr),
    .m_awvalid       (c_awvalid),
    .m_awready       (c_awready),
    .m_awid          (c_awid),
    .m_awaddr        (c_awaddr),
    .m_awlen         (c_awlen),
    .m_awsize        (c_awsize),
    .m_awburst       (c_awburst),
    .m_awlock        (c_awlock),
    .m_awcache       (c_awcache),
    .m_awprot        (c_awprot),
    .m_wvalid        (c_wvalid),
    .m_wready        (c_wready),
    .m_wdata         (c_wdata),
    .m_wstrb         (c_wstrb),
    .m_wlast         (c_wlast),
    .m_bvalid        (c_bvalid),
    .m_bready        (c_bready),
    .m_bid           (c_bid),
    .m_bresp         (c_bresp),
    .m_arvalid       (c_arvalid),
    .m_arready       (c_arready),
    .m_arid          (c_arid),
    .m_araddr        (c_araddr),
    .m_arlen         (c_arlen),
    .m_arsize        (c_arsize),
    .m_arburst       (c_arburst),
    .m_arlock        (c_arlock),
    .m_arcache       (c_arcache),
    .m_arprot        (c_arprot),
    .m_rvalid        (c_rvalid),
    .m_rready        (c_rready),
    .m_rid           (c_rid),
    .m_rdata         (c_rdata),
    .m_rresp         (c_rresp),
    .m_rlast         (c_rlast),
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

  // Work pending in the core, or a register access waiting at the APB port
  assign qactive = core_busy || psel;

endmodule : axi_dma330
