//==============================================================================
// dma_fetch_unit.sv
//------------------------------------------------------------------------------
// Per-thread instruction fetch front end.
//
// Keeps one cache line of the thread's program in a local line buffer, so
// that consecutive instructions are fetched without touching the shared
// instruction cache. An instruction (1..6 bytes) that straddles two lines is
// assembled from the buffered line plus the next line.
//
//   fetch_req (level, from thread) -> insn_valid / fetch_err (1-cycle pulses)
//
//   F_IDLE : line hit and instruction fits -> deliver next cycle
//            line miss                     -> F_MISS
//            instruction crosses the line  -> F_NEXT
//   F_MISS : read line PC from the i-cache, then retry in F_IDLE
//   F_NEXT : read the following line, assemble, deliver
//
// If the thread drops fetch_req while a line request is outstanding (killed,
// restarted) the result is not delivered.
//==============================================================================
module dma_fetch_unit
  import dma330_pkg::*;
#(
  parameter int LINE_BYTES = 32
) (
  input  logic                      clk,
  input  logic                      rst_n,

  // Thread side
  input  logic                      fetch_req,
  input  logic [ADDR_W-1:0]         pc,
  input  logic                      inv,          // invalidate line buffer
  output logic                      insn_valid,
  output logic [INSN_W-1:0]         insn,         // byte 0 = opcode
  output logic                      fetch_err,
  output logic                      miss,         // waiting on the i-cache

  // Instruction cache port
  output logic                      ic_req,
  output logic [ADDR_W-1:0]         ic_addr,      // line aligned
  input  logic                      ic_resp_valid,
  input  logic [LINE_BYTES*8-1:0]   ic_resp_data,
  input  logic                      ic_resp_err,
  input  logic                      ic_resp_retry // invalidated cache request: retry
);

  localparam int LINE_LSB = $clog2(LINE_BYTES);
  localparam int TAG_W    = ADDR_W - LINE_LSB;

  typedef enum logic [1:0] {F_IDLE, F_MISS, F_NEXT} fstate_e;
  fstate_e fstate;

  logic                    lb_valid;
  logic [TAG_W-1:0]        lb_tag;
  logic [LINE_BYTES*8-1:0] lb_data;
  logic [TAG_W-1:0]        req_tag;     // line being requested
  logic                    aborted;     // thread gave up while waiting

  logic [TAG_W-1:0]        pc_tag;
  logic [LINE_LSB-1:0]     pc_off;
  logic                    hit;
  logic [7:0]              opcode;
  logic                    crosses_line;

  assign pc_tag       = pc[ADDR_W-1:LINE_LSB];
  assign pc_off       = pc[LINE_LSB-1:0];
  assign hit          = lb_valid && (lb_tag == pc_tag);
  assign opcode       = lb_data[pc_off*8 +: 8];
  assign crosses_line = (int'(pc_off) + int'(insn_len(opcode))) > LINE_BYTES;

  assign miss    = (fstate != F_IDLE);
  assign ic_req  = (fstate != F_IDLE);
  assign ic_addr = {req_tag, {LINE_LSB{1'b0}}};

  // Gather MAX_INSN_B bytes starting at 'off' from two consecutive lines
  function automatic logic [INSN_W-1:0] assemble(input logic [LINE_BYTES*8-1:0] cur_line,
                                                 input logic [LINE_BYTES*8-1:0] next_line,
                                                 input logic [LINE_LSB-1:0]     off);
    logic [INSN_W-1:0] bytes;
    for (int k = 0; k < MAX_INSN_B; k++) begin
      int idx;
      idx = int'(off) + k;
      bytes[k*8 +: 8] = (idx < LINE_BYTES) ? cur_line[idx*8 +: 8]
                                           : next_line[(idx - LINE_BYTES)*8 +: 8];
    end
    return bytes;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fstate     <= F_IDLE;
      lb_valid   <= 1'b0;
      lb_tag     <= '0;
      lb_data    <= '0;
      req_tag    <= '0;
      aborted    <= 1'b0;
      insn_valid <= 1'b0;
      insn       <= '0;
      fetch_err  <= 1'b0;
    end else begin
      insn_valid <= 1'b0;
      fetch_err  <= 1'b0;

      if (fstate != F_IDLE && (!fetch_req || inv))
        aborted <= 1'b1;

      case (fstate)
        F_IDLE: begin
          // Do not start a new fetch in the cycle the previous result is seen
          if (fetch_req && !insn_valid && !fetch_err && !inv) begin
            aborted <= 1'b0;
            if (!hit) begin
              req_tag <= pc_tag;
              fstate  <= F_MISS;
            end else if (crosses_line) begin
              req_tag <= pc_tag + 1'b1;
              fstate  <= F_NEXT;
            end else begin
              insn       <= assemble(lb_data, '0, pc_off);
              insn_valid <= 1'b1;
            end
          end
        end

        F_MISS: begin
          if (ic_resp_valid) begin
            fstate <= F_IDLE;
            if (fetch_req && !aborted && !inv && !ic_resp_retry) begin
              if (ic_resp_err) begin
                fetch_err <= 1'b1;
              end else begin
                lb_valid <= 1'b1;
                lb_tag   <= req_tag;
                lb_data  <= ic_resp_data;
              end
            end
          end
        end

        F_NEXT: begin
          if (ic_resp_valid) begin
            fstate <= F_IDLE;
            if (fetch_req && !aborted && !inv && !ic_resp_retry) begin
              if (ic_resp_err) begin
                fetch_err <= 1'b1;
              end else begin
                insn       <= assemble(lb_data, ic_resp_data, pc_off);
                insn_valid <= 1'b1;
                lb_valid <= 1'b1;
                lb_tag   <= req_tag;
                lb_data  <= ic_resp_data;
              end
            end
          end
        end

        default: fstate <= F_IDLE;
      endcase

      // Invalidate suppresses delivery as well as allocation. A pending
      // cache request is drained, but its late response cannot revive lb.
      if (inv) begin
        lb_valid   <= 1'b0;
        insn_valid <= 1'b0;
        fetch_err  <= 1'b0;
      end
    end
  end

endmodule : dma_fetch_unit
