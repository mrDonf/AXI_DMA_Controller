//==============================================================================
// dma_prog_gen.sv - turns a dma_job into a DMA-330 program + expected op list
//------------------------------------------------------------------------------
// The generator plays the role of a DMA driver (like the Linux pl330 driver):
//
//   1. split()      : cut the source and destination ranges into legal bursts
//                     (burst shape from the job, never across a 4 KB page,
//                      byte-sized bursts for leftovers)
//   2. interleave() : order loads and stores so a DMAST always has enough data
//                     already loaded (MFIFO can never under-run or lock up)
//   3. assemble     : DMAMOV SAR/DAR/CCR, the loads/stores (CCR re-written
//                     only when the burst shape changes), DMAWMB, DMASEV, DMAEND
//
// The op list is what the scoreboard's reference model consumes.
//==============================================================================
class dma_prog_gen extends uvm_object;

  `uvm_object_utils(dma_prog_gen)

  function new(string name = "dma_prog_gen");
    super.new(name);
  endfunction

  //============================================================================
  // Burst splitting
  //============================================================================
  static function void split(bit [31:0] addr, int unsigned nbytes, int unsigned size,
                             int unsigned max_beats, bit inc, dma_op_kind_e kind,
                             ref dma_op_t ops[$], input bit force_cross = 0);
    int unsigned remaining = nbytes;
    bit [31:0]   a         = addr;
    while (remaining > 0) begin
      dma_op_t     op;
      int unsigned szb  = 1 << size;
      int unsigned off  = a % szb;
      int unsigned k, bytes;
      op.kind = kind;
      op.inc  = inc;
      op.addr = a;
      if (inc) begin
        int unsigned page_room = 4096 - (a % 4096);
        // Half of the bursts may cross a 4 KB boundary: the DMA splits them
        // into two AXI bursts (TRM 2.10.5), the scoreboard expects both
        bit          cross_ok  = force_cross || $urandom_range(1);
        k = max_beats;
        if ((remaining + off) / szb < k) k = (remaining + off) / szb;
        if (!cross_ok && (page_room + off) / szb < k) k = (page_room + off) / szb;
        if (k >= 1) begin
          op.size = size;  op.len = k - 1;  bytes = k * szb - off;
        end else begin                                // byte-sized leftovers
          k = remaining;
          if (k > 16)        k = 16;
          if (k > page_room) k = page_room;
          op.size = 0;     op.len = k - 1;  bytes = k;
        end
        a += bytes;
      end else begin
        k = remaining / (szb - off);
        if (k > max_beats) k = max_beats;
        if (k >= 1) begin
          op.size = size;  op.len = k - 1;  bytes = k * (szb - off);
        end else begin
          k = (remaining > 16) ? 16 : remaining;
          op.size = 0;     op.len = k - 1;  bytes = k;
        end
      end
      ops.push_back(op);
      remaining -= bytes;
    end
  endfunction

  // Merge load and store lists: a store is emitted as soon as the data it
  // needs has been loaded.
  static function void interleave(ref dma_op_t lds[$], ref dma_op_t sts[$],
                                  ref dma_op_t ops[$]);
    int unsigned ld_cum = 0, st_cum = 0, li = 0;
    foreach (sts[si]) begin
      int unsigned need = st_cum + dma_job::op_bytes(sts[si]);
      while (ld_cum < need && li < lds.size()) begin
        ops.push_back(lds[li]);
        ld_cum += dma_job::op_bytes(lds[li]);
        li++;
      end
      ops.push_back(sts[si]);
      st_cum = need;
    end
    while (li < lds.size()) begin
      ops.push_back(lds[li]);
      li++;
    end
  endfunction

  //============================================================================
  // Program emission helpers
  //============================================================================
  // Emits LD/ST/STZ ops, re-writing CCR whenever a burst shape changes
  static function void emit_ops(dma_job job, dma330_asm a, ref dma_op_t ops[$]);
    int unsigned s_size = 99, s_len = 99, d_size = 99, d_len = 99;
    bit          s_inc = job.src_inc, d_inc = job.dst_inc;
    foreach (ops[i]) begin
      bit changed = 0;
      if (ops[i].kind == OP_LD) begin
        if (ops[i].size != s_size || ops[i].len != s_len || ops[i].inc != s_inc) changed = 1;
        s_size = ops[i].size; s_len = ops[i].len; s_inc = ops[i].inc;
      end else begin
        if (ops[i].size != d_size || ops[i].len != d_len || ops[i].inc != d_inc) changed = 1;
        d_size = ops[i].size; d_len = ops[i].len; d_inc = ops[i].inc;
      end
      if (changed) begin
        // Unused side keeps a harmless default shape
        a.dmamov(RD_CCR, dma330_asm::ccr(s_inc, (s_size == 99) ? 0 : s_size, (s_len == 99) ? 1 : s_len + 1,
                                         d_inc, (d_size == 99) ? 0 : d_size, (d_len == 99) ? 1 : d_len + 1,
                                         job.src_prot, job.src_cache, job.dst_prot, job.dst_cache, job.swap));
      end
      case (ops[i].kind)
        OP_LD:   a.dmald();
        OP_ST:   a.dmast();
        default: a.dmastz();
      endcase
    end
  endfunction

  static function void epilogue(dma_job job, dma330_asm a);
    a.dmawmb();                // all writes done before the interrupt
    if (job.post_sev_ev >= 0) a.dmasev(job.post_sev_ev);
    a.dmasev(job.irq_ev);
    a.dmaend();
  endfunction

  //============================================================================
  // Job builders
  //============================================================================
  static function void build(dma_job job);
    if (job.kind == JOB_RAND) return;           // program already written by dma_rand_prog
    // A non-secure thread must ask for non-secure accesses (AxPROT[1] = 1),
    // otherwise it faults with ch_rdwr_err (TRM 3.3.15)
    if (job.ns) begin
      job.src_prot[1] = 1'b1;
      job.dst_prot[1] = 1'b1;
    end
    job.ops.delete();
    job.exp_acks.delete();
    job.last_on_final = (job.kind inside {JOB_PERIPH_MIXED, JOB_P2M_MIXED});
    job.prog = dma330_asm::type_id::create("prog");
    if (job.pre_wfe_ev >= 0) job.prog.dmawfe(job.pre_wfe_ev, job.wfe_invalidate);
    case (job.kind)
      JOB_M2M:          build_m2m(job);
      JOB_FILL:         build_fill(job);
      JOB_LOOP2D:       build_loop2d(job);
      JOB_M2P:          build_m2p(job);
      JOB_P2M:          build_p2m(job);
      JOB_PERIPH_MIXED: build_periph_mixed(job);
      JOB_P2M_MIXED:    build_p2m_mixed(job);
      JOB_COND_LOOP:    build_cond_loop(job);
      JOB_ISA_MIX:      build_isa_mix(job);
      default: ;
    endcase
  endfunction

  // Memory to memory copy of any length / alignment
  static function void build_m2m(dma_job job);
    dma_op_t lds[$], sts[$];
    split(job.src, job.nbytes, job.src_size, job.src_beats, job.src_inc, OP_LD, lds, job.cross_4k);
    split(job.dst, job.nbytes, job.dst_size, job.dst_beats, job.dst_inc, OP_ST, sts, job.cross_4k);
    interleave(lds, sts, job.ops);
    job.prog.dmamov(RD_SAR, job.src);
    job.prog.dmamov(RD_DAR, job.dst);
    emit_ops(job, job.prog, job.ops);
    epilogue(job, job.prog);
  endfunction

  // Zero fill with DMASTZ
  static function void build_fill(dma_job job);
    split(job.dst, job.nbytes, job.dst_size, job.dst_beats, job.dst_inc, OP_STZ, job.ops, job.cross_4k);
    job.prog.dmamov(RD_DAR, job.dst);
    emit_ops(job, job.prog, job.ops);
    epilogue(job, job.prog);
  endfunction

  // 2D block copy:
  //   for r in rows: for b in row_bursts: LD; ST
  //   SAR += src_gap, DAR += dst_gap  (or DAR moves back a row: DMAADNH)
  // Source/destination use the same aligned burst shape.
  static function void build_loop2d(dma_job job);
    int unsigned szb      = 1 << job.src_size;
    int unsigned bb       = szb * job.src_beats;            // bytes per burst
    int unsigned row      = bb * job.row_bursts;
    int unsigned s_stride = row + job.src_gap;
    int unsigned d_stride = row + job.dst_gap;
    bit [31:0]   s_a, d_a;
    int unsigned outer, inner;

    job.dst_size  = job.src_size;
    job.dst_beats = job.src_beats;
    job.src_inc   = 1;
    job.dst_inc   = 1;
    job.src       = job.src & ~32'hFFF;                     // keep bursts in one page
    job.dst       = job.dst & ~32'hFFF;
    // Whole 2D block inside one 4 KB page (AXI bursts must not cross it)
    while (job.rows > 1 && ((job.rows - 1) * s_stride + row > 4096 ||
                            (job.rows - 1) * d_stride + row > 4096))
      job.rows--;
    if (job.dst_reverse) job.dst += (job.rows - 1) * d_stride;
    job.nbytes    = row * job.rows;

    // Expected op list (loops unrolled)
    s_a = job.src;
    d_a = job.dst;
    for (int r = 0; r < job.rows; r++) begin
      for (int b = 0; b < job.row_bursts; b++) begin
        job.ops.push_back('{kind: OP_LD, addr: s_a + b*bb, len: job.src_beats - 1, size: job.src_size, inc: 1});
        job.ops.push_back('{kind: OP_ST, addr: d_a + b*bb, len: job.dst_beats - 1, size: job.dst_size, inc: 1});
      end
      s_a += s_stride;
      d_a  = job.dst_reverse ? d_a - d_stride : d_a + d_stride;
    end

    job.prog.dmamov(RD_SAR, job.src);
    job.prog.dmamov(RD_DAR, job.dst);
    job.prog.dmamov(RD_CCR, dma330_asm::ccr(1, job.src_size, job.src_beats, 1, job.dst_size, job.dst_beats,
                                            job.src_prot, job.src_cache, job.dst_prot, job.dst_cache, job.swap));
    outer = job.prog.dmalp(1, job.rows);
      inner = job.prog.dmalp(0, job.row_bursts);
        job.prog.dmald();
        job.prog.dmast();
      job.prog.dmalpend(0, inner);
      if (job.src_gap > 0) job.prog.dmaaddh(0, job.src_gap);
      if (job.dst_reverse)
        job.prog.dmaadnh(1, 16'(32'h1_0000 - (row + d_stride)));   // DAR -= row + stride
      else if (job.dst_gap > 0)
        job.prog.dmaaddh(1, job.dst_gap);
    job.prog.dmalpend(1, outer);
    epilogue(job, job.prog);
  endfunction

  // Memory -> peripheral FIFO: one burst per peripheral burst request
  static function void build_m2p(dma_job job);
    int unsigned body;
    job.src_inc = 1;  job.dst_inc = 0;
    job.dst_size = job.src_size;  job.dst_beats = job.src_beats;
    job.src = job.src & ~32'hFFF;          // num_req * burst <= 12 * 128 B: one page
    job.dst = dma_job::fifo_addr(job.periph);
    job.exp_acks.push_back(dma_periph_pkg::PACK_FLUSH);
    job.req_types.delete();
    for (int i = 0; i < job.num_req; i++) begin
      split_one(job, OP_LD, job.src + i * (job.src_beats << job.src_size), 1);
      split_one(job, OP_ST, job.dst, 0);
      job.req_types.push_back(dma_periph_pkg::PREQ_BURST);
      job.exp_acks.push_back(dma_periph_pkg::PACK_BURST);
    end
    job.nbytes = job.num_req * (job.src_beats << job.src_size);

    job.prog.dmamov(RD_SAR, job.src);
    job.prog.dmamov(RD_DAR, job.dst);
    job.prog.dmamov(RD_CCR, dma330_asm::ccr(1, job.src_size, job.src_beats, 0, job.dst_size, job.dst_beats,
                                            job.src_prot, job.src_cache, job.dst_prot, job.dst_cache, job.swap));
    job.prog.dmaflushp(job.periph);
    body = job.prog.dmalp(0, job.num_req);
      job.prog.dmawfp(job.periph, WFP_BURST);
      job.prog.dmald();
      job.prog.dmastp(COND_B, job.periph);
    job.prog.dmalpend(0, body);
    epilogue(job, job.prog);
  endfunction

  // Peripheral FIFO -> memory: acknowledge when the read burst completes
  static function void build_p2m(dma_job job);
    int unsigned body;
    job.src_inc = 0;  job.dst_inc = 1;
    job.dst_size = job.src_size;  job.dst_beats = job.src_beats;
    job.src = dma_job::fifo_addr(job.periph);
    job.dst = job.dst & ~32'hFFF;
    job.exp_acks.push_back(dma_periph_pkg::PACK_FLUSH);
    job.req_types.delete();
    for (int i = 0; i < job.num_req; i++) begin
      split_one(job, OP_LD, job.src, 0);
      split_one(job, OP_ST, job.dst + i * (job.dst_beats << job.dst_size), 1);
      job.req_types.push_back(dma_periph_pkg::PREQ_BURST);
      job.exp_acks.push_back(dma_periph_pkg::PACK_BURST);
    end
    job.nbytes = job.num_req * (job.src_beats << job.src_size);

    job.prog.dmamov(RD_SAR, job.src);
    job.prog.dmamov(RD_DAR, job.dst);
    job.prog.dmamov(RD_CCR, dma330_asm::ccr(0, job.src_size, job.src_beats, 1, job.dst_size, job.dst_beats,
                                            job.src_prot, job.src_cache, job.dst_prot, job.dst_cache, job.swap));
    job.prog.dmaflushp(job.periph);
    body = job.prog.dmalp(0, job.num_req);
      job.prog.dmawfp(job.periph, WFP_BURST);
      job.prog.dmaldp(COND_B, job.periph);
      job.prog.dmast();
    job.prog.dmalpend(0, body);
    epilogue(job, job.prog);
  endfunction

  // Peripheral-paced loop until the peripheral flags its last request:
  //   loop: DMAWFP P ; DMALDS ; DMALDB ; DMASTPS ; DMASTPB ; DMALPFE
  // Exactly one of each S/B pair executes per request: a burst request moves
  // one CCR burst, a single request one beat (S forms: AxLEN = 0).
  static function void build_periph_mixed(dma_job job);
    int unsigned body;
    int unsigned bb, moved = 0;
    job.src_inc = 1;  job.dst_inc = 0;
    job.dst_size = job.src_size;  job.dst_beats = job.src_beats;
    job.src = job.src & ~32'hFFF;
    job.dst = dma_job::fifo_addr(job.periph);
    bb = job.src_beats << job.src_size;
    job.exp_acks.push_back(dma_periph_pkg::PACK_FLUSH);
    job.req_types.delete();
    for (int i = 0; i < job.num_req; i++) begin
      dma_periph_pkg::periph_req_e t = ($urandom_range(1) == 1) ? dma_periph_pkg::PREQ_BURST
                                                               : dma_periph_pkg::PREQ_SINGLE;
      bit single = (t == dma_periph_pkg::PREQ_SINGLE);
      job.req_types.push_back(t);
      split_one(job, OP_LD, job.src + moved, 1, single);
      split_one(job, OP_ST, job.dst, 0, single);
      moved += single ? (1 << job.src_size) : bb;
      job.exp_acks.push_back(t == dma_periph_pkg::PREQ_BURST ? dma_periph_pkg::PACK_BURST
                                                             : dma_periph_pkg::PACK_SINGLE);
    end
    job.nbytes = moved;

    job.prog.dmamov(RD_SAR, job.src);
    job.prog.dmamov(RD_DAR, job.dst);
    job.prog.dmamov(RD_CCR, dma330_asm::ccr(1, job.src_size, job.src_beats, 0, job.dst_size, job.dst_beats,
                                            job.src_prot, job.src_cache, job.dst_prot, job.dst_cache, job.swap));
    job.prog.dmaflushp(job.periph);
    body = job.prog.pc();
      job.prog.dmawfp(job.periph, WFP_PERIPH);
      job.prog.dmald(COND_S);
      job.prog.dmald(COND_B);
      job.prog.dmastp(COND_S, job.periph);
      job.prog.dmastp(COND_B, job.periph);
    job.prog.dmalpend(0, body, COND_ALWAYS, 1);
    epilogue(job, job.prog);
  endfunction

  // Peripheral FIFO -> memory, peripheral-paced until drlast:
  //   loop: DMAWFP P ; DMALDPS ; DMALDPB ; DMASTS ; DMASTB ; DMALPFE
  // Read-side acknowledges of both types (single on R for DMALDPS).
  static function void build_p2m_mixed(dma_job job);
    int unsigned body;
    int unsigned bb, moved = 0;
    job.src_inc = 0;  job.dst_inc = 1;
    job.dst_size = job.src_size;  job.dst_beats = job.src_beats;
    job.src = dma_job::fifo_addr(job.periph);
    job.dst = job.dst & ~32'hFFF;
    bb = job.src_beats << job.src_size;
    job.exp_acks.push_back(dma_periph_pkg::PACK_FLUSH);
    job.req_types.delete();
    for (int i = 0; i < job.num_req; i++) begin
      dma_periph_pkg::periph_req_e t = ($urandom_range(1) == 1) ? dma_periph_pkg::PREQ_BURST
                                                               : dma_periph_pkg::PREQ_SINGLE;
      bit single = (t == dma_periph_pkg::PREQ_SINGLE);
      job.req_types.push_back(t);
      split_one(job, OP_LD, job.src, 0, single);
      split_one(job, OP_ST, job.dst + moved, 1, single);
      moved += single ? (1 << job.dst_size) : bb;
      job.exp_acks.push_back(t == dma_periph_pkg::PREQ_BURST ? dma_periph_pkg::PACK_BURST
                                                             : dma_periph_pkg::PACK_SINGLE);
    end
    job.nbytes = moved;

    job.prog.dmamov(RD_SAR, job.src);
    job.prog.dmamov(RD_DAR, job.dst);
    job.prog.dmamov(RD_CCR, dma330_asm::ccr(0, job.src_size, job.src_beats, 1, job.dst_size, job.dst_beats,
                                            job.src_prot, job.src_cache, job.dst_prot, job.dst_cache, job.swap));
    job.prog.dmaflushp(job.periph);
    body = job.prog.pc();
      job.prog.dmawfp(job.periph, WFP_PERIPH);
      job.prog.dmaldp(COND_S, job.periph);
      job.prog.dmaldp(COND_B, job.periph);
      job.prog.dmast(COND_S);
      job.prog.dmast(COND_B);
    job.prog.dmalpend(1, body, COND_ALWAYS, 1);         // DMALPFE, LC1 encoding
    epilogue(job, job.prog);
  endfunction

  // Conditional loop ends. The peripheral sends three single requests; each
  // pass moves one beat (S forms):
  //   DMALP LC1,2 { DMAWFP S ; LDS ; STPS } DMALPENDS LC1  -> condition true: 2 passes
  //   DMALP LC0,4 { DMAWFP S ; LDS ; STPS } DMALPENDB LC0  -> condition false: exits
  //                                                           after the 1st pass
  static function void build_cond_loop(dma_job job);
    int unsigned body;
    int unsigned bb;
    job.src_inc = 1;  job.dst_inc = 1;
    job.dst_size = job.src_size;  job.dst_beats = job.src_beats;
    job.src = job.src & ~32'hFFF;
    job.dst = job.dst & ~32'hFFF;
    bb = 1 << job.src_size;                               // one beat per request
    job.exp_acks.push_back(dma_periph_pkg::PACK_FLUSH);
    job.req_types.delete();
    for (int i = 0; i < 3; i++) begin
      job.req_types.push_back(dma_periph_pkg::PREQ_SINGLE);
      split_one(job, OP_LD, job.src + i * bb, 1, 1);
      split_one(job, OP_ST, job.dst + i * bb, 1, 1);
      job.exp_acks.push_back(dma_periph_pkg::PACK_SINGLE);
    end
    job.nbytes = 3 * bb;

    job.prog.dmamov(RD_SAR, job.src);
    job.prog.dmamov(RD_DAR, job.dst);
    job.prog.dmamov(RD_CCR, dma330_asm::ccr(1, job.src_size, job.src_beats, 1, job.dst_size, job.dst_beats,
                                            job.src_prot, job.src_cache, job.dst_prot, job.dst_cache, job.swap));
    job.prog.dmaflushp(job.periph);
    body = job.prog.dmalp(1, 2);
      job.prog.dmawfp(job.periph, WFP_SINGLE);
      job.prog.dmald(COND_S);
      job.prog.dmastp(COND_S, job.periph);
    job.prog.dmalpend(1, body, COND_S);
    body = job.prog.dmalp(0, 4);
      job.prog.dmawfp(job.periph, WFP_SINGLE);
      job.prog.dmald(COND_S);
      job.prog.dmastp(COND_S, job.periph);
    job.prog.dmalpend(0, body, COND_B);
    epilogue(job, job.prog);
  endfunction

  // Copies blocks in reverse source order using the less common instructions:
  //   DMANOP ; loop { DMALD ; DMARMB ; DMAST ; DMAADNH SAR,-2*burst } ;
  //   DMAWMB ; DMASEV ; DMAKILL      (DMAKILL ends the program instead of DMAEND)
  static function void build_isa_mix(dma_job job);
    int unsigned body;
    int unsigned bb;
    int unsigned n;
    job.src_inc = 1;  job.dst_inc = 1;
    job.dst_size = job.src_size;  job.dst_beats = job.src_beats;
    job.src = job.src & ~32'hFFF;
    job.dst = job.dst & ~32'hFFF;
    bb = job.src_beats << job.src_size;
    n  = (job.num_req > 8) ? 8 : job.num_req;            // 8 x 128 B max: one page
    for (int i = 0; i < n; i++) begin
      split_one(job, OP_LD, job.src + (n - 1 - i) * bb, 1);
      split_one(job, OP_ST, job.dst + i * bb, 1);
    end
    job.nbytes = n * bb;

    job.prog.dmanop();
    job.prog.dmamov(RD_SAR, job.src + (n - 1) * bb);
    job.prog.dmamov(RD_DAR, job.dst);
    job.prog.dmamov(RD_CCR, dma330_asm::ccr(1, job.src_size, job.src_beats, 1, job.dst_size, job.dst_beats,
                                            job.src_prot, job.src_cache, job.dst_prot, job.dst_cache, job.swap));
    body = job.prog.dmalp(0, n);
      job.prog.dmald();
      job.prog.dmarmb();                                  // read must be complete
      job.prog.dmast();
      job.prog.dmaadnh(0, 16'(32'h1_0000 - 2 * bb));       // SAR -= 2 bursts
    job.prog.dmalpend(0, body);
    job.prog.dmawmb();
    job.prog.dmasev(job.irq_ev);
    job.prog.dmakill();
  endfunction

  // One op with the job's burst shape
  // One CCR burst, or one beat for an S-form instruction (AxLEN = 0)
  static function void split_one(dma_job job, dma_op_kind_e kind, bit [31:0] addr, bit inc,
                                 bit single = 0);
    dma_op_t op;
    op.kind = kind;
    op.addr = addr;
    op.inc  = inc;
    op.size = (kind == OP_LD) ? job.src_size      : job.dst_size;
    op.len  = single ? 0 : ((kind == OP_LD) ? job.src_beats - 1 : job.dst_beats - 1);
    job.ops.push_back(op);
  endfunction

endclass : dma_prog_gen
