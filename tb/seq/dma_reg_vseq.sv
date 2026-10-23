//==============================================================================
// dma_reg_vseq.sv - register map checks
//   1. built-in UVM reset-value check of every register
//   2. built-in UVM bit-bash of the writable registers
//   3. identification registers and configuration registers
//   4. PSLVERR: with APB_SLVERR = 1 unmapped accesses and writes to read-only
//      registers return an error and have no effect; otherwise never
//==============================================================================
class dma_reg_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_reg_vseq)

  function new(string name = "dma_reg_vseq");
    super.new(name);
  endfunction

  virtual task body();
    uvm_reg_hw_reset_seq reset_seq;
    uvm_reg_bit_bash_seq bash_seq;
    uvm_reg_data_t       v;
    bit [31:0]           id;

    reset_seq = uvm_reg_hw_reset_seq::type_id::create("reset_seq");
    reset_seq.model = rm;
    reset_seq.start(null, this);

    bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq");
    bash_seq.model = rm;
    bash_seq.start(null, this);

    // Identification registers, one byte per word
    id = 0;
    foreach (rm.PCELL_ID[k]) begin
      reg_rd(rm.PCELL_ID[k], v);
      id[k*8 +: 8] = v[7:0];
    end
    if (id != 32'hB105_F00D)
      `uvm_error("REGCHK", $sformatf("PrimeCell ID 0x%08h != 0xB105F00D", id))

    // Status registers after reset: manager and channels stopped, no faults
    reg_rd(rm.DSR, v);
    if (v[3:0] != dma330_pkg::ST_STOPPED) `uvm_error("REGCHK", "manager not stopped after reset")
    foreach (rm.CSR[n]) begin
      reg_rd(rm.CSR[n], v);
      if (v[3:0] != dma330_pkg::ST_STOPPED) `uvm_error("REGCHK", $sformatf("ch%0d not stopped", n))
    end

    // DBGCMD values other than 0 ("execute") are reserved and ignored
    reg_wr(rm.DBGINST0, 32'h0001_0000);                  // would be DMAKILL to the manager
    reg_wr(rm.DBGCMD, 2'b01);
    reg_rd(rm.DBGSTATUS, v);
    if (v[0]) `uvm_error("REGCHK", "reserved DBGCMD value started a debug instruction")
    reg_rd(rm.DSR, v);
    if (v[3:0] != dma330_pkg::ST_STOPPED) `uvm_error("REGCHK", "reserved DBGCMD value changed the manager")

    // Unmapped addresses read as zero (raw APB access, outside the RAL)
    begin
      bit [31:0]            unmapped [3] = '{32'h200, 32'h8F0, 32'hC00};
      apb_pkg::apb_read_seq rd = apb_pkg::apb_read_seq::type_id::create("rd_unmapped");
      foreach (unmapped[i]) begin
        rd.addr = unmapped[i];
        rd.start(p_sequencer.apb_sqr, this);
        if (rd.data != 0)
          `uvm_error("REGCHK", $sformatf("unmapped 0x%03h reads 0x%08h", rd.addr, rd.data))
      end
    end
    check_slverr();
    `uvm_info("REGCHK", "register checks finished", UVM_LOW)
  endtask

  protected task raw_rd(bit [31:0] addr, output bit [31:0] data, output bit err);
    apb_pkg::apb_read_seq rd = apb_pkg::apb_read_seq::type_id::create("raw_rd");
    rd.addr = addr;
    rd.start(p_sequencer.apb_sqr, this);
    data = rd.data;
    err  = rd.slverr;
  endtask

  protected task raw_wr(bit [31:0] addr, bit [31:0] data, output bit err);
    apb_pkg::apb_write_seq wr = apb_pkg::apb_write_seq::type_id::create("raw_wr");
    wr.addr = addr;
    wr.data = data;
    wr.start(p_sequencer.apb_sqr, this);
    err = wr.slverr;
  endtask

  protected task check_slverr();
    bit        en = p_sequencer.cfg.apb_slverr;
    bit        err;
    bit [31:0] d;
    int unsigned n = dma_tb_params_pkg::NUM_CH;
    bit [31:0]   unmapped [4] = '{32'h200, 32'h8F0, 32'hC00, 32'hE88};
    bit [31:0]   ro_regs  [6] = '{32'h000, 32'h038, 32'h040, 32'h060, 32'hE00, 32'hFF0};

    // Unmapped addresses: read as zero, error only with APB_SLVERR
    foreach (unmapped[i]) begin
      bit [31:0] a = unmapped[i];
      raw_rd(a, d, err);
      if (err != en) `uvm_error("REGCHK", $sformatf("read 0x%03h: PSLVERR=%0b, expected %0b", a, err, en))
      raw_wr(a, 32'hFFFF_FFFF, err);
      if (err != en) `uvm_error("REGCHK", $sformatf("write 0x%03h: PSLVERR=%0b, expected %0b", a, err, en))
    end
    // Registers of a channel that does not exist are unmapped
    if (n < 8) begin
      raw_rd(32'h100 + 8 * n, d, err);
      if (err != en) `uvm_error("REGCHK", $sformatf("CSR%0d (absent): PSLVERR=%0b", n, err))
    end
    // Writes to read-only registers: error with APB_SLVERR, never any effect
    foreach (ro_regs[i]) begin
      bit [31:0] a = ro_regs[i];
      bit [31:0] v_old, v_new;
      raw_rd(a, v_old, err);
      if (err) `uvm_error("REGCHK", $sformatf("read of mapped 0x%03h returned PSLVERR", a))
      raw_wr(a, ~v_old, err);
      if (err != en) `uvm_error("REGCHK", $sformatf("write to RO 0x%03h: PSLVERR=%0b, expected %0b", a, err, en))
      raw_rd(a, v_new, err);
      if (v_new != v_old) `uvm_error("REGCHK", $sformatf("write to RO 0x%03h changed it", a))
    end
    // A rejected write to a writable register would be a bug: legal writes OK
    raw_wr(32'h020, 32'h0000_00A5, err);
    if (err) `uvm_error("REGCHK", "legal write to INTEN returned PSLVERR")
    raw_wr(32'h020, 0, err);
    `uvm_info("REGCHK", $sformatf("PSLVERR behaviour checked (APB_SLVERR=%0b)", en), UVM_LOW)
  endtask

endclass : dma_reg_vseq
