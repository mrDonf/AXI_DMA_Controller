//==============================================================================
// axi4_master_sva.sv
//------------------------------------------------------------------------------
// AXI4 protocol assertions for a MASTER port (what the DMA drives) plus the
// response-side rules the master relies on. Bound to the DUT's external AXI
// port in tb_top.
//
//   AXI_M_*  : master obligations (VALID/payload stability, legal bursts...)
//   AXI_S_*  : slave obligations observed at the same port
//==============================================================================
module axi4_master_sva #(
  parameter int ID_W     = 4,
  parameter int ADDR_W   = 32,
  parameter int DATA_W   = 64,
  parameter int MAX_LEN  = 15          // DMA-330 bursts are AXI3-compatible
) (
  input logic                aclk,
  input logic                aresetn,
  input logic                awvalid, awready,
  input logic [ID_W-1:0]     awid,
  input logic [ADDR_W-1:0]   awaddr,
  input logic [7:0]          awlen,
  input logic [2:0]          awsize,
  input logic [1:0]          awburst,
  input logic [3:0]          awcache,
  input logic [2:0]          awprot,
  input logic                wvalid, wready,
  input logic [DATA_W-1:0]   wdata,
  input logic [DATA_W/8-1:0] wstrb,
  input logic                wlast,
  input logic                bvalid, bready,
  input logic [ID_W-1:0]     bid,
  input logic [1:0]          bresp,
  input logic                arvalid, arready,
  input logic [ID_W-1:0]     arid,
  input logic [ADDR_W-1:0]   araddr,
  input logic [7:0]          arlen,
  input logic [2:0]          arsize,
  input logic [1:0]          arburst,
  input logic [3:0]          arcache,
  input logic [2:0]          arprot,
  input logic                rvalid, rready,
  input logic [ID_W-1:0]     rid,
  input logic [DATA_W-1:0]   rdata,
  input logic [1:0]          rresp,
  input logic                rlast
);

  localparam int MAX_SIZE = $clog2(DATA_W / 8);

  default clocking cb @(posedge aclk); endclocking
  default disable iff (!aresetn);

  //----------------------------------------------------------------------------
  // Helpers
  //----------------------------------------------------------------------------
  function automatic bit crosses_4k(input logic [ADDR_W-1:0] addr,
                                    input logic [7:0] len, input logic [2:0] size,
                                    input logic [1:0] burst);
    logic [ADDR_W-1:0] aligned, last;
    if (burst != 2'b01) return 1'b0;                        // only INCR advances
    aligned = addr & ~((ADDR_W'(1) << size) - 1);
    last    = aligned + ((ADDR_W'(len) + 1) << size) - 1;
    return aligned[ADDR_W-1:12] != last[ADDR_W-1:12];
  endfunction

  //----------------------------------------------------------------------------
  // Reset values
  //----------------------------------------------------------------------------
  // (disable iff is switched off: the default would disable this check exactly
  // while the reset it is about is active)
  AXI_M_NO_VALID_IN_RESET: assert property (@(posedge aclk) disable iff (1'b0)
      !aresetn |-> !awvalid && !wvalid && !arvalid);
  AXI_C_RESET_SEEN:        cover property (@(posedge aclk) disable iff (1'b0) !aresetn ##1 aresetn);

  AXI_M_VALID_KNOWN: assert property (
      !$isunknown({awvalid, wvalid, arvalid, bready, rready}));

  //----------------------------------------------------------------------------
  // VALID must stay asserted and payload stable until READY
  //----------------------------------------------------------------------------
  AXI_M_AW_STABLE: assert property (
      awvalid && !awready |=> awvalid &&
      $stable({awid, awaddr, awlen, awsize, awburst, awcache, awprot}));

  AXI_M_W_STABLE: assert property (
      wvalid && !wready |=> wvalid && $stable({wdata, wstrb, wlast}));

  AXI_M_AR_STABLE: assert property (
      arvalid && !arready |=> arvalid &&
      $stable({arid, araddr, arlen, arsize, arburst, arcache, arprot}));

  AXI_S_B_STABLE: assert property (
      bvalid && !bready |=> bvalid && $stable({bid, bresp}));

  AXI_S_R_STABLE: assert property (
      rvalid && !rready |=> rvalid && $stable({rid, rdata, rresp, rlast}));

  //----------------------------------------------------------------------------
  // Legal address-channel encodings
  //----------------------------------------------------------------------------
  AXI_M_AW_LEN:   assert property (awvalid |-> awlen <= MAX_LEN);
  AXI_M_AR_LEN:   assert property (arvalid |-> arlen <= MAX_LEN);
  AXI_M_AW_SIZE:  assert property (awvalid |-> awsize <= MAX_SIZE);
  AXI_M_AR_SIZE:  assert property (arvalid |-> arsize <= MAX_SIZE);
  AXI_M_AW_BURST: assert property (awvalid |-> awburst inside {2'b00, 2'b01});
  AXI_M_AR_BURST: assert property (arvalid |-> arburst inside {2'b00, 2'b01});
  AXI_M_AW_4KB:   assert property (awvalid |-> !crosses_4k(awaddr, awlen, awsize, awburst));
  AXI_M_AR_4KB:   assert property (arvalid |-> !crosses_4k(araddr, arlen, arsize, arburst));
  AXI_M_W_KNOWN:  assert property (wvalid  |-> !$isunknown({wstrb, wlast}));

  //----------------------------------------------------------------------------
  // WLAST position: W beats follow AW order (AXI4, no write interleaving).
  // AW and W may arrive in any order, so lengths are matched through queues.
  //----------------------------------------------------------------------------
  int unsigned aw_len_q [$];
  int unsigned w_len_q  [$];
  int unsigned w_beats;

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      aw_len_q.delete();
      w_len_q.delete();
      w_beats <= 0;
    end else begin
      if (awvalid && awready) aw_len_q.push_back(awlen + 1);
      if (wvalid && wready) begin
        if (wlast) begin
          w_len_q.push_back(w_beats + 1);
          w_beats <= 0;
        end else begin
          w_beats <= w_beats + 1;
        end
      end
      if (aw_len_q.size() > 0 && w_len_q.size() > 0) begin
        AXI_M_WLAST_POSITION: assert (aw_len_q[0] == w_len_q[0])
          else $error("WLAST after %0d beats, AWLEN+1 = %0d", w_len_q[0], aw_len_q[0]);
        void'(aw_len_q.pop_front());
        void'(w_len_q.pop_front());
      end
    end
  end

  //----------------------------------------------------------------------------
  // Coverage of interesting handshakes
  //----------------------------------------------------------------------------
  AXI_C_AW_BACKPRESSURE: cover property (awvalid && !awready ##1 awvalid && awready);
  AXI_C_W_BEFORE_AW:     cover property (wvalid && wready && !awvalid);
  AXI_C_R_INTERLEAVE:    cover property (rvalid && rready && !rlast ##1
                                         rvalid && rready && ($past(rid) != rid));
  AXI_C_FIXED_BURST:     cover property (arvalid && arready && arburst == 2'b00);

endmodule : axi4_master_sva
