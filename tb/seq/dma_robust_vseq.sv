//==============================================================================
// dma_robust_vseq.sv - robustness and power-management features
//
//   dma_watchdog_vseq : channel lock-up watchdog (WD / WDSTAT / FTR lockup_err)
//   dma_lowpower_vseq : AMBA Q-Channel quiescence handshake and clock gating
//==============================================================================

//------------------------------------------------------------------------------
// Watchdog
//   A. abort mode     : a hung read stalls the channel -> lockup_err fault,
//                       WDSTAT, irq_abort; recovery once the bus answers
//   B. report only    : WD.irq_only = 1 -> WDSTAT + irq_abort, the transfer
//                       continues and completes with correct data
//   C. no false alarm : waiting for an event or a peripheral is not a lock-up
//   D. disabled       : timeout = 0 never reports
//   E. every channel  : all channels hung at once, each one is reported
//   F. killing        : a channel killed while its bus is hung is reported
//                       but not faulted (it is already being stopped)
//   G. fault pending  : a channel in Fault completing on a hung bus is
//                       reported, its fault type stays the original one
//------------------------------------------------------------------------------
class dma_watchdog_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_watchdog_vseq)

  int unsigned            CH;                     // chosen per seed
  localparam int unsigned TIMEOUT = 4;            // x256 clk = 1024 clk

  function new(string name = "dma_watchdog_vseq");
    super.new(name);
  endfunction

  virtual task pre_body();
    super.pre_body();
    CH = $urandom_range(dma_tb_params_pkg::NUM_CH - 1);
    `uvm_info("WDOG", $sformatf("using channel %0d", CH), UVM_LOW)
  endtask

  // Read responses of the channel's source region are held back
  protected function void hang_reads(int ch = -1);
    bit [31:0] lo = dma_job::src_base(ch < 0 ? CH : ch);
    p_sequencer.cfg.axi_cfg.add_stall_region(lo, lo + 32'h000F_FFFF);
  endfunction

  protected function void release_bus();
    p_sequencer.cfg.axi_cfg.clear_stall_regions();
  endfunction

  protected function dma_job big_job(int ch = -1);
    dma_job job = make_job(ch < 0 ? CH : ch, JOB_M2M);
    job.nbytes = 2048;                 // more than the MFIFO: the thread blocks
    return job;
  endfunction

  protected task expect_clean(string what);
    uvm_reg_data_t v;
    reg_rd(rm.WDSTAT, v);
    if (v != 0) `uvm_error("WDOG", $sformatf("%s: WDSTAT=0x%0h, no lock-up expected", what, v))
    if (vif.irq_abort !== 1'b0) `uvm_error("WDOG", $sformatf("%s: irq_abort set", what))
  endtask

  protected task finish(dma_job job);
    wait_irq(job.irq_ev);
    clear_irq(job.irq_ev);
    wait_ch_status(job.ch, dma330_pkg::ST_STOPPED);
    p_sequencer.sb.job_done(job);
  endtask

  virtual task body();
    uvm_reg_data_t v;
    dma_job        job;
    reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);

    //------------------------------------------------------------ A. abort mode
    reg_wr(rm.WD, TIMEOUT << 16);
    reg_rd(rm.WD, v);
    if (v != (TIMEOUT << 16)) `uvm_error("WDOG", $sformatf("WD read back 0x%08h", v))
    job = big_job();
    load_job(job);
    p_sequencer.sb.ignore_channel(CH, 1);
    hang_reads();
    start_channel(CH, job.prog_addr);
    wait_abort();
    reg_rd(rm.WDSTAT, v);
    if (!v[CH]) `uvm_error("WDOG", $sformatf("A: WDSTAT=0x%0h, bit %0d expected", v, CH))
    reg_rd(rm.FTR[CH], v);
    if (!v[dma330_pkg::FTC_LOCKUP_ERR]) `uvm_error("WDOG", $sformatf("A: FTR=0x%08h, lockup_err expected", v))
    p_sequencer.cov.sample_fault(v, 0);
    reg_rd(rm.FSRC, v);
    if (!v[CH]) `uvm_error("WDOG", $sformatf("A: FSRC=0x%0h", v))
    begin
      bit [3:0] s;
      read_ch_status(CH, s);
      if (s != dma330_pkg::ST_FAULT_COMPLETING)
        `uvm_error("WDOG", $sformatf("A: status %0d, fault completing expected (reads still held)", s))
    end
    // The bus answers again: outstanding reads retire, the channel parks
    release_bus();
    wait_ch_status(CH, dma330_pkg::ST_FAULTING);
    reg_wr(rm.WDSTAT, 1 << CH);
    kill_channel(CH);
    wait_ch_status(CH, dma330_pkg::ST_STOPPED);
    vif.wait_clks(10);
    reg_rd(rm.FTR[CH], v);
    if (v != 0) `uvm_error("WDOG", $sformatf("A: FTR=0x%08h after kill", v))
    expect_clean("A after recovery");
    p_sequencer.sb.ignore_channel(CH, 0);
    `uvm_info("WDOG", "A: hung read detected, channel aborted with lockup_err and recovered", UVM_LOW)

    //------------------------------------------------------------ B. report only
    reg_wr(rm.WD, (TIMEOUT << 16) | 1);
    job = big_job();
    load_job(job);
    p_sequencer.sb.add_job(job);
    hang_reads();
    start_channel(CH, job.prog_addr);
    wait_abort();
    reg_rd(rm.WDSTAT, v);
    if (!v[CH]) `uvm_error("WDOG", $sformatf("B: WDSTAT=0x%0h, bit %0d expected", v, CH))
    reg_rd(rm.FSRC, v);
    if (v != 0) `uvm_error("WDOG", $sformatf("B: FSRC=0x%0h, irq_only must not abort", v))
    release_bus();
    finish(job);                                          // data still correct
    reg_wr(rm.WDSTAT, 1 << CH);
    vif.wait_clks(5);
    expect_clean("B after WDSTAT clear");
    `uvm_info("WDOG", "B: report-only lock-up, transfer completed", UVM_LOW)

    //------------------------------------------------------------ C. legitimate waits
    reg_wr(rm.WD, 2 << 16);                               // 512 clk
    job = make_job(CH, JOB_M2M);
    job.pre_wfe_ev = 9;
    load_job(job);
    p_sequencer.sb.add_job(job);
    start_channel(CH, job.prog_addr);
    wait_ch_status(CH, dma330_pkg::ST_WAIT_EVENT);
    vif.wait_clks(3000);
    expect_clean("C waiting for an event");
    dbg_exec(1, CH, '{8'h34, 8'(9 << 3)});
    finish(job);

    job = make_job(CH, JOB_M2P);
    job.periph = CH % dma_tb_params_pkg::NUM_PERIPH;
    load_job(job);
    p_sequencer.sb.add_job(job);
    start_channel(CH, job.prog_addr);
    wait_ch_status(CH, dma330_pkg::ST_WAIT_PERIPH);
    vif.wait_clks(3000);
    expect_clean("C waiting for a peripheral");
    begin
      dma_periph_pkg::periph_req_seq s = dma_periph_pkg::periph_req_seq::type_id::create("reqs");
      s.types = job.req_types;
      fork
        s.start(p_sequencer.per_sqr[job.periph]);
        finish(job);
      join
    end
    expect_clean("C after the transfers");
    `uvm_info("WDOG", "C: event / peripheral waits are not reported", UVM_LOW)

    //------------------------------------------------------------ D. disabled
    reg_wr(rm.WD, 0);
    job = big_job();
    load_job(job);
    p_sequencer.sb.add_job(job);
    hang_reads();
    start_channel(CH, job.prog_addr);
    vif.wait_clks(3000);
    expect_clean("D watchdog disabled");
    release_bus();
    finish(job);
    `uvm_info("WDOG", "D: disabled watchdog never reports", UVM_LOW)

    //------------------------------------------------------------ E. every channel
    begin
      dma_job      jobs [dma_tb_params_pkg::NUM_CH];
      bit [31:0]   all = (1 << dma_tb_params_pkg::NUM_CH) - 1;
      int unsigned polls = 0;
      reg_wr(rm.WD, (TIMEOUT << 16) | 1);
      foreach (jobs[c]) begin
        jobs[c] = big_job(c);
        load_job(jobs[c]);
        p_sequencer.sb.add_job(jobs[c]);
        hang_reads(c);
      end
      foreach (jobs[c]) start_channel(c, jobs[c].prog_addr);
      do begin
        vif.wait_clks(100);
        reg_rd(rm.WDSTAT, v);
        polls++;
      end while (v != all && polls < 100);
      if (v != all) `uvm_error("WDOG", $sformatf("E: WDSTAT=0x%0h, all channels expected", v))
      vif.wait_clks(600);                       // timers stay at the timeout, no re-report
      reg_wr(rm.WDSTAT, all);
      reg_rd(rm.WDSTAT, v);
      if (v != 0) `uvm_error("WDOG", $sformatf("E: lock-up reported twice without progress: WDSTAT=0x%0h", v))
      release_bus();
      foreach (jobs[c]) begin
        automatic int k = c;
        fork finish(jobs[k]); join_none
      end
      wait fork;
      reg_wr(rm.WDSTAT, all);
      vif.wait_clks(5);
      expect_clean("E after WDSTAT clear");
      `uvm_info("WDOG", "E: lock-up of every channel reported, all transfers completed", UVM_LOW)
    end

    //------------------------------------------------------------ F. killing
    reg_wr(rm.WD, 0);
    job = big_job();
    load_job(job);
    p_sequencer.sb.ignore_channel(CH, 1);
    hang_reads();
    start_channel(CH, job.prog_addr);
    vif.wait_clks(500);
    kill_channel(CH);                                     // waits for the hung reads
    wait_ch_status(CH, dma330_pkg::ST_KILLING);
    reg_wr(rm.WD, 2 << 16);
    wait_abort();
    reg_rd(rm.WDSTAT, v);
    if (!v[CH]) `uvm_error("WDOG", $sformatf("F: WDSTAT=0x%0h, bit %0d expected", v, CH))
    reg_rd(rm.FTR[CH], v);
    if (v != 0) `uvm_error("WDOG", $sformatf("F: FTR=0x%08h, a killed channel is not faulted", v))
    release_bus();
    wait_ch_status(CH, dma330_pkg::ST_STOPPED);
    reg_wr(rm.WDSTAT, 1 << CH);
    vif.wait_clks(5);
    expect_clean("F after kill");
    p_sequencer.sb.ignore_channel(CH, 0);
    `uvm_info("WDOG", "F: hung kill reported, channel stopped once the bus answered", UVM_LOW)

    //------------------------------------------------------------ G. fault pending
    reg_wr(rm.WD, 0);
    job = big_job();
    load_job(job);
    p_sequencer.sb.ignore_channel(CH, 1);
    hang_reads();
    start_channel(CH, job.prog_addr);
    vif.wait_clks(500);
    dbg_exec(1, CH, '{8'h18});                            // illegal debug insn -> fault
    wait_ch_status(CH, dma330_pkg::ST_FAULT_COMPLETING);
    reg_wr(rm.WD, 2 << 16);
    do begin
      vif.wait_clks(100);
      reg_rd(rm.WDSTAT, v);
    end while (!v[CH]);
    reg_rd(rm.FTR[CH], v);
    if (v[dma330_pkg::FTC_LOCKUP_ERR] || !v[dma330_pkg::FTC_DBG_INSTR])
      `uvm_error("WDOG", $sformatf("G: FTR=0x%08h, original debug fault only", v))
    release_bus();
    wait_ch_status(CH, dma330_pkg::ST_FAULTING);
    kill_channel(CH);
    wait_ch_status(CH, dma330_pkg::ST_STOPPED);
    reg_wr(rm.WDSTAT, 1 << CH);
    reg_wr(rm.WD, 0);
    vif.wait_clks(5);
    expect_clean("G after kill");
    p_sequencer.sb.ignore_channel(CH, 0);
    `uvm_info("WDOG", "G: lock-up during fault completion reported, fault type kept", UVM_LOW)
  endtask

