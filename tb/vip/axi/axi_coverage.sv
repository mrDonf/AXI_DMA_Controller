//==============================================================================
// axi_coverage.sv - functional coverage of observed AXI bursts
//==============================================================================
class axi_coverage extends uvm_subscriber #(axi_txn);

  `uvm_component_utils(axi_coverage)

  axi_txn      t;
  int unsigned addr_off;     // start address offset inside one beat
  bit          narrow;       // beat narrower than the bus
  axi_resp_e   rsp;

  covergroup cg_burst;
    option.per_instance = 1;
    cp_dir   : coverpoint t.dir;
    cp_len   : coverpoint t.len   { bins single = {0}; bins short_b = {[1:3]};
                                    bins mid_b = {[4:7]}; bins long_b = {[8:15]}; }
    cp_size  : coverpoint t.size  { bins s[] = {[0:$clog2(AXI_STRB_W)]}; }
    cp_burst : coverpoint t.burst { bins fixed = {AXI_FIXED}; bins incr = {AXI_INCR}; }
    cp_align : coverpoint addr_off { bins aligned = {0}; bins unaligned = {[1:$]}; }
    cp_narrow: coverpoint narrow;
    cp_resp  : coverpoint rsp     { bins okay = {AXI_OKAY}; bins slverr = {AXI_SLVERR};
                                    bins decerr = {AXI_DECERR}; }
    x_dir_len_size : cross cp_dir, cp_len, cp_size;
    x_dir_burst    : cross cp_dir, cp_burst;
    x_dir_align    : cross cp_dir, cp_align;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_burst = new();
  endfunction

  virtual function void write(axi_txn t);
    this.t   = t;
    addr_off = t.addr % t.bytes_per_beat();
    narrow   = t.bytes_per_beat() < AXI_STRB_W;
    rsp      = AXI_OKAY;
    foreach (t.resp[i]) if (t.resp[i] != AXI_OKAY) rsp = t.resp[i];
    cg_burst.sample();
  endfunction

endclass : axi_coverage
