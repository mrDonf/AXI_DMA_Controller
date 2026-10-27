//==============================================================================
// dma_seq_pkg.sv - virtual sequence library
//==============================================================================
package dma_seq_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import dma_tb_params_pkg::*;
  import dma_env_pkg::*;

  `include "dma_base_vseq.sv"
  `include "dma_reg_vseq.sv"
  `include "dma_traffic_vseq.sv"
  `include "dma_event_vseq.sv"
  `include "dma_cache_vseq.sv"
  `include "dma_boot_vseq.sv"
  `include "dma_fault_vseq.sv"
  `include "dma_kill_vseq.sv"
  `include "dma_corner_vseq.sv"
  `include "dma_robust_vseq.sv"
  `include "dma_mfifo_vseq.sv"
  `include "dma_security_vseq.sv"

endpackage : dma_seq_pkg
