//==============================================================================
// apb_reg_adapter.sv - UVM register layer <-> APB transfers
//==============================================================================
class apb_reg_adapter extends uvm_reg_adapter;

  `uvm_object_utils(apb_reg_adapter)

  function new(string name = "apb_reg_adapter");
    super.new(name);
    supports_byte_enable = 0;
    provides_responses   = 0;   // driver fills read data into the request
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    apb_seq_item t = apb_seq_item::type_id::create("apb_reg_item");
    t.kind = (rw.kind == UVM_WRITE) ? APB_WRITE : APB_READ;
    t.addr = rw.addr;
    t.data = rw.data;
    t.idle = 0;
    return t;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    apb_seq_item t;
    if (!$cast(t, bus_item))
      `uvm_fatal("CAST", "bus2reg: not an apb_seq_item")
    rw.kind   = (t.kind == APB_WRITE) ? UVM_WRITE : UVM_READ;
    rw.addr   = t.addr;
    rw.data   = t.data;
    rw.status = t.slverr ? UVM_NOT_OK : UVM_IS_OK;
  endfunction

endclass : apb_reg_adapter
