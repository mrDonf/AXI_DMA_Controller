//==============================================================================
// axi_monitor.sv - reconstructs complete AXI bursts from the five channels
//------------------------------------------------------------------------------
//   ap_write : write burst (AW + W beats + B response)
//   ap_read  : read burst  (AR + R beats with per-beat response)
//
// All channels are sampled in one process per clock so that same-cycle
// events are handled in protocol order (AW/W before B, AR before R).
//==============================================================================
class axi_monitor extends uvm_monitor;

  `uvm_component_utils(axi_monitor)

  uvm_analysis_port #(axi_txn) ap_write;
  uvm_analysis_port #(axi_txn) ap_read;

  axi_config cfg;
  axi_vif_t  vif;

  protected axi_txn aw_q [$];                     // AW seen, W not complete
  protected axi_txn w_q  [$];                     // completed W bursts (data only)
  protected axi_txn w_cur;                        // W burst being collected
  protected axi_txn b_wait [bit [AXI_ID_W-1:0]][$];
  protected axi_txn r_wait [bit [AXI_ID_W-1:0]][$];

  int unsigned num_writes, num_reads;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap_write = new("ap_write", this);
    ap_read  = new("ap_read",  this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(axi_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "axi_config not set")
    vif = cfg.vif;
  endfunction

  virtual task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      if (!vif.aresetn) begin
        aw_q.delete(); w_q.delete(); w_cur = null; b_wait.delete(); r_wait.delete();
        continue;
      end
      sample_aw();
      sample_w();
      pair_writes();
      sample_b();
      sample_ar();
      sample_r();
    end
  endtask

  //----------------------------------------------------------------------------
  protected function void sample_aw();
    if (vif.mon_cb.awvalid && vif.mon_cb.awready) begin
      axi_txn t = axi_txn::type_id::create("mon_wr");
      t.dir        = AXI_WRITE;
      t.id         = vif.mon_cb.awid;
      t.addr       = vif.mon_cb.awaddr;
      t.len        = vif.mon_cb.awlen;
      t.size       = vif.mon_cb.awsize;
      t.burst      = axi_burst_e'(vif.mon_cb.awburst);
      t.lock       = vif.mon_cb.awlock;
      t.cache      = vif.mon_cb.awcache;
      t.prot       = vif.mon_cb.awprot;
      t.start_time = $time;
      aw_q.push_back(t);
    end
  endfunction

  protected function void sample_w();
    if (vif.mon_cb.wvalid && vif.mon_cb.wready) begin
      if (w_cur == null) w_cur = axi_txn::type_id::create("mon_wdata");
      w_cur.data.push_back(vif.mon_cb.wdata);
      w_cur.strb.push_back(vif.mon_cb.wstrb);
      if (vif.mon_cb.wlast) begin
        w_q.push_back(w_cur);
        w_cur = null;
      end
    end
  endfunction

  protected function void pair_writes();
    while (aw_q.size() > 0 && w_q.size() > 0) begin
      axi_txn t = aw_q.pop_front();
      axi_txn d = w_q.pop_front();
      t.data = d.data;
      t.strb = d.strb;
      if (t.data.size() != t.num_beats())
        `uvm_error("AXI_MON", $sformatf("write id=%0h: %0d W beats for AWLEN+1=%0d",
                                        t.id, t.data.size(), t.num_beats()))
      b_wait[t.id].push_back(t);
    end
  endfunction

  protected function void sample_b();
    if (vif.mon_cb.bvalid && vif.mon_cb.bready) begin
      bit [AXI_ID_W-1:0] id = vif.mon_cb.bid;
      if (!b_wait.exists(id) || b_wait[id].size() == 0) begin
        `uvm_error("AXI_MON", $sformatf("B response for id=%0h with no completed write", id))
      end else begin
        axi_txn t = b_wait[id].pop_front();
        t.resp.push_back(axi_resp_e'(vif.mon_cb.bresp));
        t.end_time = $time;
        num_writes++;
        `uvm_info("AXI_MON", {"write ", t.convert2string()}, UVM_HIGH)
        ap_write.write(t);
      end
    end
  endfunction

  protected function void sample_ar();
    if (vif.mon_cb.arvalid && vif.mon_cb.arready) begin
      axi_txn t = axi_txn::type_id::create("mon_rd");
      t.dir        = AXI_READ;
      t.id         = vif.mon_cb.arid;
      t.addr       = vif.mon_cb.araddr;
      t.len        = vif.mon_cb.arlen;
      t.size       = vif.mon_cb.arsize;
      t.burst      = axi_burst_e'(vif.mon_cb.arburst);
      t.lock       = vif.mon_cb.arlock;
      t.cache      = vif.mon_cb.arcache;
      t.prot       = vif.mon_cb.arprot;
      t.start_time = $time;
      r_wait[t.id].push_back(t);
    end
  endfunction

  protected function void sample_r();
    if (vif.mon_cb.rvalid && vif.mon_cb.rready) begin
      bit [AXI_ID_W-1:0] id = vif.mon_cb.rid;
      if (!r_wait.exists(id) || r_wait[id].size() == 0) begin
        `uvm_error("AXI_MON", $sformatf("R beat for id=%0h with no outstanding read", id))
      end else begin
        axi_txn t = r_wait[id][0];
        t.data.push_back(vif.mon_cb.rdata);
        t.resp.push_back(axi_resp_e'(vif.mon_cb.rresp));
        if (vif.mon_cb.rlast) begin
          void'(r_wait[id].pop_front());
          if (t.data.size() != t.num_beats())
            `uvm_error("AXI_MON", $sformatf("read id=%0h: RLAST after %0d beats, ARLEN+1=%0d",
                                            id, t.data.size(), t.num_beats()))
          t.end_time = $time;
          num_reads++;
          `uvm_info("AXI_MON", {"read ", t.convert2string()}, UVM_HIGH)
          ap_read.write(t);
        end else if (t.data.size() >= t.num_beats()) begin
          `uvm_error("AXI_MON", $sformatf("read id=%0h: missing RLAST", id))
        end
      end
    end
  endfunction

  virtual function void report_phase(uvm_phase phase);
    `uvm_info("AXI_MON", $sformatf("observed %0d write bursts, %0d read bursts",
                                   num_writes, num_reads), UVM_LOW)
  endfunction

endclass : axi_monitor
