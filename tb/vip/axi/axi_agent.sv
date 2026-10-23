//==============================================================================
// axi_agent.sv - AXI slave agent (reactive memory driver + monitor + coverage)
//==============================================================================
class axi_agent extends uvm_agent;

  `uvm_component_utils(axi_agent)

  axi_config       cfg;
  axi_slave_driver drv;
  axi_monitor      mon;
  axi_coverage     cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(axi_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "axi_config not set")
    uvm_config_db #(axi_config)::set(this, "*", "cfg", cfg);

    mon = axi_monitor::type_id::create("mon", this);
    if (cfg.is_active == UVM_ACTIVE)
      drv = axi_slave_driver::type_id::create("drv", this);
    if (cfg.has_coverage)
      cov = axi_coverage::type_id::create("cov", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    if (cfg.has_coverage) begin
      mon.ap_write.connect(cov.analysis_export);
      mon.ap_read.connect(cov.analysis_export);
    end
  endfunction

endclass : axi_agent
