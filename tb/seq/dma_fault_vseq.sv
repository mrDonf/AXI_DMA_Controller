//==============================================================================
// dma_fault_vseq.sv - every channel / manager fault type, plus recovery
//------------------------------------------------------------------------------
// For each scenario: run a faulty program on the victim channel, wait for
// irq_abort, check FSRC/FTR/CSR/CPC, kill the channel, check that it is clean
// again. Meanwhile another channel keeps moving data (fault isolation). At the
// end the victim channel must still work.
//==============================================================================
class dma_fault_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_fault_vseq)

  int unsigned            victim;                     // chosen per seed: 1..NUM_CH-1
  localparam int unsigned BYSTANDER  = 0;
  localparam bit [31:0]   ERR_RD     = 32'hE000_0000;   // SLVERR on reads
  localparam bit [31:0]   ERR_WR     = 32'hE001_0000;   // DECERR on writes
  localparam bit [31:0]   ERR_FETCH  = 32'hE002_0000;   // SLVERR on instruction fetch
  // Instruction fetch errors that hit only part of what a thread fetches
  localparam bit [31:0]   STRADDLE   = 32'h0003_8000;   // error line after a good one
  localparam bit [31:0]   LAST_BEAT  = 32'h0003_9000;   // last beat of a line errors
  localparam bit [31:0]   FIRST_BEAT = 32'h0003_A000;   // first beat of a line errors

  function new(string name = "dma_fault_vseq");
    super.new(name);
  endfunction

  //----------------------------------------------------------------------------
  // Runs one faulty program and checks the reported fault
  //----------------------------------------------------------------------------
  protected task run_fault(string name, dma330_asm a, int unsigned exp_bit,
                           bit [31:0] start_pc = 0, bit check_cpc = 0,
                           bit [31:0] exp_far = 0);
    uvm_reg_data_t v;
    bit [31:0]     pc = dma_job::prog_base(victim) + 32'h4000;
    if (start_pc != 0) pc = start_pc;

    `uvm_info("FAULT", $sformatf("scenario %s:%s", name, a.sprint_listing()), UVM_LOW)
    p_sequencer.cfg.mem.write_bytes(pc, a.code);
    p_sequencer.sb.add_prog_region(pc, a.code.size());
    p_sequencer.cov.sample_program(a.code);
    p_sequencer.sb.ignore_channel(victim, 1);

    start_channel(victim, pc);
    wait_abort();
    wait_ch_status(victim, dma330_pkg::ST_FAULTING);

    reg_rd(rm.FSRC, v);
    if (!v[victim]) `uvm_error("FAULT", $sformatf("%s: FSRC=0x%0h, bit %0d expected", name, v, victim))
    reg_rd(rm.FTR[victim], v);
    if (!v[exp_bit])
      `uvm_error("FAULT", $sformatf("%s: FTR=0x%08h, bit %0d expected", name, v, exp_bit))
    else
      `uvm_info("FAULT", $sformatf("%s: FTR=0x%08h as expected", name, v), UVM_LOW)
    p_sequencer.cov.sample_fault(v, 0);

    // FAR: address of the first bus error (only for bus-error scenarios)
    if (exp_far != 0) begin
      reg_rd(rm.FAR[victim], v);
      if (v != exp_far) `uvm_error("FAULT", $sformatf("%s: FAR=0x%08h, expected 0x%08h", name, v, exp_far))
      else              `uvm_info("FAULT", $sformatf("%s: FAR=0x%08h as expected", name, v), UVM_LOW)
    end

    if (check_cpc) begin
      uvm_reg_data_t cpc;
      reg_rd(rm.CPC[victim], cpc);
      if (cpc != pc) `uvm_error("FAULT", $sformatf("%s: CPC=0x%08h, expected 0x%08h", name, cpc, pc))
    end

    kill_channel(victim);
    wait_ch_status(victim, dma330_pkg::ST_STOPPED);
    reg_rd(rm.FTR[victim], v);
    if (v != 0) `uvm_error("FAULT", $sformatf("%s: FTR not cleared by DMAKILL: 0x%08h", name, v))
    vif.wait_clks(10);
    if (vif.irq_abort !== 1'b0) `uvm_error("FAULT", $sformatf("%s: irq_abort still set", name))
    p_sequencer.sb.ignore_channel(victim, 0);
  endtask

  // Common program prologue
  protected function dma330_asm prologue(bit [31:0] sar, bit [31:0] dar, bit [31:0] ccr);
    dma330_asm a = dma330_asm::type_id::create("fault_prog");
    a.dmamov(RD_SAR, sar);
    a.dmamov(RD_DAR, dar);
    a.dmamov(RD_CCR, ccr);
    return a;
  endfunction

  //----------------------------------------------------------------------------
  virtual task pre_body();
    super.pre_body();
    victim = $urandom_range(dma_tb_params_pkg::NUM_CH - 1, 1);   // not the bystander
    `uvm_info("FAULT", $sformatf("victim channel %0d, bystander channel %0d", victim, BYSTANDER), UVM_LOW)
  endtask

  virtual task body();
    dma330_asm   a;
    bit [31:0]   src = dma_job::src_base(victim);
    bit [31:0]   dst = dma_job::dst_base(victim);
    bit [31:0]   ccr8x16 = dma330_asm::ccr(1, 3, 16, 1, 3, 16);
    uvm_reg_data_t v;
    bit           bystander_done = 0;

    p_sequencer.cfg.axi_cfg.add_err_region(ERR_RD,    ERR_RD + 32'hFFFF,    axi_pkg::AXI_SLVERR, 1, 0);
    p_sequencer.cfg.axi_cfg.add_err_region(ERR_WR,    ERR_WR + 32'hFFFF,    axi_pkg::AXI_DECERR, 0, 1);
    p_sequencer.cfg.axi_cfg.add_err_region(ERR_FETCH, ERR_FETCH + 32'hFFFF, axi_pkg::AXI_SLVERR, 1, 0);
    p_sequencer.sb.add_prog_region(ERR_FETCH, 64);
    p_sequencer.cfg.axi_cfg.add_err_region(STRADDLE,          STRADDLE + 32'hFF,   axi_pkg::AXI_SLVERR, 1, 0);
    p_sequencer.cfg.axi_cfg.add_err_region(LAST_BEAT + 32'h18, LAST_BEAT + 32'h1F, axi_pkg::AXI_SLVERR, 1, 0);
    p_sequencer.cfg.axi_cfg.add_err_region(FIRST_BEAT,        FIRST_BEAT + 32'h7,  axi_pkg::AXI_DECERR, 1, 0);
    reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);

    fork
      // Fault isolation: a healthy channel keeps working throughout
      begin
        repeat (6) run_job(make_job(BYSTANDER, JOB_M2M));
        bystander_done = 1;
      end
      begin
        a = dma330_asm::type_id::create("p");  a.raw(8'hFF);
        run_fault("undefined opcode", a, dma330_pkg::FTC_UNDEF_INSTR, 0, 1);

        a = dma330_asm::type_id::create("p");  a.dmago(1, 32'h1000);
        run_fault("DMAGO in a channel", a, dma330_pkg::FTC_UNDEF_INSTR);

        a = dma330_asm::type_id::create("p");
        a.raw(8'hBC); a.raw(8'h03); a.raw(0); a.raw(0); a.raw(0); a.raw(0);
        run_fault("DMAMOV bad register", a, dma330_pkg::FTC_OPERAND_INVALID);

        a = dma330_asm::type_id::create("p");  a.dmasev(20);
        run_fault("event number too large", a, dma330_pkg::FTC_CH_EVNT_ERR);

        a = dma330_asm::type_id::create("p");  a.dmawfp(7, WFP_BURST);
        run_fault("peripheral number too large", a, dma330_pkg::FTC_CH_PERIPH_ERR);

        a = prologue(src, dst, dma330_asm::ccr(1, 4, 1, 1, 3, 1));  a.dmald();
        run_fault("burst size wider than the bus", a, dma330_pkg::FTC_CH_RDWR_ERR);

        a = prologue(src, dst, dma330_asm::ccr(1, 3, 1, 1, 4, 1));  a.dmald(); a.dmast();
        run_fault("store burst size wider than the bus", a, dma330_pkg::FTC_CH_RDWR_ERR);

        a = prologue(src, dst, ccr8x16);  a.dmald(); a.dmald(); a.dmald();
        run_fault("loads overflow MFIFO", a, dma330_pkg::FTC_MFIFO_ERR);

        a = prologue(src, dst, ccr8x16);  a.dmast();
        run_fault("store without data", a, dma330_pkg::FTC_ST_DATA_UNAVAIL);

        a = prologue(ERR_RD, dst, ccr8x16);  a.dmald(); a.dmast(); a.dmawmb(); a.dmaend();
        run_fault("read SLVERR", a, dma330_pkg::FTC_DATA_READ_ERR, 0, 0, ERR_RD);

        a = prologue(src, ERR_WR, ccr8x16);  a.dmald(); a.dmast(); a.dmawmb(); a.dmaend();
        run_fault("write DECERR", a, dma330_pkg::FTC_DATA_WRITE_ERR, 0, 0, ERR_WR);

        a = dma330_asm::type_id::create("p");  a.dmanop();
        run_fault("instruction fetch error", a, dma330_pkg::FTC_INSTR_FETCH_ERR, ERR_FETCH, 0, ERR_FETCH);

        a = prologue(src, dst, ccr8x16);  a.dmaldp(COND_S, 9);
        run_fault("DMALDP peripheral number too large", a, dma330_pkg::FTC_CH_PERIPH_ERR);

        a = prologue(src, dst, ccr8x16);  a.dmald(); a.dmastp(COND_S, 9);
        run_fault("DMASTP peripheral number too large", a, dma330_pkg::FTC_CH_PERIPH_ERR);

        // A 6-byte DMAMOV starting 2 bytes before an erroring line: the first
        // line is fine, the fetch of the second line fails
        a = dma330_asm::type_id::create("p");  a.dmamov(RD_SAR, src);
        run_fault("instruction straddles into a bad line", a,
                  dma330_pkg::FTC_INSTR_FETCH_ERR, STRADDLE - 2);

        a = dma330_asm::type_id::create("p");  a.dmanop();
        run_fault("cache refill error on the last beat", a,
                  dma330_pkg::FTC_INSTR_FETCH_ERR, LAST_BEAT);

        a = dma330_asm::type_id::create("p");  a.dmanop();
        run_fault("cache refill error on the first beat", a,
                  dma330_pkg::FTC_INSTR_FETCH_ERR, FIRST_BEAT + 8);

        // AXI protocol protection: a burst that would cross a 4 KB boundary
        // faults the channel; nothing reaches the bus
        a = prologue(src + 32'hFF8, dst, ccr8x16);  a.dmald();
        run_fault("load burst crosses 4 KB", a, dma330_pkg::FTC_CH_RDWR_ERR);

        a = prologue(src, dst + 32'hFF0, ccr8x16);  a.dmald(); a.dmast();
        run_fault("store burst crosses 4 KB", a, dma330_pkg::FTC_CH_RDWR_ERR);

        // Endian swap: group larger than the destination beat, unaligned DAR
        a = prologue(src, dst, dma330_asm::ccr(1, 3, 2, 1, 2, 4, 0, 0, 0, 0, 3));
        a.dmald(); a.dmast();
        run_fault("endian swap wider than the beat", a, dma330_pkg::FTC_CH_RDWR_ERR);

        a = prologue(src, dst + 2, dma330_asm::ccr(1, 3, 2, 1, 3, 2, 0, 0, 0, 0, 2));
        a.dmald(); a.dmast();
        run_fault("endian swap with unaligned DAR", a, dma330_pkg::FTC_CH_RDWR_ERR);

        // Illegal debug instructions sent to a stopped channel
        debug_channel_fault("debug DMANOP to a channel", '{8'h18});
        debug_channel_fault("debug DMASEV with a bad event", '{8'h34, 8'(20 << 3)});

        // A debug instruction for a channel that does not exist is ignored
        dbg_exec(1, 6, '{8'h01});
        vif.wait_clks(50);
        if (vif.irq_abort !== 1'b0) `uvm_error("FAULT", "debug to a missing channel caused a fault")
        reg_rd(rm.FSRC, v);
        if (v != 0) `uvm_error("FAULT", $sformatf("debug to a missing channel: FSRC=0x%0h", v))

        // Manager faults through the debug interface
        manager_fault("DMAGO to a missing channel", '{8'hA0, 8'd7, 0, 0, 0, 0},
                      dma330_pkg::FTD_OPERAND_INVALID);
        manager_fault("DMAWFE is not a debug instruction", '{8'h36, 8'h00},
                      dma330_pkg::FTD_UNDEF_INSTR);
        manager_fault("event number too large", '{8'h34, 8'(31 << 3)},
                      dma330_pkg::FTD_MGR_EVNT_ERR);
      end
    join

    p_sequencer.cfg.axi_cfg.clear_err_regions();

    // Recovery: the victim channel works normally again
    repeat (2) run_job(make_job(victim, JOB_M2M));
    begin
      uvm_reg_data_t far;
      reg_rd(rm.FAR[victim], far);
      if (far != 0) `uvm_error("FAULT", $sformatf("FAR=0x%08h after an error-free job (cleared by DMAGO)", far))
    end
    `uvm_info("FAULT", "all fault scenarios handled, channel recovered", UVM_LOW)
  endtask

  // An illegal debug instruction faults the (stopped) victim channel
  protected task debug_channel_fault(string name, bit [7:0] insn[$]);
    uvm_reg_data_t v;
    p_sequencer.sb.ignore_channel(victim, 1);
    dbg_exec(1, victim, insn);
    wait_abort();
    reg_rd(rm.FTR[victim], v);
    if (!(v[dma330_pkg::FTC_DBG_INSTR] && v[dma330_pkg::FTC_UNDEF_INSTR]))
      `uvm_error("FAULT", $sformatf("%s: FTR=0x%08h", name, v))
    else
      `uvm_info("FAULT", $sformatf("%s: FTR=0x%08h as expected", name, v), UVM_LOW)
    p_sequencer.cov.sample_fault(v, 0);
    // A second illegal debug instruction to the already faulting channel
    // leaves it faulting
    dbg_exec(1, victim, insn);
    wait_ch_status(victim, dma330_pkg::ST_FAULTING);
    kill_channel(victim);
    wait_ch_status(victim, dma330_pkg::ST_STOPPED);
    p_sequencer.sb.ignore_channel(victim, 0);
  endtask

  // A faulting manager ignores every debug instruction except DMAKILL, so no
  // other thread may issue DMAGO until the manager has been killed again.
  protected task manager_fault(string name, bit [7:0] insn[$], int unsigned exp_bit);
    uvm_reg_data_t v;
    p_sequencer.dbg_lock.get();
    dbg_exec_locked(0, 0, insn);
    wait_abort();
    reg_rd(rm.FSRD, v);
    if (!v[0]) `uvm_error("FAULT", {name, ": FSRD not set"})
    reg_rd(rm.FTRD, v);
    if (!v[exp_bit] || !v[dma330_pkg::FTD_DBG_INSTR])
      `uvm_error("FAULT", $sformatf("%s: FTRD=0x%08h, bits %0d and 30 expected", name, v, exp_bit))
    else
      `uvm_info("FAULT", $sformatf("manager %s: FTRD=0x%08h as expected", name, v), UVM_LOW)
    p_sequencer.cov.sample_fault(v, 1);
    // Anything but DMAKILL is ignored while the manager is faulting
    dbg_exec_locked(0, 0, '{8'h18});                       // DMANOP
    reg_rd(rm.FSRD, v);
    if (!v[0]) `uvm_error("FAULT", {name, ": debug DMANOP cleared the manager fault"})
    dbg_exec_locked(0, 0, '{8'h01});                       // DMAKILL manager
    vif.wait_clks(10);
    reg_rd(rm.DSR, v);
    if (v[3:0] != dma330_pkg::ST_STOPPED) `uvm_error("FAULT", {name, ": manager not stopped after DMAKILL"})
    p_sequencer.dbg_lock.put();
  endtask

endclass : dma_fault_vseq
