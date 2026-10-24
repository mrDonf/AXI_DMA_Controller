//==============================================================================
// dma_tb_params_pkg.sv - DUT configuration shared by tb_top and the UVM env
//==============================================================================
package dma_tb_params_pkg;

  localparam int NUM_CH      = 4;
  localparam int NUM_PERIPH  = 4;
  localparam int NUM_EVENTS  = 16;
  localparam int DATA_W      = 64;
  localparam int ID_W        = 4;
  localparam int RQ_DEPTH    = 4;
  localparam int WQ_DEPTH    = 4;
  localparam int RD_OUT      = 4;
  localparam int WR_OUT      = 4;
  localparam int MFIFO_LINES = 128;         // shared by all channels
  localparam int IC_LINES    = 8;
  localparam int IC_BEATS    = 4;
  localparam logic [31:0] PERIPH_ID = 32'h0000_0330;

  localparam int IFETCH_ID   = (1 << ID_W) - 1;
  localparam int MFIFO_BYTES = MFIFO_LINES * DATA_W / 8;   // whole MFIFO pool

endpackage : dma_tb_params_pkg
