//==============================================================================
// dma_periph_if.sv - DMA-330 style peripheral request interface
//   drvalid/drtype/drlast/drready : peripheral -> DMA request
//   davalid/datype/daready        : DMA -> peripheral acknowledge
//==============================================================================
interface dma_periph_if (
  input logic clk,
  input logic rst_n
);

  logic       drvalid;
  logic       drready;
  logic [1:0] drtype;
  logic       drlast;
  logic       davalid;
  logic       daready;
  logic [1:0] datype;

  // Peripheral (requester) driver view
  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output drvalid, drtype, drlast, daready;
    input  drready, davalid, datype;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input drvalid, drready, drtype, drlast, davalid, daready, datype;
  endclocking

  modport periph  (clocking drv_cb, input clk, rst_n);
  modport monitor (clocking mon_cb, input clk, rst_n);

endinterface : dma_periph_if
