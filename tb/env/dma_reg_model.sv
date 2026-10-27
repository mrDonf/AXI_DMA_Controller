//==============================================================================
// dma_reg_model.sv - UVM register model of the DMA-330 style register map
//==============================================================================

//------------------------------------------------------------------------------
// Generic 32-bit registers with one field
//------------------------------------------------------------------------------
class dma_reg32 extends uvm_reg;
  `uvm_object_utils(dma_reg32)

  rand uvm_reg_field value;

  function new(string name = "dma_reg32");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  // access: "RO", "RW", "WO"
  function void build(string access, uvm_reg_data_t reset = 0, bit volatile = 0,
                      int unsigned width = 32);
    value = uvm_reg_field::type_id::create("value");
    value.configure(this, width, 0, access, volatile, reset, 1, 1, 1);
  endfunction
endclass

//------------------------------------------------------------------------------
// DSR - manager status
//------------------------------------------------------------------------------
class dma_reg_dsr extends uvm_reg;
  `uvm_object_utils(dma_reg_dsr)
  uvm_reg_field status, wakeup_event, dns;

  function new(string name = "dma_reg_dsr");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  function void build();
    status       = uvm_reg_field::type_id::create("status");
    wakeup_event = uvm_reg_field::type_id::create("wakeup_event");
    dns          = uvm_reg_field::type_id::create("dns");
    status.configure      (this, 4, 0, "RO", 1, 0, 1, 0, 0);
    wakeup_event.configure(this, 5, 4, "RO", 1, 0, 1, 0, 0);
    dns.configure         (this, 1, 9, "RO", 1, 0, 1, 0, 0);
  endfunction
endclass

//------------------------------------------------------------------------------
// CSRn - channel status
//------------------------------------------------------------------------------
class dma_reg_csr extends uvm_reg;
  `uvm_object_utils(dma_reg_csr)
  uvm_reg_field status, wakeup_number, dmawfp_b_ns, dmawfp_periph, cns;

  function new(string name = "dma_reg_csr");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  function void build();
    status        = uvm_reg_field::type_id::create("status");
    wakeup_number = uvm_reg_field::type_id::create("wakeup_number");
    dmawfp_b_ns   = uvm_reg_field::type_id::create("dmawfp_b_ns");
    dmawfp_periph = uvm_reg_field::type_id::create("dmawfp_periph");
    cns           = uvm_reg_field::type_id::create("cns");
    status.configure       (this, 4, 0,  "RO", 1, 0, 1, 0, 0);
    wakeup_number.configure(this, 5, 4,  "RO", 1, 0, 1, 0, 0);
    dmawfp_b_ns.configure  (this, 1, 14, "RO", 1, 0, 1, 0, 0);
    dmawfp_periph.configure(this, 1, 15, "RO", 1, 0, 1, 0, 0);
    cns.configure          (this, 1, 21, "RO", 1, 0, 1, 0, 0);
  endfunction
endclass

//------------------------------------------------------------------------------
// DBGINST0
//------------------------------------------------------------------------------
class dma_reg_dbginst0 extends uvm_reg;
  `uvm_object_utils(dma_reg_dbginst0)
  rand uvm_reg_field debug_thread, channel, instr_byte0, instr_byte1;

  function new(string name = "dma_reg_dbginst0");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  function void build();
    debug_thread = uvm_reg_field::type_id::create("debug_thread");
    channel      = uvm_reg_field::type_id::create("channel");
    instr_byte0  = uvm_reg_field::type_id::create("instr_byte0");
    instr_byte1  = uvm_reg_field::type_id::create("instr_byte1");
    debug_thread.configure(this, 1, 0,  "RW", 0, 0, 1, 1, 0);
    channel.configure     (this, 3, 8,  "RW", 0, 0, 1, 1, 0);
    instr_byte0.configure (this, 8, 16, "RW", 0, 0, 1, 1, 0);
    instr_byte1.configure (this, 8, 24, "RW", 0, 0, 1, 1, 0);
  endfunction
endclass

