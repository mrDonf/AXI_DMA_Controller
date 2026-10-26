//==============================================================================
// dma_scoreboard.sv - reference model + checker
//------------------------------------------------------------------------------
// Reference model (predict):
//   For every job, walk its op list in program order:
//     LD  -> expected read burst; append the bytes it returns (taken from a
//            memory snapshot) to the channel's byte stream
//     ST  -> expected write burst; consume bytes from the stream and place
//            them on the AXI lanes of each beat (data + WSTRB)
//     STZ -> expected write burst of zeros
//
// Checks (per AXI ID = channel, bursts of one ID are in order):
//   * every observed data read / write matches the next expected burst
//     exactly: address, length, size, burst type, cache, prot, strobes, data
//     (an expected INCR burst that crosses 4 KB is expected as the two AXI
//     bursts the DMA splits it into, TRM 2.10.5)
//   * responses are OKAY (unless the channel is in "ignore" mode for a fault)
//   * instruction fetches only touch registered program regions
//   * peripheral acknowledges match the expected type sequence
//   * nothing expected is left over at job end / end of test
//
// Two predictors:
//   * the job's op list (generator based: it knows the job's knobs)
//   * the C reference model (dma_cmodel, DPI-C): decodes the program bytes in
//     memory and executes them, so it shares nothing with the generator.
// A job that has an op list is cross-checked against the model when it is
// loaded (SB_XCHECK); a random instruction stream (JOB_RAND) has no op list
// and is predicted by the model alone.
//==============================================================================
`uvm_analysis_imp_decl(_axi_wr)
`uvm_analysis_imp_decl(_axi_rd)
`uvm_analysis_imp_decl(_periph)

class dma_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(dma_scoreboard)

  uvm_analysis_imp_axi_wr #(axi_pkg::axi_txn, dma_scoreboard)              wr_imp;
  uvm_analysis_imp_axi_rd #(axi_pkg::axi_txn, dma_scoreboard)              rd_imp;
  uvm_analysis_imp_periph #(dma_periph_pkg::periph_item, dma_scoreboard)   per_imp;

  axi_pkg::axi_mem_model mem;
  bit                    cmodel_en = 1;           // set by the environment
  dma_cmodel             cm;                      // null when the model is off / not built

  // Expected traffic
  protected axi_pkg::axi_txn             exp_wr  [int][$];
  protected axi_pkg::axi_txn             exp_rd  [int][$];
  protected dma_periph_pkg::periph_ack_e exp_ack [int][$];

  // Instruction memory regions
  typedef struct { bit [31:0] lo; bit [31:0] hi; } region_t;
  protected region_t prog_regions [$];

  // Channels under fault injection / kill: traffic not checked
  protected bit ignore_ch [int];
  protected bit ignore_periph [int];

  // Timestamps for ordering checks
  time first_rd_time [int];
  time last_wr_time  [int];

  // Statistics
  int unsigned n_wr_ok, n_rd_ok, n_ifetch, n_ack_ok, n_ignored, n_bytes;
  int unsigned n_xcheck_jobs, n_xcheck_bursts, n_model_jobs, n_arch_jobs, n_arch_bad;
  int unsigned n_split_4k;                         // expected bursts split at a 4 KB boundary

  function new(string name, uvm_component parent);
    super.new(name, parent);
    wr_imp  = new("wr_imp",  this);
    rd_imp  = new("rd_imp",  this);
    per_imp = new("per_imp", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cmodel_en && dma330_dpi_pkg::CMODEL_BUILT) begin
      cm = dma_cmodel::type_id::create("cm");
      cm.build_model();
    end
  endfunction

  function bit cmodel_available();
    return cm != null && cm.available();
  endfunction

  //============================================================================
  // Job registration / prediction
  //============================================================================
  function void add_prog_region(bit [31:0] addr, int unsigned nbytes);
    region_t r;
    r.lo = addr & ~32'h1F;
    r.hi = addr + nbytes + 64;            // fetch unit may read a line ahead
    prog_regions.push_back(r);
  endfunction

  // Generator-based prediction: the job's op list as expected AXI bursts
  protected function void predict_ops(dma_job job, ref axi_pkg::axi_txn rd [$],
                                      ref axi_pkg::axi_txn wr [$], input bit count = 1);
    byte unsigned stream [$];
    int           ch = job.ch;

    foreach (job.ops[i]) begin
      dma_op_t         op = job.ops[i];
      axi_pkg::axi_txn t  = axi_pkg::axi_txn::type_id::create("exp");
      t.id    = ch;
      t.addr  = op.addr;
      t.len   = op.len;
      t.size  = op.size;
      t.burst = op.inc ? axi_pkg::AXI_INCR : axi_pkg::AXI_FIXED;

      if (op.kind == OP_LD) begin
        t.dir   = axi_pkg::AXI_READ;
        t.cache = {1'b0, job.src_cache};                                 // ARCACHE[2:0]
        t.prot  = job.src_prot;
        for (int b = 0; b <= op.len; b++) begin
          int unsigned lo, hi;
          bit [31:0]   a = t.beat_addr(b);
          t.beat_lanes(b, lo, hi);
          for (int k = 0; k <= hi - lo; k++) stream.push_back(mem.read_byte(a + k));
        end
        rd.push_back(t);
      end else begin
        byte unsigned bb [$];                // the burst's bytes, in address order
        int unsigned  total = 0, taken = 0;
        t.dir   = axi_pkg::AXI_WRITE;
        t.cache = {job.dst_cache[2], 1'b0, job.dst_cache[1:0]};          // AWCACHE[3,1,0]
        t.prot  = job.dst_prot;
        for (int b = 0; b <= op.len; b++) begin
          int unsigned lo, hi;
          t.beat_lanes(b, lo, hi);
          total += hi - lo + 1;
        end
        for (int i = 0; i < total; i++) begin
          byte unsigned v = 0;
          if (op.kind == OP_ST) begin
            if (stream.size() == 0)
              `uvm_fatal("SB_MODEL", $sformatf("ch%0d: store without loaded data (bad job)", ch))
            v = stream.pop_front();
          end
          bb.push_back(v);
        end
        // CCR endian swap: the bytes of every group of 2**swap consecutive
        // bytes are reversed (DAR is aligned to the group, the burst holds
        // whole groups); a group may span several narrow beats
        if (op.kind == OP_ST && job.swap != 0) begin
          byte unsigned sw [$];
          int unsigned  g = 1 << job.swap;
          foreach (bb[i]) sw.push_back(bb[i ^ (g - 1)]);
          bb = sw;
        end
        for (int b = 0; b <= op.len; b++) begin
          int unsigned         lo, hi;
          bit [axi_pkg::AXI_DATA_W-1:0] d = '0;
          bit [axi_pkg::AXI_STRB_W-1:0] s = '0;
          t.beat_lanes(b, lo, hi);
          for (int lane = lo; lane <= hi; lane++) begin
            d[lane*8 +: 8] = bb[taken++];
            s[lane]        = 1'b1;
          end
          t.data.push_back(d);
          t.strb.push_back(s);
          if (count) n_bytes += hi - lo + 1;
        end
        wr.push_back(t);
      end
    end
  endfunction

  // An INCR burst that crosses a 4 KB boundary appears on AXI as two bursts:
  // up to the boundary, and from it (TRM 2.10.5). Bursts are at most 256 B,
  // so they cross at most once.
  function void split_4k(ref axi_pkg::axi_txn q [$]);
    axi_pkg::axi_txn out [$];
    foreach (q[i]) begin
      axi_pkg::axi_txn t = q[i];
      int unsigned     start, span, n1;
      start = int'(t.addr[11:0]) & ~(t.bytes_per_beat() - 1);
      span  = t.num_beats() * t.bytes_per_beat();
      if (t.burst != axi_pkg::AXI_INCR || start + span <= 4096) begin
        out.push_back(t);
        continue;
      end
      n1 = (4096 - start) / t.bytes_per_beat();
      n_split_4k++;
      for (int piece = 0; piece < 2; piece++) begin
        axi_pkg::axi_txn p = axi_pkg::axi_txn::type_id::create(t.get_name());
        int unsigned     b0 = (piece == 0) ? 0 : n1;
        int unsigned     nb = (piece == 0) ? n1 : t.num_beats() - n1;
        p.dir   = t.dir;    p.id    = t.id;     p.size = t.size;  p.burst = t.burst;
        p.cache = t.cache;  p.prot  = t.prot;
        p.addr  = (piece == 0) ? t.addr : {t.addr[31:12] + 20'd1, 12'h000};
        p.len   = 8'(nb - 1);
        for (int b = b0; b < b0 + nb && b < t.data.size(); b++) p.data.push_back(t.data[b]);
        for (int b = b0; b < b0 + nb && b < t.strb.size(); b++) p.strb.push_back(t.strb[b]);
        out.push_back(p);
      end
    end
    q = out;
  endfunction

  // Registers a job: its bursts become the expected traffic of the channel.
  // They come from the op list, or from the C model for a job without one.
  function void add_job(dma_job job);
    axi_pkg::axi_txn rd [$], wr [$];
    int              ch = job.ch;
    bit              from_model = (job.ops.size() == 0);

    if (!from_model) begin
      predict_ops(job, rd, wr);
      foreach (job.exp_acks[i]) exp_ack[job.periph].push_back(job.exp_acks[i]);
    end else begin
      if (job.cm_ref == null)
        `uvm_fatal("SB_MODEL", $sformatf("ch%0d: a job without an op list needs the C model: %s",
                                         ch, job.convert2string()))
      if (!job.cm_ref.clean_end())
        `uvm_error("SB_CMODEL", $sformatf("ch%0d: C model: program does not end cleanly: %s",
                                          ch, job.cm_ref.convert2string()))
      rd = job.cm_ref.rd;
      wr = job.cm_ref.wr;
      foreach (wr[i]) foreach (wr[i].strb[b]) n_bytes += $countones(wr[i].strb[b]);
      foreach (job.cm_ref.acks[i]) exp_ack[job.cm_ref.acks[i].periph].push_back(job.cm_ref.acks[i].ack);
      n_model_jobs++;
    end
    split_4k(rd);
    split_4k(wr);
    foreach (rd[i]) exp_rd[ch].push_back(rd[i]);
    foreach (wr[i]) exp_wr[ch].push_back(wr[i]);
    first_rd_time.delete(ch);
    last_wr_time.delete(ch);

    `uvm_info("SB", $sformatf("job added (%s): %s -> %0d rd / %0d wr expected",
                              from_model ? "C model" : "op list", job.convert2string(),
                              exp_rd[ch].size(), exp_wr[ch].size()), UVM_MEDIUM)
  endfunction

  //============================================================================
  // C reference model
  //============================================================================
  // Runs the program of 'job' (already in the memory model) through the C
  // model; a job with an op list is cross-checked against it.
  function void model_job(dma_job job);
    if (!cmodel_available()) return;
    job.cm_ref = cm.run(job, mem);
    if (job.ops.size() != 0) xcheck(job);
  endfunction

  protected function string txn_diff(axi_pkg::axi_txn e, axi_pkg::axi_txn t);
    if (e.addr != t.addr || e.len != t.len || e.size != t.size || e.burst != t.burst ||
        e.cache != t.cache || e.prot != t.prot)
      return "burst attributes differ";
    if (e.dir == axi_pkg::AXI_WRITE) begin
      foreach (e.data[b]) begin
        bit [axi_pkg::AXI_DATA_W-1:0] mask = '0;
        for (int k = 0; k < axi_pkg::AXI_STRB_W; k++) if (e.strb[b][k]) mask[k*8 +: 8] = 8'hFF;
        if (t.strb[b] != e.strb[b])
          return $sformatf("beat %0d strobes differ: %h vs %h", b, e.strb[b], t.strb[b]);
        if ((t.data[b] & mask) != (e.data[b] & mask))
          return $sformatf("beat %0d data differs: %h vs %h", b, e.data[b] & mask, t.data[b] & mask);
      end
    end
    return "";
  endfunction

  protected function void compare_lists(string tag, string what, axi_pkg::axi_txn gen [$],
                                        axi_pkg::axi_txn mdl [$]);
    if (gen.size() != mdl.size()) begin
      `uvm_error("SB_XCHECK", $sformatf("%s: %0d %s bursts predicted by the generator, %0d by the C model",
                                        tag, gen.size(), what, mdl.size()))
      return;
    end
    foreach (gen[i]) begin
      string d = txn_diff(gen[i], mdl[i]);
      if (d != "") begin
        `uvm_error("SB_XCHECK", $sformatf("%s: %s burst %0d: %s\n  generator: %s\n  C model  : %s",
                                          tag, what, i, d, gen[i].convert2string(), mdl[i].convert2string()))
        return;
      end
    end
    n_xcheck_bursts += gen.size();
  endfunction

  // Generator-based prediction versus C model, for one job
  protected function void xcheck(dma_job job);
    axi_pkg::axi_txn  rd [$], wr [$];
    dma_cmodel_result r   = job.cm_ref;
    string            tag = $sformatf("ch%0d %s", job.ch, job.kind.name());

    n_xcheck_jobs++;
    if (!r.clean_end()) begin
      `uvm_error("SB_XCHECK", $sformatf("%s: the C model does not see a clean program: %s", tag, r.convert2string()))
      return;
    end
    predict_ops(job, rd, wr, 0);
    compare_lists(tag, "read",  rd, r.rd);
    compare_lists(tag, "write", wr, r.wr);

    if (job.exp_acks.size() != r.acks.size()) begin
      `uvm_error("SB_XCHECK", $sformatf("%s: %0d acknowledges predicted by the generator, %0d by the C model",
                                        tag, job.exp_acks.size(), r.acks.size()))
    end else begin
      foreach (r.acks[i])
        if (r.acks[i].periph != int'(job.periph) || r.acks[i].ack != job.exp_acks[i])
          `uvm_error("SB_XCHECK", $sformatf("%s: acknowledge %0d: generator periph%0d %s, C model periph%0d %s",
                                            tag, i, job.periph, job.exp_acks[i].name(),
                                            r.acks[i].periph, r.acks[i].ack.name()))
    end
  endfunction

  // Acknowledge produced outside a channel job (e.g. a manager DMAFLUSHP)
  function void add_expected_ack(int p, dma_periph_pkg::periph_ack_e a);
    exp_ack[p].push_back(a);
  endfunction

  // Called after the job's interrupt: everything must have been observed
  function void job_done(dma_job job);
    int ch = job.ch;
    if (exp_wr.exists(ch) && exp_wr[ch].size() != 0)
      `uvm_error("SB_MISSING", $sformatf("ch%0d: %0d expected write bursts not seen, next: %s",
                                         ch, exp_wr[ch].size(), exp_wr[ch][0].convert2string()))
    if (exp_rd.exists(ch) && exp_rd[ch].size() != 0)
      `uvm_error("SB_MISSING", $sformatf("ch%0d: %0d expected read bursts not seen, next: %s",
                                         ch, exp_rd[ch].size(), exp_rd[ch][0].convert2string()))
    if (job.exp_acks.size() > 0 && exp_ack.exists(job.periph) && exp_ack[job.periph].size() != 0)
      `uvm_error("SB_MISSING", $sformatf("periph%0d: %0d expected acknowledges not seen",
                                         job.periph, exp_ack[job.periph].size()))
  endfunction

  //============================================================================
  // Fault / kill support
  //============================================================================
  function void ignore_channel(int ch, bit en);
    ignore_ch[ch] = en;
    if (!en) begin
      exp_wr.delete(ch);
      exp_rd.delete(ch);
    end
  endfunction

  function void ignore_peripheral(int p, bit en);
    ignore_periph[p] = en;
    if (!en) exp_ack.delete(p);
  endfunction

  protected function bit is_ignored(int ch);
    return ignore_ch.exists(ch) && ignore_ch[ch];
  endfunction

  //============================================================================
  // Observed traffic
  //============================================================================
  function void write_axi_wr(axi_pkg::axi_txn t);
    int ch = t.id;
    last_wr_time[ch] = t.end_time;
    if (ch == dma_tb_params_pkg::IFETCH_ID) begin
      `uvm_error("SB_WR", {"write with the instruction-fetch ID: ", t.convert2string()})
      return;
    end
    if (is_ignored(ch)) begin
      n_ignored++;
      return;
    end
    if (!exp_wr.exists(ch) || exp_wr[ch].size() == 0) begin
      `uvm_error("SB_WR", {"unexpected write: ", t.convert2string()})
      return;
    end
    compare_write(exp_wr[ch].pop_front(), t);
  endfunction

  function void write_axi_rd(axi_pkg::axi_txn t);
    int ch = t.id;
    if (ch == dma_tb_params_pkg::IFETCH_ID) begin
      check_ifetch(t);
      return;
    end
    if (!first_rd_time.exists(ch)) first_rd_time[ch] = t.start_time;
    if (is_ignored(ch)) begin
      n_ignored++;
      return;
    end
    if (!exp_rd.exists(ch) || exp_rd[ch].size() == 0) begin
      `uvm_error("SB_RD", {"unexpected read: ", t.convert2string()})
      return;
    end
    compare_read(exp_rd[ch].pop_front(), t);
  endfunction

  function void write_periph(dma_periph_pkg::periph_item t);
    int p = t.periph_id;
    if (t.dir != dma_periph_pkg::PER_ACK) return;
    if (ignore_periph.exists(p) && ignore_periph[p]) return;
    if (!exp_ack.exists(p) || exp_ack[p].size() == 0) begin
      `uvm_error("SB_ACK", {"unexpected acknowledge: ", t.convert2string()})
      return;
    end
    begin
      dma_periph_pkg::periph_ack_e e = exp_ack[p].pop_front();
      if (e != t.ack_type)
        `uvm_error("SB_ACK", $sformatf("periph%0d: expected %s, got %s", p, e.name(), t.ack_type.name()))
      else
        n_ack_ok++;
    end
  endfunction

  //============================================================================
  // Comparators
  //============================================================================
  protected function bit compare_attr(axi_pkg::axi_txn e, axi_pkg::axi_txn t, string kind);
    if (e.addr != t.addr || e.len != t.len || e.size != t.size || e.burst != t.burst ||
        e.cache != t.cache || e.prot != t.prot) begin
      `uvm_error({"SB_", kind}, $sformatf("ch%0d burst mismatch\n  expected: %s\n  actual  : %s",
                                          t.id, e.convert2string(), t.convert2string()))
      return 0;
    end
    return 1;
  endfunction

  protected function void compare_write(axi_pkg::axi_txn e, axi_pkg::axi_txn t);
    bit ok;
    ok = compare_attr(e, t, "WR");
    if (ok) begin
      foreach (e.data[b]) begin
        bit [axi_pkg::AXI_DATA_W-1:0] mask = '0;
        for (int k = 0; k < axi_pkg::AXI_STRB_W; k++) if (e.strb[b][k]) mask[k*8 +: 8] = 8'hFF;
        if (t.strb[b] != e.strb[b] || (t.data[b] & mask) != (e.data[b] & mask)) begin
          `uvm_error("SB_WR", $sformatf("ch%0d addr=0x%08h beat %0d: expected data=%h strb=%h, got data=%h strb=%h",
                                        t.id, t.addr, b, e.data[b] & mask, e.strb[b],
                                        t.data[b] & mask, t.strb[b]))
          ok = 0;
          break;
        end
      end
    end
    if (t.resp[0] != axi_pkg::AXI_OKAY) begin
      `uvm_error("SB_WR", $sformatf("ch%0d addr=0x%08h unexpected BRESP %s", t.id, t.addr, t.resp[0].name()))
      ok = 0;
    end
    if (ok) n_wr_ok++;
  endfunction

  protected function void compare_read(axi_pkg::axi_txn e, axi_pkg::axi_txn t);
    bit ok = compare_attr(e, t, "RD");
    foreach (t.resp[i]) if (t.resp[i] != axi_pkg::AXI_OKAY) begin
      `uvm_error("SB_RD", $sformatf("ch%0d addr=0x%08h unexpected RRESP %s", t.id, t.addr, t.resp[i].name()))
      ok = 0;
      break;
    end
    if (ok) n_rd_ok++;
  endfunction

  protected function void check_ifetch(axi_pkg::axi_txn t);
    bit hit = 0;
    n_ifetch++;
    foreach (prog_regions[i])
      if (t.addr >= prog_regions[i].lo && t.addr <= prog_regions[i].hi) hit = 1;
    if (!hit)
      `uvm_error("SB_IFETCH", $sformatf("instruction fetch outside program memory: 0x%08h", t.addr))
    // TRM Table 2-1: privileged instruction access, cacheable write-through
    // allocate-on-read
    if (t.prot[2] != 1'b1 || t.prot[0] != 1'b1)
      `uvm_error("SB_IFETCH", $sformatf("instruction fetch not privileged + instruction: prot=%0h", t.prot))
    if (t.cache != 4'b0110)
      `uvm_error("SB_IFETCH", $sformatf("instruction fetch ARCACHE=%0h, 0110 expected", t.cache))
    if (t.len != dma_tb_params_pkg::IC_BEATS - 1 || t.burst != axi_pkg::AXI_INCR)
      `uvm_error("SB_IFETCH", {"unexpected i-cache refill shape: ", t.convert2string()})
  endfunction

  //============================================================================
  virtual function void check_phase(uvm_phase phase);
    foreach (exp_wr[ch]) if (exp_wr[ch].size() != 0 && !is_ignored(ch))
      `uvm_error("SB_EOT", $sformatf("ch%0d: %0d write bursts never observed", ch, exp_wr[ch].size()))
    foreach (exp_rd[ch]) if (exp_rd[ch].size() != 0 && !is_ignored(ch))
      `uvm_error("SB_EOT", $sformatf("ch%0d: %0d read bursts never observed", ch, exp_rd[ch].size()))
    foreach (exp_ack[p]) if (exp_ack[p].size() != 0)
      `uvm_error("SB_EOT", $sformatf("periph%0d: %0d acknowledges never observed", p, exp_ack[p].size()))
  endfunction

  virtual function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf({"\n  write bursts matched : %0d\n  read bursts matched  : %0d",
                               "\n  bytes checked        : %0d\n  instruction fetches  : %0d",
                               "\n  periph acks matched  : %0d\n  ignored (fault/kill) : %0d",
                               "\n  bursts split at 4 KB : %0d",
                               "\n  C model              : %s",
                               "\n    jobs cross-checked : %0d (%0d bursts)\n    jobs predicted by the model alone: %0d",
                               "\n    final registers compared: %0d jobs (%0d mismatches)"},
                              n_wr_ok, n_rd_ok, n_bytes, n_ifetch, n_ack_ok, n_ignored, n_split_4k,
                              cmodel_available() ? "on" : "off", n_xcheck_jobs, n_xcheck_bursts,
                              n_model_jobs, n_arch_jobs, n_arch_bad), UVM_LOW)
  endfunction

endclass : dma_scoreboard
