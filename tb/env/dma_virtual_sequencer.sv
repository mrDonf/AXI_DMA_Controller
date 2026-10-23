//==============================================================================
// dma_virtual_sequencer.sv
//==============================================================================
class dma_virtual_sequencer extends uvm_sequencer;

  `uvm_component_utils(dma_virtual_sequencer)

  apb_pkg::apb_sequencer           apb_sqr;
  dma_periph_pkg::periph_sequencer per_sqr [dma_tb_params_pkg::NUM_PERIPH];
  dma_reg_block                    rm;
  dma_env_cfg                      cfg;
  dma_scoreboard                   sb;
  dma_coverage                     cov;

  // DBGINST0/DBGINST1/DBGCMD must be written as one atomic group
  semaphore                        dbg_lock;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    dbg_lock = new(1);
  endfunction

endclass : dma_virtual_sequencer