//------------------------------------------------------------------------------
// WD - watchdog: [0] irq_only, [31:16] timeout (x256 core clocks, 0 = off)
//------------------------------------------------------------------------------
class dma_reg_wd extends uvm_reg;
  `uvm_object_utils(dma_reg_wd)
  rand uvm_reg_field irq_only, timeout;

  function new(string name = "dma_reg_wd");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  function void build();
    irq_only = uvm_reg_field::type_id::create("irq_only");
    timeout  = uvm_reg_field::type_id::create("timeout");
    irq_only.configure(this, 1,  0,  "RW", 0, 0, 1, 1, 0);
    timeout.configure (this, 16, 16, "RW", 0, 0, 1, 1, 0);
  endfunction
endclass

//------------------------------------------------------------------------------
// Register block
//------------------------------------------------------------------------------
class dma_reg_block extends uvm_reg_block;
  `uvm_object_utils(dma_reg_block)

  dma_reg_dsr      DSR;
  dma_reg32        DPC;
  dma_reg32        INTEN;
  dma_reg32        INT_EVENT_RIS;
  dma_reg32        INTMIS;
  dma_reg32        INTCLR;
  dma_reg32        FSRD;
  dma_reg32        FSRC;
  dma_reg32        FTRD;
  dma_reg32        FTR [];
  dma_reg32        FAR [];
  dma_reg_csr      CSR [];
  dma_reg32        CPC [];
  dma_reg32        SAR [];
  dma_reg32        DAR [];
  dma_reg32        CCR [];
  dma_reg32        LC0 [];
  dma_reg32        LC1 [];
  dma_reg32        DBGSTATUS;
  dma_reg32        DBGCMD;
  dma_reg_dbginst0 DBGINST0;
  dma_reg32        DBGINST1;
  dma_reg32        CR0, CR1, CR2, CR3, CR4, CRD;
  dma_reg_wd       WD;
  dma_reg32        WDSTAT;
  dma_reg32        PERIPH_ID [4];
  dma_reg32        PCELL_ID  [4];

  int unsigned     num_ch;

  function new(string name = "dma_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  // Helper: create, build and map a single-field register
  protected function dma_reg32 add32(string name, uvm_reg_addr_t offset, string access,
                                     uvm_reg_data_t reset = 0, bit volatile = 0,
                                     int unsigned width = 32);
    dma_reg32 r = dma_reg32::type_id::create(name);
    r.configure(this);
    r.build(access, reset, volatile, width);
    // W1C is a field policy. Map rights accept only RO/WO/RW; the field
    // still retains its W1C prediction and write behaviour.
    default_map.add_reg(r, offset, access == "W1C" ? "RW" : access);
    return r;
  endfunction

  function void build(int unsigned num_ch, int unsigned num_events,
                      uvm_reg_data_t cr0, uvm_reg_data_t cr1, uvm_reg_data_t crd,
                      bit [31:0] periph_id, bit slverr_en = 0);
    this.num_ch = num_ch;
    default_map = create_map("apb_map", 'h0, 4, UVM_LITTLE_ENDIAN, 1);

    DSR = dma_reg_dsr::type_id::create("DSR");
    DSR.configure(this);
    DSR.build();
    default_map.add_reg(DSR, 'h000, "RO");

    DPC           = add32("DPC",           'h004, "RO", 0, 1);
    INTEN         = add32("INTEN",         'h020, "RW", 0, 0, num_events);
    INT_EVENT_RIS = add32("INT_EVENT_RIS", 'h024, "RO", 0, 1);
    INTMIS        = add32("INTMIS",        'h028, "RO", 0, 1);
    INTCLR        = add32("INTCLR",        'h02C, "WO");
    FSRD          = add32("FSRD",          'h030, "RO", 0, 1);
    FSRC          = add32("FSRC",          'h034, "RO", 0, 1);
    FTRD          = add32("FTRD",          'h038, "RO", 0, 1);

    FTR = new[num_ch]; FAR = new[num_ch]; CSR = new[num_ch]; CPC = new[num_ch];
    SAR = new[num_ch]; DAR = new[num_ch]; CCR = new[num_ch];
    LC0 = new[num_ch]; LC1 = new[num_ch];
    for (int n = 0; n < num_ch; n++) begin
      FTR[n] = add32($sformatf("FTR%0d", n), 'h040 + 4*n, "RO", 0, 1);
      FAR[n] = add32($sformatf("FAR%0d", n), 'h060 + 4*n, "RO", 0, 1);
      CSR[n] = dma_reg_csr::type_id::create($sformatf("CSR%0d", n));
      CSR[n].configure(this);
      CSR[n].build();
      default_map.add_reg(CSR[n], 'h100 + 8*n, "RO");
      CPC[n] = add32($sformatf("CPC%0d", n), 'h104 + 8*n, "RO", 0, 1);
      SAR[n] = add32($sformatf("SAR%0d", n), 'h400 + 'h20*n, "RO", 0, 1);
      DAR[n] = add32($sformatf("DAR%0d", n), 'h404 + 'h20*n, "RO", 0, 1);
      CCR[n] = add32($sformatf("CCR%0d", n), 'h408 + 'h20*n, "RO", 'h0080_0200, 1);  // TRM reset value
      LC0[n] = add32($sformatf("LC0_%0d", n), 'h40C + 'h20*n, "RO", 0, 1);
      LC1[n] = add32($sformatf("LC1_%0d", n), 'h410 + 'h20*n, "RO", 0, 1);
    end

    DBGSTATUS = add32("DBGSTATUS", 'hD00, "RO", 0, 1);
    DBGCMD    = add32("DBGCMD",    'hD04, "WO");
    DBGINST0  = dma_reg_dbginst0::type_id::create("DBGINST0");
    DBGINST0.configure(this);
    DBGINST0.build();
    default_map.add_reg(DBGINST0, 'hD08, "RW");
    DBGINST1  = add32("DBGINST1",  'hD0C, "RW");

    CR0 = add32("CR0", 'hE00, "RO", cr0);
    CR1 = add32("CR1", 'hE04, "RO", cr1);
    CR2 = add32("CR2", 'hE08, "RO", 0, 1);
    CR3 = add32("CR3", 'hE0C, "RO", 0, 1);           // boot_irq_ns / boot_periph_ns: set per test
    CR4 = add32("CR4", 'hE10, "RO", 0, 1);
    CRD = add32("CRD", 'hE14, "RO", crd);
    WD = dma_reg_wd::type_id::create("WD");
    WD.configure(this);
    WD.build();
    default_map.add_reg(WD, 'hE80, "RW");
    WDSTAT = add32("WDSTAT", 'hE84, "W1C", 0, 1, num_ch);

    for (int k = 0; k < 4; k++) begin
      PERIPH_ID[k] = add32($sformatf("PERIPH_ID_%0d", k), 'hFE0 + 4*k, "RO", periph_id[k*8 +: 8]);
      PCELL_ID[k]  = add32($sformatf("PCELL_ID_%0d", k),  'hFF0 + 4*k, "RO", (32'hB105F00D >> (8*k)) & 'hFF);
    end

    // Writing DBGCMD/INTCLR has side effects: keep them out of generic tests
    uvm_resource_db #(bit)::set({"REG::", DBGCMD.get_full_name()}, "NO_REG_TESTS", 1, this);
    uvm_resource_db #(bit)::set({"REG::", INTCLR.get_full_name()}, "NO_REG_TESTS", 1, this);

    lock_model();

    // With PSLVERR reporting, a write to a read-only register is an error
    // response: bit-bash only the writable registers
    if (slverr_en) begin
      uvm_reg regs[$];
      get_registers(regs);
      foreach (regs[i]) begin
        uvm_reg_field f[$];
        bit any_w = 0;
        regs[i].get_fields(f);
        foreach (f[k]) if (f[k].get_access(default_map) != "RO") any_w = 1;
        if (!any_w)
          uvm_resource_db #(bit)::set({"REG::", regs[i].get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
      end
    end
  endfunction

endclass : dma_reg_block
