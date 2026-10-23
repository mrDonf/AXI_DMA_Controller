//==============================================================================
// apb_config.sv - APB agent configuration
//==============================================================================
class apb_config extends uvm_object;

  apb_vif_t               vif;
  uvm_active_passive_enum is_active    = UVM_ACTIVE;
  bit                     has_coverage = 1;
  bit                     cov_slverr   = 1;   // 0: completer never returns PSLVERR

  `uvm_object_utils_begin(apb_config)
    `uvm_field_enum(uvm_active_passive_enum, is_active, UVM_ALL_ON)
    `uvm_field_int (has_coverage, UVM_ALL_ON)
    `uvm_field_int (cov_slverr,   UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "apb_config");
    super.new(name);
  endfunction

endclass : apb_config
