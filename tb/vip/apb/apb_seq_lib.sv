//==============================================================================
// apb_seq_lib.sv - basic APB sequences
//==============================================================================
class apb_base_seq extends uvm_sequence #(apb_seq_item);
  `uvm_object_utils(apb_base_seq)
  function new(string name = "apb_base_seq");
    super.new(name);
  endfunction
endclass

// Single write
class apb_write_seq extends apb_base_seq;
  `uvm_object_utils(apb_write_seq)

  rand bit [APB_ADDR_W-1:0] addr;
  rand bit [APB_DATA_W-1:0] data;
       bit                  slverr;

  function new(string name = "apb_write_seq");
    super.new(name);
  endfunction

  virtual task body();
    req = apb_seq_item::type_id::create("req");
    start_item(req);
    if (!req.randomize() with { kind == APB_WRITE; addr == local::addr; data == local::data; })
      `uvm_fatal("RAND", "apb_write_seq randomize failed")
    finish_item(req);
    slverr = req.slverr;
  endtask
endclass

// Single read; result in 'data'
class apb_read_seq extends apb_base_seq;
  `uvm_object_utils(apb_read_seq)

  rand bit [APB_ADDR_W-1:0] addr;
       bit [APB_DATA_W-1:0] data;
       bit                  slverr;

  function new(string name = "apb_read_seq");
    super.new(name);
  endfunction

  virtual task body();
    req = apb_seq_item::type_id::create("req");
    start_item(req);
    if (!req.randomize() with { kind == APB_READ; addr == local::addr; })
      `uvm_fatal("RAND", "apb_read_seq randomize failed")
    finish_item(req);
    data   = req.data;
    slverr = req.slverr;
  endtask
endclass
