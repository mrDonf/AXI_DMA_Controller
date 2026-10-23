//==============================================================================
// apb_monitor.sv - reconstructs completed APB transfers + protocol coverage
//==============================================================================
class apb_monitor extends uvm_monitor;

  `uvm_component_utils(apb_monitor)

  uvm_analysis_port #(apb_seq_item) ap;

  apb_config cfg;
  apb_vif_t  vif;

  // Coverage of what the requester exercised
  apb_seq_item cov_item;
  int unsigned cov_wait;

  covergroup cg_apb;
    option.per_instance = 1;
    cp_kind : coverpoint cov_item.kind;
    // zero-wait slave / classic wait states / slow or bridged slave
    cp_wait : coverpoint cov_wait { bins zero = {0}; bins short_w = {[1:3]}; bins long_w = {[4:$]}; }
    cp_err  : coverpoint cov_item.slverr;
    x_kind_wait : cross cp_kind, cp_wait;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
    cg_apb = new();
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(apb_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "apb_config not set")
    vif = cfg.vif;
    // Completers that never signal PSLVERR: error response is not a goal
    if (!cfg.cov_slverr) cg_apb.cp_err.option.weight = 0;
  endfunction

  virtual task run_phase(uvm_phase phase);
    int unsigned wait_cnt = 0;
    forever begin
      @(vif.mon_cb);
      if (!vif.presetn) begin
        wait_cnt = 0;
        continue;
      end
      if (vif.mon_cb.psel && vif.mon_cb.penable) begin
        if (vif.mon_cb.pready) begin
          apb_seq_item t = apb_seq_item::type_id::create("apb_mon_item");
          t.kind   = vif.mon_cb.pwrite ? APB_WRITE : APB_READ;
          t.addr   = vif.mon_cb.paddr;
          t.data   = vif.mon_cb.pwrite ? vif.mon_cb.pwdata : vif.mon_cb.prdata;
          t.slverr = vif.mon_cb.pslverr;
          if (cfg.has_coverage) begin
            cov_item = t;
            cov_wait = wait_cnt;
            cg_apb.sample();
          end
          `uvm_info("APB_MON", t.convert2string(), UVM_HIGH)
          ap.write(t);
          wait_cnt = 0;
        end else begin
          wait_cnt++;
        end
      end
    end
  endtask

endclass : apb_monitor
