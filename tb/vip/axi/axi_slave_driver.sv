//==============================================================================
// axi_slave_driver.sv - reactive AXI4 memory slave
//------------------------------------------------------------------------------
// Five independent channel processes (one per AXI channel) plus a write
// processor that joins AW with its W beats:
//
//   aw_channel  : random AWREADY, queue accepted addresses
//   w_channel   : random WREADY, queue accepted beats
//   wr_process  : AW + complete W burst -> update memory -> pending B
//   b_channel   : return B responses (per-ID order, optional reordering)
//   ar_channel  : random ARREADY, queue accepted reads with a latency
//   r_channel   : return read beats (per-ID order, optional interleaving)
//
// Handshakes are detected on the clock edge with the READY value driven in
// the previous cycle (rdy_q) and the VALID sampled through the clocking block.
// Memory and error responses come from axi_config / axi_mem_model.
//==============================================================================
class axi_slave_driver extends uvm_driver #(axi_txn);

  `uvm_component_utils(axi_slave_driver)

  axi_config    cfg;
  axi_vif_t     vif;

  typedef struct {
    bit [AXI_DATA_W-1:0] data;
    bit [AXI_STRB_W-1:0] strb;
    bit                  last;
  } wbeat_t;

  protected axi_txn      aw_q   [$];   // waiting for W data
  protected wbeat_t      w_q    [$];   // beats not yet matched to an AW
  protected axi_txn      b_pend [$];   // waiting for the B handshake
  protected axi_txn      r_pend [$];   // accepted reads, in arrival order
  protected int unsigned cycle;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(axi_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "axi_config not set")
    vif = cfg.vif;
    if (cfg.mem == null)
      `uvm_fatal("NOMEM", "axi_config.mem (axi_mem_model) not set")
  endfunction

  virtual task run_phase(uvm_phase phase);
    forever begin
      drive_reset_values();
      clear_state();
      @(posedge vif.aresetn);
      fork
        begin : channel_procs
          fork
            cycle_counter();
            aw_channel();
            w_channel();
            wr_process();
            b_channel();
            ar_channel();
            r_channel();
          join
        end
        @(negedge vif.aresetn);
      join_any
      disable fork;
    end
  endtask

  //----------------------------------------------------------------------------
  protected task drive_reset_values();
    vif.slv_cb.awready <= 1'b0;
    vif.slv_cb.wready  <= 1'b0;
    vif.slv_cb.arready <= 1'b0;
    vif.slv_cb.bvalid  <= 1'b0;
    vif.slv_cb.bid     <= '0;
    vif.slv_cb.bresp   <= '0;
    vif.slv_cb.rvalid  <= 1'b0;
    vif.slv_cb.rid     <= '0;
    vif.slv_cb.rdata   <= '0;
    vif.slv_cb.rresp   <= '0;
    vif.slv_cb.rlast   <= 1'b0;
  endtask

  protected function void clear_state();
    aw_q.delete(); w_q.delete(); b_pend.delete(); r_pend.delete();
    cycle = 0;
  endfunction

  protected function bit chance(int unsigned pct);
    return ($urandom_range(99) < pct);
  endfunction

  protected task cycle_counter();
    forever begin
      @(vif.slv_cb);
      cycle++;
    end
  endtask

  //============================================================================
  // Write address / data acceptance
  //============================================================================
  protected task aw_channel();
    bit rdy_q = 0;
    forever begin
      @(vif.slv_cb);
      if (rdy_q && vif.slv_cb.awvalid) begin
        axi_txn t = axi_txn::type_id::create("aw");
        t.dir        = AXI_WRITE;
        t.id         = vif.slv_cb.awid;
        t.addr       = vif.slv_cb.awaddr;
        t.len        = vif.slv_cb.awlen;
        t.size       = vif.slv_cb.awsize;
        t.burst      = axi_burst_e'(vif.slv_cb.awburst);
        t.lock       = vif.slv_cb.awlock;
        t.cache      = vif.slv_cb.awcache;
        t.prot       = vif.slv_cb.awprot;
        t.start_time = $time;
        aw_q.push_back(t);
      end
      rdy_q = chance(cfg.aw_ready_pct);
      vif.slv_cb.awready <= rdy_q;
    end
  endtask

  protected task w_channel();
    bit rdy_q = 0;
    forever begin
      @(vif.slv_cb);
      if (rdy_q && vif.slv_cb.wvalid) begin
        wbeat_t b;
        b.data = vif.slv_cb.wdata;
        b.strb = vif.slv_cb.wstrb;
        b.last = vif.slv_cb.wlast;
        w_q.push_back(b);
      end
      rdy_q = chance(cfg.w_ready_pct);
      vif.slv_cb.wready <= rdy_q;
    end
  endtask

  // Joins an AW with its W beats (AXI4: W order == AW order) and commits it
  protected task wr_process();
    forever begin
      axi_txn t;
      int     nbeats;
      // Re-evaluated once per clock (queue contents are not wait-sensitive)
      while (!(aw_q.size() > 0 && w_burst_complete())) @(vif.slv_cb);
      t = aw_q.pop_front();
      nbeats = 0;
      while (1) begin
        wbeat_t b = w_q.pop_front();
        t.data.push_back(b.data);
        t.strb.push_back(b.strb);
        nbeats++;
        if (b.last) break;
      end
      if (nbeats != t.num_beats())
        `uvm_error("AXI_SLV", $sformatf("WLAST after %0d beats, AWLEN+1=%0d", nbeats, t.num_beats()))
      commit_write(t);
      t.ready_cycle = cycle + $urandom_range(cfg.b_lat_max, cfg.b_lat_min);
      b_pend.push_back(t);
    end
  endtask

  protected function bit w_burst_complete();
    foreach (w_q[i]) if (w_q[i].last) return 1;
    return 0;
  endfunction

  protected function void commit_write(axi_txn t);
    axi_resp_e r = AXI_OKAY;
    for (int unsigned i = 0; i < t.num_beats(); i++) begin
      axi_resp_e br = cfg.lookup_resp(t.beat_addr(i), 1);
      if (br != AXI_OKAY) r = br;
    end
    // Erroneous writes do not modify memory
    if (r == AXI_OKAY) begin
      for (int unsigned i = 0; i < t.num_beats(); i++)
        cfg.mem.write_beat(t.beat_addr(i), t.data[i], t.strb[i]);
    end
    t.resp.push_back(r);
  endfunction

  //============================================================================
  // Write response
  //============================================================================
  // Index of a B/R candidate: the oldest entry of its ID whose latency expired.
  protected function int pick_ready(ref axi_txn q[$]);
    int cand [$];
    bit [AXI_ID_W-1:0] seen [$];
    foreach (q[i]) begin
      if (q[i].id inside {seen}) continue;      // younger entry of an ID
      seen.push_back(q[i].id);
      if (q[i].ready_cycle <= cycle && !cfg.is_stalled(q[i].addr)) begin
        cand.push_back(i);
        if (!cfg.reorder_en) break;
      end else if (!cfg.reorder_en) begin
        break;                                  // strict global order
      end
    end
    if (cand.size() == 0) return -1;
    return cand[$urandom_range(cand.size() - 1)];
  endfunction

  protected task b_channel();
    axi_txn cur = null;
    forever begin
      @(vif.slv_cb);
      if (cur != null && vif.slv_cb.bready) begin
        foreach (b_pend[i]) if (b_pend[i] == cur) begin b_pend.delete(i); break; end
        cur = null;
      end
      if (cur == null) begin
        int idx = pick_ready(b_pend);
        if (idx >= 0) begin
          cur = b_pend[idx];
          vif.slv_cb.bvalid <= 1'b1;
          vif.slv_cb.bid    <= cur.id;
          vif.slv_cb.bresp  <= cur.resp[0];
        end else begin
          vif.slv_cb.bvalid <= 1'b0;
        end
      end
    end
  endtask

  //============================================================================
  // Read address / data
  //============================================================================
  protected task ar_channel();
    bit rdy_q = 0;
    forever begin
      @(vif.slv_cb);
      if (rdy_q && vif.slv_cb.arvalid) begin
        axi_txn t = axi_txn::type_id::create("ar");
        t.dir         = AXI_READ;
        t.id          = vif.slv_cb.arid;
        t.addr        = vif.slv_cb.araddr;
        t.len         = vif.slv_cb.arlen;
        t.size        = vif.slv_cb.arsize;
        t.burst       = axi_burst_e'(vif.slv_cb.arburst);
        t.lock        = vif.slv_cb.arlock;
        t.cache       = vif.slv_cb.arcache;
        t.prot        = vif.slv_cb.arprot;
        t.start_time  = $time;
        t.beat_idx    = 0;
        t.ready_cycle = cycle + $urandom_range(cfg.r_lat_max, cfg.r_lat_min);
        r_pend.push_back(t);
      end
      rdy_q = chance(cfg.ar_ready_pct);
      vif.slv_cb.arready <= rdy_q;
    end
  endtask

  protected task r_channel();
    axi_txn cur = null;      // burst whose beat is on the bus
    axi_txn last_t = null;   // burst of the previous beat (non-interleave mode)
    forever begin
      @(vif.slv_cb);
      // Handshake of the beat driven in the previous cycle
      if (cur != null && vif.slv_cb.rready) begin
        cur.beat_idx++;
        if (cur.beat_idx == cur.num_beats()) begin
          foreach (r_pend[i]) if (r_pend[i] == cur) begin r_pend.delete(i); break; end
          last_t = null;
        end else begin
          last_t = cur;
        end
        cur = null;
      end

      if (cur == null) begin
        axi_txn t = null;
        if (!chance(cfg.r_gap_pct)) begin
          if (last_t != null && !cfg.interleave_en) begin
            t = last_t;                          // finish current burst first
          end else begin
            int idx = pick_ready(r_pend);
            if (idx >= 0) t = r_pend[idx];
          end
        end
        if (t != null) begin
          bit [AXI_ADDR_W-1:0] a = t.beat_addr(t.beat_idx);
          axi_resp_e r = cfg.lookup_resp(a, 0);
          cur = t;
          vif.slv_cb.rvalid <= 1'b1;
          vif.slv_cb.rid    <= t.id;
          vif.slv_cb.rdata  <= (t.prot[1] && cfg.ns_raz(a)) ? '0 : cfg.mem.read_beat(a);
          vif.slv_cb.rresp  <= r;
          vif.slv_cb.rlast  <= (t.beat_idx == t.num_beats() - 1);
        end else begin
          vif.slv_cb.rvalid <= 1'b0;
          vif.slv_cb.rlast  <= 1'b0;
        end
      end
    end
  endtask

endclass : axi_slave_driver
