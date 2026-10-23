//==============================================================================
// axi_pkg.sv - AXI4 VIP (reactive memory slave, monitor, coverage)
//==============================================================================
package axi_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `ifndef AXI_ID_W
    `define AXI_ID_W 4
  `endif
  `ifndef AXI_ADDR_W
    `define AXI_ADDR_W 32
  `endif
  `ifndef AXI_DATA_W
    `define AXI_DATA_W 64
  `endif

  localparam int AXI_ID_W   = `AXI_ID_W;
  localparam int AXI_ADDR_W = `AXI_ADDR_W;
  localparam int AXI_DATA_W = `AXI_DATA_W;
  localparam int AXI_STRB_W = AXI_DATA_W / 8;

  typedef virtual axi_if #(AXI_ID_W, AXI_ADDR_W, AXI_DATA_W) axi_vif_t;

  typedef enum bit {AXI_READ = 1'b0, AXI_WRITE = 1'b1} axi_dir_e;

  typedef enum bit [1:0] {
    AXI_FIXED = 2'b00,
    AXI_INCR  = 2'b01,
    AXI_WRAP  = 2'b10
  } axi_burst_e;

  typedef enum bit [1:0] {
    AXI_OKAY   = 2'b00,
    AXI_EXOKAY = 2'b01,
    AXI_SLVERR = 2'b10,
    AXI_DECERR = 2'b11
  } axi_resp_e;

  `include "axi_txn.sv"
  `include "axi_mem_model.sv"
  `include "axi_config.sv"
  `include "axi_slave_driver.sv"
  `include "axi_monitor.sv"
  `include "axi_coverage.sv"
  `include "axi_agent.sv"

endpackage : axi_pkg
