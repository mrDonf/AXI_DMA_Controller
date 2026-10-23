//==============================================================================
// dma_env_cfg.sv - environment configuration
//==============================================================================
class dma_env_cfg extends uvm_object;

  `uvm_object_utils(dma_env_cfg)

  apb_pkg::apb_config           apb_cfg;
  axi_pkg::axi_config           axi_cfg;
  dma_periph_pkg::periph_config per_cfg [dma_tb_params_pkg::NUM_PERIPH];
  axi_pkg::axi_mem_model        mem;
  virtual dma_ctrl_if #(dma_tb_params_pkg::NUM_EVENTS) ctrl_vif;

  bit has_scoreboard = 1;
  bit has_coverage   = 1;
  bit cmodel_en      = 1;          // C reference model (DPI-C): cross-check + architectural state
  int async_mode     = 0;          // 1: APB/AXI/peripherals on their own clocks
  bit apb_slverr     = 0;          // DUT built with APB_SLVERR = 1

  function new(string name = "dma_env_cfg");
    super.new(name);
  endfunction

endclass : dma_env_cfg
