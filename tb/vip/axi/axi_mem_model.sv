//==============================================================================
// axi_mem_model.sv - sparse byte-addressed memory shared by the slave driver,
// the test (backdoor program/data loading) and the scoreboard.
//
// Bytes never written return a deterministic address-derived pattern, so a
// read of uninitialised memory is still predictable by the reference model.
//==============================================================================
class axi_mem_model extends uvm_object;

  `uvm_object_utils(axi_mem_model)

  protected bit [7:0] mem [bit [AXI_ADDR_W-1:0]];

  function new(string name = "axi_mem_model");
    super.new(name);
  endfunction

  static function bit [7:0] default_byte(bit [AXI_ADDR_W-1:0] addr);
    return addr[7:0] ^ addr[15:8] ^ addr[23:16] ^ addr[31:24] ^ 8'h5A;
  endfunction

  function bit [7:0] read_byte(bit [AXI_ADDR_W-1:0] addr);
    return mem.exists(addr) ? mem[addr] : default_byte(addr);
  endfunction

  function void write_byte(bit [AXI_ADDR_W-1:0] addr, bit [7:0] data);
    mem[addr] = data;
  endfunction

  function void write_bytes(bit [AXI_ADDR_W-1:0] addr, const ref bit [7:0] data[$]);
    foreach (data[i]) mem[addr + i] = data[i];
  endfunction

  function void read_bytes(bit [AXI_ADDR_W-1:0] addr, int unsigned n, ref bit [7:0] data[$]);
    data.delete();
    for (int unsigned i = 0; i < n; i++) data.push_back(read_byte(addr + i));
  endfunction

  // Fill a region with random bytes
  function void randomize_region(bit [AXI_ADDR_W-1:0] addr, int unsigned n);
    for (int unsigned i = 0; i < n; i++) mem[addr + i] = $urandom();
  endfunction

  // One bus beat (all lanes) at an aligned address
  function bit [AXI_DATA_W-1:0] read_beat(bit [AXI_ADDR_W-1:0] addr);
    bit [AXI_ADDR_W-1:0] base = (addr / AXI_STRB_W) * AXI_STRB_W;
    bit [AXI_DATA_W-1:0] d;
    for (int k = 0; k < AXI_STRB_W; k++) d[k*8 +: 8] = read_byte(base + k);
    return d;
  endfunction

  function void write_beat(bit [AXI_ADDR_W-1:0] addr, bit [AXI_DATA_W-1:0] data,
                           bit [AXI_STRB_W-1:0] strb);
    bit [AXI_ADDR_W-1:0] base = (addr / AXI_STRB_W) * AXI_STRB_W;
    for (int k = 0; k < AXI_STRB_W; k++)
      if (strb[k]) mem[base + k] = data[k*8 +: 8];
  endfunction

endclass : axi_mem_model
