//==============================================================================
// tb_top.sv - testbench top
//------------------------------------------------------------------------------
// The DMA core runs on the AXI clock (aclk, 200 MHz). The Q-Channel model can
// gate the DMA's branch of aclk; the AXI slave VIP stays on the free-running
// clock.
//
//   ASYNC = 0 : APB and every peripheral run on aclk (CDC logic bypassed)
//   ASYNC = 1 : APB (both ports) and each peripheral run on their own
//               unrelated clocks -> exercises the APB async bridges and the
//               peripheral handshake synchronizers
//==============================================================================
`timescale 1ns/1ps

module tb_top;

  import uvm_pkg::*;
  import dma_tb_params_pkg::*;
  import dma_test_pkg::*;

  parameter bit ASYNC = 1'b0;

  //============================================================================
  // Clocks and reset
  //============================================================================
  logic aclk = 1'b0;                // 200 MHz AXI + DMA core clock
  logic apb_clk_a = 1'b0;           //  ~79 MHz
  logic [NUM_PERIPH-1:0] per_clk_a = '0;
  logic por_rst_n = 1'b0;           // power-on reset
  logic rst_n;                      // system reset (power-on AND test reset)

  always #2.5 aclk = ~aclk;

  // Gated DMA clock (Q-Channel tests). Latch-based glitch-free gate.
  logic aclk_en_l = 1'b1;
  logic dut_aclk;
  always_latch if (!aclk) aclk_en_l = ctrl.clk_en;
  assign dut_aclk = aclk & aclk_en_l;
  always #6.3 apb_clk_a = ~apb_clk_a;
  for (genvar p = 0; p < NUM_PERIPH; p++) begin : g_per_clk
    always #(4.1 + 1.3 * p) per_clk_a[p] = ~per_clk_a[p];
  end

  logic pclk;
  logic [NUM_PERIPH-1:0] periph_clk;
  assign pclk       = ASYNC ? apb_clk_a : aclk;
  assign periph_clk = ASYNC ? per_clk_a : {NUM_PERIPH{aclk}};

  initial begin
    por_rst_n = 1'b0;
    #103 por_rst_n = 1'b1;
  end

  assign rst_n = por_rst_n && ctrl.sw_rst_n;

  //============================================================================
  // Interfaces
  //============================================================================
  apb_if #(32, 32)                 apb    (.pclk(pclk), .presetn(rst_n));   // secure port
  apb_if #(32, 32)                 apb_ns (.pclk(pclk), .presetn(rst_n));   // non-secure port
  axi_if #(ID_W, 32, DATA_W)       axi    (.aclk(aclk), .aresetn(rst_n));
  dma_ctrl_if #(NUM_EVENTS)        ctrl   (.clk(aclk), .rst_n(rst_n));

  // One interface per peripheral, explicitly on its own clock. (An instance
  // array would map periph_clk[NUM_PERIPH-1] to per[0].)
  for (genvar p = 0; p < NUM_PERIPH; p++) begin : g_per
    dma_periph_if per (.clk(periph_clk[p]), .rst_n(rst_n));
  end

  //============================================================================
  // DUT
  //============================================================================
  logic [NUM_PERIPH-1:0]      drvalid, drready, drlast, davalid, daready;
  logic [NUM_PERIPH-1:0][1:0] drtype, datype;

  for (genvar p = 0; p < NUM_PERIPH; p++) begin : g_per_wires
    assign drvalid[p]         = g_per[p].per.drvalid;
    assign drtype[p]          = g_per[p].per.drtype;
    assign drlast[p]          = g_per[p].per.drlast;
    assign g_per[p].per.drready = drready[p];
    assign g_per[p].per.davalid = davalid[p];
    assign g_per[p].per.datype  = datype[p];
    assign daready[p]         = g_per[p].per.daready;
  end

  axi_dma330 #(
    .NUM_CH       (NUM_CH),
    .NUM_PERIPH   (NUM_PERIPH),
    .NUM_EVENTS   (NUM_EVENTS),
    .DATA_W       (DATA_W),
    .ID_W         (ID_W),
    .RQ_DEPTH     (RQ_DEPTH),
    .WQ_DEPTH     (WQ_DEPTH),
    .RD_OUT       (RD_OUT),
    .WR_OUT       (WR_OUT),
    .MFIFO_LINES  (MFIFO_LINES),
    .IC_LINES     (IC_LINES),
    .IC_BEATS     (IC_BEATS),
    .PERIPH_ID    (PERIPH_ID),
    .APB_ASYNC    (ASYNC),
    .PERIPH_ASYNC (ASYNC),
    .APB_SLVERR   (ASYNC)        // async snapshot also checks PSLVERR reporting
  ) u_dut (
    .aclk            (dut_aclk),
    .aresetn         (rst_n),
    .pclk            (pclk),
    .presetn         (rst_n),
    .periph_clk      (periph_clk),
    .periph_rst_n    ({NUM_PERIPH{rst_n}}),
    .boot_from_pc    (ctrl.boot_from_pc),
    .boot_addr       (ctrl.boot_addr),
    .boot_manager_ns (ctrl.boot_manager_ns),
    .boot_irq_ns     (ctrl.boot_irq_ns),
    .boot_periph_ns  (ctrl.boot_periph_ns[NUM_PERIPH-1:0]),

    .psel            (apb.psel),
    .penable         (apb.penable),
    .pwrite          (apb.pwrite),
    .paddr           (apb.paddr[11:0]),
    .pwdata          (apb.pwdata),
    .pready          (apb.pready),
    .prdata          (apb.prdata),
    .pslverr         (apb.pslverr),

    .psel_ns         (apb_ns.psel),
    .penable_ns      (apb_ns.penable),
    .pwrite_ns       (apb_ns.pwrite),
    .paddr_ns        (apb_ns.paddr[11:0]),
    .pwdata_ns       (apb_ns.pwdata),
    .pready_ns       (apb_ns.pready),
    .prdata_ns       (apb_ns.prdata),
    .pslverr_ns      (apb_ns.pslverr),

    .m_axi_awvalid   (axi.awvalid),  .m_axi_awready (axi.awready),
    .m_axi_awid      (axi.awid),     .m_axi_awaddr  (axi.awaddr),
    .m_axi_awlen     (axi.awlen),    .m_axi_awsize  (axi.awsize),
    .m_axi_awburst   (axi.awburst),  .m_axi_awlock  (axi.awlock),
    .m_axi_awcache   (axi.awcache),  .m_axi_awprot  (axi.awprot),
    .m_axi_wvalid    (axi.wvalid),   .m_axi_wready  (axi.wready),
    .m_axi_wdata     (axi.wdata),    .m_axi_wstrb   (axi.wstrb),
    .m_axi_wlast     (axi.wlast),
    .m_axi_bvalid    (axi.bvalid),   .m_axi_bready  (axi.bready),
    .m_axi_bid       (axi.bid),      .m_axi_bresp   (axi.bresp),
    .m_axi_arvalid   (axi.arvalid),  .m_axi_arready (axi.arready),
    .m_axi_arid      (axi.arid),     .m_axi_araddr  (axi.araddr),
    .m_axi_arlen     (axi.arlen),    .m_axi_arsize  (axi.arsize),
    .m_axi_arburst   (axi.arburst),  .m_axi_arlock  (axi.arlock),
    .m_axi_arcache   (axi.arcache),  .m_axi_arprot  (axi.arprot),
    .m_axi_rvalid    (axi.rvalid),   .m_axi_rready  (axi.rready),
    .m_axi_rid       (axi.rid),      .m_axi_rdata   (axi.rdata),
    .m_axi_rresp     (axi.rresp),    .m_axi_rlast   (axi.rlast),

    .drvalid         (drvalid),
    .drready         (drready),
    .drtype          (drtype),
    .drlast          (drlast),
    .davalid         (davalid),
    .daready         (daready),
    .datype          (datype),

    .irq             (ctrl.irq),
    .irq_abort       (ctrl.irq_abort),

    .qreqn           (ctrl.qreqn),
    .qacceptn        (ctrl.qacceptn),
    .qdeny           (ctrl.qdeny),
    .qactive         (ctrl.qactive)
  );

  //============================================================================
  // Protocol assertions on the DUT boundary + white-box binds
  //============================================================================
  axi4_master_sva #(.ID_W(ID_W), .ADDR_W(32), .DATA_W(DATA_W)) u_axi_sva (
    .aclk (aclk), .aresetn (rst_n),
    .awvalid (axi.awvalid), .awready (axi.awready), .awid (axi.awid), .awaddr (axi.awaddr),
    .awlen (axi.awlen), .awsize (axi.awsize), .awburst (axi.awburst), .awcache (axi.awcache),
    .awprot (axi.awprot),
    .wvalid (axi.wvalid), .wready (axi.wready), .wdata (axi.wdata), .wstrb (axi.wstrb),
    .wlast (axi.wlast),
    .bvalid (axi.bvalid), .bready (axi.bready), .bid (axi.bid), .bresp (axi.bresp),
    .arvalid (axi.arvalid), .arready (axi.arready), .arid (axi.arid), .araddr (axi.araddr),
    .arlen (axi.arlen), .arsize (axi.arsize), .arburst (axi.arburst), .arcache (axi.arcache),
    .arprot (axi.arprot),
    .rvalid (axi.rvalid), .rready (axi.rready), .rid (axi.rid), .rdata (axi.rdata),
    .rresp (axi.rresp), .rlast (axi.rlast)
  );

  apb_slave_sva #(.ADDR_W(12), .DATA_W(32), .SLVERR_EN(ASYNC)) u_apb_sva (
    .pclk (pclk), .presetn (rst_n), .psel (apb.psel), .penable (apb.penable),
    .pwrite (apb.pwrite), .paddr (apb.paddr[11:0]), .pwdata (apb.pwdata),
    .pready (apb.pready), .prdata (apb.prdata), .pslverr (apb.pslverr)
  );

  apb_slave_sva #(.ADDR_W(12), .DATA_W(32), .SLVERR_EN(ASYNC)) u_apb_ns_sva (
    .pclk (pclk), .presetn (rst_n), .psel (apb_ns.psel), .penable (apb_ns.penable),
    .pwrite (apb_ns.pwrite), .paddr (apb_ns.paddr[11:0]), .pwdata (apb_ns.pwdata),
    .pready (apb_ns.pready), .prdata (apb_ns.prdata), .pslverr (apb_ns.pslverr)
  );

  for (genvar p = 0; p < NUM_PERIPH; p++) begin : g_per_sva
    dma_periph_sva u_per_sva (
      .clk (periph_clk[p]), .rst_n (rst_n),
      .drvalid (drvalid[p]), .drready (drready[p]), .drtype (drtype[p]), .drlast (drlast[p]),
      .davalid (davalid[p]), .daready (daready[p]), .datype (datype[p])
    );
  end

  dma_lpi_sva u_lpi_sva (
    .clk (aclk), .rst_n (rst_n),
    .qreqn (ctrl.qreqn), .qacceptn (ctrl.qacceptn), .qdeny (ctrl.qdeny), .qactive (ctrl.qactive),
    .awvalid (axi.awvalid), .wvalid (axi.wvalid), .arvalid (axi.arvalid),
    .davalid (|davalid), .irq_abort (ctrl.irq_abort),
    .psel (apb.psel), .penable (apb.penable), .pready (apb.pready),
    .psel_ns (apb_ns.psel), .penable_ns (apb_ns.penable), .pready_ns (apb_ns.pready)
  );

  dma_sva_bind u_sva_binds ();

  //============================================================================
  // UVM
  //============================================================================
  for (genvar p = 0; p < NUM_PERIPH; p++) begin : g_per_vif
    initial uvm_config_db #(virtual dma_periph_if)::set(null, "uvm_test_top",
                                                        $sformatf("per_vif%0d", p), g_per[p].per);
  end

  initial begin
    $timeformat(-9, 1, " ns", 12);
    uvm_config_db #(virtual apb_if #(32, 32))::set(null, "uvm_test_top", "apb_vif", apb);
    uvm_config_db #(virtual apb_if #(32, 32))::set(null, "uvm_test_top", "apb_ns_vif", apb_ns);
    uvm_config_db #(virtual axi_if #(ID_W, 32, DATA_W))::set(null, "uvm_test_top", "axi_vif", axi);
    uvm_config_db #(virtual dma_ctrl_if #(NUM_EVENTS))::set(null, "uvm_test_top", "ctrl_vif", ctrl);
    uvm_config_db #(int)::set(null, "uvm_test_top", "async_mode", int'(ASYNC));
    run_test();
  end

endmodule : tb_top
