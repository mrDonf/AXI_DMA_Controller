`timescale 1ns/1ps
module dma_fetch_unit_tb;
  import dma330_pkg::*;
  parameter int LINE_BYTES = 8;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic fetch_req = 0, inv = 0, insn_valid, fetch_err, miss, fast_hit, ic_req;
  logic [31:0] pc = 32'h1000, ic_addr;
  logic [INSN_W-1:0] insn;
  logic ic_resp_valid = 0, ic_resp_err = 0, ic_resp_retry = 0;
  logic [LINE_BYTES*8-1:0] ic_resp_data = '0;
  dma_fetch_unit #(.LINE_BYTES(LINE_BYTES)) dut (.*);
  task step(); @(posedge clk); #1; endtask
  task no_result();
    if (insn_valid || fetch_err) $fatal(1, "cancelled fetch delivered an instruction/error");
  endtask
  task wait_req();
    for (int n = 0; n < 20 && !ic_req; n++) step();
    if (!ic_req) $fatal(1, "fetch did not retry");
  endtask
  task respond(logic [LINE_BYTES*8-1:0] data, bit retry = 0, bit err = 0);
    ic_resp_data = data; ic_resp_valid = 1; ic_resp_retry = retry; ic_resp_err = err;
    step();
    ic_resp_valid = 0; ic_resp_retry = 0; ic_resp_err = 0;
  endtask
  task expect_insn(byte op);
    for (int n = 0; n < 20 && !insn_valid && !fetch_err; n++) step();
    if (!insn_valid || fetch_err || insn[7:0] !== op)
      $fatal(1, "instruction %h, expected opcode %h", insn, op);
    fetch_req = 0;
    step();
  endtask
  task restart();
    fetch_req = 0; inv = 1; step(); inv = 0;
    pc = 32'h1000; fetch_req = 1; wait_req();
  endtask
  initial begin
    logic [LINE_BYTES*8-1:0] crossing;
    repeat (2) step(); rst_n = 1; step();
    restart(); respond({LINE_BYTES{8'h18}}); expect_insn(8'h18);
    // Hit + invalidate: the cached NOP must not escape on this edge.
    fetch_req = 1; inv = 1; step(); no_result(); inv = 0;
    wait_req(); respond('0); expect_insn(8'h00);
    // Invalidation in a pending miss, and on the response edge.
    for (int same_edge = 0; same_edge < 2; same_edge++) begin
      restart(); inv = 1;
      if (!same_edge) begin step(); no_result(); inv = 0; end
      respond({LINE_BYTES{8'h18}}); no_result(); inv = 0;
      wait_req(); respond('0); expect_insn(8'h00);
    end
    // Invalidate after a line was returned, before instruction delivery.
    restart(); respond({LINE_BYTES{8'h18}}); inv = 1; step(); no_result(); inv = 0;
    wait_req(); respond('0); expect_insn(8'h00);
    // A cross-line MOV must restart from its first line after invalidation.
    restart(); pc = 32'h1000 + LINE_BYTES - 2;
    crossing = '0; crossing[(LINE_BYTES-2)*8 +: 8] = 8'hbc;
    crossing[(LINE_BYTES-1)*8 +: 8] = 8'h00;
    respond(crossing); wait_req();
    if (ic_addr != 32'h1000 + LINE_BYTES) $fatal(1, "missing second instruction line");
    inv = 1; step(); inv = 0; respond({LINE_BYTES{8'h11}}); no_result();
    wait_req();
    if (ic_addr != 32'h1000) $fatal(1, "cross-line retry lost the first line");
    respond('0); expect_insn(8'h00);
    // Cache cancellation is a retry, even if stale bus data had an error.
    restart(); respond('1, 1, 1); no_result();
    wait_req(); respond('0); expect_insn(8'h00);
    // Kill/restart before a late error response: no stale fill or fault.
    restart(); fetch_req = 0; inv = 1; step(); inv = 0;
    pc = 32'h2000; fetch_req = 1; respond('1, 0, 1); no_result();
    wait_req();
    if (ic_addr != 32'h2000) $fatal(1, "restart used the old PC");
    respond('0); expect_insn(8'h00);
    // Cross-line fetch (F_NEXT): delivery, and every way the second-line
    // response can be dropped. After a drop the instruction must still be
    // assembled correctly from a fresh second line.
    for (int mode = 0; mode < 5; mode++) begin
      // 0: assembled at once   1: cache retry on the second line
      // 2: thread drops fetch_req (kill) while the second line is pending
      // 3: invalidate on the second-line response edge
      // 4: thread drops fetch_req on the second-line response edge
      restart(); pc = 32'h1000 + LINE_BYTES - 2;
      respond(crossing); wait_req();
      if (ic_addr != 32'h1000 + LINE_BYTES) $fatal(1, "F_NEXT mode %0d: no second-line request", mode);
      case (mode)
        1: begin respond({LINE_BYTES{8'h11}}, 1); no_result(); wait_req(); end
        2: begin
          fetch_req = 0; step();
          respond({LINE_BYTES{8'h11}}); no_result();
          fetch_req = 1; wait_req();
        end
        3: begin
          inv = 1; respond({LINE_BYTES{8'h11}}); no_result(); inv = 0;
          wait_req();
          if (ic_addr != 32'h1000) $fatal(1, "F_NEXT invalidate: first line not fetched again");
          respond(crossing); wait_req();
        end
        4: begin
          fetch_req = 0; respond({LINE_BYTES{8'h11}}); no_result();
          fetch_req = 1; wait_req();
        end
        default: ;
      endcase
      if (ic_addr != 32'h1000 + LINE_BYTES) $fatal(1, "F_NEXT mode %0d: second line not requested", mode);
      respond({LINE_BYTES{8'h22}});
      for (int n = 0; n < 20 && !insn_valid && !fetch_err; n++) step();
      if (!insn_valid || fetch_err || insn[7:0] !== 8'hbc || insn[15:8] !== 8'h00 ||
          insn[23:16] !== 8'h22 || insn[47:40] !== 8'h22)
        $fatal(1, "F_NEXT mode %0d: assembled %h", mode, insn);
      fetch_req = 0; step();
    end
    // A miss whose thread drops fetch_req (kill) delivers nothing, and the
    // next fetch requests the line again.
    restart(); fetch_req = 0; step();
    respond({LINE_BYTES{8'h18}}); no_result();
    fetch_req = 1; wait_req(); respond('0); expect_insn(8'h00);
    if (LINE_BYTES == 4) begin
      // Third-line assembly, retry, invalidation, late kill and bus error.
      for (int mode=0; mode<5; mode++) begin
        restart(); pc=32'h1003;
        respond(32'hBC000000); wait_req();
        respond(32'h33221100); wait_req();
        if(ic_addr != 32'h1008) $fatal(1,"missing third line");
        case(mode)
          1: begin
            respond('1,1); no_result(); wait_req();
            respond(32'h33221100); wait_req();
          end
          2: begin
            inv=1; respond('1); no_result(); inv=0;
            wait_req(); respond(32'hBC000000); wait_req();
            respond(32'h33221100); wait_req();
          end
          3: begin
            fetch_req=0; step(); respond('1,0,1); no_result();
            fetch_req=1; wait_req(); respond(32'h33221100); wait_req();
          end
          4: begin
            respond('1,0,1);
            if(!fetch_err || insn_valid) $fatal(1,"third-line bus error not reported");
            fetch_req=0; step(); continue;
          end
          default: ;
        endcase
        respond(32'h00000044);
        if(!insn_valid || insn !== 48'h4433221100BC)
          $fatal(1,"third-line assembly mode %0d: %h",mode,insn);
        fetch_req=0; step();
      end
    end
    // ... also when fetch_req drops on the response edge itself
    restart(); fetch_req = 0; respond({LINE_BYTES{8'h18}}); no_result();
    fetch_req = 1; wait_req(); respond('0); expect_insn(8'h00);
    $display("UNIT TEST PASSED: dma_fetch_unit_tb LINE_BYTES=%0d", LINE_BYTES);
    $finish;
  end
  initial begin #100000; $fatal(1, "fetch test timeout"); end
endmodule
