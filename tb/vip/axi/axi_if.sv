//==============================================================================
// axi_if.sv - AXI4 interface for the AXI VIP
//==============================================================================
interface axi_if #(
  parameter int ID_W   = 4,
  parameter int ADDR_W = 32,
  parameter int DATA_W = 64
) (
  input logic aclk,
  input logic aresetn
);

  // Write address
  logic                awvalid, awready;
  logic [ID_W-1:0]     awid;
  logic [ADDR_W-1:0]   awaddr;
  logic [7:0]          awlen;
  logic [2:0]          awsize;
  logic [1:0]          awburst;
  logic                awlock;
  logic [3:0]          awcache;
  logic [2:0]          awprot;
  // Write data
  logic                wvalid, wready;
  logic [DATA_W-1:0]   wdata;
  logic [DATA_W/8-1:0] wstrb;
  logic                wlast;
  // Write response
  logic                bvalid, bready;
  logic [ID_W-1:0]     bid;
  logic [1:0]          bresp;
  // Read address
  logic                arvalid, arready;
  logic [ID_W-1:0]     arid;
  logic [ADDR_W-1:0]   araddr;
  logic [7:0]          arlen;
  logic [2:0]          arsize;
  logic [1:0]          arburst;
  logic                arlock;
  logic [3:0]          arcache;
  logic [2:0]          arprot;
  // Read data
  logic                rvalid, rready;
  logic [ID_W-1:0]     rid;
  logic [DATA_W-1:0]   rdata;
  logic [1:0]          rresp;
  logic                rlast;

  // Completer (slave) driver view
  clocking slv_cb @(posedge aclk);
    default input #1step output #1;
    input  awvalid, awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot;
    output awready;
    input  wvalid, wdata, wstrb, wlast;
    output wready;
    output bvalid, bid, bresp;
    input  bready;
    input  arvalid, arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot;
    output arready;
    output rvalid, rid, rdata, rresp, rlast;
    input  rready;
  endclocking

  // Passive monitor view
  clocking mon_cb @(posedge aclk);
    default input #1step;
    input awvalid, awready, awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot;
    input wvalid, wready, wdata, wstrb, wlast;
    input bvalid, bready, bid, bresp;
    input arvalid, arready, arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot;
    input rvalid, rready, rid, rdata, rresp, rlast;
  endclocking

  modport slave   (clocking slv_cb, input aclk, aresetn);
  modport monitor (clocking mon_cb, input aclk, aresetn);

endinterface : axi_if
