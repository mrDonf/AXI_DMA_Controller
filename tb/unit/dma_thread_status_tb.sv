`timescale 1ns/1ps
// Exercise real thread executors and the shared cache, observing architectural
// CSR/DSR and PC outputs. No access to either thread's internal FSM is needed.
module dma_thread_status_tb;
  import dma330_pkg::*;
  parameter bit MANAGER = 0;
  localparam int DATA_W = 64, BEATS = 4, LINE_BYTES = DATA_W*BEATS/8;
  localparam logic [31:0] BASE = 32'h1000;
  localparam int TID = MANAGER ? 1 : 0;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic go_valid = 0, dbg_kill = 0, wfe_hit = 0, local_inv = 0;
  logic [1:0] cache_inv_extra = 0, inv_req, req, ns, resp_valid, refill_pending;
  logic [31:0] req_addr[2];
  logic [LINE_BYTES*8-1:0] resp_data;
  logic resp_err, resp_retry, idle;
  logic [31:0] csr, cpc, sar, lc0, channel_ftr, dsr, dpc, manager_ftr;
  wire [3:0] status = MANAGER ? dsr[3:0] : csr[3:0];
  wire [31:0] thread_pc = MANAGER ? dpc : cpc;
  logic ar_valid, ar_ready = 0, r_valid = 0, r_ready, r_last = 0;
  logic [31:0] ar_addr;
  logic [7:0] ar_len;
  logic [2:0] ar_size, ar_prot;
  logic [3:0] ar_cache;
  logic [DATA_W-1:0] r_data = 0;
  logic [1:0] r_resp = 0;
  int updates = 0, refills = 0;
  bit check_commit = 0, seen_local_request = 0;
  logic [31:0] expected_commit;

  dma_channel #(.LINE_BYTES(LINE_BYTES), .NUM_EVENTS(2), .NUM_PERIPH(1)) channel (
    .clk(clk), .rst_n(rst_n), .go_valid(go_valid), .go_pc(BASE), .go_ns(1'b0),
    .dbg_kill(dbg_kill), .dbg_fault(1'b0), .dbg_evnt_fault(1'b0), .dbg_opnd_fault(1'b0),
    .wd_fault(1'b0), .irq_ns(2'b11), .periph_ns(1'b1),
    .ic_inv(inv_req[0] | (!MANAGER && local_inv)), .ic_inv_req(inv_req[0]),
    .ic_req(req[0]), .ic_addr(req_addr[0]), .ic_ns(ns[0]),
    .ic_resp_valid(resp_valid[0]), .ic_resp_data(resp_data), .ic_resp_err(resp_err),
    .ic_resp_retry(resp_retry), .ic_refill(refill_pending[0]),
    .sev_valid(), .sev_event(), .wfe_valid(), .wfe_event(), .wfe_hit(wfe_hit),
    .wfp_valid(), .wfp_periph(), .wfp_kind(), .wfp_gnt(1'b0), .wfp_burst(1'b0), .wfp_last(1'b0),
    .flush_valid(), .flush_periph(), .flush_ready(1'b1),
    .ld_req(), .ld_valid(), .ld_xfer(), .ld_ready(1'b1), .ld_lockup(1'b0), .ld_dlock(1'b0),
    .ll_release(), .st_valid(), .st_xfer(), .st_ready(1'b1), .st_short(1'b0),
    .rd_busy(1'b0), .wr_busy(1'b0), .rd_err(1'b0), .wr_err(1'b0),
    .rd_err_addr(32'd0), .wr_err_addr(32'd0), .dp_flush(),
    .csr(csr), .cpc(cpc), .sar_o(sar), .dar_o(), .ccr_o(), .lc0_o(lc0), .lc1_o(),
    .ftr(channel_ftr), .far(), .faulting()
  );
  dma_manager #(.LINE_BYTES(LINE_BYTES), .NUM_CH(1), .NUM_EVENTS(2), .NUM_PERIPH(1)) manager (
    .clk(clk), .rst_n(rst_n), .boot_from_pc(MANAGER), .boot_addr(BASE), .boot_manager_ns(1'b0),
    .irq_ns(2'b11), .periph_ns(1'b1),
    .ic_inv(inv_req[1] | (MANAGER && local_inv)), .ic_inv_req(inv_req[1]),
    .ic_req(req[1]), .ic_addr(req_addr[1]), .ic_ns(ns[1]),
    .ic_resp_valid(resp_valid[1]), .ic_resp_data(resp_data), .ic_resp_err(resp_err),
    .ic_resp_retry(resp_retry), .ic_refill(refill_pending[1]),
    .go_valid(), .go_pc(), .go_ns(), .sev_valid(), .sev_event(),
    .wfe_valid(), .wfe_event(), .wfe_hit(wfe_hit),
    .flush_valid(), .flush_periph(), .flush_ready(1'b1),
    .dbg_valid(1'b0), .dbg_insn(48'd0), .dbg_done(),
    .dsr(dsr), .dpc(dpc), .ftrd(manager_ftr), .faulting()
  );
  dma_icache #(.NUM_THREADS(2), .DATA_W(DATA_W), .LINE_BEATS(BEATS), .NUM_LINES(4)) cache (
    .clk(clk), .rst_n(rst_n), .inv(inv_req | cache_inv_extra), .idle(idle),
    .req(req), .req_addr(req_addr), .req_ns(ns), .resp_valid(resp_valid),
    .resp_data(resp_data), .resp_err(resp_err), .resp_retry(resp_retry),
    .refill_pending(refill_pending), .ar_valid(ar_valid), .ar_ready(ar_ready),
    .ar_addr(ar_addr), .ar_len(ar_len), .ar_size(ar_size), .ar_cache(ar_cache), .ar_prot(ar_prot),
    .r_valid(r_valid), .r_ready(r_ready), .r_data(r_data), .r_resp(r_resp), .r_last(r_last)
  );

  function automatic byte program_byte(int i);
    if (MANAGER) begin
      case (i)
        0,3: return 8'h18;           // NOP
        1,4: return 8'h36;           // WFE
        5:   return 8'h08;           // event 1
        default: return 0;           // event 0 / END
      endcase
    end else begin
      case (i)
        0: return 8'hbc;             // MOV SAR, 0x1234
        2: return 8'h34;
        3: return 8'h12;
        6: return 8'h20;             // LP LC0, 2 iterations
        7: return 8'h01;
        8,13: return 8'h18;          // NOP
        9: return 8'h38;             // LPEND LC0 -> offset 8
        10: return 8'h01;
        11,14: return 8'h36;         // WFE
        15: return 8'h08;            // event 1
        default: return 0;
      endcase
    end
  endfunction
  function automatic int update_from(int n);
    if (MANAGER) begin
      case (n) 0:return 0; 1:return 1; 2:return 3; 3:return 4; default:return -1; endcase
    end else begin
      case (n)
        0:return 0; 1:return 6; 2:return 8; 3:return 9; 4:return 8;
        5:return 9; 6:return 11; 7:return 13; 8:return 14; default:return -1;
      endcase
    end
  endfunction
  function automatic int update_to(int n);
    if (MANAGER) begin
      case (n) 0:return 1; 1:return 3; 2:return 4; 3:return 6; default:return -1; endcase
    end else begin
      case (n)
        0:return 6; 1:return 8; 2:return 9; 3:return 8; 4:return 9;
        5:return 11; 6:return 13; 7:return 14; 8:return 16; default:return -1;
      endcase
    end
  endfunction
  always @(posedge clk) begin
    if (!rst_n) begin
      updates = 0; refills = 0; check_commit = 0;
    end else begin
      if (check_commit && thread_pc !== expected_commit)
        $fatal(1, "Updating PC committed %h, expected %h", thread_pc, expected_commit);
      check_commit = (status == ST_UPDATING_PC);
      if (status == ST_UPDATING_PC) begin
        if (update_from(updates) < 0 || thread_pc !== BASE + update_from(updates))
          $fatal(1, "Updating PC phase %0d at wrong PC %h", updates, thread_pc);
        expected_commit = BASE + update_to(updates);
        updates++;
      end
      if (status == ST_CACHE_MISS && !(ar_valid || r_ready))
        $fatal(1, "false Cache miss: no AXI refill pending");
      if (ar_valid && ar_ready) refills++;
    end
  end
  task step(); @(posedge clk); #1; endtask
  task wait_status(logic [3:0] wanted);
    for (int n = 0; n < 200 && status != wanted; n++) step();
    if (status != wanted) $fatal(1, "status %0d not reached (got %0d)", wanted, status);
  endtask
  task cold_refill();
    wait_status(ST_CACHE_MISS);
    if (!ar_valid) $fatal(1, "false Cache miss before refill AR");
    if (refill_pending !== (2'b01 << TID) || ar_addr != BASE)
      $fatal(1, "Cache miss belongs to wrong thread/address");
    repeat (3) begin step(); if (status != ST_CACHE_MISS) $fatal(1, "lost miss during AR stall"); end
    ar_ready = 1; step(); ar_ready = 0;
    for (int b = 0; b < BEATS; b++) begin
      repeat (2) begin step(); if (status != ST_CACHE_MISS) $fatal(1, "lost miss during R stall"); end
      for (int k = 0; k < DATA_W/8; k++) r_data[k*8 +: 8] = program_byte(b*DATA_W/8+k);
      r_valid = 1; r_last = (b == BEATS-1); step(); r_valid = 0; r_last = 0;
    end
    if (refill_pending != 0) $fatal(1, "miss remained after RLAST");
  endtask
  initial begin
    repeat (2) step(); rst_n = 1; step();
    if (!MANAGER) begin go_valid = 1; step(); go_valid = 0; end
    cold_refill();
    wait_status(ST_WAIT_EVENT);
    // Force a cold local line buffer through its public invalidate input,
    // keeping the shared cache warm. This access must not report Cache miss.
    local_inv = 1; step(); local_inv = 0;
    wfe_hit = 1; step(); wfe_hit = 0;
    seen_local_request = 0;
    for (int n = 0; n < 100 && status != ST_WAIT_EVENT; n++) begin
      if (req[TID]) seen_local_request = 1;
      if (status == ST_CACHE_MISS || ar_valid) $fatal(1, "false Cache miss on shared-cache hit");
      step();
    end
    if (status != ST_WAIT_EVENT || !seen_local_request || refills != 1)
      $fatal(1, "shared-cache-hit scenario not exercised");
    // With both levels invalidated, exactly one more real refill is needed.
    local_inv = 1; cache_inv_extra[TID] = 1; step();
    local_inv = 0; cache_inv_extra = 0;
    wfe_hit = 1; step(); wfe_hit = 0;
    cold_refill();
    wait_status(ST_STOPPED);
    if (updates != (MANAGER ? 4 : 9)) $fatal(1, "Updating PC count=%0d", updates);
    if (thread_pc != BASE + (MANAGER ? 6 : 16) || refills != 2)
      $fatal(1, "wrong final PC or refill count");
    if (MANAGER ? manager_ftr != 0 : (channel_ftr != 0 || sar != 32'h1234 || lc0 != 0))
      $fatal(1, "program register state mismatch");
    $display("UNIT TEST PASSED: dma_thread_status_tb MANAGER=%0d updates=%0d refills=%0d", MANAGER, updates, refills);
    $finish;
  end
  initial begin #100000; $fatal(1, "thread status test timeout"); end
endmodule
