//==============================================================================
// apb_if.sv - APB4 interface for the APB VIP
//==============================================================================
interface apb_if #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 32
) (
  input logic pclk,
  input logic presetn
);

  logic              psel;
  logic              penable;
  logic              pwrite;
  logic [ADDR_W-1:0] paddr;
  logic [DATA_W-1:0] pwdata;
  logic [DATA_W/8-1:0] pstrb;
  logic [2:0]        pprot;
  logic [DATA_W-1:0] prdata;
  logic              pready;
  logic              pslverr;

  // Requester (master) driver view
  clocking mst_cb @(posedge pclk);
    default input #1step output #1;
    output psel, penable, pwrite, paddr, pwdata, pstrb, pprot;
    input  prdata, pready, pslverr;
  endclocking

  // Passive monitor view
  clocking mon_cb @(posedge pclk);
    default input #1step;
    input psel, penable, pwrite, paddr, pwdata, pstrb, pprot, prdata, pready, pslverr;
  endclocking

  modport master  (clocking mst_cb, input pclk, presetn);
  modport monitor (clocking mon_cb, input pclk, presetn);

endinterface : apb_if
