//==============================================================================
// dma_base_vseq.sv - driver-level helpers shared by all virtual sequences
//------------------------------------------------------------------------------
// Mirrors what a software driver does with the DMA:
//   dbg_exec()      : DBGINST0/1 + DBGCMD (atomic, waits for DBGSTATUS idle)
//   start_channel() : DMAGO through the manager debug interface
//   kill_channel()  : DMAKILL to a channel thread
//   run_job()       : generate + load program, start, wait interrupt, check
//==============================================================================
class dma_base_vseq extends uvm_sequence;

  `uvm_object_utils(dma_base_vseq)
  `uvm_declare_p_sequencer(dma_virtual_sequencer)

  dma_reg_block                 rm;
  virtual dma_ctrl_if #(dma_tb_params_pkg::NUM_EVENTS) vif;
  int unsigned                  timeout_clks = 400_000;

  protected int unsigned        job_count [int];
  dma_rand_prog                 rgen;                 // JOB_RAND programs

  function new(string name = "dma_base_vseq");
    super.new(name);
  endfunction

  virtual task pre_body();
    rm  = p_sequencer.rm;
    vif = p_sequencer.cfg.ctrl_vif;
  endtask

  //============================================================================
  // Register access
  //============================================================================
  task reg_wr(uvm_reg r, uvm_reg_data_t v);
    uvm_status_e status;
    r.write(status, v, .parent(this));
    if (status != UVM_IS_OK) `uvm_error("REG", {"write failed: ", r.get_name()})
  endtask

  task reg_rd(uvm_reg r, output uvm_reg_data_t v);
    uvm_status_e status;
    r.read(status, v, .parent(this));
    if (status != UVM_IS_OK) `uvm_error("REG", {"read failed: ", r.get_name()})
  endtask

  //============================================================================
  // Debug instruction interface
  //============================================================================
  task dbg_exec(bit to_channel, int unsigned ch, bit [7:0] insn[$]);
    p_sequencer.dbg_lock.get();
    dbg_exec_locked(to_channel, ch, insn);
    p_sequencer.dbg_lock.put();
  endtask

  // Caller already owns dbg_lock (used to keep a multi-step debug sequence,
  // e.g. "fault the manager, check, DMAKILL it", atomic w.r.t. other threads)
  task dbg_exec_locked(bit to_channel, int unsigned ch, bit [7:0] insn[$]);
    uvm_reg_data_t v;
    bit [31:0]     inst0, inst1;
    while (insn.size() < 6) insn.push_back(8'h00);
    inst0 = {insn[1], insn[0], 5'd0, 3'(ch), 7'd0, to_channel};
    inst1 = {insn[5], insn[4], insn[3], insn[2]};

    do reg_rd(rm.DBGSTATUS, v); while (v[0]);
    reg_wr(rm.DBGINST0, inst0);
    reg_wr(rm.DBGINST1, inst1);
    reg_wr(rm.DBGCMD, 0);
  endtask

  task start_channel(int unsigned ch, bit [31:0] pc, bit ns = 0);
    `uvm_info("VSEQ", $sformatf("DMAGO ch%0d pc=0x%08h", ch, pc), UVM_MEDIUM)
    dbg_exec(0, 0, '{8'hA0 | (ns << 1), 8'(ch), pc[7:0], pc[15:8], pc[23:16], pc[31:24]});
  endtask

  task kill_channel(int unsigned ch);
    `uvm_info("VSEQ", $sformatf("DMAKILL ch%0d", ch), UVM_MEDIUM)
    dbg_exec(1, ch, '{8'h01});
  endtask

  task kill_manager();
    dbg_exec(0, 0, '{8'h01});
  endtask

  //============================================================================
  // Status / interrupts
  //============================================================================
  task read_ch_status(int unsigned ch, output bit [3:0] status);
    uvm_reg_data_t v;
    reg_rd(rm.CSR[ch], v);
    status = v[3:0];
  endtask

  task wait_ch_status(int unsigned ch, bit [3:0] status, int unsigned max_polls = 2000);
    bit [3:0] s;
    for (int i = 0; i < max_polls; i++) begin
      read_ch_status(ch, s);
      if (s == status) return;
      vif.wait_clks(20);
    end
    `uvm_error("VSEQ", $sformatf("ch%0d: status %0d not reached (last %0d)", ch, status, s))
  endtask

  // Note: several channel threads wait concurrently, so the watchdog is
  // cancelled with 'disable fork' inside an isolating fork. ('disable <block>'
  // would kill the same block in every other thread as well.)
  task wait_irq(int unsigned ev);
    bit timed_out = 0;
    fork
      begin
        fork
          wait (vif.irq[ev] === 1'b1);
          begin
            vif.wait_clks(timeout_clks);
            timed_out = 1;
          end
        join_any
        disable fork;
      end
    join
    if (timed_out) begin
      `uvm_error("VSEQ", $sformatf("timeout waiting for irq[%0d]", ev))
      dump_state();
    end
  endtask

  // Debug aid: thread states when something hangs
  task dump_state();
    uvm_reg_data_t dsr, csr, cpc, ftr;
    string s;
    reg_rd(rm.DSR, dsr);
    s = $sformatf("DSR=0x%08h", dsr);
    foreach (rm.CSR[n]) begin
      reg_rd(rm.CSR[n], csr);
      reg_rd(rm.CPC[n], cpc);
      reg_rd(rm.FTR[n], ftr);
      s = {s, $sformatf("\n  ch%0d CSR=0x%08h CPC=0x%08h FTR=0x%08h", n, csr, cpc, ftr)};
    end
    `uvm_info("DUMP", s, UVM_NONE)
  endtask

  task wait_abort();
    fork
      begin
        fork
          wait (vif.irq_abort === 1'b1);
          begin
            vif.wait_clks(timeout_clks);
            `uvm_error("VSEQ", "timeout waiting for irq_abort")
          end
        join_any
        disable fork;
      end
    join
  endtask

  task clear_irq(int unsigned ev);
    reg_wr(rm.INTCLR, 1 << ev);
  endtask

  //============================================================================
  // Jobs
  //============================================================================
  // Generates the program and loads it into memory
  task load_job(dma_job job);
    int unsigned n = job_count.exists(job.ch) ? job_count[job.ch] : 0;
    job_count[job.ch] = n + 1;
    job.irq_ev    = job.ch;
    job.prog_addr = dma_job::prog_base(job.ch) + (n % 2) * 32'h8000;
    if (job.kind == JOB_RAND) begin
      // Random instruction stream: written to memory by the generator, which
      // lets the C model run it until it is acceptable
      if (rgen == null) rgen = dma_rand_prog::type_id::create("rgen");
      rgen.build(job, p_sequencer.sb.cm, p_sequencer.cfg.mem);
    end else begin
      dma_prog_gen::build(job);
      p_sequencer.cfg.mem.write_bytes(job.prog_addr, job.prog.code);
    end
    if (p_sequencer.sb != null) begin
      p_sequencer.sb.add_prog_region(job.prog_addr, job.prog.code.size());
      // Program is in memory: the C model runs it, and a job with an op list is
      // cross-checked against it
      if (job.kind != JOB_RAND) p_sequencer.sb.model_job(job);
    end
    if (job.kind == JOB_RAND) p_sequencer.cov.sample_program(job.prog.code);
    else                      p_sequencer.cov.sample_job(job);
    `uvm_info("VSEQ", $sformatf("ch%0d job: %s\n  program @0x%08h (%0d bytes):%s", job.ch,
                                job.convert2string(), job.prog_addr, job.prog.code.size(),
                                job.prog.sprint_listing()), UVM_HIGH)
  endtask

  // Complete flow for one job
  task run_job(dma_job job);
    dma_periph_pkg::periph_req_seq pseq;
    bit uses_periph = (job.kind inside {JOB_M2P, JOB_P2M, JOB_PERIPH_MIXED,
                                        JOB_P2M_MIXED, JOB_COND_LOOP});

    load_job(job);
    if (p_sequencer.sb != null) p_sequencer.sb.add_job(job);
    `uvm_info("VSEQ", {"start ", job.convert2string()}, UVM_MEDIUM)

    if (uses_periph) begin
      pseq = dma_periph_pkg::periph_req_seq::type_id::create("pseq");
      pseq.types         = job.req_types;
      pseq.last_on_final = (job.kind inside {JOB_PERIPH_MIXED, JOB_P2M_MIXED});
    end

    fork
      if (uses_periph) pseq.start(p_sequencer.per_sqr[job.periph]);
      begin
        start_channel(job.ch, job.prog_addr, job.ns);
        wait_irq(job.irq_ev);
        clear_irq(job.irq_ev);
        wait_ch_status(job.ch, dma330_pkg::ST_STOPPED);
      end
    join

    check_arch_state(job);
    if (p_sequencer.sb != null) p_sequencer.sb.job_done(job);
    `uvm_info("VSEQ", {"done  ", job.convert2string()}, UVM_MEDIUM)
  endtask

  // Architectural state of a finished channel against the C model: the program
  // counter (at DMAEND / DMAKILL) and every register the program wrote
  task check_arch_state(dma_job job);
    dma_cmodel_result r = job.cm_ref;
    uvm_reg_data_t    v;
    string            tag = $sformatf("ch%0d %s", job.ch, job.kind.name());
    int unsigned      bad = 0;

    if (r == null || !r.clean_end()) return;

    reg_rd(rm.CPC[job.ch], v);
    if (v != r.pc) begin
      `uvm_error("ARCH", $sformatf("%s: CPC=0x%08h, C model 0x%08h", tag, v, r.pc))
      bad++;
    end
    if (r.sar_v) begin
      reg_rd(rm.SAR[job.ch], v);
      if (v != r.sar) begin `uvm_error("ARCH", $sformatf("%s: SAR=0x%08h, C model 0x%08h", tag, v, r.sar)) bad++; end
    end
    if (r.dar_v) begin
      reg_rd(rm.DAR[job.ch], v);
      if (v != r.dar) begin `uvm_error("ARCH", $sformatf("%s: DAR=0x%08h, C model 0x%08h", tag, v, r.dar)) bad++; end
    end
    if (r.ccr_v) begin
      reg_rd(rm.CCR[job.ch], v);
      if (v != r.ccr) begin `uvm_error("ARCH", $sformatf("%s: CCR=0x%08h, C model 0x%08h", tag, v, r.ccr)) bad++; end
    end
    if (r.lc0_v) begin
      reg_rd(rm.LC0[job.ch], v);
      if (v != r.lc0) begin `uvm_error("ARCH", $sformatf("%s: LC0=%0d, C model %0d", tag, v, r.lc0)) bad++; end
    end
    if (r.lc1_v) begin
      reg_rd(rm.LC1[job.ch], v);
      if (v != r.lc1) begin `uvm_error("ARCH", $sformatf("%s: LC1=%0d, C model %0d", tag, v, r.lc1)) bad++; end
    end
    if (p_sequencer.sb != null) begin
      p_sequencer.sb.n_arch_jobs++;
      p_sequencer.sb.n_arch_bad += bad;
    end
  endtask

  // A randomized job for a channel; extra constraints come from the caller
  function dma_job make_job(int unsigned ch, dma_job_kind_e kind);
    dma_job job = dma_job::type_id::create($sformatf("job_ch%0d", ch));
    if (!job.randomize() with { ch == local::ch; kind == local::kind; })
      `uvm_fatal("RAND", "dma_job randomize failed")
    job.periph = ch % dma_tb_params_pkg::NUM_PERIPH;
    return job;
  endfunction

endclass : dma_base_vseq
