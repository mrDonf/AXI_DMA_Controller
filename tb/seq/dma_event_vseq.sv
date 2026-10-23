//==============================================================================
// dma_event_vseq.sv - DMASEV / DMAWFE synchronisation between threads
//   part 1: ch0 waits on event 8, ch1 signals it after its transfer (+DMAWMB)
//           -> ch0's first data read must come after ch1's last write
//   part 2: ch2 and ch3 wait on event 9; one debug DMASEV wakes both
//   part 3: an event signalled before DMAWFE is remembered (sticky)
//   part 4: an event number configured as interrupt does not release DMAWFE
//==============================================================================
class dma_event_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_event_vseq)

  localparam int EV_A = 8, EV_B = 9, EV_C = 10, EV_D = 13;

  function new(string name = "dma_event_vseq");
    super.new(name);
  endfunction

  // Load + register a job without starting it
  protected task prepare(dma_job job);
    load_job(job);
    p_sequencer.sb.add_job(job);
  endtask

  protected task finish(dma_job job);
    wait_irq(job.irq_ev);
    clear_irq(job.irq_ev);
    wait_ch_status(job.ch, dma330_pkg::ST_STOPPED);
    p_sequencer.sb.job_done(job);
  endtask

  protected task expect_waiting(int unsigned ch, int unsigned ev);
    uvm_reg_data_t v;
    wait_ch_status(ch, dma330_pkg::ST_WAIT_EVENT);
    reg_rd(rm.CSR[ch], v);
    if (v[8:4] != ev)
      `uvm_error("EVENT", $sformatf("ch%0d CSR.wakeup_number=%0d, expected %0d", ch, v[8:4], ev))
  endtask

  virtual task body();
    dma_job j0, j1, j2, j3;
    reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);     // events >= 4 stay events

    //-------------------------------------------------------------- part 1
    j0 = make_job(0, JOB_M2M);  j0.pre_wfe_ev  = EV_A;
    j1 = make_job(1, JOB_M2M);  j1.post_sev_ev = EV_A;
    prepare(j0);
    prepare(j1);
    start_channel(0, j0.prog_addr);
    expect_waiting(0, EV_A);
    vif.wait_clks(200);
    if (p_sequencer.sb.first_rd_time.exists(0))
      `uvm_error("EVENT", "ch0 read data while waiting for its event")
    start_channel(1, j1.prog_addr);
    fork
      finish(j0);
      finish(j1);
    join
    if (p_sequencer.sb.first_rd_time[0] <= p_sequencer.sb.last_wr_time[1])
      `uvm_error("EVENT", $sformatf("ch0 started at %0t before ch1 finished at %0t",
                                    p_sequencer.sb.first_rd_time[0], p_sequencer.sb.last_wr_time[1]))
    else
      `uvm_info("EVENT", "part 1: DMAWFE/DMASEV ordering OK", UVM_LOW)

    //-------------------------------------------------------------- part 2
    j2 = make_job(2, JOB_M2M);  j2.pre_wfe_ev = EV_B;
    j3 = make_job(3, JOB_M2M);  j3.pre_wfe_ev = EV_B;
    prepare(j2);
    prepare(j3);
    start_channel(2, j2.prog_addr);
    start_channel(3, j3.prog_addr);
    expect_waiting(2, EV_B);
    expect_waiting(3, EV_B);
    dbg_exec(1, 2, '{8'h34, 8'(EV_B << 3)});                 // debug DMASEV
    fork
      finish(j2);
      finish(j3);
    join
    `uvm_info("EVENT", "part 2: one event released two waiting channels", UVM_LOW)

    //-------------------------------------------------------------- part 3
    dbg_exec(1, 0, '{8'h34, 8'(EV_C << 3)});
    j0 = make_job(0, JOB_M2M);  j0.pre_wfe_ev = EV_C;  j0.wfe_invalidate = 1;
    prepare(j0);
    start_channel(0, j0.prog_addr);
    finish(j0);
    begin
      uvm_reg_data_t v;
      reg_rd(rm.INT_EVENT_RIS, v);
      if (v[EV_C]) `uvm_error("EVENT", "event flag not consumed by DMAWFE")
    end
    `uvm_info("EVENT", "part 3: pending event consumed by a later DMAWFE", UVM_LOW)

    //-------------------------------------------------------------- part 4
    // An event number configured as an interrupt does not release DMAWFE:
    // the flag raises irq[EV_D] instead. After INTCLR and switching the number
    // back to "event", a new DMASEV releases the waiting channel.
    j1 = make_job(1, JOB_M2M);  j1.pre_wfe_ev = EV_D;
    prepare(j1);
    reg_wr(rm.INTEN, ((1 << dma_tb_params_pkg::NUM_CH) - 1) | (1 << EV_D));
    start_channel(1, j1.prog_addr);
    expect_waiting(1, EV_D);
    dbg_exec(1, 1, '{8'h34, 8'(EV_D << 3)});
    wait_irq(EV_D);
    vif.wait_clks(100);
    expect_waiting(1, EV_D);                                 // still waiting
    clear_irq(EV_D);
    reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);
    dbg_exec(1, 1, '{8'h34, 8'(EV_D << 3)});
    finish(j1);
    `uvm_info("EVENT", "part 4: interrupt-mode event did not release DMAWFE", UVM_LOW)
  endtask

endclass : dma_event_vseq
