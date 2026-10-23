//==============================================================================
// dma_periph_pkg.sv - peripheral request VIP (models a DMA-capable peripheral)
//==============================================================================
package dma_periph_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef virtual dma_periph_if periph_vif_t;

  // drtype encodings
  typedef enum bit [1:0] {
    PREQ_SINGLE    = 2'b00,
    PREQ_BURST     = 2'b01,
    PREQ_FLUSH_ACK = 2'b10
  } periph_req_e;

  // datype encodings
  typedef enum bit [1:0] {
    PACK_SINGLE = 2'b00,
    PACK_BURST  = 2'b01,
    PACK_FLUSH  = 2'b10
  } periph_ack_e;

  typedef enum bit {PER_REQ, PER_ACK} periph_dir_e;

  `include "periph_item.sv"
  `include "periph_config.sv"
  `include "periph_driver.sv"
  `include "periph_monitor.sv"
  `include "periph_agent.sv"
  `include "periph_seq_lib.sv"

endpackage : dma_periph_pkg
