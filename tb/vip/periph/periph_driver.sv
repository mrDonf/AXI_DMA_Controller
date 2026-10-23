//==============================================================================
// periph_driver.sv - behaves like a DMA-capable peripheral
//------------------------------------------------------------------------------
// request process:
//   * takes request items from the sequencer and raises them on dr*
//   * with wait_ack, holds the item (and the sequence) until the DMA has
//     acknowledged it on da* -> the sequence finishes when all are served
//   * on a flush request from the DMA (datype = 10) it answers with
//     drtype = 10 and then re-sends its still-unacknowledged request
//     ("resend level status", as a DMA-330 peripheral does)
// ack process:
//   * random DAREADY, counts single/burst acknowledges, flags flushes
//==============================================================================
class periph_driver extends uvm_driver #(periph_item);

  `uvm_component_utils(periph_driver)

  periph_config cfg;
  periph_vif_t  vif;

  protected int unsigned acks_rcvd;
  protected bit          flush_pending;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(periph_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "periph_config not set")
    vif = cfg.vif;
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.drv_cb.drvalid <= 1'b0;
    vif.drv_cb.drtype  <= '0;
    vif.drv_cb.drlast  <= 1'b0;
    vif.drv_cb.daready <= 1'b0;
    @(posedge vif.rst_n);
    fork
      request_process();
      ack_process();
    join
  endtask

  //----------------------------------------------------------------------------
  protected task send_request(periph_req_e t, bit last);
    @(vif.drv_cb);
    vif.drv_cb.drvalid <= 1'b1;
    vif.drv_cb.drtype  <= t;
    vif.drv_cb.drlast  <= last;
    @(vif.drv_cb);
    while (!vif.drv_cb.drready) @(vif.drv_cb);
    vif.drv_cb.drvalid <= 1'b0;
    vif.drv_cb.drlast  <= 1'b0;
    `uvm_info("PER_DRV", $sformatf("periph%0d sent %s%s", cfg.periph_id, t.name(),
                                   last ? " LAST" : ""), UVM_HIGH)
  endtask

  protected task request_process();
    periph_item cur = null;
    bit         waiting_ack = 0;
    forever begin
      if (flush_pending) begin
        flush_pending = 0;
        send_request(PREQ_FLUSH_ACK, 1'b0);
        if (waiting_ack && cur != null)
          send_request(cur.req_type, cur.last);        // re-send level status
        continue;
      end

      if (waiting_ack) begin
        if (acks_rcvd > 0) begin
          acks_rcvd--;
          waiting_ack = 0;
          seq_item_port.item_done();
          cur = null;
        end else begin
          @(vif.drv_cb);
        end
        continue;
      end

      seq_item_port.try_next_item(cur);
      if (cur == null) begin
        @(vif.drv_cb);
        continue;
      end
      repeat (cur.delay) @(vif.drv_cb);
      send_request(cur.req_type, cur.last);
      if (cfg.wait_ack && cur.req_type != PREQ_FLUSH_ACK) begin
        waiting_ack = 1;
      end else begin
        seq_item_port.item_done();
        cur = null;
      end
    end
  endtask

  protected task ack_process();
    bit rdy_q = 0;
    forever begin
      @(vif.drv_cb);
      if (rdy_q && vif.drv_cb.davalid) begin
        periph_ack_e a = periph_ack_e'(vif.drv_cb.datype);
        if (a == PACK_FLUSH) begin
          if (cfg.auto_flush_ack) flush_pending = 1;
        end else if (cfg.wait_ack) begin
          acks_rcvd++;            // only counted when requests wait for them
        end
      end
      rdy_q = ($urandom_range(99) < cfg.daready_pct);
      vif.drv_cb.daready <= rdy_q;
    end
  endtask

endclass : periph_driver
