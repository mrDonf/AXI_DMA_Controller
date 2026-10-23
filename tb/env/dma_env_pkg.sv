//==============================================================================
// dma_env_pkg.sv - DMA verification environment package
//==============================================================================
package dma_env_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import dma_tb_params_pkg::*;
  import apb_pkg::*;
  import axi_pkg::*;
  import dma_periph_pkg::*;
  import dma330_dpi_pkg::*;

  `include "dma_reg_model.sv"
  `include "dma330_asm.sv"
  `include "dma_job.sv"
  `include "dma_cmodel.sv"
  `include "dma_prog_gen.sv"
  `include "dma_rand_prog.sv"
  `include "dma_env_cfg.sv"
  `include "dma_scoreboard.sv"
  `include "dma_coverage.sv"
  `include "dma_virtual_sequencer.sv"
  `include "dma_env.sv"

endpackage : dma_env_pkg
