//==============================================================================
// axi_config.sv - AXI slave agent configuration (timing knobs, error map)
//==============================================================================
class axi_config extends uvm_object;

  axi_vif_t               vif;
  uvm_active_passive_enum is_active    = UVM_ACTIVE;
  bit                     has_coverage = 1;
  axi_mem_model           mem;

  // Handshake timing: probability (percent) that READY is high in a cycle
  int unsigned aw_ready_pct = 70;
  int unsigned w_ready_pct  = 70;
  int unsigned ar_ready_pct = 70;
  // Response latency in cycles after the request is complete
  int unsigned b_lat_min = 1, b_lat_max = 8;
  int unsigned r_lat_min = 1, r_lat_max = 10;
  // Probability (percent) of an idle cycle between read beats
  int unsigned r_gap_pct = 15;
  // Out-of-order responses across IDs and interleaved read data
  bit          reorder_en    = 1;
  bit          interleave_en = 1;

  // Error response regions
  typedef struct {
    bit [AXI_ADDR_W-1:0] lo;
    bit [AXI_ADDR_W-1:0] hi;
    axi_resp_e           resp;
    bit                  on_read;
    bit                  on_write;
  } err_region_t;

  err_region_t err_regions [$];

  // Stall regions: B / R responses of bursts starting inside a region are
  // held back until the region is removed (models a hung slave)
  typedef struct {
    bit [AXI_ADDR_W-1:0] lo;
    bit [AXI_ADDR_W-1:0] hi;
  } stall_region_t;

  stall_region_t stall_regions [$];

  // Secure-only regions: a non-secure read (ARPROT[1] = 1) returns zeros
  // (models a TrustZone filter in front of secure memory)
  stall_region_t ns_raz_regions [$];

  `uvm_object_utils_begin(axi_config)
    `uvm_field_enum(uvm_active_passive_enum, is_active, UVM_ALL_ON)
    `uvm_field_int (aw_ready_pct,  UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (w_ready_pct,   UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (ar_ready_pct,  UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (b_lat_min,     UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (b_lat_max,     UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (r_lat_min,     UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (r_lat_max,     UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (r_gap_pct,     UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (reorder_en,    UVM_ALL_ON)
    `uvm_field_int (interleave_en, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "axi_config");
    super.new(name);
  endfunction

  // Moderate random back-pressure (construction defaults)
  function void set_default();
    aw_ready_pct = 70; w_ready_pct = 70; ar_ready_pct = 70;
    b_lat_min = 1; b_lat_max = 8; r_lat_min = 1; r_lat_max = 10; r_gap_pct = 15;
  endfunction

  // Fast, no-backpressure profile
  function void set_fast();
    aw_ready_pct = 100; w_ready_pct = 100; ar_ready_pct = 100;
    b_lat_min = 0; b_lat_max = 1; r_lat_min = 0; r_lat_max = 1; r_gap_pct = 0;
  endfunction

  // Heavy back-pressure / latency profile
  function void set_slow();
    aw_ready_pct = 30; w_ready_pct = 30; ar_ready_pct = 30;
    b_lat_min = 2; b_lat_max = 30; r_lat_min = 2; r_lat_max = 30; r_gap_pct = 40;
  endfunction

  // Choked slave: address/data channels accept rarely and answers are slow, so
  // the DMA's outstanding queues and the CDC FIFOs behind AW / AR fill up
  function void set_choke();
    aw_ready_pct = 10; w_ready_pct = 25; ar_ready_pct = 10;
    b_lat_min = 5; b_lat_max = 40; r_lat_min = 5; r_lat_max = 40; r_gap_pct = 50;
  endfunction

  function void add_err_region(bit [AXI_ADDR_W-1:0] lo, bit [AXI_ADDR_W-1:0] hi,
                               axi_resp_e resp, bit on_read = 1, bit on_write = 1);
    err_region_t r;
    r.lo = lo; r.hi = hi; r.resp = resp; r.on_read = on_read; r.on_write = on_write;
    err_regions.push_back(r);
  endfunction

  function void clear_err_regions();
    err_regions.delete();
  endfunction

  function void add_stall_region(bit [AXI_ADDR_W-1:0] lo, bit [AXI_ADDR_W-1:0] hi);
    stall_region_t r;
    r.lo = lo; r.hi = hi;
    stall_regions.push_back(r);
  endfunction

  function void clear_stall_regions();
    stall_regions.delete();
  endfunction

  function void add_ns_raz_region(bit [AXI_ADDR_W-1:0] lo, bit [AXI_ADDR_W-1:0] hi);
    stall_region_t r;
    r.lo = lo; r.hi = hi;
    ns_raz_regions.push_back(r);
  endfunction

  function void clear_ns_raz_regions();
    ns_raz_regions.delete();
  endfunction

  function bit ns_raz(bit [AXI_ADDR_W-1:0] addr);
    foreach (ns_raz_regions[i])
      if (addr >= ns_raz_regions[i].lo && addr <= ns_raz_regions[i].hi) return 1;
    return 0;
  endfunction

  function bit is_stalled(bit [AXI_ADDR_W-1:0] addr);
    foreach (stall_regions[i])
      if (addr >= stall_regions[i].lo && addr <= stall_regions[i].hi) return 1;
    return 0;
  endfunction

  // Response for one beat address
  function axi_resp_e lookup_resp(bit [AXI_ADDR_W-1:0] addr, bit is_write);
    foreach (err_regions[i]) begin
      if (addr >= err_regions[i].lo && addr <= err_regions[i].hi &&
          (is_write ? err_regions[i].on_write : err_regions[i].on_read))
        return err_regions[i].resp;
    end
    return AXI_OKAY;
  endfunction

endclass : axi_config
