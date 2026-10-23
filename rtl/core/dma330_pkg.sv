//==============================================================================
// dma330_pkg.sv
//------------------------------------------------------------------------------
// Shared definitions for the AXI DMA controller (DMA-330 / PL330 style).
//
//   * Instruction set encoding (byte-code, DMA-330 compatible)
//   * Thread status encodings (DSR / CSR register values)
//   * Fault-type bit positions (FTRD / FTRn registers)
//   * Channel Control Register (CCR) layout
//   * Burst descriptor passed from a channel thread to the data path
//   * Helper functions for burst / beat arithmetic
//
// Address width is fixed to 32 bits, as in DMA-330.
//==============================================================================
package dma330_pkg;

  //----------------------------------------------------------------------------
  // Global constants
  //----------------------------------------------------------------------------
  localparam int ADDR_W      = 32;
  localparam int MAX_INSN_B  = 6;        // longest instruction (DMAMOV/DMAGO)
  localparam int INSN_W      = MAX_INSN_B * 8;
  localparam int XBYTES_W    = 9;        // bytes in one burst: up to 16 beats x 16 B = 256

  //----------------------------------------------------------------------------
  // Decoded instruction classes
  //----------------------------------------------------------------------------
  typedef enum logic [4:0] {
    I_UNDEF   = 5'd0,
    I_END     = 5'd1,   // DMAEND
    I_KILL    = 5'd2,   // DMAKILL
    I_NOP     = 5'd3,   // DMANOP
    I_RMB     = 5'd4,   // DMARMB      read memory barrier
    I_WMB     = 5'd5,   // DMAWMB      write memory barrier
    I_LD      = 5'd6,   // DMALD[S|B]
    I_ST      = 5'd7,   // DMAST[S|B]
    I_STZ     = 5'd8,   // DMASTZ      store zeros
    I_LDP     = 5'd9,   // DMALDP<S|B> load + peripheral acknowledge
    I_STP     = 5'd10,  // DMASTP<S|B> store + peripheral acknowledge
    I_LP      = 5'd11,  // DMALP       loop start (loads LC0/LC1)
    I_LPEND   = 5'd12,  // DMALPEND[S|B] / DMALPFE end
    I_WFP     = 5'd13,  // DMAWFP<S|B|P> wait for peripheral
    I_SEV     = 5'd14,  // DMASEV      send event / interrupt
    I_FLUSHP  = 5'd15,  // DMAFLUSHP   flush peripheral
    I_WFE     = 5'd16,  // DMAWFE      wait for event
    I_ADDH    = 5'd17,  // DMAADDH     add halfword
    I_ADNH    = 5'd18,  // DMAADNH     add negative halfword
    I_MOV     = 5'd19,  // DMAMOV      move 32-bit immediate
    I_GO      = 5'd20   // DMAGO       start a channel (manager only)
  } insn_e;

  //----------------------------------------------------------------------------
  // Opcode decoder (byte 0 of the instruction).
  //
  //   Encoding notes (DMA-330):
  //     DMALPEND = 0 0 1 nf 1 lc bs x . With nf=0 (forever loop) and lc=0,
  //     x=1 the encoding overlaps DMASTP (0x29/0x2B); those two bytes always
  //     decode as DMASTP. Conditional forever loops must use the LC1 encoding.
  //----------------------------------------------------------------------------
  function automatic insn_e decode_op(input logic [7:0] op);
    casez (op)
      8'h00:                    return I_END;
      8'h01:                    return I_KILL;
      8'h04, 8'h05, 8'h07:      return I_LD;
      8'h08, 8'h09, 8'h0B:      return I_ST;
      8'h0C:                    return I_STZ;
      8'h12:                    return I_RMB;
      8'h13:                    return I_WMB;
      8'h18:                    return I_NOP;
      8'h20, 8'h22:             return I_LP;
      8'h25, 8'h27:             return I_LDP;
      8'h29, 8'h2B:             return I_STP;
      8'h28, 8'h2A, 8'b0010_11??,
      8'b0011_1???:             return I_LPEND;
      8'h30, 8'h31, 8'h32:      return I_WFP;
      8'h34:                    return I_SEV;
      8'h35:                    return I_FLUSHP;
      8'h36:                    return I_WFE;
      8'h54, 8'h56:             return I_ADDH;
      8'h5C, 8'h5E:             return I_ADNH;
      8'hBC:                    return I_MOV;
      8'hA0, 8'hA2:             return I_GO;
      default:                  return I_UNDEF;
    endcase
  endfunction

  // Instruction length in bytes. Undefined opcodes report 1 so that the
  // fetch logic always has a well-defined window; they fault on execute.
  function automatic logic [2:0] insn_len(input logic [7:0] op);
    case (decode_op(op))
      I_LP, I_LDP, I_STP, I_LPEND, I_WFP,
      I_SEV, I_FLUSHP, I_WFE:          return 3'd2;
      I_ADDH, I_ADNH:                  return 3'd3;
      I_MOV, I_GO:                     return 3'd6;
      default:                         return 3'd1;
    endcase
  endfunction

  //----------------------------------------------------------------------------
  // Thread status (DSR[3:0] for the manager, CSRn[3:0] for channels)
  //----------------------------------------------------------------------------
  localparam logic [3:0] ST_STOPPED          = 4'd0;
  localparam logic [3:0] ST_EXECUTING        = 4'd1;
  localparam logic [3:0] ST_CACHE_MISS       = 4'd2;
  localparam logic [3:0] ST_UPDATING_PC      = 4'd3;
  localparam logic [3:0] ST_WAIT_EVENT       = 4'd4;
  localparam logic [3:0] ST_AT_BARRIER       = 4'd5;
  localparam logic [3:0] ST_WAIT_PERIPH      = 4'd7;
  localparam logic [3:0] ST_KILLING          = 4'd8;
  localparam logic [3:0] ST_COMPLETING       = 4'd9;
  localparam logic [3:0] ST_FAULT_COMPLETING = 4'd14;
  localparam logic [3:0] ST_FAULTING         = 4'd15;

  //----------------------------------------------------------------------------
  // Fault type bit positions
  //----------------------------------------------------------------------------
  // Manager (FTRD)
  localparam int FTD_UNDEF_INSTR     = 0;
  localparam int FTD_OPERAND_INVALID = 1;
  localparam int FTD_MGR_EVNT_ERR    = 4;
  localparam int FTD_DMAGO_ERR       = 5;
  localparam int FTD_INSTR_FETCH_ERR = 16;
  localparam int FTD_DBG_INSTR       = 30;
  // Channel (FTRn)
  localparam int FTC_UNDEF_INSTR     = 0;
  localparam int FTC_OPERAND_INVALID = 1;
  localparam int FTC_CH_EVNT_ERR     = 5;
  localparam int FTC_CH_PERIPH_ERR   = 6;
  localparam int FTC_CH_RDWR_ERR     = 7;
  localparam int FTC_MFIFO_ERR       = 12;
  localparam int FTC_ST_DATA_UNAVAIL = 13;
  localparam int FTC_INSTR_FETCH_ERR = 16;
  localparam int FTC_DATA_WRITE_ERR  = 17;
  localparam int FTC_DATA_READ_ERR   = 18;
  localparam int FTC_DBG_INSTR       = 30;
  localparam int FTC_LOCKUP_ERR      = 31;

  //----------------------------------------------------------------------------
  // Channel Control Register
  //----------------------------------------------------------------------------
  typedef struct packed {
    logic       reserved31;       // [31]    reserved, ignored
    logic [2:0] endian_swap;      // [30:28] 0 none, 1: 16-bit, 2: 32-bit, 3: 64-bit, 4: 128-bit
    logic [2:0] dst_cache;        // [27:25] -> AWCACHE[2:0]
    logic [2:0] dst_prot;         // [24:22] -> AWPROT
    logic [3:0] dst_burst_len;    // [21:18] beats - 1
    logic [2:0] dst_burst_size;   // [17:15] log2(bytes per beat)
    logic       dst_inc;          // [14]
    logic [2:0] src_cache;        // [13:11] -> ARCACHE[2:0]
    logic [2:0] src_prot;         // [10:8]  -> ARPROT
    logic [3:0] src_burst_len;    // [7:4]
    logic [2:0] src_burst_size;   // [3:1]
    logic       src_inc;          // [0]
  } ccr_t;

  //----------------------------------------------------------------------------
  // Burst descriptor: one DMALD/DMAST issued by a channel thread
  //----------------------------------------------------------------------------
  typedef struct packed {
    logic [ADDR_W-1:0]   addr;        // start address (may be unaligned)
    logic [3:0]          len;         // AxLEN (beats - 1)
    logic [2:0]          size;        // AxSIZE
    logic                inc;         // 1: INCR, 0: FIXED
    logic [3:0]          cache;       // AxCACHE
    logic [2:0]          prot;        // AxPROT (NS already merged into bit 1)
    logic [XBYTES_W-1:0] bytes;       // payload bytes moved by this burst
    logic                zero;        // DMASTZ: write zeros, no MFIFO data
    logic                periph_ack;  // DMALDP/DMASTP: acknowledge peripheral
    logic [4:0]          periph;      // peripheral number for the acknowledge
    logic                ack_burst;   // acknowledge type: 0 single, 1 burst
    logic [2:0]          swap;        // DMAST: endian swap size (log2 bytes), 0 = none
  } xfer_t;

  localparam int XFER_W = $bits(xfer_t);

  //----------------------------------------------------------------------------
  // Burst arithmetic
  //----------------------------------------------------------------------------
  // Bytes per beat for a given AxSIZE
  function automatic logic [4:0] size_bytes(input logic [2:0] size);
    return 5'd1 << size;
  endfunction

  // Offset of an address inside one beat of the given size
  function automatic logic [3:0] size_offset(input logic [ADDR_W-1:0] addr,
                                             input logic [2:0]        size);
    return addr[3:0] & (size_bytes(size) - 5'd1);
  endfunction

  // Total payload bytes of a burst. An unaligned start address only shortens
  // the first beat (INCR) or every beat (FIXED).
  function automatic logic [XBYTES_W-1:0] burst_bytes(input logic [ADDR_W-1:0] addr,
                                                      input logic [2:0]        size,
                                                      input logic [3:0]        len,
                                                      input logic              inc);
    logic [XBYTES_W-1:0] beats, sz, off;
    beats = XBYTES_W'(len) + 1'b1;
    sz    = XBYTES_W'(size_bytes(size));
    off   = XBYTES_W'(size_offset(addr, size));
    return inc ? (beats * sz - off) : (beats * (sz - off));
  endfunction

  // An INCR burst whose bytes span two 4 KB pages (illegal on AXI). The
  // aligned start address is used, as the AXI rule is defined on it.
  function automatic logic crosses_4k(input logic [ADDR_W-1:0] addr,
                                      input logic [2:0]        size,
                                      input logic [3:0]        len,
                                      input logic              inc);
    logic [12:0] start, span;
    start = {1'b0, addr[11:0] & ~12'(size_bytes(size) - 5'd1)};
    span  = (13'(len) + 13'd1) << size;
    return inc && ((start + span) > 13'd4096);
  endfunction

  // Endian swap: bytes are reversed inside every aligned (2**swap)-byte group
  // of a bus word. Byte k of a group of g bytes moves to k XOR (g-1), so the
  // swap is fixed wiring plus a 5-way multiplexer.
  function automatic logic [127:0] endian_swap(input logic [127:0] d,
                                               input logic [2:0]   swap);
    logic [127:0] r;
    r = d;
    for (int k = 0; k < 16; k++) begin
      case (swap)
        3'd1:    r[k*8 +: 8] = d[(k ^ 1)*8  +: 8];
        3'd2:    r[k*8 +: 8] = d[(k ^ 3)*8  +: 8];
        3'd3:    r[k*8 +: 8] = d[(k ^ 7)*8  +: 8];
        3'd4:    r[k*8 +: 8] = d[(k ^ 15)*8 +: 8];
        default: ;
      endcase
    end
    return r;
  endfunction

  // Address of beat number 'beat' inside a burst
  function automatic logic [ADDR_W-1:0] beat_addr(input logic [ADDR_W-1:0] addr,
                                                  input logic [2:0]        size,
                                                  input logic              inc,
                                                  input logic [3:0]        beat);
    logic [ADDR_W-1:0] aligned;
    aligned = addr & ~ADDR_W'(size_bytes(size) - 5'd1);
    if (!inc || beat == 4'd0) return addr;
    return aligned + (ADDR_W'(beat) << size);
  endfunction

  // Valid payload bytes carried by beat number 'beat'
  function automatic logic [4:0] beat_bytes(input logic [ADDR_W-1:0] addr,
                                            input logic [2:0]        size,
                                            input logic              inc,
                                            input logic [3:0]        beat);
    if (!inc || beat == 4'd0) return size_bytes(size) - 5'(size_offset(addr, size));
    return size_bytes(size);
  endfunction

endpackage : dma330_pkg
