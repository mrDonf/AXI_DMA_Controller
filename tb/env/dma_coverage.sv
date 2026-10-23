//==============================================================================
// dma_coverage.sv - DMA-level functional coverage
//   cg_job   : job shapes (burst sizes / lengths, alignment, addressing modes)
//   cg_insn  : instruction-set usage (opcodes present in executed programs)
//   cg_fault : fault types observed in FTR / FTRD
//==============================================================================
class dma_coverage extends uvm_component;

  `uvm_component_utils(dma_coverage)

  // Sampled values
  dma_job          job;
  int unsigned     src_off, dst_off;
  dma330_pkg::insn_e insn;
  int unsigned     fault_bit;
  bit              fault_mgr;

  covergroup cg_job;
    option.per_instance = 1;
    // A random stream has no knobs to sample; its instructions go to cg_insn
    cp_kind     : coverpoint job.kind { ignore_bins rand_prog = {JOB_RAND}; }
    cp_ch       : coverpoint job.ch { bins ch[] = {[0:dma_tb_params_pkg::NUM_CH-1]}; }
    cp_src_size : coverpoint job.src_size { bins s[] = {[0:3]}; }
    cp_dst_size : coverpoint job.dst_size { bins s[] = {[0:3]}; }
    cp_src_len  : coverpoint job.src_beats { bins one = {1}; bins few = {[2:4]}; bins many = {[5:15]}; bins max = {16}; }
    cp_dst_len  : coverpoint job.dst_beats { bins one = {1}; bins few = {[2:4]}; bins many = {[5:15]}; bins max = {16}; }
    cp_src_off  : coverpoint src_off { bins aligned = {0}; bins unaligned = {[1:7]}; }
    cp_dst_off  : coverpoint dst_off { bins aligned = {0}; bins unaligned = {[1:7]}; }
    cp_src_inc  : coverpoint job.src_inc;
    cp_dst_inc  : coverpoint job.dst_inc;
    cp_swap     : coverpoint job.swap iff (job.kind == JOB_M2M) {
                    bins none = {0}; bins swap16 = {1}; bins swap32 = {2}; bins swap64 = {3}; }
    cp_bytes    : coverpoint job.nbytes { bins b_tiny = {[1:8]}; bins b_small = {[9:128]};
                                          bins b_medium = {[129:1024]}; bins b_large = {[1025:$]}; }
    x_size      : cross cp_src_size, cp_dst_size iff (job.kind == JOB_M2M);
    x_align     : cross cp_src_off, cp_dst_off   iff (job.kind == JOB_M2M);
    x_inc       : cross cp_src_inc, cp_dst_inc   iff (job.kind == JOB_M2M);
  endgroup

  covergroup cg_insn;
    option.per_instance = 1;
    cp_insn : coverpoint insn {
      ignore_bins undef = {dma330_pkg::I_UNDEF};
    }
  endgroup

  covergroup cg_fault;
    option.per_instance = 1;
    cp_ch_fault  : coverpoint fault_bit iff (!fault_mgr) {
      bins undef_instr     = {dma330_pkg::FTC_UNDEF_INSTR};
      bins operand_invalid = {dma330_pkg::FTC_OPERAND_INVALID};
      bins evnt_err        = {dma330_pkg::FTC_CH_EVNT_ERR};
      bins periph_err      = {dma330_pkg::FTC_CH_PERIPH_ERR};
      bins rdwr_err        = {dma330_pkg::FTC_CH_RDWR_ERR};
      bins mfifo_err       = {dma330_pkg::FTC_MFIFO_ERR};
      bins st_data_unavail = {dma330_pkg::FTC_ST_DATA_UNAVAIL};
      bins fetch_err       = {dma330_pkg::FTC_INSTR_FETCH_ERR};
      bins write_err       = {dma330_pkg::FTC_DATA_WRITE_ERR};
      bins read_err        = {dma330_pkg::FTC_DATA_READ_ERR};
      bins dbg_instr       = {dma330_pkg::FTC_DBG_INSTR};
      bins lockup_err      = {dma330_pkg::FTC_LOCKUP_ERR};
    }
    cp_mgr_fault : coverpoint fault_bit iff (fault_mgr) {
      bins undef_instr     = {dma330_pkg::FTD_UNDEF_INSTR};
      bins operand_invalid = {dma330_pkg::FTD_OPERAND_INVALID};
      bins evnt_err        = {dma330_pkg::FTD_MGR_EVNT_ERR};
      bins dmago_err       = {dma330_pkg::FTD_DMAGO_ERR};
      bins dbg_instr       = {dma330_pkg::FTD_DBG_INSTR};
    }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_job   = new();
    cg_insn  = new();
    cg_fault = new();
  endfunction

  function void sample_job(dma_job j);
    job     = j;
    src_off = j.src % 8;
    dst_off = j.dst % 8;
    cg_job.sample();
    if (j.prog != null) sample_program(j.prog.code);
  endfunction

  // Walk a program and sample every instruction class it contains
  function void sample_program(const ref bit [7:0] code[$]);
    int unsigned pc = 0;
    while (pc < code.size()) begin
      insn = dma330_pkg::decode_op(code[pc]);
      cg_insn.sample();
      pc += dma330_pkg::insn_len(code[pc]);
    end
  endfunction

  function void sample_fault(bit [31:0] ftr, bit is_manager);
    fault_mgr = is_manager;
    for (int b = 0; b < 32; b++) begin
      if (ftr[b]) begin
        fault_bit = b;
        cg_fault.sample();
      end
    end
  endfunction

endclass : dma_coverage
