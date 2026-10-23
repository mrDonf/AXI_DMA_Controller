//==============================================================================
// periph_config.sv
//==============================================================================
class periph_config extends uvm_object;

  periph_vif_t            vif;
  uvm_active_passive_enum is_active      = UVM_ACTIVE;
  int                     periph_id      = 0;
  int unsigned            daready_pct    = 70;   // DAREADY probability per cycle
  bit                     auto_flush_ack = 1;    // answer DMAFLUSHP with drtype=10
  bit                     wait_ack       = 1;    // next request only after the ack

  `uvm_object_utils_begin(periph_config)
    `uvm_field_enum(uvm_active_passive_enum, is_active, UVM_ALL_ON)
    `uvm_field_int (periph_id,      UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (daready_pct,    UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (auto_flush_ack, UVM_ALL_ON)
    `uvm_field_int (wait_ack,       UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "periph_config");
    super.new(name);
  endfunction

endclass : periph_config
