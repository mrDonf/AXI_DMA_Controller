//==============================================================================
// periph_item.sv
//   As a sequence item : one request the peripheral raises (type, last, delay)
//   As a monitor item  : an observed request (PER_REQ) or acknowledge (PER_ACK)
//==============================================================================
class periph_item extends uvm_sequence_item;

  rand periph_req_e   req_type;
  rand bit            last;
  rand int unsigned   delay;          // idle cycles before raising the request

  // Monitor fields
  periph_dir_e        dir;
  periph_ack_e        ack_type;
  int                 periph_id;

  constraint c_delay { delay inside {[0:8]}; }
  constraint c_type  { req_type != PREQ_FLUSH_ACK; }

  `uvm_object_utils_begin(periph_item)
    `uvm_field_enum(periph_req_e, req_type, UVM_ALL_ON)
    `uvm_field_int (last,                   UVM_ALL_ON)
    `uvm_field_int (delay,                  UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_enum(periph_dir_e, dir,      UVM_ALL_ON)
    `uvm_field_enum(periph_ack_e, ack_type, UVM_ALL_ON)
    `uvm_field_int (periph_id,              UVM_ALL_ON | UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "periph_item");
    super.new(name);
  endfunction

  virtual function string convert2string();
    if (dir == PER_ACK)
      return $sformatf("periph%0d ACK %s", periph_id, ack_type.name());
    return $sformatf("periph%0d REQ %s%s", periph_id, req_type.name(), last ? " LAST" : "");
  endfunction

endclass : periph_item
