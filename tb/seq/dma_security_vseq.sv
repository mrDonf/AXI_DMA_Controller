//==============================================================================
// dma_security_vseq.sv - TrustZone security: two APB ports, CR3 / CR4
//------------------------------------------------------------------------------
// Boot configuration (set by dma_security_test before reset):
//   boot_irq_ns    = IRQ_NS     events 0..7 non-secure, 8..15 secure
//   boot_periph_ns = PERIPH_NS  peripherals 0, 1 non-secure, 2, 3 secure
//
// Phase 1, secure manager (boot_manager_ns = 0)
//   * CR3 / CR4 / CR0 read the boot configuration on both ports
//   * channel registers: a secure channel reads as zero on the NS port, a
//     non-secure one reads the same on both ports
//   * INTEN / INT_EVENT_RIS / INTMIS / INTCLR only see the NS events on the
//     NS port; WD is secure only
//   * each port has its own DBGINST0/1; both ports may be busy at once
//   * the NS port cannot drive secure threads: DMAGO through a secure manager,
//     DMAKILL / DMASEV to a secure channel are ignored
//   * a non-secure thread faults on a secure event (DMASEV, DMAWFE, debug
//     DMASEV: ch_evnt_err) and a secure peripheral (DMAWFP, DMAFLUSHP,
//     DMALDP, DMASTP: ch_periph_err); it may use NS events and peripherals;
//     a secure thread may use everything
//   * faults of secure threads are invisible on the NS port
// Phase 2, non-secure manager (reset with boot_manager_ns = 1)
//   * the NS port starts a non-secure channel and runs a whole job alone
//   * NS manager faults: DMAGO to a secure channel (dmago_err), DMASEV of a
//     secure event (mgr_evnt_err); both visible on and cleared from the NS port
//==============================================================================
class dma_security_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_security_vseq)

  localparam bit [15:0]   IRQ_NS     = 16'h00FF;
  localparam bit [3:0]    PERIPH_NS  = 4'b0011;
  localparam int unsigned NS_EV      = 3;
  localparam int unsigned SEC_EV     = 9;
  localparam int unsigned NS_PERIPH  = 1;
  localparam int unsigned SEC_PERIPH = 2;
  localparam int unsigned S_CH       = 0;               // secure channel
  localparam int unsigned N_CH       = 1;               // non-secure channel

  // Register offsets used outside the RAL
  localparam bit [11:0] A_DSR = 12'h000, A_DPC = 12'h004, A_INTEN = 12'h020, A_RIS = 12'h024,
                        A_INTMIS = 12'h028, A_INTCLR = 12'h02C, A_FSRD = 12'h030, A_FSRC = 12'h034,
                        A_FTRD = 12'h038, A_DBGSTATUS = 12'hD00, A_DBGINST0 = 12'hD08,
                        A_DBGINST1 = 12'hD0C, A_CR0 = 12'hE00, A_CR3 = 12'hE0C, A_CR4 = 12'hE10,
                        A_WD = 12'hE80;

  function new(string name = "dma_security_vseq");
    super.new(name);
  endfunction

  //----------------------------------------------------------------------------
  // Helpers
  //----------------------------------------------------------------------------
  protected function bit [11:0] a_ftr(int unsigned ch); return 12'h040 + 12'(4 * ch); endfunction
  protected function bit [11:0] a_csr(int unsigned ch); return 12'h100 + 12'(8 * ch); endfunction
  protected function bit [11:0] a_cpc(int unsigned ch); return 12'h104 + 12'(8 * ch); endfunction

  protected function void expect_eq(string what, bit [31:0] got, bit [31:0] exp);
    if (got != exp) `uvm_error("SEC", $sformatf("%s: 0x%08h, expected 0x%08h", what, got, exp))
  endfunction

  protected function bit [31:0] pc_of(int unsigned ch); return dma_job::prog_base(ch) + 32'h6000; endfunction

  protected task load_prog(int unsigned ch, dma330_asm a);
    p_sequencer.cfg.mem.write_bytes(pc_of(ch), a.code);
    p_sequencer.sb.add_prog_region(pc_of(ch), a.code.size());
    p_sequencer.cov.sample_program(a.code);
  endtask

  // Waits until channel 'ch' reaches 'status', reading CSR on the given port
  protected task wait_status_port(bit ns, int unsigned ch, bit [3:0] status);
    bit [31:0] v;
    for (int i = 0; i < 2000; i++) begin
      apb_rd(ns, a_csr(ch), v);
      if (v[3:0] == status) return;
      vif.wait_clks(20);
    end
    `uvm_error("SEC", $sformatf("ch%0d: status %0d not reached on the %s port (CSR=0x%08h)",
                                ch, status, ns ? "NS" : "S", v))
  endtask

  // Event 'ev' raised by a debug DMASEV to a stopped channel
  protected task dbg_sev(bit ns_port, int unsigned ch, int unsigned ev);
    if (ns_port) dbg_exec_ns(1, ch, '{8'h34, 8'(ev << 3)});
    else         dbg_exec(1, ch, '{8'h34, 8'(ev << 3)});
  endtask

  //----------------------------------------------------------------------------
  // Configuration registers on both ports
  //----------------------------------------------------------------------------
  protected task check_config(bit mgr_ns);
    bit [31:0] v;
    for (int p = 0; p < 2; p++) begin
      string port = p ? "NS" : "S";
      apb_rd(p, A_CR3, v);  expect_eq({port, " CR3"}, v, 32'(IRQ_NS));
      apb_rd(p, A_CR4, v);  expect_eq({port, " CR4"}, v, 32'(PERIPH_NS));
      apb_rd(p, A_CR0, v);  expect_eq({port, " CR0.mgr_ns_at_rst"}, v[2], mgr_ns);
    end
    apb_rd(0, A_DSR, v);
    expect_eq("S DSR.DNS", v[9], mgr_ns);
    apb_rd(1, A_DSR, v);
    expect_eq("NS DSR", v, mgr_ns ? 32'h200 : 32'h0);
  endtask

  //----------------------------------------------------------------------------
  // Channel registers: hidden for a secure channel, shared for a NS one
  //----------------------------------------------------------------------------
  protected task channel_view(int unsigned ch, bit ns);
    bit [11:0] regs [$] = '{a_ftr(ch), 12'h060 + 12'(4 * ch), a_csr(ch), a_cpc(ch)};
    bit [31:0] vs, vn;
    for (int k = 0; k < 5; k++) regs.push_back(12'h400 + 12'(32 * ch + 4 * k));
    foreach (regs[i]) begin
      apb_rd(0, regs[i], vs);
      apb_rd(1, regs[i], vn);
      expect_eq($sformatf("ch%0d (%s) reg 0x%03h on the NS port", ch, ns ? "NS" : "S", regs[i]),
                vn, ns ? vs : 32'h0);
    end
    apb_rd(0, a_cpc(ch), vs);
    if (vs == 0) `uvm_error("SEC", $sformatf("ch%0d: CPC is 0, the view check is weak", ch))
    apb_rd(0, a_csr(ch), vs);
    expect_eq($sformatf("ch%0d CSR.CNS", ch), vs[21], ns);
    `uvm_info("SEC", $sformatf("ch%0d (%s): register view on the NS port OK", ch, ns ? "NS" : "S"), UVM_LOW)
  endtask

  //----------------------------------------------------------------------------
  // Interrupt registers and WD
  //----------------------------------------------------------------------------
  protected task interrupt_view();
    bit [31:0] v;
    bit [15:0] both = (1 << SEC_EV) | (1 << NS_EV);

    // INTEN: the NS port changes only the NS bits
    reg_wr(rm.INTEN, 0);
    apb_wr(1, A_INTEN, 32'hFFFF);
    apb_rd(0, A_INTEN, v);  expect_eq("S INTEN after NS write 1s", v, 32'(IRQ_NS));
    reg_wr(rm.INTEN, 32'hFFFF);
    apb_wr(1, A_INTEN, 0);
    apb_rd(0, A_INTEN, v);  expect_eq("S INTEN after NS write 0s", v, {16'h0, ~IRQ_NS});
    apb_rd(1, A_INTEN, v);  expect_eq("NS INTEN", v, 0);

    // Raw / masked status and INTCLR
    reg_wr(rm.INTEN, both);
    dbg_sev(0, S_CH, SEC_EV);
    dbg_sev(0, S_CH, NS_EV);
    wait_irq(SEC_EV);
    wait_irq(NS_EV);
    apb_rd(0, A_RIS, v);     expect_eq("S INT_EVENT_RIS", v, both);
    apb_rd(1, A_RIS, v);     expect_eq("NS INT_EVENT_RIS", v, 1 << NS_EV);
    apb_rd(1, A_INTMIS, v);  expect_eq("NS INTMIS", v, 1 << NS_EV);
    apb_wr(1, A_INTCLR, 32'hFFFF);
    vif.wait_clks(5);
    if (vif.irq[NS_EV] !== 1'b0 || vif.irq[SEC_EV] !== 1'b1)
      `uvm_error("SEC", $sformatf("NS INTCLR of all bits: irq=0x%04h, only the NS one should clear", vif.irq))
    apb_rd(0, A_RIS, v);     expect_eq("S INT_EVENT_RIS after NS INTCLR", v, 1 << SEC_EV);
    clear_irq(SEC_EV);

    // WD is secure only
    reg_wr(rm.WD, 32'h0010_0001);
    apb_rd(1, A_WD, v);      expect_eq("NS WD", v, 0);
    apb_wr(1, A_WD, 0);
    apb_rd(0, A_WD, v);      expect_eq("S WD after an NS write", v, 32'h0010_0001);
    reg_wr(rm.WD, 0);
    reg_wr(rm.INTEN, 32'hFFFF);
    `uvm_info("SEC", "interrupt registers and WD: NS view and NS writes OK", UVM_LOW)
  endtask

  //----------------------------------------------------------------------------
  // Each port has its own debug instruction registers
  //----------------------------------------------------------------------------
  protected task debug_banks();
    bit [31:0] v;
    apb_wr(0, A_DBGINST0, 32'h1234_0001);
    apb_wr(0, A_DBGINST1, 32'hA5A5_A5A5);
    apb_wr(1, A_DBGINST0, 32'h5678_0300);
    apb_wr(1, A_DBGINST1, 32'h5A5A_5A5A);
    apb_rd(0, A_DBGINST0, v);  expect_eq("S DBGINST0", v, 32'h1234_0001);
    apb_rd(0, A_DBGINST1, v);  expect_eq("S DBGINST1", v, 32'hA5A5_A5A5);
    apb_rd(1, A_DBGINST0, v);  expect_eq("NS DBGINST0", v, 32'h5678_0300);
    apb_rd(1, A_DBGINST1, v);  expect_eq("NS DBGINST1", v, 32'h5A5A_5A5A);
  endtask

  // Both ports busy at the same time: accesses that meet in the same cycle are
  // serialized (the NS one waits), every write lands in its own bank and every
  // read returns its own port's data
  protected task concurrent_ports();
    int unsigned bad = 0;
    fork
      for (int i = 0; i < 64; i++) begin
        bit [31:0] v, w = 32'h5000_0000 | i;
        apb_wr(0, A_DBGINST1, w);
        apb_rd(0, A_DBGINST1, v);
        if (v != w) bad++;
      end
      for (int i = 0; i < 64; i++) begin
        bit [31:0] v, w = 32'hA000_0000 | i;
        apb_wr(1, A_DBGINST1, w);
        apb_rd(1, A_DBGINST1, v);
        if (v != w) bad++;
      end
    join
    if (bad != 0) `uvm_error("SEC", $sformatf("concurrent S / NS accesses: %0d reads returned the wrong data", bad))
    else          `uvm_info("SEC", "concurrent S / NS accesses OK", UVM_LOW)
  endtask

  // PSLVERR on the NS port follows APB_SLVERR as on the secure port: an
  // unmapped read and a write to a read-only register
  protected task ns_slverr();
    apb_pkg::apb_read_seq  rd = apb_pkg::apb_read_seq::type_id::create("ns_rd_unmapped");
    apb_pkg::apb_write_seq wr = apb_pkg::apb_write_seq::type_id::create("ns_wr_ro");
    bit                    en = p_sequencer.cfg.apb_slverr;
    bit [31:0]             v0, v1;

    rd.addr = 12'h200;
    rd.start(p_sequencer.apb_ns_sqr, this);
    if (rd.slverr != en || rd.data != 0)
      `uvm_error("SEC", $sformatf("NS read of an unmapped address: PSLVERR=%0b (expected %0b), data 0x%08h",
                                  rd.slverr, en, rd.data))
    apb_rd(1, A_CR0, v0);
    wr.addr = A_CR0;
    wr.data = ~v0;
    wr.start(p_sequencer.apb_ns_sqr, this);
    apb_rd(1, A_CR0, v1);
    if (wr.slverr != en || v1 != v0)
      `uvm_error("SEC", $sformatf("NS write to CR0: PSLVERR=%0b (expected %0b), CR0 0x%08h -> 0x%08h",
                                  wr.slverr, en, v0, v1))
  endtask

  //----------------------------------------------------------------------------
  // The NS port cannot drive secure threads
  //----------------------------------------------------------------------------
  protected task ns_debug_ignored();
    dma330_asm a = dma330_asm::type_id::create("p");
    dma_job    job;
    bit [31:0] v;

    // DMAGO through the secure manager: nothing starts
    a.dmasev(N_CH);
    a.dmaend();
    load_prog(N_CH, a);
    dbg_exec_ns(0, 0, '{8'hA2, 8'(N_CH), pc_of(N_CH)[7:0], pc_of(N_CH)[15:8],
                        pc_of(N_CH)[23:16], pc_of(N_CH)[31:24]});
    vif.wait_clks(300);
    apb_rd(0, A_DBGSTATUS, v);  expect_eq("DBGSTATUS after an NS debug to a secure manager", v, 0);
    apb_rd(0, a_csr(N_CH), v);  expect_eq("CSR after an NS DMAGO through a secure manager", v[3:0], 0);
    apb_rd(0, A_FSRD, v);       expect_eq("FSRD after an ignored NS DMAGO", v, 0);
    if (vif.irq[N_CH] !== 1'b0) `uvm_error("SEC", "NS DMAGO through a secure manager started a channel")

    // DMASEV to a secure channel: no event
    dbg_sev(1, S_CH, NS_EV);
    vif.wait_clks(20);
    if (vif.irq[NS_EV] !== 1'b0) `uvm_error("SEC", "NS debug DMASEV to a secure channel raised an event")

    // DMAKILL to a running secure channel: the job completes normally
    job = make_job(S_CH, JOB_M2M);
    job.ns     = 0;
    job.nbytes = 2048;
    fork
      run_job(job);
      begin
        // As soon as the channel runs
        for (int i = 0; i < 2000; i++) begin
          apb_rd(0, a_csr(S_CH), v);
          if (v[3:0] != dma330_pkg::ST_STOPPED) break;
        end
        dbg_exec_ns(1, S_CH, '{8'h01});
      end
    join
    `uvm_info("SEC", "NS debug instructions to secure threads are ignored", UVM_LOW)
  endtask

  //----------------------------------------------------------------------------
  // Non-secure thread faults, checked and cleared from the NS port
  //----------------------------------------------------------------------------
  protected task ns_thread_fault(string name, dma330_asm a, int unsigned exp_bit);
    bit [31:0] v;
    `uvm_info("SEC", $sformatf("NS thread: %s:%s", name, a.sprint_listing()), UVM_MEDIUM)
    load_prog(N_CH, a);
    p_sequencer.sb.ignore_channel(N_CH, 1);
    start_channel(N_CH, pc_of(N_CH), 1);
    wait_abort();
    wait_status_port(1, N_CH, dma330_pkg::ST_FAULTING);
    apb_rd(1, A_FSRC, v);
    expect_eq({name, ": NS FSRC"}, v, 1 << N_CH);
    apb_rd(1, a_ftr(N_CH), v);
    if (v != (1 << exp_bit))
      `uvm_error("SEC", $sformatf("%s: NS FTR=0x%08h, only bit %0d expected", name, v, exp_bit))
    p_sequencer.cov.sample_fault(v, 0);
    dbg_exec_ns(1, N_CH, '{8'h01});                         // NS DMAKILL of a NS channel
    wait_status_port(1, N_CH, dma330_pkg::ST_STOPPED);
    apb_rd(1, a_ftr(N_CH), v);  expect_eq({name, ": FTR after the NS DMAKILL"}, v, 0);
    p_sequencer.sb.ignore_channel(N_CH, 0);
  endtask

  protected function dma330_asm prologue();
    dma330_asm a = dma330_asm::type_id::create("p");
    a.dmamov(RD_SAR, dma_job::src_base(N_CH));
    a.dmamov(RD_DAR, dma_job::dst_base(N_CH));
    a.dmamov(RD_CCR, dma330_asm::ccr(1, 3, 2, 1, 3, 2));
    return a;
  endfunction

  protected task ns_thread_faults();
    dma330_asm a;
    bit [31:0] v;

    a = dma330_asm::type_id::create("p");  a.dmasev(SEC_EV);
    ns_thread_fault("DMASEV of a secure event", a, dma330_pkg::FTC_CH_EVNT_ERR);
    a = dma330_asm::type_id::create("p");  a.dmawfe(SEC_EV);
    ns_thread_fault("DMAWFE of a secure event", a, dma330_pkg::FTC_CH_EVNT_ERR);
    a = dma330_asm::type_id::create("p");  a.dmawfp(SEC_PERIPH, WFP_SINGLE);
    ns_thread_fault("DMAWFP of a secure peripheral", a, dma330_pkg::FTC_CH_PERIPH_ERR);
    a = dma330_asm::type_id::create("p");  a.dmaflushp(SEC_PERIPH);
    ns_thread_fault("DMAFLUSHP of a secure peripheral", a, dma330_pkg::FTC_CH_PERIPH_ERR);
    a = prologue();  a.dmaldp(COND_S, SEC_PERIPH);
    ns_thread_fault("DMALDPS of a secure peripheral", a, dma330_pkg::FTC_CH_PERIPH_ERR);
    a = prologue();  a.dmald();  a.dmastp(COND_S, SEC_PERIPH);
    ns_thread_fault("DMASTPS of a secure peripheral", a, dma330_pkg::FTC_CH_PERIPH_ERR);

    // Debug DMASEV of a secure event to a stopped NS channel
    p_sequencer.sb.ignore_channel(N_CH, 1);
    dbg_sev(1, N_CH, SEC_EV);
    wait_abort();
    apb_rd(1, a_ftr(N_CH), v);
    expect_eq("NS debug DMASEV of a secure event: FTR", v,
              (1 << dma330_pkg::FTC_CH_EVNT_ERR) | (1 << dma330_pkg::FTC_DBG_INSTR));
    dbg_exec_ns(1, N_CH, '{8'h01});
    wait_status_port(1, N_CH, dma330_pkg::ST_STOPPED);
    p_sequencer.sb.ignore_channel(N_CH, 0);

    // What a non-secure thread may use: NS events and peripherals
    a = dma330_asm::type_id::create("p");
    a.dmaflushp(NS_PERIPH);
    a.dmasev(NS_EV);
    a.dmaend();
    load_prog(N_CH, a);
    p_sequencer.sb.add_expected_ack(NS_PERIPH, dma_periph_pkg::PACK_FLUSH);
    start_channel(N_CH, pc_of(N_CH), 1);
    wait_irq(NS_EV);
    apb_wr(1, A_INTCLR, 1 << NS_EV);
    wait_status_port(1, N_CH, dma330_pkg::ST_STOPPED);
    apb_rd(1, a_ftr(N_CH), v);   expect_eq("NS thread with NS resources: FTR", v, 0);
    dbg_sev(1, N_CH, NS_EV);                              // NS debug DMASEV of a NS event
    wait_irq(NS_EV);
    apb_wr(1, A_INTCLR, 1 << NS_EV);

    // A secure thread may use secure and non-secure resources
    a = dma330_asm::type_id::create("p");
    a.dmaflushp(SEC_PERIPH);
    a.dmasev(SEC_EV);
    a.dmasev(NS_EV);
    a.dmaend();
    load_prog(S_CH, a);
    p_sequencer.sb.add_expected_ack(SEC_PERIPH, dma_periph_pkg::PACK_FLUSH);
    start_channel(S_CH, pc_of(S_CH), 0);
    wait_irq(SEC_EV);
    wait_irq(NS_EV);
    clear_irq(SEC_EV);
    clear_irq(NS_EV);
    wait_ch_status(S_CH, dma330_pkg::ST_STOPPED);
    apb_rd(0, a_ftr(S_CH), v);   expect_eq("secure thread with secure resources: FTR", v, 0);
    `uvm_info("SEC", "event / peripheral security of channel threads OK", UVM_LOW)
  endtask

  //----------------------------------------------------------------------------
  // Faults of secure threads are invisible on the NS port
  //----------------------------------------------------------------------------
  protected task secure_faults_hidden();
    dma330_asm a = dma330_asm::type_id::create("p");
    bit [31:0] v;

    a.dmasev(20);                                         // no such event
    load_prog(S_CH, a);
    p_sequencer.sb.ignore_channel(S_CH, 1);
    start_channel(S_CH, pc_of(S_CH), 0);
    wait_abort();
    wait_ch_status(S_CH, dma330_pkg::ST_FAULTING);
    apb_rd(0, A_FSRC, v);        expect_eq("S FSRC", v, 1 << S_CH);
    apb_rd(1, A_FSRC, v);        expect_eq("NS FSRC with a secure channel faulting", v, 0);
    apb_rd(1, a_ftr(S_CH), v);   expect_eq("NS FTR of a secure channel", v, 0);
    dbg_exec_ns(1, S_CH, '{8'h01});                       // ignored
    vif.wait_clks(50);
    apb_rd(0, a_csr(S_CH), v);   expect_eq("secure channel after an NS DMAKILL", v[3:0], dma330_pkg::ST_FAULTING);
    kill_channel(S_CH);
    wait_ch_status(S_CH, dma330_pkg::ST_STOPPED);
    p_sequencer.sb.ignore_channel(S_CH, 0);

    // Secure manager fault
    p_sequencer.dbg_lock.get();
    dbg_exec_locked(0, 0, '{8'hA0, 8'd7, 0, 0, 0, 0});     // DMAGO to a missing channel
    p_sequencer.dbg_lock.put();
    wait_abort();
    apb_rd(0, A_FSRD, v);        expect_eq("S FSRD", v, 1);
    apb_rd(1, A_FSRD, v);        expect_eq("NS FSRD of a secure manager", v, 0);
    apb_rd(1, A_FTRD, v);        expect_eq("NS FTRD of a secure manager", v, 0);
    apb_rd(1, A_DPC, v);         expect_eq("NS DPC of a secure manager", v, 0);
    dbg_exec_ns(0, 0, '{8'h01});                          // ignored
    vif.wait_clks(20);
    apb_rd(0, A_FSRD, v);        expect_eq("S FSRD after an NS DMAKILL", v, 1);
    kill_manager();
    vif.wait_clks(20);
    apb_rd(0, A_FSRD, v);        expect_eq("S FSRD after DMAKILL", v, 0);
    `uvm_info("SEC", "secure faults are hidden from the NS port", UVM_LOW)
  endtask

  //----------------------------------------------------------------------------
  // Phase 2: non-secure manager
  //----------------------------------------------------------------------------
  protected task ns_manager();
    dma_job    job = make_job(N_CH, JOB_M2M);
    bit [31:0] v;

    // A whole job driven from the NS port only
    job.ns = 1;
    load_job(job);
    p_sequencer.sb.add_job(job);
    apb_wr(1, A_INTEN, 1 << job.irq_ev);
    dbg_exec_ns(0, 0, '{8'hA2, 8'(N_CH), job.prog_addr[7:0], job.prog_addr[15:8],
                        job.prog_addr[23:16], job.prog_addr[31:24]});
    wait_irq(job.irq_ev);
    apb_wr(1, A_INTCLR, 1 << job.irq_ev);
    wait_status_port(1, N_CH, dma330_pkg::ST_STOPPED);
    check_arch_state(job);
    p_sequencer.sb.job_done(job);
    `uvm_info("SEC", "job started and completed from the NS port only", UVM_LOW)

    // NS manager faults, visible on and cleared from the NS port
    ns_manager_fault("DMAGO of a secure channel", '{8'hA0, 8'(S_CH), 0, 0, 1, 0},
                     dma330_pkg::FTD_DMAGO_ERR, 1);
    ns_manager_fault("DMASEV of a secure event", '{8'h34, 8'(SEC_EV << 3)},
                     dma330_pkg::FTD_MGR_EVNT_ERR, 1);
    ns_manager_fault("secure-port DMAGO of a secure channel", '{8'hA0, 8'(S_CH), 0, 0, 1, 0},
                     dma330_pkg::FTD_DMAGO_ERR, 0);

    // The NS manager may raise a NS event
    apb_wr(1, A_INTEN, 1 << NS_EV);
    dbg_exec_ns(0, 0, '{8'h34, 8'(NS_EV << 3)});
    wait_irq(NS_EV);
    apb_wr(1, A_INTCLR, 1 << NS_EV);
    apb_rd(1, A_FSRD, v);        expect_eq("NS manager DMASEV of a NS event: FSRD", v, 0);
    `uvm_info("SEC", "non-secure manager OK", UVM_LOW)
  endtask

  protected task ns_manager_fault(string name, bit [7:0] insn[$], int unsigned exp_bit, bit ns_port);
    bit [31:0] v;
    if (ns_port) dbg_exec_ns(0, 0, insn);
    else         dbg_exec(0, 0, insn);
    wait_abort();
    apb_rd(1, A_FSRD, v);        expect_eq({name, ": NS FSRD"}, v, 1);
    apb_rd(1, A_FTRD, v);
    if (!v[exp_bit] || !v[dma330_pkg::FTD_DBG_INSTR])
      `uvm_error("SEC", $sformatf("%s: NS FTRD=0x%08h, bits %0d and 30 expected", name, v, exp_bit))
    p_sequencer.cov.sample_fault(v, 1);
    dbg_exec_ns(0, 0, '{8'h01});                          // NS DMAKILL of the NS manager
    vif.wait_clks(20);
    apb_rd(1, A_FSRD, v);        expect_eq({name, ": NS FSRD after DMAKILL"}, v, 0);
  endtask

  //----------------------------------------------------------------------------
  virtual task body();
    dma_job job;

    reg_wr(rm.INTEN, 32'hFFFF);
    check_config(0);

    // A secure and a non-secure job, then the register view of both channels
    job = make_job(S_CH, JOB_M2M);  job.ns = 0;  run_job(job);
    job = make_job(N_CH, JOB_M2M);  job.ns = 1;  run_job(job);
    channel_view(S_CH, 0);
    channel_view(N_CH, 1);

    interrupt_view();
    debug_banks();
    concurrent_ports();
    ns_slverr();
    ns_debug_ignored();
    ns_thread_faults();
    secure_faults_hidden();

    // Phase 2: reset with a non-secure manager
    `uvm_info("SEC", "reset with boot_manager_ns = 1", UVM_LOW)
    vif.boot_manager_ns = 1'b1;
    vif.pulse_reset(20);
    rm.reset();
    vif.wait_clks(50);
    check_config(1);
    ns_manager();
  endtask

endclass : dma_security_vseq