endclass : dma_watchdog_vseq

//------------------------------------------------------------------------------
// Low power (Q-Channel)
//   1. idle            -> accepted; clock gated; an APB access wakes the DMA
//                         up (qactive) and completes after the exit handshake
//   2. transfer busy   -> denied, the transfer is not disturbed
//   3. waiting in WFP  -> denied (a channel program is still running)
//   4. faulting channel-> quiescent: accepted
//   5. repeated entry / exit between random transfers
//------------------------------------------------------------------------------
class dma_lowpower_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_lowpower_vseq)

  function new(string name = "dma_lowpower_vseq");
    super.new(name);
  endfunction

  protected task finish(dma_job job);
    wait_irq(job.irq_ev);
    clear_irq(job.irq_ev);
    wait_ch_status(job.ch, dma330_pkg::ST_STOPPED);
    p_sequencer.sb.job_done(job);
  endtask

  // Enter quiescence, gate the clock for 'n' cycles, then wake up by an APB
  // access (a write of INTEN, alternating with a read of DSR): the access
  // must stall until the controller has restored the clock and left
  // Q_STOPPED, and a write must not be lost.
  int unsigned wake_count;

  protected task sleep_and_wake_by_apb(int unsigned n, string what);
    bit            acc, released;
    uvm_reg_data_t v;
    bit            use_write = wake_count[0];
    uvm_reg_data_t inten_val = ((1 << dma_tb_params_pkg::NUM_CH) - 1) | (32'h100 << wake_count[1]);
    wake_count++;
    vif.q_request(acc);
    if (!acc) begin
      `uvm_error("LPI", {what, ": quiescence denied while idle"})
      vif.q_release();
      return;
    end
    if (vif.qactive !== 1'b0) `uvm_error("LPI", {what, ": qactive set while quiescent"})
    vif.gate_clock();
    vif.wait_clks(n);
    released = 0;
    fork
      begin                                   // stalls while quiescent
        if (use_write) reg_wr(rm.INTEN, inten_val);
        else           reg_rd(rm.DSR, v);
        if (!released)
          `uvm_error("LPI", {what, ": APB access completed while the DMA was quiescent"})
      end
      begin
        wait (vif.qactive === 1'b1);          // wake-up request from the APB port
        vif.wait_clks(3);
        vif.q_release();
        released = 1;
      end
    join
    if (use_write) begin
      reg_rd(rm.INTEN, v);
      if (v != inten_val) `uvm_error("LPI", $sformatf("%s: write during sleep lost, INTEN=0x%0h", what, v))
      reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);
    end else if (v[3:0] != dma330_pkg::ST_STOPPED && v[3:0] != dma330_pkg::ST_FAULTING) begin
      `uvm_error("LPI", $sformatf("%s: DSR=0x%08h after wake-up", what, v))
    end
  endtask

  protected task expect_deny(string what);
    bit acc;
    vif.q_request(acc);
    if (acc) `uvm_error("LPI", {what, ": quiescence accepted while busy"})
    else     `uvm_info("LPI", {what, ": quiescence denied"}, UVM_LOW)
    vif.q_release();
  endtask

  virtual task body();
    dma_job job;
    int unsigned p;
    reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);

    //------------------------------------------------------------ 1
    sleep_and_wake_by_apb(300, "1 idle");
    `uvm_info("LPI", "1: idle DMA accepted, clock gated, woken up by APB", UVM_LOW)

    //------------------------------------------------------------ 2
    job = make_job(0, JOB_M2M);
    job.nbytes = 4096;
    load_job(job);
    p_sequencer.sb.add_job(job);
    start_channel(0, job.prog_addr);
    vif.wait_clks(200);
    expect_deny("2 transfer in progress");
    finish(job);

    //------------------------------------------------------------ 3
    p   = 1 % dma_tb_params_pkg::NUM_PERIPH;
    job = make_job(1 % dma_tb_params_pkg::NUM_CH, JOB_M2P);
    job.periph = p;
    load_job(job);
    p_sequencer.sb.add_job(job);
    start_channel(job.ch, job.prog_addr);
    wait_ch_status(job.ch, dma330_pkg::ST_WAIT_PERIPH);
    vif.wait_clks(200);                        // flush handshake done
    expect_deny("3 channel waiting for a peripheral");
    begin
      dma_periph_pkg::periph_req_seq s = dma_periph_pkg::periph_req_seq::type_id::create("reqs");
      s.types = job.req_types;
      fork
        s.start(p_sequencer.per_sqr[p]);
        finish(job);
      join
    end
    vif.wait_clks(300);                        // last acknowledge through the CDC

    //------------------------------------------------------------ 4
    begin
      int unsigned ch = 2 % dma_tb_params_pkg::NUM_CH;
      dma330_asm   a  = dma330_asm::type_id::create("bad");
      bit [31:0]   pc = dma_job::prog_base(ch) + 32'h4000;
      a.raw(8'hFF);
      p_sequencer.cfg.mem.write_bytes(pc, a.code);
      p_sequencer.sb.add_prog_region(pc, a.code.size());
      p_sequencer.sb.ignore_channel(ch, 1);
      start_channel(ch, pc);
      wait_abort();
      wait_ch_status(ch, dma330_pkg::ST_FAULTING);
      sleep_and_wake_by_apb(100, "4 faulting channel");
      kill_channel(ch);
      wait_ch_status(ch, dma330_pkg::ST_STOPPED);
      p_sequencer.sb.ignore_channel(ch, 0);
      `uvm_info("LPI", "4: a faulting channel does not prevent quiescence", UVM_LOW)
    end

    //------------------------------------------------------------ 5
    repeat (5) begin
      run_job(make_job($urandom_range(dma_tb_params_pkg::NUM_CH - 1), JOB_M2M));
      sleep_and_wake_by_apb($urandom_range(300, 10), "5 between transfers");
    end
    `uvm_info("LPI", "5: repeated sleep / wake-up between transfers", UVM_LOW)
  endtask

endclass : dma_lowpower_vseq
