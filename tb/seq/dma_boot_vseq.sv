//==============================================================================
// dma_boot_vseq.sv - manager thread booted from memory (boot_from_pc = 1)
//
// The test prepares everything before reset is released:
//   manager program @ boot_addr :  DMAGO ch0 (ns) ; DMAGO ch1 (ns)
//                                  DMAWFE 12      ; DMASEV 11 ; DMAEND
//   ch1's program ends with DMASEV 12 (event for the manager)
// This sequence then checks completion, and finally uses the non-secure
// manager to provoke a dmago_err (DMAGO to a secure channel).
//==============================================================================
class dma_boot_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_boot_vseq)

  dma_job      jobs [$];
  bit [31:0]   mgr_end_pc;
  localparam int EV_MGR_DONE = 11;

  function new(string name = "dma_boot_vseq");
    super.new(name);
  endfunction

  virtual task body();
    uvm_reg_data_t v;

    reg_wr(rm.INTEN, (1 << EV_MGR_DONE) | ((1 << dma_tb_params_pkg::NUM_CH) - 1));
    wait_irq(EV_MGR_DONE);
    clear_irq(EV_MGR_DONE);

    foreach (jobs[i]) begin
      wait_irq(jobs[i].irq_ev);
      clear_irq(jobs[i].irq_ev);
      wait_ch_status(jobs[i].ch, dma330_pkg::ST_STOPPED);
      p_sequencer.sb.job_done(jobs[i]);
      reg_rd(rm.CSR[jobs[i].ch], v);
      if (!v[21]) `uvm_error("BOOT", $sformatf("ch%0d should run non-secure (CSR.CNS)", jobs[i].ch))
    end

    // Manager: stopped at its DMAEND, non-secure
    vif.wait_clks(50);
    reg_rd(rm.DSR, v);
    if (v[3:0] != dma330_pkg::ST_STOPPED || !v[9])
      `uvm_error("BOOT", $sformatf("DSR=0x%08h, expected stopped + DNS", v))
    reg_rd(rm.DPC, v);
    if (v != mgr_end_pc)
      `uvm_error("BOOT", $sformatf("DPC=0x%08h, expected 0x%08h", v, mgr_end_pc))
    reg_rd(rm.CR0, v);
    if (!v[1] || !v[2]) `uvm_error("BOOT", "CR0 boot_en / mgr_ns_at_rst not reported")

    // Debug DMAKILL to a stopped manager is harmless
    kill_manager();
    reg_rd(rm.DSR, v);
    if (v[3:0] != dma330_pkg::ST_STOPPED) `uvm_error("BOOT", "debug DMAKILL disturbed a stopped manager")

    // Non-secure manager may not start a secure channel -> dmago_err
    dbg_exec(0, 0, '{8'hA0, 8'd2, 8'h00, 8'h00, 8'h01, 8'h00});
    wait_abort();
    reg_rd(rm.FTRD, v);
    if (!v[dma330_pkg::FTD_DMAGO_ERR]) `uvm_error("BOOT", $sformatf("FTRD=0x%08h, dmago_err expected", v))
    p_sequencer.cov.sample_fault(v, 1);
    kill_manager();
    vif.wait_clks(20);
    reg_rd(rm.FSRD, v);
    if (v[0]) `uvm_error("BOOT", "manager still faulting after DMAKILL")
    `uvm_info("BOOT", "boot-from-PC flow and dmago_err OK", UVM_LOW)
  endtask

endclass : dma_boot_vseq
