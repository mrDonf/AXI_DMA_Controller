//==============================================================================
// dma_job.sv - one DMA job (what a channel program does) + its expected ops
//------------------------------------------------------------------------------
// A job is the unit of stimulus AND of prediction:
//   * random knobs (addresses, size, burst shapes, attributes)
//   * the generated program (dma330_asm)
//   * 'ops' : the ordered list of loads/stores the program issues; the
//             scoreboard turns it into expected AXI bursts.
//==============================================================================
typedef enum {OP_LD, OP_ST, OP_STZ} dma_op_kind_e;

typedef struct {
  dma_op_kind_e kind;
  bit [31:0]    addr;
  int unsigned  len;          // beats - 1
  int unsigned  size;         // log2(bytes per beat)
  bit           inc;
} dma_op_t;

typedef enum {
  JOB_M2M,          // memory to memory copy, any alignment / burst shape
  JOB_FILL,         // DMASTZ zero fill
  JOB_LOOP2D,       // 2D copy using nested DMALP + DMAADDH/DMAADNH
  JOB_M2P,          // memory -> peripheral FIFO, burst requests
  JOB_P2M,          // peripheral FIFO -> memory, burst requests
  JOB_PERIPH_MIXED, // DMALPFE + DMAWFP P + conditional LD/STP, drlast exit
  JOB_P2M_MIXED,    // DMALPFE + DMAWFP P + conditional LDP/ST (read-side acks)
  JOB_COND_LOOP,    // DMALPEND S/B: condition true (loop) and false (early exit)
  JOB_ISA_MIX,      // reverse-order copy: DMANOP, DMARMB, DMAADNH SAR, DMAKILL end
  JOB_RAND          // random instruction stream (dma_rand_prog); no op list, the C model predicts it
} dma_job_kind_e;

typedef class dma_cmodel_result;

class dma_job extends uvm_object;

  `uvm_object_utils(dma_job)

  //---------------------------------------------------------------- knobs
  rand dma_job_kind_e kind;
  rand int unsigned   ch;
  rand bit [31:0]     src;
  rand bit [31:0]     dst;
  rand int unsigned   nbytes;
  rand int unsigned   src_size, src_beats;
  rand int unsigned   dst_size, dst_beats;
  rand bit            src_inc, dst_inc;
  rand bit [2:0]      src_prot, dst_prot;
  rand bit [2:0]      src_cache, dst_cache;
  rand bit [2:0]      swap;               // CCR endian_swap_size (stores)
  // 2D
  rand int unsigned   rows, row_bursts, src_gap, dst_gap;
  rand bit            dst_reverse;
  // peripheral
  rand int unsigned   periph;
  rand int unsigned   num_req;

  int unsigned        max_size  = 3;      // log2(bus bytes)
  int unsigned        max_bytes = 4096;
  bit                 ns        = 0;
  int unsigned        irq_ev;
  bit [31:0]          prog_addr;
  int                 pre_wfe_ev  = -1;   // DMAWFE <ev> before the transfer
  bit                 wfe_invalidate = 0; // ... with the i-cache invalidate flag
  int                 post_sev_ev = -1;   // DMASEV <ev> after the transfer
  dma_periph_pkg::periph_req_e req_types [$];
  bit                 last_on_final = 0;  // the final peripheral request carries drlast

  //---------------------------------------------------------------- results
  dma_op_t            ops [$];
  dma330_asm          prog;
  dma_periph_pkg::periph_ack_e exp_acks [$];
  dma_cmodel_result   cm_ref;             // what the C reference model says this program does

  //---------------------------------------------------------------- memory map
  static function bit [31:0] src_base(int unsigned ch);  return 32'h1000_0000 + ch * 32'h0100_0000; endfunction
  static function bit [31:0] dst_base(int unsigned ch);  return 32'h2000_0000 + ch * 32'h0100_0000; endfunction
  static function bit [31:0] prog_base(int unsigned ch); return 32'h0001_0000 + ch * 32'h0001_0000; endfunction
  static function bit [31:0] fifo_addr(int unsigned p);  return 32'h4000_0000 + p  * 32'h0000_1000; endfunction

  //---------------------------------------------------------------- constraints
  constraint c_kind_default { soft kind == JOB_M2M; }

  constraint c_sizes {
    src_size  <= max_size;  dst_size  <= max_size;
    src_beats inside {[1:16]};
    dst_beats inside {[1:16]};
  }

  constraint c_bytes {
    nbytes inside {[1:max_bytes]};          // max_bytes >= 65
    nbytes dist { [1:64] :/ 25, [65:max_bytes] :/ 75 };
  }

  constraint c_addr {
    src inside {[src_base(ch) : src_base(ch) + 32'h000F_FFFF]};
    dst inside {[dst_base(ch) : dst_base(ch) + 32'h000F_FFFF]};
  }

  constraint c_swap_default { soft swap == 0; }

  constraint c_inc_default {
    soft src_inc == 1;
    soft dst_inc == 1;
  }

  constraint c_2d {
    rows       inside {[1:8]};
    row_bursts inside {[1:4]};
    src_gap    inside {[0:64]};
    dst_gap    inside {[0:64]};
    src_gap % 8 == 0;
    dst_gap % 8 == 0;
  }

  constraint c_periph {
    periph  < dma_tb_params_pkg::NUM_PERIPH;
    num_req inside {[1:12]};
  }

  function new(string name = "dma_job");
    super.new(name);
  endfunction

  function int unsigned bytes_moved();
    int unsigned n = 0;
    foreach (ops[i]) if (ops[i].kind != OP_LD) n += op_bytes(ops[i]);
    return n;
  endfunction

  static function int unsigned op_bytes(dma_op_t op);
    int unsigned szb = 1 << op.size;
    int unsigned off = op.addr % szb;
    return op.inc ? (op.len + 1) * szb - off : (op.len + 1) * (szb - off);
  endfunction

  virtual function string convert2string();
    // A random stream has no knobs: the program is the description
    if (kind == JOB_RAND)
      return $sformatf("JOB_RAND ch%0d prog=%0d B @0x%08h moves %0d B", ch,
                       prog != null ? prog.code.size() : 0, prog_addr, nbytes);
    return $sformatf("%s ch%0d src=0x%08h(%s s%0d x%0d) dst=0x%08h(%s s%0d x%0d) bytes=%0d swap=%0d ops=%0d",
                     kind.name(), ch, src, src_inc ? "inc" : "fix", src_size, src_beats,
                     dst, dst_inc ? "inc" : "fix", dst_size, dst_beats, nbytes, swap, ops.size());
  endfunction

endclass : dma_job
