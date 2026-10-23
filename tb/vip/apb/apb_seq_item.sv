//==============================================================================
// apb_seq_item.sv - one APB transfer
//==============================================================================
class apb_seq_item extends uvm_sequence_item;

  rand apb_kind_e             kind;
  rand bit [APB_ADDR_W-1:0]   addr;
  rand bit [APB_DATA_W-1:0]   data;      // write data, or read data (response)
  rand int unsigned           idle;      // idle cycles before the transfer
       bit                    slverr;    // response

  constraint c_idle  { idle inside {[0:3]}; }
  constraint c_align { addr[1:0] == 2'b00; }

  `uvm_object_utils_begin(apb_seq_item)
    `uvm_field_enum(apb_kind_e, kind, UVM_ALL_ON)
    `uvm_field_int (addr,   UVM_ALL_ON | UVM_HEX)
    `uvm_field_int (data,   UVM_ALL_ON | UVM_HEX)
    `uvm_field_int (idle,   UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int (slverr, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "apb_seq_item");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf("%s addr=0x%08h data=0x%08h%s",
                     kind.name(), addr, data, slverr ? " SLVERR" : "");
  endfunction

endclass : apb_seq_item
