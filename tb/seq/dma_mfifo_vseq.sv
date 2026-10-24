//==============================================================================
// dma_mfifo_vseq.sv - shared, dynamically allocated MFIFO
//------------------------------------------------------------------------------
//   1. One channel loads 7/8 of the whole pool before it stores (more than
//      three times what a channel had with a static per-channel split),
//      aligned and unaligned: the copy is correct, no fault.
//   2. Waiting for space: channel A holds 7/8 of the pool and waits for an
//      event; channel B's second load does not fit. B waits (no fault) until
//      A is released and drains, then both copies complete.
//   3. Deadlock: A holds 6/8 of the pool and waits for an event, B fills the
//      rest and waits for space. When A wakes up and loads again, no line can
//      ever be freed: both channels fault with mfifo_err, their lines return
//      to the pool and every channel works again. A third channel C, running,
//      whose stream was emptied at an odd byte offset, holds no line (it gave
//      its last one back): it also waits for space, is not part of the
//      deadlock, does not fault and completes once A and B are gone.
// The programs are hand-written; the scoreboard ignores the two channels and
// the copies are checked in the memory model.
//==============================================================================
class dma_mfifo_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_mfifo_vseq)

  localparam int unsigned BURST       = 128;                    // 16 x 8-byte beats
  localparam int unsigned POOL_BURSTS = dma_tb_params_pkg::MFIFO_BYTES / BURST;
  localparam int unsigned EV_GO       = 12;                     // event a holding channel waits for
  localparam int unsigned EV_C        = 13;                     // event channel C waits for

  int unsigned a_ch, b_ch, c_ch;
  bit [31:0]   ccr16;                                           // 16 x 8-byte beats, both sides

  function new(string name = "dma_mfifo_vseq");
    super.new(name);
  endfunction

  virtual task pre_body();
    super.pre_body();
    a_ch  = $urandom_range(dma_tb_params_pkg::NUM_CH - 1);
    b_ch  = (a_ch + 1 + $urandom_range(dma_tb_params_pkg::NUM_CH - 2)) % dma_tb_params_pkg::NUM_CH;
    c_ch  = 0;
    while (c_ch == a_ch || c_ch == b_ch) c_ch++;
    ccr16 = dma330_asm::ccr(1, 3, 16, 1, 3, 16);
    `uvm_info("MFIFO", $sformatf("pool %0d bytes (%0d bursts of %0d B), channels A=%0d B=%0d C=%0d",
                                 dma_tb_params_pkg::MFIFO_BYTES, POOL_BURSTS, BURST, a_ch, b_ch, c_ch), UVM_LOW)
  endtask

  //----------------------------------------------------------------------------
  // Helpers
  //----------------------------------------------------------------------------
  protected function bit [31:0] src_of(int unsigned ch); return dma_job::src_base(ch) + 32'h4000; endfunction
  protected function bit [31:0] dst_of(int unsigned ch); return dma_job::dst_base(ch) + 32'h4000; endfunction
  protected function bit [31:0] pc_of(int unsigned ch);  return dma_job::prog_base(ch) + 32'h4000; endfunction

  // Program prologue: SAR, DAR, CCR (3 x 6 bytes)
  protected function dma330_asm prologue(bit [31:0] sar, bit [31:0] dar);
    dma330_asm a = dma330_asm::type_id::create("mfifo_prog");
    a.dmamov(RD_SAR, sar);
    a.dmamov(RD_DAR, dar);
    a.dmamov(RD_CCR, ccr16);
    return a;
  endfunction

  // Hand-written program in memory; the scoreboard ignores the channel
  protected task load_prog(int unsigned ch, dma330_asm a);
    `uvm_info("MFIFO", $sformatf("ch%0d program:%s", ch, a.sprint_listing()), UVM_MEDIUM)
    p_sequencer.cfg.mem.write_bytes(pc_of(ch), a.code);
    p_sequencer.sb.add_prog_region(pc_of(ch), a.code.size());
    p_sequencer.cov.sample_program(a.code);
    p_sequencer.sb.ignore_channel(ch, 1);
  endtask

  protected task finish(int unsigned ch);
    uvm_reg_data_t v;
    wait_irq(ch);
    clear_irq(ch);
    wait_ch_status(ch, dma330_pkg::ST_STOPPED);
    reg_rd(rm.FTR[ch], v);
    if (v != 0) `uvm_error("MFIFO", $sformatf("ch%0d: FTR=0x%08h after a clean run", ch, v))
    p_sequencer.sb.ignore_channel(ch, 0);
  endtask

  // dst[0 .. n-1] must equal src[0 .. n-1]
  protected function void check_copy(string tag, bit [31:0] src, bit [31:0] dst, int unsigned n);
    for (int unsigned i = 0; i < n; i++) begin
      bit [7:0] s = p_sequencer.cfg.mem.read_byte(src + i);
      bit [7:0] d = p_sequencer.cfg.mem.read_byte(dst + i);
      if (s != d) begin
        `uvm_error("MFIFO", $sformatf("%s: byte %0d @0x%08h = 0x%02h, source 0x%02h", tag, i, dst + i, d, s))
        return;
      end
    end
    `uvm_info("MFIFO", $sformatf("%s: %0d bytes copied correctly", tag, n), UVM_LOW)
  endfunction

  // Waits until the channel has stopped advancing, then checks that it waits
  // at 'pc' without a fault
  protected task check_waiting(int unsigned ch, bit [31:0] pc, string tag);
    uvm_reg_data_t csr, cpc, fsrc;
    vif.wait_clks(3000);
    reg_rd(rm.CSR[ch], csr);
    reg_rd(rm.CPC[ch], cpc);
    reg_rd(rm.FSRC, fsrc);
    if (csr[3:0] != dma330_pkg::ST_EXECUTING || cpc != pc || fsrc != 0)
      `uvm_error("MFIFO", $sformatf("%s: ch%0d CSR=0x%08h CPC=0x%08h (0x%08h expected) FSRC=0x%0h",
                                    tag, ch, csr, cpc, pc, fsrc))
    else
      `uvm_info("MFIFO", $sformatf("%s: ch%0d waits for MFIFO space at 0x%08h", tag, ch, pc), UVM_LOW)
  endtask

  //----------------------------------------------------------------------------
  // 1. One channel uses most of the pool
  //----------------------------------------------------------------------------
  protected task big_copy(int unsigned ch, int unsigned soff, int unsigned doff);
    int unsigned n = POOL_BURSTS - 1;
    dma330_asm   a = prologue(src_of(ch) + soff, dst_of(ch) + doff);
    repeat (n) a.dmald();
    repeat (n) a.dmast();
    a.dmawmb();
    a.dmasev(ch);
    a.dmaend();
    load_prog(ch, a);
    start_channel(ch, pc_of(ch));
    finish(ch);
    // Unaligned INCR bursts: the first one is shorter by the start offset
    check_copy($sformatf("ch%0d %0d loads before the first store (+%0d/+%0d)", ch, n, soff, doff),
               src_of(ch) + soff, dst_of(ch) + doff, n * BURST - doff);
  endtask

  //----------------------------------------------------------------------------
  // 2. A load that does not fit waits for another channel to drain
  //----------------------------------------------------------------------------
  protected task wait_for_space();
    int unsigned n = POOL_BURSTS - 1;
    dma330_asm   a = prologue(src_of(a_ch), dst_of(a_ch));
    dma330_asm   b = prologue(src_of(b_ch), dst_of(b_ch));
    int unsigned lp;

    repeat (n) a.dmald();
    a.dmawfe(EV_GO);
    repeat (n) a.dmast();
    a.dmawmb();
    a.dmasev(a_ch);
    a.dmaend();

    lp = b.dmalp(0, 2);                       // 2 x (LD LD ST ST): 2 bursts in flight
    b.dmald(); b.dmald(); b.dmast(); b.dmast();
    b.dmalpend(0, lp);
    b.dmawmb();
    b.dmasev(b_ch);
    b.dmaend();

    load_prog(a_ch, a);
    load_prog(b_ch, b);
    start_channel(a_ch, pc_of(a_ch));
    wait_ch_status(a_ch, dma330_pkg::ST_WAIT_EVENT);
    start_channel(b_ch, pc_of(b_ch));
    // B's second load (prologue 18 + DMALP 2 + DMALD 1) does not fit
    check_waiting(b_ch, pc_of(b_ch) + 21, "wait for space");

    dbg_exec(1, a_ch, '{8'h34, 8'(EV_GO << 3)});          // debug DMASEV: A goes on
    fork
      finish(a_ch);
      finish(b_ch);
    join
    check_copy($sformatf("ch%0d (held the pool)", a_ch), src_of(a_ch), dst_of(a_ch), n * BURST);
    check_copy($sformatf("ch%0d (waited)", b_ch), src_of(b_ch), dst_of(b_ch), 4 * BURST);
  endtask

  //----------------------------------------------------------------------------
  // 3. Deadlock between two channels: both fault with mfifo_err
  //----------------------------------------------------------------------------
  protected task deadlock();
    int unsigned   na = POOL_BURSTS - 2;
    dma330_asm     a = prologue(src_of(a_ch), dst_of(a_ch));
    dma330_asm     b = prologue(src_of(b_ch), dst_of(b_ch));
    dma330_asm     c = prologue(src_of(c_ch) + 3, dst_of(c_ch) + 3);
    bit [31:0]     a_ld_pc, c_ld_pc;
    uvm_reg_data_t v;

    repeat (na) a.dmald();
    a.dmawfe(EV_GO);
    a_ld_pc = pc_of(a_ch) + a.pc();
    a.dmald();
    repeat (na + 1) a.dmast();
    a.dmaend();

    b.dmald(); b.dmald(); b.dmald();          // the third one does not fit
    repeat (3) b.dmast();
    b.dmaend();

    // C: 125 B copied and drained (stream empty at line offset 5), then a
    // wait, then one more burst
    c.dmald();
    c.dmast();
    c.dmawmb();
    c.dmawfe(EV_C);
    c_ld_pc = pc_of(c_ch) + c.pc();
    c.dmald();
    c.dmast();
    c.dmawmb();
    c.dmasev(c_ch);
    c.dmaend();

    load_prog(a_ch, a);
    load_prog(b_ch, b);
    load_prog(c_ch, c);
    start_channel(c_ch, pc_of(c_ch));
    wait_ch_status(c_ch, dma330_pkg::ST_WAIT_EVENT);
    start_channel(a_ch, pc_of(a_ch));
    wait_ch_status(a_ch, dma330_pkg::ST_WAIT_EVENT);
    start_channel(b_ch, pc_of(b_ch));
    // A only waits for an event, so B just waits for space
    check_waiting(b_ch, pc_of(b_ch) + 20, "before the deadlock");
    // C holds no line, so it only waits for space as well
    dbg_exec(1, c_ch, '{8'h34, 8'(EV_C << 3)});
    check_waiting(c_ch, c_ld_pc, "no line held");

    dbg_exec(1, a_ch, '{8'h34, 8'(EV_GO << 3)});
    wait_abort();
    wait_ch_status(a_ch, dma330_pkg::ST_FAULTING);
    wait_ch_status(b_ch, dma330_pkg::ST_FAULTING);
    for (int i = 0; i < 2; i++) begin
      int unsigned ch = (i == 0) ? a_ch : b_ch;
      bit [31:0]   pc = (i == 0) ? a_ld_pc : pc_of(b_ch) + 20;
      reg_rd(rm.FTR[ch], v);
      if (v != (1 << dma330_pkg::FTC_MFIFO_ERR))
        `uvm_error("MFIFO", $sformatf("deadlock: ch%0d FTR=0x%08h, mfifo_err only expected", ch, v))
      p_sequencer.cov.sample_fault(v, 0);
      reg_rd(rm.CPC[ch], v);
      if (v != pc) `uvm_error("MFIFO", $sformatf("deadlock: ch%0d CPC=0x%08h, expected 0x%08h", ch, v, pc))
    end
    reg_rd(rm.FSRC, v);
    if (v != ((1 << a_ch) | (1 << b_ch))) `uvm_error("MFIFO", $sformatf("deadlock: FSRC=0x%0h", v))
    `uvm_info("MFIFO", "deadlock detected: both channels faulted with mfifo_err", UVM_LOW)

    // C was not part of the deadlock: it completes on the freed lines
    finish(c_ch);
    check_copy($sformatf("ch%0d (waited during the deadlock)", c_ch),
               src_of(c_ch) + 3, dst_of(c_ch) + 3, 125 + BURST);

    kill_channel(a_ch);
    kill_channel(b_ch);
    wait_ch_status(a_ch, dma330_pkg::ST_STOPPED);
    wait_ch_status(b_ch, dma330_pkg::ST_STOPPED);
    vif.wait_clks(10);
    if (vif.irq_abort !== 1'b0) `uvm_error("MFIFO", "irq_abort still set after DMAKILL")
    p_sequencer.sb.ignore_channel(a_ch, 0);
    p_sequencer.sb.ignore_channel(b_ch, 0);
  endtask

  //----------------------------------------------------------------------------
  virtual task body();
    reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);

    big_copy(a_ch, 0, 0);
    big_copy(b_ch, 3, 5);
    wait_for_space();
    deadlock();

    // The pool is empty again: every channel works, and one channel alone can
    // again use most of it
    for (int ch = 0; ch < dma_tb_params_pkg::NUM_CH; ch++) begin
      automatic int c = ch;
      fork
        repeat (2) run_job(make_job(c, JOB_M2M));
      join_none
    end
    wait fork;
    big_copy(a_ch, 1, 6);
    `uvm_info("MFIFO", "shared MFIFO checks finished", UVM_LOW)
  endtask

endclass : dma_mfifo_vseq
