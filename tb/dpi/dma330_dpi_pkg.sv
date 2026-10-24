//==============================================================================
// dma330_dpi_pkg.sv - DPI-C import of the DMA-330 channel reference model
//------------------------------------------------------------------------------
// C side : model/dma330_ref.c (instruction-set simulator) + model/dma330_dpi.c
//          built into a shared library and loaded with  vsim -sv_lib dma330_ref
//
// Imports only: scalar types and bit [127:0] (one 16-byte chunk). The model
// asks for what it needs (instruction bytes, load data) with an event and the
// SV side answers with dma330_dpi_supply(), so no DPI export (and therefore no
// C compiler inside the simulator) is required.
//
// +define+DMA_NO_CMODEL compiles inert stubs instead, for a flow without the
// shared library. The environment then runs with its generator-based
// predictor only (tests that need the model skip themselves).
//==============================================================================
package dma330_dpi_pkg;

  // dm_ev_kind_t of model/dma330_ref.h
  typedef enum int {
    DM_EV_NONE = 0, DM_EV_NEED_CODE, DM_EV_LD, DM_EV_ST, DM_EV_STZ, DM_EV_ACK,
    DM_EV_SEV, DM_EV_WFE, DM_EV_END, DM_EV_KILL, DM_EV_FAULT, DM_EV_STARVED,
    DM_EV_UNKNOWN, DM_EV_RUNAWAY, DM_EV_UNSURE
  } dm_ev_e;

  // dm_ack_t
  typedef enum int {DM_ACK_SINGLE = 0, DM_ACK_BURST = 1, DM_ACK_FLUSH = 2} dm_ack_e;

  // dm_reg_t
  localparam int DM_R_PC = 0, DM_R_SAR = 1, DM_R_DAR = 2, DM_R_CCR = 3, DM_R_LC0 = 4,
                 DM_R_LC1 = 5, DM_R_FTR = 6, DM_R_FTR_MAYBE = 7, DM_R_EVENTS = 8;

  // Field selectors of dma330_dpi_ev() (enum in model/dma330_dpi.c)
  localparam int F_KIND = 0, F_PC = 1, F_ADDR = 2, F_LEN = 3, F_SIZE = 4, F_INC = 5,
                 F_CACHE = 6, F_PROT = 7, F_BYTES = 8, F_NBEATS = 9, F_SUPPLY_ADDR = 10,
                 F_SUPPLY_BYTES = 11, F_PERIPH = 12, F_ACK = 13, F_EVENT_NO = 14,
                 F_WFE_INV = 15, F_FTR = 16, F_FTR_MAYBE = 17;

`ifndef DMA_NO_CMODEL

  localparam bit CMODEL_BUILT = 1'b1;

  import "DPI-C" function chandle dma330_dpi_new(input int unsigned bus_bytes,
                                                 input int unsigned num_events,
                                                 input int unsigned num_periph,
                                                 input int unsigned mfifo_bytes);
  import "DPI-C" function void     dma330_dpi_free(input chandle h);
  import "DPI-C" function void     dma330_dpi_security(input chandle h, input int unsigned irq_ns,
                                                       input int unsigned periph_ns);
  import "DPI-C" function void     dma330_dpi_go(input chandle h, input int unsigned pc, input int ns);
  import "DPI-C" function void     dma330_dpi_periph_req(input chandle h, input int periph,
                                                         input int burst, input int last);
  import "DPI-C" function int      dma330_dpi_step(input chandle h);
  import "DPI-C" function int unsigned dma330_dpi_ev(input chandle h, input int field);
  import "DPI-C" function void     dma330_dpi_supply(input chandle h, input bit [127:0] chunk,
                                                     input int nbytes);
  import "DPI-C" function void     dma330_dpi_beat(input chandle h, input int idx,
                                                   output bit [127:0] data,
                                                   output int unsigned strb);
  import "DPI-C" function int unsigned dma330_dpi_reg(input chandle h, input int r);
  import "DPI-C" function int      dma330_dpi_reg_valid(input chandle h, input int r);
  import "DPI-C" function int unsigned dma330_dpi_insns(input chandle h);

`else

  localparam bit CMODEL_BUILT = 1'b0;

  function automatic chandle dma330_dpi_new(int unsigned bus_bytes, int unsigned num_events,
                                            int unsigned num_periph, int unsigned mfifo_bytes);
    return null;
  endfunction
  function automatic void dma330_dpi_free(chandle h); endfunction
  function automatic void dma330_dpi_security(chandle h, int unsigned irq_ns,
                                              int unsigned periph_ns); endfunction
  function automatic void dma330_dpi_go(chandle h, int unsigned pc, int ns); endfunction
  function automatic void dma330_dpi_periph_req(chandle h, int periph, int burst, int last); endfunction
  function automatic int dma330_dpi_step(chandle h); return int'(DM_EV_UNKNOWN); endfunction
  function automatic int unsigned dma330_dpi_ev(chandle h, int field); return 0; endfunction
  function automatic void dma330_dpi_supply(chandle h, bit [127:0] chunk, int nbytes); endfunction
  function automatic void dma330_dpi_beat(chandle h, int idx, output bit [127:0] data,
                                          output int unsigned strb);
    data = '0; strb = 0;
  endfunction
  function automatic int unsigned dma330_dpi_reg(chandle h, int r); return 0; endfunction
  function automatic int dma330_dpi_reg_valid(chandle h, int r); return 0; endfunction
  function automatic int unsigned dma330_dpi_insns(chandle h); return 0; endfunction

`endif

endpackage : dma330_dpi_pkg
