//==============================================================================
// axi_txn.sv - one AXI burst (address phase + all data beats + response)
//==============================================================================
class axi_txn extends uvm_sequence_item;

  axi_dir_e                 dir;
  bit [AXI_ID_W-1:0]        id;
  bit [AXI_ADDR_W-1:0]      addr;
  bit [7:0]                 len;          // beats - 1
  bit [2:0]                 size;
  axi_burst_e               burst;
  bit                       lock;
  bit [3:0]                 cache;
  bit [2:0]                 prot;
  bit [AXI_DATA_W-1:0]      data [$];     // one entry per beat
  bit [AXI_STRB_W-1:0]      strb [$];     // write strobes per beat
  axi_resp_e                resp [$];     // R: per beat, B: one entry

  // VIP bookkeeping (not compared)
  time                      start_time;
  time                      end_time;
  int unsigned              ready_cycle;  // slave: earliest response cycle
  int unsigned              beat_idx;     // slave: next beat to return

  `uvm_object_utils_begin(axi_txn)
    `uvm_field_enum (axi_dir_e,   dir,   UVM_ALL_ON)
    `uvm_field_int  (id,                 UVM_ALL_ON | UVM_HEX)
    `uvm_field_int  (addr,               UVM_ALL_ON | UVM_HEX)
    `uvm_field_int  (len,                UVM_ALL_ON | UVM_DEC)
    `uvm_field_int  (size,               UVM_ALL_ON | UVM_DEC)
    `uvm_field_enum (axi_burst_e, burst, UVM_ALL_ON)
    `uvm_field_int  (lock,               UVM_ALL_ON)
    `uvm_field_int  (cache,              UVM_ALL_ON | UVM_HEX)
    `uvm_field_int  (prot,               UVM_ALL_ON | UVM_HEX)
    `uvm_field_queue_int (data,          UVM_ALL_ON | UVM_HEX)
    `uvm_field_queue_int (strb,          UVM_ALL_ON | UVM_HEX)
    `uvm_field_queue_enum(axi_resp_e, resp, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "axi_txn");
    super.new(name);
  endfunction

  function int unsigned num_beats();
    return int'(len) + 1;
  endfunction

  function int unsigned bytes_per_beat();
    return 1 << size;
  endfunction

  // Address of beat i, per AXI4 rules (FIXED / INCR / WRAP)
  function bit [AXI_ADDR_W-1:0] beat_addr(int unsigned i);
    bit [AXI_ADDR_W-1:0] nbytes, aligned, wrap_size, wrap_base, a;
    nbytes  = bytes_per_beat();
    aligned = (addr / nbytes) * nbytes;
    case (burst)
      AXI_FIXED: return addr;
      AXI_INCR:  return (i == 0) ? addr : aligned + i * nbytes;
      default: begin
        wrap_size = nbytes * num_beats();
        wrap_base = (addr / wrap_size) * wrap_size;
        a         = aligned + i * nbytes;
        if (a >= wrap_base + wrap_size) a -= wrap_size;
        return (i == 0) ? addr : a;
      end
    endcase
  endfunction

  // Byte lanes [lo, hi] that are valid for beat i (narrow / unaligned rules)
  function void beat_lanes(int unsigned i, output int unsigned lo, output int unsigned hi);
    bit [AXI_ADDR_W-1:0] a;
    int unsigned nbytes;
    a      = beat_addr(i);
    nbytes = bytes_per_beat();
    lo     = a % AXI_STRB_W;
    hi     = ((a / nbytes) * nbytes) % AXI_STRB_W + nbytes - 1;
  endfunction

  virtual function string convert2string();
    string s;
    s = $sformatf("%s id=%0h addr=0x%08h len=%0d size=%0d %s cache=%0h prot=%0h",
                  dir.name(), id, addr, len, size, burst.name(), cache, prot);
    foreach (data[i]) begin
      s = {s, $sformatf("\n    beat%0d data=%h", i, data[i])};
      if (dir == AXI_WRITE && i < strb.size()) s = {s, $sformatf(" strb=%h", strb[i])};
      if (dir == AXI_READ  && i < resp.size()) s = {s, $sformatf(" %s", resp[i].name())};
    end
    if (dir == AXI_WRITE && resp.size() > 0) s = {s, $sformatf("\n    bresp=%s", resp[0].name())};
    return s;
  endfunction

endclass : axi_txn
