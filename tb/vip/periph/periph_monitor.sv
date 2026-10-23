//==============================================================================
// periph_monitor.sv - publishes every request and acknowledge handshake
//==============================================================================
class periph_monitor extends uvm_monitor;

  `uvm_component_utils(periph_monitor)

  uvm_analysis_port #(periph_item) ap;

  periph_config cfg;
  periph_vif_t  vif;

  periph_item cov_item;

  covergroup cg_periph;
    option.per_instance = 1;
    cp_dir : coverpoint cov_item.dir;
    cp_req : coverpoint cov_item.req_type iff (cov_item.dir == PER_REQ);
    cp_ack : coverpoint cov_item.ack_type iff (cov_item.dir == PER_ACK);
    cp_last: coverpoint cov_item.last     iff (cov_item.dir == PER_REQ);
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
    cg_periph = new();
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(periph_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "periph_config not set")
    vif = cfg.vif;
  endfunction

  virtual task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      if (!vif.rst_n) continue;
      if (vif.mon_cb.drvalid && vif.mon_cb.drready) begin
        periph_item t = periph_item::type_id::create("per_req");
        t.dir       = PER_REQ;
        t.req_type  = periph_req_e'(vif.mon_cb.drtype);
        t.last      = vif.mon_cb.drlast;
        t.periph_id = cfg.periph_id;
        publish(t);
      end
      if (vif.mon_cb.davalid && vif.mon_cb.daready) begin
        periph_item t = periph_item::type_id::create("per_ack");
        t.dir       = PER_ACK;
        t.ack_type  = periph_ack_e'(vif.mon_cb.datype);
        t.periph_id = cfg.periph_id;
        publish(t);
      end
    end
  endtask

  protected function void publish(periph_item t);
    cov_item = t;
    cg_periph.sample();
    `uvm_info("PER_MON", t.convert2string(), UVM_HIGH)
    ap.write(t);
  endfunction

endclass : periph_monitor
