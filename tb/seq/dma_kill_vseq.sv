//==============================================================================
// dma_kill_vseq.sv - DMAKILL from the debug interface in every waiting state
//   1. during a long transfer under heavy AXI back-pressure
//      and while the first instruction fetch is still missing in the cache
//   2. while waiting for a peripheral request   (CSR = waiting for periph)
//   3. while waiting for an event               (CSR = waiting for event)
// After each kill the channel must be stopped, fault-free and reusable.
//==============================================================================
class dma_kill_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_kill_vseq)

  int unsigned CH;                     // chosen per seed

  function new(string name = "dma_kill_vseq");
    super.new(name);
  endfunction

  protected task kill_and_check(string what);
    uvm_reg_data_t v;
    p_sequencer.sb.ignore_channel(CH, 1);
    kill_channel(CH);
    wait_ch_status(CH, dma330_pkg::ST_STOPPED);
    reg_rd(rm.FTR[CH], v);
    if (v != 0) `uvm_error("KILL", $sformatf("%s: FTR=0x%08h after kill", what, v))
    p_sequencer.sb.ignore_channel(CH, 0);
    `uvm_info("KILL", {what, ": channel killed cleanly"}, UVM_LOW)
  endtask

  protected task start_custom(dma330_asm a);
    bit [31:0] pc = dma_job::prog_base(CH) + 32'h4000;
    p_sequencer.cfg.mem.write_bytes(pc, a.code);
    p_sequencer.sb.add_prog_region(pc, a.code.size());
    p_sequencer.cov.sample_program(a.code);
    start_channel(CH, pc);
  endtask

  virtual task pre_body();
    super.pre_body();
    CH = $urandom_range(dma_tb_params_pkg::NUM_CH - 1);
    `uvm_info("KILL", $sformatf("using channel %0d", CH), UVM_LOW)
  endtask

  virtual task body();
    dma_job    job;
    dma330_asm a;
    int unsigned p = CH % dma_tb_params_pkg::NUM_PERIPH;

    reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);

    // 1. Kill in the middle of a transfer
    p_sequencer.cfg.axi_cfg.set_slow();
    job = make_job(CH, JOB_M2M);
    job.nbytes = 4096;
    load_job(job);
    p_sequencer.sb.add_job(job);
    start_channel(CH, job.prog_addr);
    vif.wait_clks(1500);
    kill_and_check("mid-transfer");

    // 1b. Kill while the very first instruction fetch is still a cache miss
    //     (the fetch unit must drop the late i-cache response)
    job = make_job(CH, JOB_M2M);
    load_job(job);
    p_sequencer.sb.add_job(job);
    p_sequencer.cfg.axi_cfg.ar_ready_pct = 5;            // keep the refill pending
    start_channel(CH, job.prog_addr);
    begin
      bit [3:0] s;
      read_ch_status(CH, s);
      if (s != dma330_pkg::ST_CACHE_MISS)
        `uvm_info("KILL", $sformatf("status before kill = %0d (cache miss expected)", s), UVM_LOW)
    end
    kill_and_check("during instruction cache miss");
    p_sequencer.cfg.axi_cfg.set_default();

    // 2. Kill while waiting for a peripheral that never asks
    p_sequencer.sb.ignore_peripheral(p, 1);
    a = dma330_asm::type_id::create("wfp");
    a.dmaflushp(p);
    a.dmawfp(p, WFP_BURST);
    a.dmaend();
    start_custom(a);
    wait_ch_status(CH, dma330_pkg::ST_WAIT_PERIPH);
    kill_and_check("waiting for peripheral");
    vif.wait_clks(200);                 // let the flush handshake finish
    p_sequencer.sb.ignore_peripheral(p, 0);

    // 3. Kill while waiting for an event that never comes
    a = dma330_asm::type_id::create("wfe");
    a.dmawfe(15);
    a.dmaend();
    start_custom(a);
    wait_ch_status(CH, dma330_pkg::ST_WAIT_EVENT);
    kill_and_check("waiting for event");

    // DMAKILL to a channel that is already stopped is a no-op
    kill_channel(CH);
    vif.wait_clks(50);
    begin
      bit [3:0] st;
      read_ch_status(CH, st);
      if (st != dma330_pkg::ST_STOPPED || vif.irq_abort !== 1'b0)
        `uvm_error("KILL", "DMAKILL to a stopped channel changed its state")
    end

    // The channel is fully usable again
    repeat (3) run_job(make_job(CH, JOB_M2M));
  endtask

endclass : dma_kill_vseq
