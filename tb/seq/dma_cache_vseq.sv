// Thread-local instruction-cache maintenance and CPU program replacement.
// Two channels execute different cached versions at the same physical PC.
// DMAWFE invalid must refresh the issuing thread; unrelated DMAGO/DMANOP
// must preserve the other thread's cached stream and program counter.
class dma_cache_vseq extends dma_base_vseq;
  `uvm_object_utils(dma_cache_vseq)
  localparam bit [31:0] PC = 32'h0006_0000;
  localparam int EV_START = 6, EV_PATCH = 7, EV_END = 8;
  localparam bit [31:0] OLD_SAR = 32'h1111_2222, NEW_SAR = 32'h3333_4444;
  localparam bit [31:0] NEW_DAR = 32'h5555_6666;
  function new(string name = "dma_cache_vseq"); super.new(name); endfunction

  protected function void program_version(bit [31:0] sar, bit [31:0] dar);
    dma330_asm a = dma330_asm::type_id::create("cache_program");
    a.dmawfe(EV_START);
    a.dmamov(RD_SAR, sar);
    a.dmawfe(EV_PATCH, 1);
    a.dmamov(RD_DAR, dar);
    a.dmawfe(EV_END);
    a.dmaend();
    p_sequencer.cfg.mem.write_bytes(PC, a.code);
    p_sequencer.sb.add_prog_region(PC, a.code.size());
    p_sequencer.cov.sample_program(a.code);
  endfunction
  protected task waiting(int ch, int ev);
    uvm_reg_data_t csr;
    for (int n = 0; n < 2000; n++) begin
      reg_rd(rm.CSR[ch], csr);
      if (csr[3:0] == dma330_pkg::ST_WAIT_EVENT && csr[8:4] == ev) return;
      vif.wait_clks(10);
    end
    `uvm_fatal("CACHE", $sformatf("ch%0d did not wait for event %0d: CSR=%h", ch, ev, csr))
  endtask
  protected task check_reg(uvm_reg r, bit [31:0] expected);
    uvm_reg_data_t actual;
    reg_rd(r, actual);
    if (actual != expected)
      `uvm_error("CACHE", $sformatf("%s=%08h expected %08h", r.get_name(), actual, expected))
  endtask
  protected task signal_event(int ev);
    dbg_exec(0, 0, '{8'h34, 8'(ev << 3)});
  endtask

  virtual task body();
    reg_wr(rm.INTEN, 0); // every event used here is an event, not an interrupt
    program_version(OLD_SAR, 32'hdead_beef);
    start_channel(0, PC);
    waiting(0, EV_START);
    program_version(NEW_SAR, 32'hdead_beef);
    // A running channel must ignore DMAGO, including cache side effects.
    start_channel(0, PC + 32'h1000);
    waiting(0, EV_START);
    // The same address must be fetched afresh for a different thread.
    start_channel(1, PC);
    waiting(1, EV_START);
    signal_event(EV_START);
    waiting(0, EV_PATCH); waiting(1, EV_PATCH);
    check_reg(rm.SAR[0], OLD_SAR);
    check_reg(rm.SAR[1], NEW_SAR);
    // Each DMAWFE invalid has discarded that thread's cached code. CPU
    // writes after the wait, then signals the event to resume execution.
    program_version(NEW_SAR, NEW_DAR);
    signal_event(EV_PATCH);
    waiting(0, EV_END); waiting(1, EV_END);
    check_reg(rm.DAR[0], NEW_DAR); check_reg(rm.DAR[1], NEW_DAR);
    kill_channel(0);
    wait_ch_status(0, dma330_pkg::ST_STOPPED);
    signal_event(EV_END);
    wait_ch_status(1, dma330_pkg::ST_STOPPED);
    // Both END and KILL leave their channel reusable with new code.
    begin
      dma330_asm a = dma330_asm::type_id::create("replacement");
      a.dmamov(RD_SAR, 32'h7777_8888); a.dmaend();
      p_sequencer.cfg.mem.write_bytes(PC, a.code);
      foreach (rm.CSR[ch]) begin
        if (ch > 1) break;
        start_channel(ch, PC);
        vif.wait_clks(100);
        wait_ch_status(ch, dma330_pkg::ST_STOPPED);
        check_reg(rm.SAR[ch], 32'h7777_8888);
        check_reg(rm.FTR[ch], 0);
      end
    end
    if (vif.irq_abort) `uvm_error("CACHE", "unexpected abort during program replacement")
    `uvm_info("CACHE", "thread isolation, DMAGO NOP, DMAWFE invalid and END/KILL reuse passed", UVM_LOW)
  endtask
endclass
