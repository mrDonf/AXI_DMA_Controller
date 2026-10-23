//==============================================================================
// dma_corner_vseq.sv - corner cases added for coverage closure
//
//   dma_periph_corner_vseq : peripheral protocol corner cases
//   dma_boot_err_vseq      : manager boots from a failing address
//   dma_reset_vseq         : system reset in the middle of traffic
//==============================================================================

//------------------------------------------------------------------------------
// Peripheral protocol corners
//   1. a flush acknowledge the DMA never asked for is ignored
//   2. the peripheral fires all requests back to back (no wait for the
//      acknowledge): the DMA back-pressures with drready = 0
//   3. two channels wait on the same peripheral: requests are shared, both
//      DMAFLUSHPs are answered, the second flush acknowledge is ignored
//   4. a request that arrives while the DMA is still flushing is dropped
//------------------------------------------------------------------------------
class dma_periph_corner_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_periph_corner_vseq)

  function new(string name = "dma_periph_corner_vseq");
    super.new(name);
  endfunction

  protected task send_requests(int unsigned p, dma_periph_pkg::periph_req_e types[$]);
    dma_periph_pkg::periph_req_seq s = dma_periph_pkg::periph_req_seq::type_id::create("reqs");
    s.types = types;
    s.start(p_sequencer.per_sqr[p]);
  endtask

  protected task finish(dma_job job);
    wait_irq(job.irq_ev);
    clear_irq(job.irq_ev);
    wait_ch_status(job.ch, dma330_pkg::ST_STOPPED);
  endtask

  protected function dma_job m2p_job(int unsigned ch, int unsigned p, int unsigned n);
    dma_job job = make_job(ch, JOB_M2P);
    job.periph  = p;
    job.num_req = n;
    return job;
  endfunction

  virtual task body();
    dma_periph_pkg::periph_req_e  types [$];
    dma_job j0, j1;
    int unsigned p = 2;
    reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);

    // Scenarios 1 and 2 on every peripheral, each driven by channel q
    for (int q = 0; q < dma_tb_params_pkg::NUM_PERIPH; q++) begin
      int unsigned ch = q % dma_tb_params_pkg::NUM_CH;
      dma_periph_pkg::periph_config qcfg = p_sequencer.cfg.per_cfg[q];

      //---------------------------------------------------------- 1. stray flush ack
      begin
        dma_periph_pkg::periph_req_seq s = dma_periph_pkg::periph_req_seq::type_id::create("stray");
        s.types = '{dma_periph_pkg::PREQ_FLUSH_ACK};
        s.start(p_sequencer.per_sqr[q]);
        vif.wait_clks(100);
      end
      j0 = m2p_job(ch, q, 3);
      run_job(j0);
      `uvm_info("PCORNER", $sformatf("1: periph%0d ignored an unsolicited flush acknowledge", q), UVM_LOW)

      //---------------------------------------------------------- 2. back-to-back requests
      j0 = m2p_job(ch, q, 8);
      load_job(j0);
      p_sequencer.sb.add_job(j0);
      start_channel(ch, j0.prog_addr);
      wait_ch_status(ch, dma330_pkg::ST_WAIT_PERIPH);      // flush is done
      qcfg.wait_ack = 0;
      send_requests(q, j0.req_types);
      finish(j0);
      vif.wait_clks(300);                                   // last ack through the CDC
      qcfg.wait_ack = 1;
      p_sequencer.sb.job_done(j0);
      `uvm_info("PCORNER", $sformatf("2: periph%0d back-to-back requests back-pressured", q), UVM_LOW)
    end

    //------------------------------------------------------------ 4. requests during a flush
    // The peripheral does not answer the flush by itself: while the DMA is
    // flushing (already waiting in DMAWFP) a request arrives and must be
    // dropped; then the flush acknowledge; then the real requests.
    begin
      dma_periph_pkg::periph_config qcfg = p_sequencer.cfg.per_cfg[p];
      dma_periph_pkg::periph_req_e  seq_types [$];
      j0 = m2p_job(0, p, 4);
      load_job(j0);
      p_sequencer.sb.add_job(j0);
      qcfg.auto_flush_ack = 0;
      qcfg.wait_ack       = 0;
      start_channel(0, j0.prog_addr);
      wait_ch_status(0, dma330_pkg::ST_WAIT_PERIPH);
      seq_types = '{dma_periph_pkg::PREQ_BURST, dma_periph_pkg::PREQ_FLUSH_ACK};
      send_requests(p, seq_types);                       // dropped, then flush done
      vif.wait_clks(100);
      begin
        uvm_reg_data_t v;
        reg_rd(rm.SAR[0], v);
        if (v != j0.src) `uvm_error("PCORNER", "a request sent during the flush was not dropped")
      end
      send_requests(p, j0.req_types);
      finish(j0);
      vif.wait_clks(300);
      qcfg.auto_flush_ack = 1;
      qcfg.wait_ack       = 1;
      p_sequencer.sb.job_done(j0);
      `uvm_info("PCORNER", "4: request during flush dropped", UVM_LOW)
    end

    //------------------------------------------------------------ 3. two channels, one peripheral
    j0 = m2p_job(0, p, 3);
    j1 = m2p_job(1, p, 4);
    load_job(j0);
    load_job(j1);
    // Expected acknowledges in arrival order: both flushes, then 7 bursts
    j0.exp_acks = '{dma_periph_pkg::PACK_FLUSH, dma_periph_pkg::PACK_FLUSH};
    repeat (7) j0.exp_acks.push_back(dma_periph_pkg::PACK_BURST);
    j1.exp_acks.delete();
    p_sequencer.sb.add_job(j0);
    p_sequencer.sb.add_job(j1);
    start_channel(0, j0.prog_addr);
    start_channel(1, j1.prog_addr);
    wait_ch_status(0, dma330_pkg::ST_WAIT_PERIPH);
    wait_ch_status(1, dma330_pkg::ST_WAIT_PERIPH);
    repeat (7) types.push_back(dma_periph_pkg::PREQ_BURST);
    send_requests(p, types);
    fork
      finish(j0);
      finish(j1);
    join
    vif.wait_clks(300);
    p_sequencer.sb.job_done(j0);
    p_sequencer.sb.job_done(j1);
    `uvm_info("PCORNER", "3: two channels shared one peripheral", UVM_LOW)
  endtask

endclass : dma_periph_corner_vseq

//------------------------------------------------------------------------------
// Manager boots from an address that returns an AXI error (set up by the test
// before reset): instruction fetch fault, then recovery through DMAKILL.
//------------------------------------------------------------------------------
class dma_boot_err_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_boot_err_vseq)

  bit [31:0] boot_addr;

  function new(string name = "dma_boot_err_vseq");
    super.new(name);
  endfunction

  virtual task body();
    uvm_reg_data_t v;
    wait_abort();
    reg_rd(rm.DSR, v);
    if (v[3:0] != dma330_pkg::ST_FAULTING) `uvm_error("BOOTERR", $sformatf("DSR=0x%08h, faulting expected", v))
    reg_rd(rm.FTRD, v);
    if (!v[dma330_pkg::FTD_INSTR_FETCH_ERR])
      `uvm_error("BOOTERR", $sformatf("FTRD=0x%08h, instr_fetch_err expected", v))
    p_sequencer.cov.sample_fault(v, 1);
    reg_rd(rm.DPC, v);
    if (v != boot_addr) `uvm_error("BOOTERR", $sformatf("DPC=0x%08h, expected 0x%08h", v, boot_addr))
    kill_manager();
    vif.wait_clks(20);
    reg_rd(rm.FSRD, v);
    if (v[0]) `uvm_error("BOOTERR", "manager still faulting after DMAKILL")

    // The controller is fully usable afterwards
    reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);
    run_job(make_job(0, JOB_M2M));
    `uvm_info("BOOTERR", "manager boot fetch error handled", UVM_LOW)
  endtask

