//==============================================================================
// dma_cmodel.sv - SystemVerilog side of the C reference model (DPI-C)
//------------------------------------------------------------------------------
//   dma_cmodel_result : what the C model says one program does
//                       (bursts, acknowledges, events, final registers/faults)
//   dma_cmodel        : runs a program that is already in the memory model
//                       through model/dma330_ref.c and returns the result
//
// The C model decodes the real byte code, so it is independent of the
// generator that wrote the program (dma_prog_gen / dma_rand_prog). Its
// answers are turned into the same axi_txn objects the scoreboard compares
// with the bus.
//==============================================================================
class dma_cmodel_result extends uvm_object;

  `uvm_object_utils(dma_cmodel_result)

  typedef struct {
    int                          periph;
    dma_periph_pkg::periph_ack_e ack;
  } ack_t;

  axi_pkg::axi_txn rd   [$];             // load bursts, program order
  axi_pkg::axi_txn wr   [$];             // store bursts, program order
  ack_t            acks [$];             // peripheral acknowledges, program order
  int              sev  [$];             // events raised by DMASEV

  dm_ev_e          end_kind;             // how the program ended
  bit [31:0]       pc, sar, dar, ccr, lc0, lc1, ftr, ftr_maybe, events;
  bit              sar_v, dar_v, ccr_v, lc0_v, lc1_v;   // the program wrote them
  int unsigned     insns;

  function new(string name = "dma_cmodel_result");
    super.new(name);
  endfunction

  // Ended through DMAEND / DMAKILL without any fault
  function bit clean_end();
    return end_kind == DM_EV_END || end_kind == DM_EV_KILL;
  endfunction

  function bit faulted();
    return end_kind == DM_EV_FAULT;
  endfunction

  virtual function string convert2string();
    return $sformatf("%s after %0d insns: %0d rd / %0d wr bursts, %0d acks, pc=0x%08h sar=0x%08h dar=0x%08h ccr=0x%08h lc0=%0d lc1=%0d ftr=0x%08h(+0x%08h)",
                     end_kind.name(), insns, rd.size(), wr.size(), acks.size(), pc, sar, dar, ccr,
                     lc0, lc1, ftr, ftr_maybe);
  endfunction

endclass : dma_cmodel_result


class dma_cmodel extends uvm_object;

  `uvm_object_utils(dma_cmodel)

  protected chandle h;
  int unsigned      max_steps = 200_000;      // events per program (run-away guard)

  function new(string name = "dma_cmodel");
    super.new(name);
  endfunction

  function bit available();
    return CMODEL_BUILT && h != null;
  endfunction

  // Model configured with the DUT parameters
  function void build_model();
    if (!CMODEL_BUILT) return;
    h = dma330_dpi_new(dma_tb_params_pkg::DATA_W / 8, dma_tb_params_pkg::NUM_EVENTS,
                       dma_tb_params_pkg::NUM_PERIPH, dma_tb_params_pkg::MFIFO_BYTES);
    if (h == null) `uvm_fatal("CMODEL", "dma330_dpi_new failed (unsupported configuration)")
  endfunction

  //----------------------------------------------------------------------------
  // Run the program at job.prog_addr with job.req_types as peripheral requests
  //----------------------------------------------------------------------------
  function dma_cmodel_result run(dma_job job, axi_pkg::axi_mem_model mem);
    dma_cmodel_result r = dma_cmodel_result::type_id::create("cm_result");
    dm_ev_e           k;
    bit               done = 0;
    int unsigned      steps = 0;

    if (h == null) `uvm_fatal("CMODEL", "run() without a model instance")

    dma330_dpi_go(h, job.prog_addr, int'(job.ns));
    foreach (job.req_types[i])
      dma330_dpi_periph_req(h, job.periph, int'(job.req_types[i] == dma_periph_pkg::PREQ_BURST),
                            int'(job.last_on_final && i == job.req_types.size() - 1));

    while (!done) begin
      k = dm_ev_e'(dma330_dpi_step(h));
      if (++steps > max_steps) begin
        r.end_kind = DM_EV_RUNAWAY;
        break;
      end
      case (k)
        DM_EV_NEED_CODE: supply(mem, ev(F_SUPPLY_ADDR), ev(F_SUPPLY_BYTES));
        DM_EV_LD: begin
          r.rd.push_back(burst(job.ch, 0));
          supply(mem, ev(F_SUPPLY_ADDR), ev(F_SUPPLY_BYTES));
        end
        DM_EV_ST, DM_EV_STZ: r.wr.push_back(burst(job.ch, 1));
        DM_EV_ACK: begin
          dma_cmodel_result::ack_t a;
          a.periph = int'(ev(F_PERIPH));
          case (dm_ack_e'(ev(F_ACK)))
            DM_ACK_BURST: a.ack = dma_periph_pkg::PACK_BURST;
            DM_ACK_FLUSH: a.ack = dma_periph_pkg::PACK_FLUSH;
            default:      a.ack = dma_periph_pkg::PACK_SINGLE;
          endcase
          r.acks.push_back(a);
        end
        DM_EV_SEV: r.sev.push_back(int'(ev(F_EVENT_NO)));
        DM_EV_WFE: ;
        default: begin                       // END, KILL, FAULT, STARVED, UNKNOWN, RUNAWAY
          r.end_kind = k;
          done = 1;
        end
      endcase
    end

    r.pc        = dma330_dpi_reg(h, DM_R_PC);
    r.sar       = dma330_dpi_reg(h, DM_R_SAR);
    r.dar       = dma330_dpi_reg(h, DM_R_DAR);
    r.ccr       = dma330_dpi_reg(h, DM_R_CCR);
    r.lc0       = dma330_dpi_reg(h, DM_R_LC0);
    r.lc1       = dma330_dpi_reg(h, DM_R_LC1);
    r.ftr       = dma330_dpi_reg(h, DM_R_FTR);
    r.ftr_maybe = dma330_dpi_reg(h, DM_R_FTR_MAYBE);
    r.events    = dma330_dpi_reg(h, DM_R_EVENTS);
    r.sar_v     = dma330_dpi_reg_valid(h, DM_R_SAR) != 0;
    r.dar_v     = dma330_dpi_reg_valid(h, DM_R_DAR) != 0;
    r.ccr_v     = dma330_dpi_reg_valid(h, DM_R_CCR) != 0;
    r.lc0_v     = dma330_dpi_reg_valid(h, DM_R_LC0) != 0;
    r.lc1_v     = dma330_dpi_reg_valid(h, DM_R_LC1) != 0;
    r.insns     = dma330_dpi_insns(h);
    return r;
  endfunction

  //----------------------------------------------------------------------------
  protected function int unsigned ev(int field);
    return dma330_dpi_ev(h, field);
  endfunction

  // Hand 'n' bytes of the memory model, from 'addr', to the C model
  protected function void supply(axi_pkg::axi_mem_model mem, bit [31:0] addr, int unsigned n);
    for (int unsigned base = 0; base < n; base += 16) begin
      bit [127:0] chunk = '0;
      int         nb    = (n - base > 16) ? 16 : int'(n - base);
      for (int k = 0; k < nb; k++) chunk[k*8 +: 8] = mem.read_byte(addr + base + k);
      dma330_dpi_supply(h, chunk, nb);
    end
  endfunction

  // The burst of the current LD / ST / STZ event as an expected AXI transaction
  protected function axi_pkg::axi_txn burst(int ch, bit is_write);
    axi_pkg::axi_txn t = axi_pkg::axi_txn::type_id::create(is_write ? "cm_wr" : "cm_rd");
    bit [31:0]       cache = ev(F_CACHE);
    bit [31:0]       prot  = ev(F_PROT);
    t.dir   = is_write ? axi_pkg::AXI_WRITE : axi_pkg::AXI_READ;
    t.id    = ch;
    t.addr  = ev(F_ADDR);
    t.len   = ev(F_LEN);
    t.size  = ev(F_SIZE);
    t.burst = ev(F_INC) ? axi_pkg::AXI_INCR : axi_pkg::AXI_FIXED;
    t.cache = {1'b0, cache[2:0]};
    t.prot  = prot[2:0];
    if (is_write) begin
      for (int b = 0; b < int'(ev(F_NBEATS)); b++) begin
        bit [127:0]  d;
        int unsigned s;
        dma330_dpi_beat(h, b, d, s);
        t.data.push_back(d[axi_pkg::AXI_DATA_W-1:0]);
        t.strb.push_back(s[axi_pkg::AXI_STRB_W-1:0]);
      end
    end
    return t;
  endfunction

  function void destroy_model();
    if (h != null) dma330_dpi_free(h);
    h = null;
  endfunction

endclass : dma_cmodel
