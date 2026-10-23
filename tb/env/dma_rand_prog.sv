//==============================================================================
// dma_rand_prog.sv - random DMA-330 instruction streams (JOB_RAND)
//------------------------------------------------------------------------------
// dma_prog_gen turns a job's knobs into one of nine fixed program shapes.
// This generator instead composes a program out of random "segments", each an
// independent copy / zero-fill / reverse-copy kernel with its own burst shapes,
// alignment, FIXED or INCR addressing, endian swap, protection attributes and
// a random loop nest (DMALP LC0/LC1, DMAADDH row gaps, DMAADNH, barriers, NOPs,
// extra events). Some segments sit at the top of the 32-bit address space so
// SAR / DAR wrap around.
//
// Data balance (every DMAST finds its bytes, the MFIFO never overflows, no
// burst crosses 4 KB) is built into each kernel. The expected behaviour is NOT
// computed here: the C reference model (dma_cmodel) executes the finished
// program, and a program it does not run to a clean DMAEND / DMAKILL is
// thrown away and generated again. The scoreboard then uses the model's
// prediction.
//==============================================================================
class dma_rand_prog extends uvm_object;

  `uvm_object_utils(dma_rand_prog)

  //---------------------------------------------------------------- knobs
  int unsigned seg_min        = 1;
  int unsigned seg_max        = 4;
  int unsigned pct_fill       = 12;     // zero-fill kernel
  int unsigned pct_reverse    = 12;     // reverse-order copy (DMAADNH)
  int unsigned pct_fixed      = 15;     // FIXED instead of INCR, per side
  int unsigned pct_unaligned  = 30;
  int unsigned pct_swap       = 20;
  int unsigned pct_inner      = 70;     // inner loop (LC)
  int unsigned pct_outer      = 40;     // outer loop with row gaps
  int unsigned pct_interleave = 50;     // LD ST LD ST instead of LD LD ST ST
  int unsigned pct_extra      = 30;     // NOP / barrier / extra event between kernels
  int unsigned pct_top        = 25;     // kernel at the top of the address space (wrap-around)
  int unsigned top_ch         = 0;      // the only channel that uses it: the top pages are shared,
                                        // and one channel re-randomizing the source data would
                                        // change what another channel is reading
  int unsigned pct_kill_end   = 10;     // end the program with DMAKILL
  int unsigned max_tries      = 60;

  //---------------------------------------------------------------- results
  typedef struct {
    bit [31:0]   lo;
    int unsigned len;
  } region_t;

  region_t     src_regions [$];         // pages the program reads (filled with random data)
  int unsigned used_tries;

  protected bit top_used;

  function new(string name = "dma_rand_prog");
    super.new(name);
  endfunction

  //============================================================================
  // Entry point: program for 'job' written to memory, verified by the model
  //============================================================================
  function void build(dma_job job, dma_cmodel cm, axi_pkg::axi_mem_model mem);
    if (cm == null || !cm.available())
      `uvm_fatal("RANDPROG", "a random program needs the C reference model")

    for (int t = 1; t <= max_tries; t++) begin
      dma330_asm a = dma330_asm::type_id::create("rand_prog");
      src_regions.delete();
      top_used = 0;
      compose(job, a);

      job.prog = a;
      mem.write_bytes(job.prog_addr, a.code);
      foreach (src_regions[i]) mem.randomize_region(src_regions[i].lo, src_regions[i].len);
      job.cm_ref = cm.run(job, mem);
      used_tries = t;
      if (acceptable(job.cm_ref)) begin
        job.nbytes = 0;
        foreach (job.cm_ref.wr[i])
          foreach (job.cm_ref.wr[i].strb[b]) job.nbytes += $countones(job.cm_ref.wr[i].strb[b]);
        return;
      end
    end
    `uvm_fatal("RANDPROG", $sformatf("no acceptable program in %0d tries (last: %s)", max_tries,
                                     job.cm_ref.convert2string()))
  endfunction

  protected function bit acceptable(dma_cmodel_result r);
    return r.clean_end() && r.insns <= 3000 && r.insns >= 8 && (r.rd.size() + r.wr.size()) > 0;
  endfunction

  //============================================================================
  // Helpers
  //============================================================================
  protected function bit chance(int unsigned pct);
    return $urandom_range(99) < pct;
  endfunction

  protected function int unsigned rnd(int unsigned hi, int unsigned lo = 0);
    return $urandom_range(hi, lo);
  endfunction

  protected function int unsigned gcd(int unsigned a, int unsigned b);
    while (b != 0) begin
      int unsigned t = a % b;
      a = b;
      b = t;
    end
    return a;
  endfunction

  protected function void add_src_region(bit [31:0] page_base);
    region_t r;
    r.lo  = page_base;
    r.len = 4096;
    src_regions.push_back(r);
  endfunction

  //============================================================================
  // Program = random segments + epilogue
  //============================================================================
  protected function void compose(dma_job job, dma330_asm a);
    int unsigned nseg = rnd(seg_max, seg_min);
    for (int s = 0; s < nseg; s++) begin
      int unsigned pick = rnd(99);
      if (pick < pct_fill)                    fill_segment(job, a, s);
      else if (pick < pct_fill + pct_reverse) reverse_segment(job, a, s);
      else                                    copy_segment(job, a, s);
      if (chance(pct_extra)) extra(a);
    end
    a.dmawmb();                                       // data written before the interrupt
    if (chance(pct_extra)) a.dmasev(8 + rnd(7));      // event that nobody waits for
    a.dmasev(job.irq_ev);
    if (chance(pct_kill_end)) a.dmakill();
    else                      a.dmaend();
  endfunction

  protected function void extra(dma330_asm a);
    case (rnd(3))
      0: a.dmanop();
      1: a.dmarmb();
      2: a.dmawmb();
      default: a.dmasev(8 + rnd(7));
    endcase
  endfunction

  // Address of a page for segment s: normal windows of the channel, or the top
  // of the address space for the (single) wrap-around kernel
  protected function bit [31:0] src_page(dma_job job, int s, bit top);
    return top ? 32'hFFFF_F000 : dma_job::src_base(job.ch) + s * 32'h2000;
  endfunction

  protected function bit [31:0] dst_page(dma_job job, int s, bit top);
    return top ? 32'hFFFF_E000 : dma_job::dst_base(job.ch) + s * 32'h2000;
  endfunction

  //============================================================================
  // Copy kernel: kl loads and ks stores per iteration move the same bytes
  //============================================================================
  protected function void copy_segment(dma_job job, dma330_asm a, int s);
    int unsigned ss, ds, sbeats, dbeats, szs, szd, bs, bd, kl, ks, g;
    int unsigned off_s, off_d, swap, n0, n1, gap_s, gap_d, k_s, k_d, total_s, total_d;
    int unsigned s_off_in_page, d_off_in_page;
    bit          s_inc, d_inc, ok = 0, top;
    bit [31:0]   src_addr, dst_addr, sp, dp;
    int unsigned lc_out, lc_in, outer_pc, inner_pc;

    top = (job.ch == top_ch) && !top_used && chance(pct_top);

    for (int tr = 0; tr < 40 && !ok; tr++) begin
      ss     = rnd(3);  ds     = rnd(3);
      sbeats = rnd(16, 1);  dbeats = rnd(16, 1);
      s_inc  = !chance(pct_fixed);
      d_inc  = !chance(pct_fixed);
      szs    = 1 << ss;  szd = 1 << ds;
      off_s  = 0;  off_d = 0;  swap = 0;
      if (!top && chance(pct_unaligned)) begin
        off_d = rnd(szd - 1);
        if (s_inc && d_inc && chance(50)) off_s = rnd(off_d < szs - 1 ? off_d : szs - 1);
        else if (!s_inc && chance(50))    off_s = rnd(szs - 1);
      end
      if (chance(pct_swap) && ds >= 1) begin
        swap  = rnd(ds < 3 ? ds : 3, 1);               // group no larger than the beat
        off_d = (off_d >> swap) << swap;               // DAR aligned to the group
        if (s_inc && d_inc && off_s > off_d) off_s = off_d;
      end
      // Steady-state bytes of one burst (an unaligned INCR start only shortens the first)
      bs = s_inc ? sbeats * szs : sbeats * (szs - off_s);
      bd = d_inc ? dbeats * szd : dbeats * (szd - off_d);
      g  = gcd(bs, bd);
      kl = bd / g;
      ks = bs / g;
      ok = (kl <= 6) && (ks <= 6) && (kl * bs <= 240);
    end
    if (!ok) begin                                     // safe fallback: 4 x 8 B both sides
      ss = 3; ds = 3; sbeats = 4; dbeats = 4; szs = 8; szd = 8; s_inc = 1; d_inc = 1;
      off_s = 0; off_d = 0; swap = 0; bs = 32; bd = 32; kl = 1; ks = 1;
    end

    // Loop nest, kept inside one 4 KB page on every INCR side
    n0 = chance(pct_inner) ? rnd(6, 1) : 1;
    n1 = chance(pct_outer) ? rnd(4, 1) : 1;
    gap_s = (s_inc && n1 > 1 && !top && chance(50)) ? 8 * rnd(8) : 0;
    gap_d = (d_inc && n1 > 1 && !top && chance(50)) ? 8 * rnd(8) : 0;
    // Row step that also skips whole 4 KB pages (DMAADDH immediates up to 0xF040):
    // the page offset advances exactly as with the small gap alone
    k_s = (s_inc && n1 > 1 && !top && chance(40)) ? (chance(25) ? rnd(15, 8) : rnd(3, 1)) : 0;
    k_d = (d_inc && n1 > 1 && !top && chance(40)) ? (chance(25) ? rnd(15, 8) : rnd(3, 1)) : 0;
    forever begin
      total_s = n1 * (n0 * kl * bs + gap_s);
      total_d = n1 * (n0 * ks * bd + gap_d);
      if ((!s_inc || total_s <= 4080) && (!d_inc || total_d <= 4080)) break;
      if (n1 > 1) n1--;
      else if (n0 > 1) n0--;
      else break;
    end
    if (n1 == 1) begin
      gap_s = 0;  gap_d = 0;  k_s = 0;  k_d = 0;
    end

    sp = src_page(job, s, top);
    dp = dst_page(job, s, top);
    // Start offsets inside the page. At the top the kernel ends exactly at the
    // end of the page, so SAR / DAR wrap to 0.
    if (top) begin
      s_off_in_page = s_inc ? 4096 - total_s : 8 * rnd(200);
      d_off_in_page = d_inc ? 4096 - total_d : 8 * rnd(200);
      top_used      = 1;
    end else begin
      s_off_in_page = s_inc ? 16 * rnd((4096 - total_s) / 16) : 8 * rnd(200);
      d_off_in_page = d_inc ? 16 * rnd((4096 - total_d) / 16) : 8 * rnd(200);
    end
    src_addr = sp + s_off_in_page + off_s;
    dst_addr = dp + d_off_in_page + off_d;
    for (int r = 0; r < n1; r++) add_src_region(sp + r * k_s * 4096);

    a.dmamov(RD_SAR, src_addr);
    a.dmamov(RD_DAR, dst_addr);
    a.dmamov(RD_CCR, dma330_asm::ccr(s_inc, ss, sbeats, d_inc, ds, dbeats,
                                     rnd(7), rnd(7), rnd(7), rnd(7), swap));

    lc_out = rnd(1);
    lc_in  = (n1 > 1 && n0 > 1) ? 1 - lc_out : rnd(1);
    if (n1 > 1) outer_pc = a.dmalp(lc_out, n1);
    if (n0 > 1) inner_pc = a.dmalp(lc_in, n0);
    emit_body(a, kl, ks, bs, bd);
    if (n0 > 1) a.dmalpend(lc_in, inner_pc);
    if (n1 > 1) begin
      if (gap_s != 0 || k_s != 0) a.dmaaddh(0, 16'(gap_s + 4096 * k_s));
      if (gap_d != 0 || k_d != 0) a.dmaaddh(1, 16'(gap_d + 4096 * k_d));
      a.dmalpend(lc_out, outer_pc);
    end
  endfunction

  // kl loads and ks stores per iteration. Either all loads first, or each
  // store as soon as the data it needs has been loaded.
  protected function void emit_body(dma330_asm a, int unsigned kl, int unsigned ks,
                                    int unsigned bs, int unsigned bd);
    if (!chance(pct_interleave)) begin
      repeat (kl) a.dmald();
      if (chance(30)) a.dmarmb();
      repeat (ks) a.dmast();
    end else begin
      int unsigned li = 0, si = 0, loaded = 0, stored = 0;
      while (si < ks) begin
        int unsigned need = stored + bd;
        while (loaded < need && li < kl) begin
          a.dmald();
          loaded += bs;
          li++;
        end
        a.dmast();
        stored += bd;
        si++;
      end
      while (li < kl) begin
        a.dmald();
        li++;
      end
    end
  endfunction

  //============================================================================
  // Reverse copy: LD ; (RMB) ; ST ; DMAADNH SAR  walks the source backwards
  //============================================================================
  protected function void reverse_segment(dma_job job, dma330_asm a, int s);
    int unsigned ss = rnd(3), beats = rnd(16, 1), n = rnd(8, 2), bb, lc, body;
    bit [31:0]   sp = src_page(job, s, 0), dp = dst_page(job, s, 0);
    int unsigned s_off, d_off;

    bb    = beats << ss;
    s_off = 16 * rnd((4096 - n * bb) / 16);
    d_off = 16 * rnd((4096 - n * bb) / 16);
    add_src_region(sp);

    a.dmamov(RD_SAR, sp + s_off + (n - 1) * bb);
    a.dmamov(RD_DAR, dp + d_off);
    a.dmamov(RD_CCR, dma330_asm::ccr(1, ss, beats, 1, ss, beats, rnd(7), rnd(7), rnd(7), rnd(7), 0));
    lc   = rnd(1);
    body = a.dmalp(lc, n);
    a.dmald();
    if (chance(50)) a.dmarmb();
    a.dmast();
    a.dmaadnh(0, 16'(32'h1_0000 - 2 * bb));            // SAR += bb (load) - 2*bb = -bb per block
    a.dmalpend(lc, body);
  endfunction

  //============================================================================
  // Zero fill: DMASTZ bursts. The endian swap field is ignored by DMASTZ, so
  // any value (even an illegal one) is programmed.
  //============================================================================
  protected function void fill_segment(dma_job job, dma330_asm a, int s);
    int unsigned ds = rnd(3), beats = rnd(16, 1), szd, off_d, k = rnd(3, 1), n0, n1, bytes, total;
    int unsigned lc_out, lc_in, outer_pc = 0, inner_pc = 0, d_off;
    bit          d_inc = !chance(pct_fixed);
    bit [31:0]   dp = dst_page(job, s, 0);

    szd   = 1 << ds;
    off_d = chance(pct_unaligned) ? rnd(szd - 1) : 0;
    bytes = d_inc ? beats * szd : beats * (szd - off_d);
    n0    = chance(pct_inner) ? rnd(6, 1) : 1;
    n1    = chance(pct_outer) ? rnd(3, 1) : 1;
    forever begin
      total = n1 * n0 * k * bytes;
      if (!d_inc || total <= 4080) break;
      if (n1 > 1) n1--; else if (n0 > 1) n0--; else if (k > 1) k--; else break;
    end
    d_off = d_inc ? 16 * rnd((4096 - total) / 16) : 8 * rnd(200);

    a.dmamov(RD_DAR, dp + d_off + off_d);
    a.dmamov(RD_CCR, dma330_asm::ccr(1, 0, 1, d_inc, ds, beats, rnd(7), rnd(7), rnd(7), rnd(7), rnd(7)));
    lc_out = rnd(1);
    lc_in  = (n1 > 1 && n0 > 1) ? 1 - lc_out : rnd(1);
    if (n1 > 1) outer_pc = a.dmalp(lc_out, n1);
    if (n0 > 1) inner_pc = a.dmalp(lc_in, n0);
    repeat (k) a.dmastz();
    if (n0 > 1) a.dmalpend(lc_in, inner_pc);
    if (n1 > 1) a.dmalpend(lc_out, outer_pc);
  endfunction

endclass : dma_rand_prog
