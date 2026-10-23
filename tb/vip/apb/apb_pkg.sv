//==============================================================================
// apb_pkg.sv - APB VIP (requester agent, monitor, RAL adapter)
//==============================================================================
package apb_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `ifndef APB_ADDR_W
    `define APB_ADDR_W 32
  `endif
  `ifndef APB_DATA_W
    `define APB_DATA_W 32
  `endif

  localparam int APB_ADDR_W = `APB_ADDR_W;
  localparam int APB_DATA_W = `APB_DATA_W;

  typedef virtual apb_if #(APB_ADDR_W, APB_DATA_W) apb_vif_t;

  typedef enum bit {APB_READ = 1'b0, APB_WRITE = 1'b1} apb_kind_e;

  `include "apb_seq_item.sv"
  `include "apb_config.sv"
  `include "apb_driver.sv"
  `include "apb_monitor.sv"
  `include "apb_agent.sv"
  `include "apb_seq_lib.sv"
  `include "apb_reg_adapter.sv"

endpackage : apb_pkg
