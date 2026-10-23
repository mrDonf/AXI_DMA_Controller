//==============================================================================
// dma330_asm.sv - assembler for the DMA-330 instruction set
//------------------------------------------------------------------------------
// Builds a program as a byte queue. Loop helpers return / take the PC of the
// loop body so DMALPEND's backward jump is computed automatically:
//
//   int body = a.dmalp(0, 8);   // DMALP LC0, 8
//   a.dmald();  a.dmast();
//   a.dmalpend(0, body);        // DMALPEND LC0
//==============================================================================
typedef enum bit [1:0] {COND_ALWAYS = 2'b00, COND_S = 2'b01, COND_B = 2'b11} dma_cond_e;
typedef enum bit [1:0] {WFP_SINGLE = 2'b00, WFP_PERIPH = 2'b01, WFP_BURST = 2'b10} dma_wfp_e;
typedef enum int {RD_SAR = 0, RD_CCR = 1, RD_DAR = 2} dma_mov_rd_e;

class dma330_asm extends uvm_object;

  `uvm_object_utils(dma330_asm)

  bit [7:0] code [$];
  string    listing [$];       // human-readable disassembly for debug

  function new(string name = "dma330_asm");
    super.new(name);
  endfunction

  function int unsigned pc();
    return code.size();
  endfunction

  protected function void emit(string text, bit [7:0] b0, int n = 1,
                               bit [7:0] b1 = 0, bit [31:0] imm = 0);
    listing.push_back($sformatf("%04h: %s", code.size(), text));
    code.push_back(b0);
    if (n >= 2) code.push_back(b1);
    if (n == 3) begin
      code.push_back(imm[7:0]);
    end else if (n == 4) begin
      code.push_back(imm[7:0]);  code.push_back(imm[15:8]);
    end else if (n == 6) begin
      code.push_back(imm[7:0]);  code.push_back(imm[15:8]);
      code.push_back(imm[23:16]); code.push_back(imm[31:24]);
    end
  endfunction

  //----------------------------------------------------------------------------
  // Channel CCR builder
  //----------------------------------------------------------------------------
  static function bit [31:0] ccr(bit src_inc, int unsigned src_size, int unsigned src_beats,
                                 bit dst_inc, int unsigned dst_size, int unsigned dst_beats,
                                 bit [2:0] src_prot = 0, bit [2:0] src_cache = 0,
                                 bit [2:0] dst_prot = 0, bit [2:0] dst_cache = 0,
                                 bit [2:0] swap = 0);
    bit [31:0] v = '0;
    v[0]     = src_inc;
    v[3:1]   = src_size;
    v[7:4]   = src_beats - 1;
    v[10:8]  = src_prot;
    v[13:11] = src_cache;
    v[14]    = dst_inc;
    v[17:15] = dst_size;
    v[21:18] = dst_beats - 1;
    v[24:22] = dst_prot;
    v[27:25] = dst_cache;
    v[30:28] = swap;          // endian swap size: 0 none, 1/2/3/4 = 16/32/64/128-bit
    return v;
  endfunction

  //----------------------------------------------------------------------------
  // Instructions
  //----------------------------------------------------------------------------
  function void dmaend();   emit("DMAEND",  8'h00); endfunction
  function void dmakill();  emit("DMAKILL", 8'h01); endfunction
  function void dmanop();   emit("DMANOP",  8'h18); endfunction
  function void dmarmb();   emit("DMARMB",  8'h12); endfunction
  function void dmawmb();   emit("DMAWMB",  8'h13); endfunction
  function void dmastz();   emit("DMASTZ",  8'h0C); endfunction

  function void dmald(dma_cond_e c = COND_ALWAYS);
    emit({"DMALD", cond_sfx(c)}, 8'h04 | c);
  endfunction

  function void dmast(dma_cond_e c = COND_ALWAYS);
    emit({"DMAST", cond_sfx(c)}, 8'h08 | c);
  endfunction

  function void dmaldp(dma_cond_e c, int unsigned periph);
    emit($sformatf("DMALDP%s P%0d", cond_sfx(c), periph),
         8'h25 | (c == COND_B ? 8'h02 : 8'h00), 2, periph << 3);
  endfunction

  function void dmastp(dma_cond_e c, int unsigned periph);
    emit($sformatf("DMASTP%s P%0d", cond_sfx(c), periph),
         8'h29 | (c == COND_B ? 8'h02 : 8'h00), 2, periph << 3);
  endfunction

  function void dmamov(dma_mov_rd_e rd, bit [31:0] imm);
    emit($sformatf("DMAMOV %s, 0x%08h", rd.name(), imm), 8'hBC, 6, rd, imm);
  endfunction

  function void dmaaddh(bit to_dar, bit [15:0] imm);
    emit($sformatf("DMAADDH %s, 0x%04h", to_dar ? "DAR" : "SAR", imm),
         8'h54 | (to_dar << 1), 3, imm[7:0], {16'h0, 8'h0, imm[15:8]});
  endfunction

  // Adds the negative value {16'hFFFF, imm}; i.e. subtracts (2**16 - imm)
  function void dmaadnh(bit to_dar, bit [15:0] imm);
    emit($sformatf("DMAADNH %s, 0x%04h", to_dar ? "DAR" : "SAR", imm),
         8'h5C | (to_dar << 1), 3, imm[7:0], {16'h0, 8'h0, imm[15:8]});
  endfunction

  // Returns the PC of the first instruction of the loop body
  function int unsigned dmalp(bit lc, int unsigned iterations);
    if (iterations < 1 || iterations > 256)
      `uvm_fatal("ASM", $sformatf("DMALP iterations %0d out of range", iterations))
    emit($sformatf("DMALP LC%0d, %0d", lc, iterations), 8'h20 | (lc << 1), 2, iterations - 1);
    return pc();
  endfunction

  // Finite loop end (DMALPEND) or forever loop end (DMALPFE, forever = 1)
  function void dmalpend(bit lc, int unsigned body_pc, dma_cond_e c = COND_ALWAYS,
                         bit forever_loop = 0);
    int unsigned jump = pc() - body_pc;
    bit [7:0] op;
    if (jump > 255) `uvm_fatal("ASM", "DMALPEND jump too long")
    // Forever loops with a condition must use the LC1 encoding (0x29/0x2B are DMASTP)
    if (forever_loop && c != COND_ALWAYS) lc = 1;
    op = 8'h28 | ((!forever_loop) << 4) | (lc << 2) | c;
    emit($sformatf("DMALPEND%s%s LC%0d (-%0d)", forever_loop ? "FE" : "", cond_sfx(c), lc, jump),
         op, 2, jump);
  endfunction

  function void dmawfp(int unsigned periph, dma_wfp_e kind);
    emit($sformatf("DMAWFP %s P%0d", kind.name(), periph), 8'h30 | kind, 2, periph << 3);
  endfunction

  function void dmaflushp(int unsigned periph);
    emit($sformatf("DMAFLUSHP P%0d", periph), 8'h35, 2, periph << 3);
  endfunction

  function void dmasev(int unsigned ev);
    emit($sformatf("DMASEV E%0d", ev), 8'h34, 2, ev << 3);
  endfunction

  function void dmawfe(int unsigned ev, bit invalidate = 0);
    emit($sformatf("DMAWFE E%0d%s", ev, invalidate ? ", invalid" : ""),
         8'h36, 2, (ev << 3) | (invalidate << 1));
  endfunction

  function void dmago(int unsigned ch, bit [31:0] start_pc, bit ns = 0);
    emit($sformatf("DMAGO C%0d, 0x%08h%s", ch, start_pc, ns ? ", ns" : ""),
         8'hA0 | (ns << 1), 6, ch, start_pc);
  endfunction

  // Arbitrary bytes (for illegal-instruction tests)
  function void raw(bit [7:0] b);
    emit($sformatf("DCB 0x%02h", b), b);
  endfunction

  //----------------------------------------------------------------------------
  protected function string cond_sfx(dma_cond_e c);
    case (c)
      COND_S:  return "S";
      COND_B:  return "B";
      default: return "";
    endcase
  endfunction

  function string sprint_listing();
    string s = "";
    foreach (listing[i]) s = {s, "\n    ", listing[i]};
    return s;
  endfunction

endclass : dma330_asm
