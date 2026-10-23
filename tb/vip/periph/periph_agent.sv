//==============================================================================
// periph_agent.sv
//==============================================================================
typedef uvm_sequencer #(periph_item) periph_sequencer;

class periph_agent extends uvm_agent;

  `uvm_component_utils(periph_agent)

  periph_config    cfg;
  periph_sequencer sqr;
  periph_driver    drv;
  periph_monitor   mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(periph_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "periph_config not set")
    uvm_config_db #(periph_config)::set(this, "*", "cfg", cfg);

    mon = periph_monitor::type_id::create("mon", this);
    if (cfg.is_active == UVM_ACTIVE) begin
      sqr = periph_sequencer::type_id::create("sqr", this);
      drv = periph_driver::type_id::create("drv", this);
    end
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    if (cfg.is_active == UVM_ACTIVE)
      drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction

endclass : periph_agent
