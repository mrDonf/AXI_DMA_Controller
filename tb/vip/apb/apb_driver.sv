//==============================================================================
// apb_driver.sv - APB requester driver
//------------------------------------------------------------------------------
// Drives SETUP / ACCESS phases, waits for PREADY, and returns read data and
// PSLVERR in the same request item (no separate response item).
//==============================================================================
class apb_driver extends uvm_driver #(apb_seq_item);

  `uvm_component_utils(apb_driver)

  apb_config cfg;
  apb_vif_t  vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(apb_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "apb_config not set")
    vif = cfg.vif;
  endfunction

  virtual task run_phase(uvm_phase phase);
    drive_idle();
    @(posedge vif.presetn);
    forever begin
      seq_item_port.get_next_item(req);
      drive_transfer(req);
      seq_item_port.item_done();
    end
  endtask

  protected task drive_idle();
    vif.mst_cb.psel    <= 1'b0;
    vif.mst_cb.penable <= 1'b0;
    vif.mst_cb.pwrite  <= 1'b0;
    vif.mst_cb.paddr   <= '0;
    vif.mst_cb.pwdata  <= '0;
    vif.mst_cb.pstrb   <= '0;
    vif.mst_cb.pprot   <= '0;
  endtask

  protected task drive_transfer(apb_seq_item t);
    repeat (t.idle) @(vif.mst_cb);

    // SETUP phase
    @(vif.mst_cb);
    vif.mst_cb.psel    <= 1'b1;
    vif.mst_cb.penable <= 1'b0;
    vif.mst_cb.pwrite  <= (t.kind == APB_WRITE);
    vif.mst_cb.paddr   <= t.addr;
    vif.mst_cb.pwdata  <= (t.kind == APB_WRITE) ? t.data : '0;
    vif.mst_cb.pstrb   <= (t.kind == APB_WRITE) ? '1 : '0;

    // ACCESS phase, wait for PREADY
    @(vif.mst_cb);
    vif.mst_cb.penable <= 1'b1;
    @(vif.mst_cb);
    while (!vif.mst_cb.pready) @(vif.mst_cb);

    if (t.kind == APB_READ) t.data = vif.mst_cb.prdata;
    t.slverr = vif.mst_cb.pslverr;
    drive_idle();
    `uvm_info("APB_DRV", t.convert2string(), UVM_HIGH)
  endtask

endclass : apb_driver
