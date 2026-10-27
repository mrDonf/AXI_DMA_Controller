`timescale 1ns/1ps
module dma_icache_tb;
  import dma330_pkg::*;
  parameter int DATA_W = 64;
  parameter int BEATS = 4;
  localparam int NT = 3, LW = DATA_W * BEATS;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [NT-1:0] inv = '0, req = '0, req_ns = '0, resp_valid;
  logic [31:0] req_addr [NT];
  logic [LW-1:0] resp_data;
  logic resp_err, resp_retry, idle;
  logic ar_valid, ar_ready = 0, r_valid = 0, r_ready, r_last = 0;
  logic [31:0] ar_addr;
  logic [7:0] ar_len;
  logic [2:0] ar_size, ar_prot;
  logic [3:0] ar_cache;
  logic [DATA_W-1:0] r_data = '0;
  logic [1:0] r_resp = 0;
  dma_icache #(.NUM_THREADS(NT), .DATA_W(DATA_W), .LINE_BEATS(BEATS),
               .NUM_LINES(3)) dut (.*);

  task step(); @(posedge clk); #1; endtask
  function automatic logic [LW-1:0] line_value(int marker);
    for (int b = 0; b < BEATS; b++)
      line_value[b*DATA_W +: DATA_W] = DATA_W'(marker + b);
  endfunction
  task begin_req(int t, bit ns = 0);
    if (!idle) $fatal(1, "cache not idle before request");
    req[t] = 1;
    req_addr[t] = 32'h1000;
    req_ns[t] = ns;
    step();
  endtask
  task result(int t, int marker, bit retry = 0, bit err = 0);
    for (int n = 0; n < 100 && !resp_valid[t]; n++) begin
      if (ar_valid && !ar_ready) $fatal(1, "unexpected cache miss");
      step();
    end
    if (resp_valid !== (NT'(1) << t) || resp_retry !== retry || resp_err !== err)
      $fatal(1, "response t%0d: valid=%b retry=%b err=%b", t, resp_valid, resp_retry, resp_err);
    if (!retry && !err && resp_data !== line_value(marker))
      $fatal(1, "stale/wrong line t%0d: %h", t, resp_data);
    req[t] = 0;
    step();
  endtask
  task refill(int t, int marker, int cancel_beat = -1, bit err = 0);
    for (int n = 0; n < 20 && !ar_valid; n++) step();
    if (!ar_valid || ar_addr != 32'h1000 || ar_len != BEATS-1 ||
        ar_size != $clog2(DATA_W/8) || ar_prot != {1'b1, req_ns[t], 1'b1})
      $fatal(1, "missing/incorrect refill AR");
    // -2 invalidates a refill whose AR is stalled; it must still drain.
    if (cancel_beat == -2) begin
      inv[t] = 1;
      step();
      inv = '0;
      repeat (3) begin
        if (!ar_valid) $fatal(1, "cancelled AR withdrawn before handshake");
        step();
      end
    end
    ar_ready = 1;
    step();
    ar_ready = 0;
    for (int b = 0; b < BEATS; b++) begin
      r_valid = 1;
      r_data = DATA_W'(marker + b);
      r_last = (b == BEATS-1);
      r_resp = err ? 2'b10 : 2'b00;
      inv[t] = (b == cancel_beat);
      if (!r_ready) $fatal(1, "refill not draining");
      step();
    end
    inv = '0;
    r_valid = 0;
    r_last = 0;
    r_resp = 0;
  endtask
  task invalidate(int t);
    inv[t] = 1;
    step();
    inv = '0;
  endtask

  initial begin
    foreach (req_addr[t]) req_addr[t] = 0;
    repeat (2) step();
    rst_n = 1;
    step();
    begin_req(0); refill(0, 16'h1100); result(0, 16'h1100);
    // Same address and NS state must not let one thread execute another's
    // cached version of a program.
    begin_req(1); refill(1, 16'h2200); result(1, 16'h2200);
    begin_req(0); result(0, 16'h1100);
    invalidate(0);
    begin_req(1); result(1, 16'h2200); // maintenance is thread-local
    begin_req(0); refill(0, 16'h3300); result(0, 16'h3300);
    // Invalidate on the lookup-hit edge must return retry, not old bytes.
    begin_req(0); inv[0] = 1; step(); inv = '0; result(0, 0, 1);
    for (int stage = -2; stage < BEATS; stage++) begin
      if (stage == -1) continue;
      invalidate(0);
      begin_req(0); refill(0, 16'h4400, stage, stage == BEATS-1); result(0, 0, 1);
      // A cancelled/errored line must not have reappeared in the cache.
      begin_req(0); refill(0, 16'h5500); result(0, 16'h5500);
      begin_req(0); result(0, 16'h5500);
    end
    invalidate(0);
    begin_req(0); refill(0, 0, -1, 1); result(0, 0, 0, 1);
    begin_req(0); refill(0, 16'h6600); result(0, 16'h6600);
    begin_req(0, 1); refill(0, 16'h7700); result(0, 16'h7700);
    $display("UNIT TEST PASSED: dma_icache_tb DATA_W=%0d BEATS=%0d", DATA_W, BEATS);
    $finish;
  end
  initial begin #100000; $fatal(1, "cache test timeout"); end
endmodule
