//==============================================================================
// periph_seq_lib.sv - peripheral request sequences
//==============================================================================

// Raise a given list of requests; the last one optionally carries drlast.
class periph_req_seq extends uvm_sequence #(periph_item);

  `uvm_object_utils(periph_req_seq)

  periph_req_e types [$];
  bit          last_on_final = 0;

  function new(string name = "periph_req_seq");
    super.new(name);
  endfunction

  virtual task body();
    foreach (types[i]) begin
      req = periph_item::type_id::create($sformatf("req%0d", i));
      // A flush acknowledge is normally only sent by the driver itself; allow
      // it explicitly when a test wants an unsolicited one
      req.c_type.constraint_mode(types[i] != PREQ_FLUSH_ACK);
      start_item(req);
      if (!req.randomize() with {
            req_type == local::types[i];
            last     == (local::last_on_final && i == local::types.size() - 1); })
        `uvm_fatal("RAND", "periph_req_seq randomize failed")
      finish_item(req);
    end
  endtask

endclass : periph_req_seq