endclass : dma_boot_err_vseq

//------------------------------------------------------------------------------
// Reset while every channel is transferring, then normal operation again
//------------------------------------------------------------------------------
class dma_reset_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_reset_vseq)

  function new(string name = "dma_reset_vseq");
    super.new(name);
  endfunction

  virtual task body();
    uvm_reg_data_t v;
    reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);

    // Start long transfers on every channel
    for (int ch = 0; ch < dma_tb_params_pkg::NUM_CH; ch++) begin
      dma_job job = make_job(ch, JOB_M2M);
      job.nbytes = 4096;
      load_job(job);
      p_sequencer.sb.add_job(job);
      start_channel(ch, job.prog_addr);
    end
    vif.wait_clks(1000 + $urandom_range(1000));

    // Reset in the middle of the traffic
    for (int ch = 0; ch < dma_tb_params_pkg::NUM_CH; ch++) p_sequencer.sb.ignore_channel(ch, 1);
    `uvm_info("RESET", "asserting reset during traffic", UVM_LOW)
    vif.pulse_reset(20);
    rm.reset();
    vif.wait_clks(50);
    for (int ch = 0; ch < dma_tb_params_pkg::NUM_CH; ch++) p_sequencer.sb.ignore_channel(ch, 0);

    // Everything is back to its reset state
    reg_rd(rm.DSR, v);
    if (v[3:0] != dma330_pkg::ST_STOPPED) `uvm_error("RESET", "manager not stopped after reset")
    foreach (rm.CSR[n]) begin
      reg_rd(rm.CSR[n], v);
      if (v[3:0] != dma330_pkg::ST_STOPPED) `uvm_error("RESET", $sformatf("ch%0d not stopped after reset", n))
    end
    reg_rd(rm.INTEN, v);
    if (v != 0) `uvm_error("RESET", "INTEN not cleared by reset")
    if (vif.irq !== '0 || vif.irq_abort !== 1'b0) `uvm_error("RESET", "interrupts active after reset")

    // And it works again
    reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);
    for (int ch = 0; ch < dma_tb_params_pkg::NUM_CH; ch++) begin
      automatic int c = ch;
      fork
        repeat (2) run_job(make_job(c, JOB_M2M));
      join_none
    end
    wait fork;
    `uvm_info("RESET", "traffic after reset OK", UVM_LOW)
  endtask

endclass : dma_reset_vseq
