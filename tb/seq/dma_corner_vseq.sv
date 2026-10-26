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
//   5. DMAWFP burst drops a single request and keeps waiting (TRM 2.6.5)
//   6. DMAWFP single continues on a burst request and leaves it pending for
//      the next DMAWFP; DMALDS / DMASTPS move one beat
//   7. DMAFLUSHP waits for the acknowledge of an earlier DMASTPB: the flush
//      request never overtakes it
//   8. DMAWFP burst clears request_last even when the request is flagged
//      last: a DMALPFE loop around it does not exit (TRM 2.6.4)
//   9. Reset of one peripheral domain alone (periph_rst_n) after an odd
//      number of transfers each way: no phantom request reaches a DMAWFP and
//      no phantom acknowledge reaches the peripheral
//------------------------------------------------------------------------------
class dma_periph_corner_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_periph_corner_vseq)

  function new(string name = "dma_periph_corner_vseq");
    super.new(name);
  endfunction

  protected task send_requests(int unsigned p, dma_periph_pkg::periph_req_e types[$],
                               bit last_on_final = 0);
    dma_periph_pkg::periph_req_seq s = dma_periph_pkg::periph_req_seq::type_id::create("reqs");
    s.types         = types;
    s.last_on_final = last_on_final;
    s.start(p_sequencer.per_sqr[p]);
  endtask

  protected task finish(dma_job job);
    wait_irq(job.irq_ev);
    clear_irq(job.irq_ev);
    wait_ch_status(job.ch, dma330_pkg::ST_STOPPED);
  endtask

  // Hand-written memory -> peripheral program (4 x 8-byte bursts, FIXED
  // destination); the scoreboard ignores the channel's AXI traffic but
  // checks the acknowledges. Returns SAR at the end.
  protected function dma330_asm hand_prog(int unsigned ch, int unsigned p);
    dma330_asm a = dma330_asm::type_id::create("pc_prog");
    a.dmamov(RD_SAR, dma_job::src_base(ch) + 32'h6000);
    a.dmamov(RD_DAR, dma_job::fifo_addr(p));
    a.dmamov(RD_CCR, dma330_asm::ccr(1, 3, 4, 0, 3, 4));
    a.dmaflushp(p);
    return a;
  endfunction

  protected task run_hand(string name, int unsigned ch, int unsigned p, dma330_asm a,
                          dma_periph_pkg::periph_req_e first [$],
                          dma_periph_pkg::periph_req_e rest [$],
                          dma_periph_pkg::periph_ack_e acks [$], int unsigned sar_moved);
    dma_periph_pkg::periph_config qcfg = p_sequencer.cfg.per_cfg[p];
    bit [31:0]     pc = dma_job::prog_base(ch) + 32'h6000;
    uvm_reg_data_t v;
    a.dmawmb();
    a.dmasev(ch);
    a.dmaend();
    `uvm_info("PCORNER", $sformatf("%s:%s", name, a.sprint_listing()), UVM_MEDIUM)
    p_sequencer.cfg.mem.write_bytes(pc, a.code);
    p_sequencer.sb.add_prog_region(pc, a.code.size());
    p_sequencer.cov.sample_program(a.code);
    p_sequencer.sb.ignore_channel(ch, 1);
    foreach (acks[i]) p_sequencer.sb.add_expected_ack(p, acks[i]);
    qcfg.wait_ack = 0;
    start_channel(ch, pc);
    wait_ch_status(ch, dma330_pkg::ST_WAIT_PERIPH);
    send_requests(p, first);
    if (rest.size() != 0) begin
      // The first requests alone must not let the channel go on
      vif.wait_clks(300);
      reg_rd(rm.CSR[ch], v);
      if (v[3:0] != dma330_pkg::ST_WAIT_PERIPH)
        `uvm_error("PCORNER", $sformatf("%s: CSR=0x%08h, still waiting for the peripheral expected", name, v))
      send_requests(p, rest);
    end
    wait_irq(ch);
    clear_irq(ch);
    wait_ch_status(ch, dma330_pkg::ST_STOPPED);
    reg_rd(rm.FTR[ch], v);
    if (v != 0) `uvm_error("PCORNER", $sformatf("%s: FTR=0x%08h", name, v))
    reg_rd(rm.SAR[ch], v);
    if (v != dma_job::src_base(ch) + 32'h6000 + sar_moved)
      `uvm_error("PCORNER", $sformatf("%s: SAR moved by %0d bytes, %0d expected",
                                      name, v - (dma_job::src_base(ch) + 32'h6000), sar_moved))
    vif.wait_clks(300);                                    // last ack through the CDC
    qcfg.wait_ack = 1;
    p_sequencer.sb.ignore_channel(ch, 0);
    `uvm_info("PCORNER", {name, " OK"}, UVM_LOW)
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

    //------------------------------------------------------------ 5. WFP burst drops a single
    begin
      dma330_asm a = hand_prog(2, p);
      a.dmawfp(p, WFP_BURST);
      a.dmald(COND_B);
      a.dmastp(COND_B, p);
      run_hand("5: DMAWFP burst drops a single request", 2, p, a,
               '{dma_periph_pkg::PREQ_SINGLE}, '{dma_periph_pkg::PREQ_BURST},
               '{dma_periph_pkg::PACK_FLUSH, dma_periph_pkg::PACK_BURST}, 32);
    end

    //------------------------------------------------------------ 6. WFP single keeps a burst
    begin
      dma330_asm a = hand_prog(2, p);
      a.dmawfp(p, WFP_SINGLE);                            // request_type = single
      a.dmald(COND_S);                                    // one beat
      a.dmald(COND_B);                                    // NOP
      a.dmastp(COND_S, p);                                // one beat, single ack
      a.dmawfp(p, WFP_PERIPH);                            // the burst request, still pending
      a.dmald(COND_B);
      a.dmastp(COND_B, p);
      run_hand("6: DMAWFP single leaves a burst request pending", 2, p, a,
               '{dma_periph_pkg::PREQ_BURST}, '{},
               '{dma_periph_pkg::PACK_FLUSH, dma_periph_pkg::PACK_SINGLE, dma_periph_pkg::PACK_BURST},
               8 + 32);
    end

    //------------------------------------------------------------ 7. flush after an ack
    begin
      dma330_asm a = hand_prog(3, p);
      a.dmawfp(p, WFP_BURST);
      a.dmald();
      a.dmastp(COND_B, p);
      a.dmaflushp(p);                                     // after the STPB acknowledge
      run_hand("7: DMAFLUSHP waits for the DMASTPB acknowledge", 3, p, a,
               '{dma_periph_pkg::PREQ_BURST}, '{},
               '{dma_periph_pkg::PACK_FLUSH, dma_periph_pkg::PACK_BURST, dma_periph_pkg::PACK_FLUSH}, 32);
    end

    //------------------------------------------------------------ 8. WFP burst: request_last = 0
    begin
      dma_periph_pkg::periph_config qcfg = p_sequencer.cfg.per_cfg[p];
      dma330_asm     a = hand_prog(2, p);
      int unsigned   body;
      uvm_reg_data_t v;
      body = a.pc();
      a.dmawfp(p, WFP_BURST);
      a.dmald(COND_B);
      a.dmastp(COND_B, p);
      a.dmalpend(1, body, COND_ALWAYS, 1);                // DMALPFE: exits on request_last
      a.dmaend();
      p_sequencer.cfg.mem.write_bytes(dma_job::prog_base(2) + 32'h6000, a.code);
      p_sequencer.sb.add_prog_region(dma_job::prog_base(2) + 32'h6000, a.code.size());
      p_sequencer.sb.ignore_channel(2, 1);
      p_sequencer.sb.add_expected_ack(p, dma_periph_pkg::PACK_FLUSH);
      p_sequencer.sb.add_expected_ack(p, dma_periph_pkg::PACK_BURST);
      qcfg.wait_ack = 0;
      start_channel(2, dma_job::prog_base(2) + 32'h6000);
      wait_ch_status(2, dma330_pkg::ST_WAIT_PERIPH);
      send_requests(p, '{dma_periph_pkg::PREQ_BURST}, 1);  // flagged last
      vif.wait_clks(500);
      reg_rd(rm.CSR[2], v);
      if (v[3:0] != dma330_pkg::ST_WAIT_PERIPH)
        `uvm_error("PCORNER", $sformatf("8: CSR=0x%08h, the DMALPFE loop must go on (request_last = 0)", v))
      reg_rd(rm.SAR[2], v);
      if (v != dma_job::src_base(2) + 32'h6000 + 32)
        `uvm_error("PCORNER", $sformatf("8: SAR=0x%08h after one burst request", v))
      kill_channel(2);
      wait_ch_status(2, dma330_pkg::ST_STOPPED);
      vif.wait_clks(300);
      qcfg.wait_ack = 1;
      p_sequencer.sb.ignore_channel(2, 0);
      `uvm_info("PCORNER", "8: DMAWFP burst cleared request_last", UVM_LOW)
    end

    //------------------------------------------------------------ 9. peripheral-only reset
    begin
      int unsigned   q = 1;
      dma_periph_pkg::periph_config qcfg = p_sequencer.cfg.per_cfg[q];
      dma330_asm     a = dma330_asm::type_id::create("pc_prog");
      bit [31:0]     pc = dma_job::prog_base(1) + 32'h6000;
      uvm_reg_data_t v;
      // flush acknowledge + 2 requests = 3 transfers into the DMA, flush +
      // 2 acknowledges = 3 out of it: both toggle handshakes end at 1
      run_job(m2p_job(1, q, 2));
      vif.pulse_periph_reset(q, 10);
      vif.wait_clks(100);
      // No DMAFLUSHP: a phantom request would satisfy the DMAWFP at once
      a.dmamov(RD_SAR, dma_job::src_base(1) + 32'h6000);
      a.dmamov(RD_DAR, dma_job::fifo_addr(q));
      a.dmamov(RD_CCR, dma330_asm::ccr(1, 3, 4, 0, 3, 4));
      a.dmawfp(q, WFP_PERIPH);
      a.dmald(COND_B);
      a.dmastp(COND_B, q);
      a.dmawmb();
      a.dmasev(1);
      a.dmaend();
      p_sequencer.cfg.mem.write_bytes(pc, a.code);
      p_sequencer.sb.add_prog_region(pc, a.code.size());
      p_sequencer.sb.ignore_channel(1, 1);
      p_sequencer.sb.add_expected_ack(q, dma_periph_pkg::PACK_BURST);
      start_channel(1, pc);
      vif.wait_clks(500);
      reg_rd(rm.CSR[1], v);
      if (v[3:0] != dma330_pkg::ST_WAIT_PERIPH)
        `uvm_error("PCORNER", $sformatf("9: CSR=0x%08h, a phantom request after the peripheral reset", v))
      send_requests(q, '{dma_periph_pkg::PREQ_BURST});
      wait_irq(1);
      clear_irq(1);
      wait_ch_status(1, dma330_pkg::ST_STOPPED);
      vif.wait_clks(300);
      p_sequencer.sb.ignore_channel(1, 0);
      `uvm_info("PCORNER", "9: peripheral-only reset left no phantom transfer", UVM_LOW)
    end
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
