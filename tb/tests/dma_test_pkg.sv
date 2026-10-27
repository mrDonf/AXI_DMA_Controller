//==============================================================================
// dma_test_pkg.sv - test library
//------------------------------------------------------------------------------
//   dma_reg_test            register reset values, bit-bash, IDs
//   dma_m2m_aligned_test    one channel, aligned 64-bit copies
//   dma_m2m_unaligned_test  one channel, any alignment / beat size / length
//   dma_multi_ch_test       all channels concurrently
//   dma_fixed_addr_test     FIXED (non-incrementing) source or destination
//   dma_fill_test           DMASTZ zero fill
//   dma_loop2d_test         nested loops, DMAADDH / DMAADNH 2D transfers
//   dma_periph_test         peripheral-paced transfers (WFP/LDP/STP/FLUSHP/LPFE)
//   dma_event_test          DMASEV / DMAWFE between threads, debug DMASEV
//   dma_cache_test          thread-local cache maintenance, program replacement
//   dma_boot_test           manager boots from memory, non-secure, dmago_err
//   dma_fault_test          every fault type, isolation, recovery
//   dma_kill_test           DMAKILL in every waiting state
//   dma_stress_test         everything at once, heavy back-pressure
//   dma_isa_test            DMANOP / DMARMB / DMAADNH SAR / DMAKILL end, loops
//   dma_periph_corner_test  stray flush ack, back-to-back requests, shared periph
//   dma_boot_err_test       manager boot fetch error and recovery
//   dma_reset_test          reset in the middle of traffic, recovery
//   dma_endian_test         CCR endian swap (16/32/64-bit) on random copies
//   dma_watchdog_test       lock-up watchdog: abort, report-only, no false alarm
//   dma_lowpower_test       Q-Channel quiescence, clock gating, wake-up
//   dma_rand_prog_test      random instruction streams, C reference model (DPI-C) predicts
//   dma_cmodel_mix_test     every job kind + random streams, choked AXI, C model cross-check
//   dma_mfifo_share_test    shared MFIFO: one channel uses most of it, wait for space, deadlock
//   dma_security_test       secure / non-secure APB ports, CR3 / CR4, NS threads and manager
//
// Plusargs:  +AXI_PROFILE=fast|slow|default   +NO_REORDER   +NO_CMODEL
//==============================================================================
package dma_test_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import dma_tb_params_pkg::*;
  import apb_pkg::*;
  import axi_pkg::*;
  import dma_periph_pkg::*;
  import dma_env_pkg::*;
  import dma_seq_pkg::*;

  //============================================================================
  // Base test
  //============================================================================
  class dma_base_test extends uvm_test;

    `uvm_component_utils(dma_base_test)

    dma_env     env;
    dma_env_cfg cfg;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      string profile;
      super.build_phase(phase);

      cfg         = dma_env_cfg::type_id::create("cfg");
      cfg.mem     = axi_mem_model::type_id::create("mem");
      cfg.apb_cfg = apb_config::type_id::create("apb_cfg");
      cfg.apb_ns_cfg = apb_config::type_id::create("apb_ns_cfg");
      cfg.axi_cfg = axi_config::type_id::create("axi_cfg");

      if (!uvm_config_db #(apb_vif_t)::get(this, "", "apb_vif", cfg.apb_cfg.vif))
        `uvm_fatal("NOVIF", "apb_vif not found")
      if (!uvm_config_db #(apb_vif_t)::get(this, "", "apb_ns_vif", cfg.apb_ns_cfg.vif))
        `uvm_fatal("NOVIF", "apb_ns_vif not found")
      if (!uvm_config_db #(axi_vif_t)::get(this, "", "axi_vif", cfg.axi_cfg.vif))
        `uvm_fatal("NOVIF", "axi_vif not found")
      if (!uvm_config_db #(virtual dma_ctrl_if #(NUM_EVENTS))::get(this, "", "ctrl_vif", cfg.ctrl_vif))
        `uvm_fatal("NOVIF", "ctrl_vif not found")
      void'(uvm_config_db #(int)::get(this, "", "async_mode", cfg.async_mode));
      cfg.apb_slverr         = (cfg.async_mode != 0);   // tb_top: APB_SLVERR = ASYNC
      cfg.apb_cfg.cov_slverr = cfg.apb_slverr;
      cfg.apb_ns_cfg.cov_slverr = cfg.apb_slverr;

      foreach (cfg.per_cfg[p]) begin
        cfg.per_cfg[p] = periph_config::type_id::create($sformatf("per_cfg%0d", p));
        cfg.per_cfg[p].periph_id = p;
        if (!uvm_config_db #(periph_vif_t)::get(this, "", $sformatf("per_vif%0d", p), cfg.per_cfg[p].vif))
          `uvm_fatal("NOVIF", $sformatf("per_vif%0d not found", p))
      end

      // AXI slave behaviour
      if ($value$plusargs("AXI_PROFILE=%s", profile)) begin
        case (profile)
          "fast":  cfg.axi_cfg.set_fast();
          "slow":  cfg.axi_cfg.set_slow();
          default: cfg.axi_cfg.set_default();
        endcase
      end
      if ($test$plusargs("NO_REORDER")) begin
        cfg.axi_cfg.reorder_en    = 0;
        cfg.axi_cfg.interleave_en = 0;
      end
      if ($test$plusargs("NO_CMODEL")) cfg.cmodel_en = 0;

      configure(cfg);
      uvm_config_db #(dma_env_cfg)::set(this, "env", "cfg", cfg);
      env = dma_env::type_id::create("env", this);
    endfunction

    // Test-specific configuration hook
    virtual function void configure(dma_env_cfg cfg);
    endfunction

    // Test-specific stimulus
    virtual function dma_base_vseq create_vseq();
      return null;
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
      `uvm_info("TEST", $sformatf("DUT: %0d channels, %0d peripherals, %0d events, %0d-bit AXI, %s clocking",
                                  NUM_CH, NUM_PERIPH, NUM_EVENTS, DATA_W,
                                  cfg.async_mode ? "ASYNC (CDC bridges)" : "SYNC"), UVM_LOW)
      uvm_top.print_topology(uvm_default_tree_printer);
    endfunction

    // Watchdog in core clocks (a time literal handed to the precompiled UVM
    // library would be scaled by its own timescale)
    int unsigned watchdog_clks = 10_000_000;

    virtual task run_phase(uvm_phase phase);
      dma_base_vseq vseq;
      fork
        begin
          cfg.ctrl_vif.wait_clks(watchdog_clks);
          `uvm_fatal("WATCHDOG", $sformatf("test still running after %0d core clocks", watchdog_clks))
        end
      join_none
      phase.raise_objection(this);
      @(posedge cfg.ctrl_vif.rst_n);
      cfg.ctrl_vif.wait_clks(20);
      vseq = create_vseq();
      if (vseq != null) vseq.start(env.vsqr);
      cfg.ctrl_vif.wait_clks(200);
      phase.drop_objection(this);
    endtask

    virtual function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      int errors = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
      if (errors == 0)
        `uvm_info("RESULT", "*** TEST PASSED ***", UVM_NONE)
      else
        `uvm_info("RESULT", $sformatf("*** TEST FAILED *** (%0d errors)", errors), UVM_NONE)
    endfunction

  endclass : dma_base_test

  //============================================================================
  // Tests
  //============================================================================
  class dma_reg_test extends dma_base_test;
    `uvm_component_utils(dma_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function dma_base_vseq create_vseq();
      return dma_reg_vseq::type_id::create("vseq");
    endfunction
  endclass

  // Common shape for traffic tests
  class dma_traffic_test extends dma_base_test;
    `uvm_component_utils(dma_traffic_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void tune(dma_traffic_vseq v);
    endfunction
    virtual function dma_base_vseq create_vseq();
      dma_traffic_vseq v = dma_traffic_vseq::type_id::create("vseq");
      tune(v);
      return v;
    endfunction
  endclass

  class dma_m2m_aligned_test extends dma_traffic_test;
    `uvm_component_utils(dma_m2m_aligned_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void tune(dma_traffic_vseq v);
      v.ch_mask = 1; v.jobs_per_ch = 6; v.aligned_only = 1;
    endfunction
  endclass

  class dma_m2m_unaligned_test extends dma_traffic_test;
    `uvm_component_utils(dma_m2m_unaligned_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void tune(dma_traffic_vseq v);
      v.ch_mask = 1; v.jobs_per_ch = 16; v.cross_4k = 1;
    endfunction
  endclass

  class dma_multi_ch_test extends dma_traffic_test;
    `uvm_component_utils(dma_multi_ch_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void tune(dma_traffic_vseq v);
      v.jobs_per_ch = 8;
    endfunction
  endclass

  class dma_fixed_addr_test extends dma_traffic_test;
    `uvm_component_utils(dma_fixed_addr_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void tune(dma_traffic_vseq v);
      v.jobs_per_ch = 6; v.fixed_mode = 1;
    endfunction
  endclass

  class dma_fill_test extends dma_traffic_test;
    `uvm_component_utils(dma_fill_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void tune(dma_traffic_vseq v);
      v.jobs_per_ch = 6; v.kinds = '{JOB_FILL, JOB_M2M};
    endfunction
  endclass

  class dma_loop2d_test extends dma_traffic_test;
    `uvm_component_utils(dma_loop2d_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void tune(dma_traffic_vseq v);
      v.jobs_per_ch = 8; v.kinds = '{JOB_LOOP2D};
    endfunction
  endclass

  class dma_periph_test extends dma_traffic_test;
    `uvm_component_utils(dma_periph_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void tune(dma_traffic_vseq v);
      v.jobs_per_ch = 8;
      v.kinds = '{JOB_M2P, JOB_P2M, JOB_PERIPH_MIXED, JOB_P2M_MIXED, JOB_COND_LOOP};
    endfunction
  endclass

  // Less common instructions: DMANOP, DMARMB, DMAADNH on SAR, DMAKILL as the
  // program end, nested loops
  class dma_isa_test extends dma_traffic_test;
    `uvm_component_utils(dma_isa_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void tune(dma_traffic_vseq v);
      v.jobs_per_ch = 6;
      v.kinds = '{JOB_ISA_MIX, JOB_LOOP2D, JOB_M2M};
    endfunction
  endclass

  class dma_periph_corner_test extends dma_base_test;
    `uvm_component_utils(dma_periph_corner_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function dma_base_vseq create_vseq();
      return dma_periph_corner_vseq::type_id::create("vseq");
    endfunction
  endclass

  class dma_reset_test extends dma_base_test;
    `uvm_component_utils(dma_reset_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function dma_base_vseq create_vseq();
      return dma_reset_vseq::type_id::create("vseq");
    endfunction
  endclass

  // Manager boots from an address that answers with SLVERR
  class dma_boot_err_test extends dma_base_test;
    `uvm_component_utils(dma_boot_err_test)
    localparam bit [31:0] BAD_BOOT = 32'hE00F_0000;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      cfg.axi_cfg.add_err_region(BAD_BOOT, BAD_BOOT + 32'hFFF, AXI_SLVERR, 1, 0);
      env.sb.add_prog_region(BAD_BOOT, 64);
      cfg.ctrl_vif.boot_from_pc = 1'b1;
      cfg.ctrl_vif.boot_addr    = BAD_BOOT;
    endfunction
    virtual function dma_base_vseq create_vseq();
      dma_boot_err_vseq v = dma_boot_err_vseq::type_id::create("vseq");
      v.boot_addr = BAD_BOOT;
      return v;
    endfunction
  endclass

  class dma_stress_test extends dma_traffic_test;
    `uvm_component_utils(dma_stress_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void configure(dma_env_cfg cfg);
      cfg.axi_cfg.set_slow();
      foreach (cfg.per_cfg[p]) cfg.per_cfg[p].daready_pct = 30;
    endfunction
    virtual function void tune(dma_traffic_vseq v);
      v.jobs_per_ch = 10;
      v.max_bytes   = 4096;
      v.wd_timeout  = 16;              // 4096 clk: must never fire on slow traffic
      v.kinds = '{JOB_M2M, JOB_M2M, JOB_FILL, JOB_LOOP2D, JOB_M2P, JOB_P2M, JOB_PERIPH_MIXED,
                  JOB_P2M_MIXED, JOB_COND_LOOP, JOB_ISA_MIX};
    endfunction
  endclass

  class dma_endian_test extends dma_traffic_test;
    `uvm_component_utils(dma_endian_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void tune(dma_traffic_vseq v);
      v.jobs_per_ch = 8; v.endian_mode = 1; v.kinds = '{JOB_M2M, JOB_M2M, JOB_FILL};
    endfunction
  endclass

  //----------------------------------------------------------------------------
  // C reference model (DPI-C) tests. The model is also active in every other
  // test that runs jobs: it cross-checks the generator-based prediction and the
  // final channel registers there. These two make it the only predictor.
  //----------------------------------------------------------------------------
  class dma_cmodel_traffic_test extends dma_traffic_test;
    `uvm_component_utils(dma_cmodel_traffic_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function dma_base_vseq create_vseq();
      if (!env.sb.cmodel_available())
        `uvm_fatal("CMODEL", "this test needs the C model: build the DPI library and do not use +NO_CMODEL")
      return super.create_vseq();
    endfunction
  endclass

  // Random instruction streams: random kernels, loop nests, addressing modes,
  // alignment, endian swap, attributes and wrap-around at the top of memory
  class dma_rand_prog_test extends dma_cmodel_traffic_test;
    `uvm_component_utils(dma_rand_prog_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void tune(dma_traffic_vseq v);
      v.jobs_per_ch = 10;
      v.kinds       = '{JOB_RAND};
    endfunction
  endclass

  // Every job kind and random streams together, on a choked AXI slave and slow peripherals
  class dma_cmodel_mix_test extends dma_cmodel_traffic_test;
    `uvm_component_utils(dma_cmodel_mix_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void configure(dma_env_cfg cfg);
      cfg.axi_cfg.set_choke();
      foreach (cfg.per_cfg[p]) cfg.per_cfg[p].daready_pct = 40;
    endfunction
    virtual function void tune(dma_traffic_vseq v);
      v.jobs_per_ch = 12;
      v.kinds = '{JOB_M2M, JOB_FILL, JOB_LOOP2D, JOB_M2P, JOB_P2M, JOB_PERIPH_MIXED,
                  JOB_P2M_MIXED, JOB_COND_LOOP, JOB_ISA_MIX, JOB_RAND, JOB_RAND, JOB_RAND};
    endfunction
  endclass

  class dma_watchdog_test extends dma_base_test;
    `uvm_component_utils(dma_watchdog_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function dma_base_vseq create_vseq();
      return dma_watchdog_vseq::type_id::create("vseq");
    endfunction
  endclass

  class dma_lowpower_test extends dma_base_test;
    `uvm_component_utils(dma_lowpower_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function dma_base_vseq create_vseq();
      return dma_lowpower_vseq::type_id::create("vseq");
    endfunction
  endclass

  class dma_event_test extends dma_base_test;
    `uvm_component_utils(dma_event_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function dma_base_vseq create_vseq();
      return dma_event_vseq::type_id::create("vseq");
    endfunction
  endclass

  class dma_fault_test extends dma_base_test;
    `uvm_component_utils(dma_fault_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function dma_base_vseq create_vseq();
      return dma_fault_vseq::type_id::create("vseq");
    endfunction
  endclass

  class dma_kill_test extends dma_base_test;
    `uvm_component_utils(dma_kill_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function dma_base_vseq create_vseq();
      return dma_kill_vseq::type_id::create("vseq");
    endfunction
  endclass

  class dma_mfifo_share_test extends dma_base_test;
    `uvm_component_utils(dma_mfifo_share_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function dma_base_vseq create_vseq();
      return dma_mfifo_vseq::type_id::create("vseq");
    endfunction
  endclass

  class dma_cache_test extends dma_base_test;
    `uvm_component_utils(dma_cache_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function dma_base_vseq create_vseq();
      return dma_cache_vseq::type_id::create("vseq");
    endfunction
  endclass

  // Event / peripheral security is configured before reset is released
  class dma_security_test extends dma_base_test;
    `uvm_component_utils(dma_security_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      cfg.ctrl_vif.boot_irq_ns     = dma_security_vseq::IRQ_NS;
      cfg.ctrl_vif.boot_periph_ns  = dma_security_vseq::PERIPH_NS;
      cfg.ctrl_vif.boot_manager_ns = 1'b0;
    endfunction
    virtual function dma_base_vseq create_vseq();
      return dma_security_vseq::type_id::create("vseq");
    endfunction
  endclass

  //----------------------------------------------------------------------------
  // Boot test: everything is prepared before reset is released
  //----------------------------------------------------------------------------
  class dma_boot_test extends dma_base_test;
    `uvm_component_utils(dma_boot_test)

    dma_boot_vseq bvseq;
    localparam bit [31:0] BOOT_ADDR = 32'h0000_8000;
    localparam int        EV_CH1_DONE = 12;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
      dma330_asm mgr;
      super.end_of_elaboration_phase(phase);
      bvseq = dma_boot_vseq::type_id::create("vseq");

      for (int ch = 0; ch < 2; ch++) begin
        dma_job job = dma_job::type_id::create($sformatf("boot_job%0d", ch));
        if (!job.randomize() with { ch == local::ch; kind == JOB_M2M; })
          `uvm_fatal("RAND", "boot job randomize failed")
        job.ns        = 1;                        // started by a non-secure manager
        job.irq_ev    = ch;
        job.prog_addr = dma_job::prog_base(ch);
        if (ch == 1) job.post_sev_ev = EV_CH1_DONE;
        dma_prog_gen::build(job);
        cfg.mem.write_bytes(job.prog_addr, job.prog.code);
        env.sb.add_prog_region(job.prog_addr, job.prog.code.size());
        env.sb.model_job(job);
        env.sb.add_job(job);
        env.cov.sample_job(job);
        bvseq.jobs.push_back(job);
      end

      mgr = dma330_asm::type_id::create("mgr_prog");
      mgr.dmanop();
      mgr.dmago(0, bvseq.jobs[0].prog_addr, 1);
      mgr.dmago(1, bvseq.jobs[1].prog_addr, 1);
      mgr.dmawfe(EV_CH1_DONE);
      mgr.dmawfe(dma_boot_vseq::EV_DBG);          // woken by a debug DMASEV while it waits
      mgr.dmasev(dma_boot_vseq::EV_MGR_DONE);
      bvseq.mgr_end_pc = BOOT_ADDR + mgr.pc();
      // A manager program ends with DMAEND or DMAKILL (both stop the manager)
      if ($urandom_range(1)) mgr.dmakill();
      else                   mgr.dmaend();
      cfg.mem.write_bytes(BOOT_ADDR, mgr.code);
      env.sb.add_prog_region(BOOT_ADDR, mgr.code.size());
      env.cov.sample_program(mgr.code);
      `uvm_info("BOOT", {"manager program:", mgr.sprint_listing()}, UVM_LOW)

      cfg.ctrl_vif.boot_from_pc    = 1'b1;
      cfg.ctrl_vif.boot_addr       = BOOT_ADDR;
      cfg.ctrl_vif.boot_manager_ns = 1'b1;
    endfunction

    virtual function dma_base_vseq create_vseq();
      return bvseq;
    endfunction
  endclass

endpackage : dma_test_pkg
