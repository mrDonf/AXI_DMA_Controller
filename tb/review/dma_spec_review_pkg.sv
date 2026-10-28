// Independent TRM conformance probes. The existing stream/C reference models
// are deliberately not used as an oracle for the disputed behavior.
package dma_spec_review_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import dma_env_pkg::*;
  import dma_seq_pkg::*;
  import dma_test_pkg::*;
  import dma_tb_params_pkg::*;

  class dma_spec_review_vseq extends dma_base_vseq;
    `uvm_object_utils(dma_spec_review_vseq)
    function new(string name="dma_spec_review_vseq"); super.new(name); endfunction
    localparam int BS=$clog2(DATA_W/8);

    task clean_end();
      bit [31:0] st,ft;
      vif.wait_clks(1000);
      apb_rd(0,12'h100,st); apb_rd(0,12'h040,ft);
      if(st[3:0]!=0 || ft!=0) `uvm_error("SPEC_COMPLETION",$sformatf("CSR=%08h FTR=%08h",st,ft))
    endtask
    task wait_barrier_pc(bit[31:0] wanted);
      bit[31:0] cp,st;
      for(int n=0;n<200;n++) begin
        apb_rd(0,12'h104,cp); apb_rd(0,12'h100,st);
        if(cp==wanted && st[3:0]==dma330_pkg::ST_AT_BARRIER) return;
        vif.wait_clks(5);
      end
      `uvm_fatal("SPEC_BARRIER_TIMEOUT",$sformatf("barrier at %h not reached, CPC=%h CSR=%h",wanted,cp,st))
    endtask

    task launch(dma330_asm a, bit ns=0);
      p_sequencer.cfg.mem.write_bytes(32'h10000, a.code);
      start_channel(0,32'h10000,ns);
    endtask

    virtual task body();
      string scenario;
      dma330_asm a = dma330_asm::type_id::create("probe_program");
      bit [31:0] status, fault, pc, ris, debug_status, old_pc;
      void'($value$plusargs("SPEC_CASE=%s",scenario));
      case (scenario)
        "alignment": begin
          // TRM 2.11.3: changing destination byte-lane alignment drains both
          // directions and discards residual data before the next instruction.
          for (int i=0;i<8;i++) begin
            p_sequencer.cfg.mem.write_byte(32'h20000000+i,8'h10+i);
            p_sequencer.cfg.mem.write_byte(32'h20000008+i,8'h20+i);
            p_sequencer.cfg.mem.write_byte(32'h30000000+i,8'hAA);
          end
          a.dmamov(RD_CCR,dma330_asm::ccr(1,BS>3 ? 3:BS,BS==2 ? 2:1,1,BS-1,1));
          a.dmamov(RD_SAR,32'h20000000);
          a.dmamov(RD_DAR,32'h30000000);
          a.dmald();
          a.dmamov(RD_DAR,32'h30000000+DATA_W/16);
          a.dmald(); a.dmast(); a.dmaend();
          launch(a); vif.wait_clks(500);
          apb_rd(0,12'h100,status); apb_rd(0,12'h040,fault);
          if (status[3:0] != dma330_pkg::ST_STOPPED || fault != 0)
            `uvm_fatal("SPEC_SETUP","alignment program did not finish cleanly")
          for (int i=0;i<DATA_W/16;i++) begin
            bit [7:0] got = p_sequencer.cfg.mem.read_byte(32'h30000000+DATA_W/16+i);
            if (got != 8'h20+i)
              `uvm_error("SPEC_ALIGNMENT",$sformatf("dst[%0d]=%02h expected=%02h after destination discontinuity",i,got,8'h20+i))
          end
        end
        "ccr_security": begin
          // TRM Table 3-21: NS programming either PROT[1] LOW aborts at MOV.
          a.dmamov(RD_CCR,0); a.dmasev(0); a.dmaend();
          launch(a,1); vif.wait_clks(300);
          apb_rd(0,12'h100,status); apb_rd(0,12'h040,fault);
          apb_rd(0,12'h104,pc); apb_rd(0,12'h024,ris);
          if (fault != 32'h80 || pc != 32'h10000 || ris[0])
            `uvm_error("SPEC_CCR_SECURITY",$sformatf("CSR=%08h FTR=%08h CPC=%08h RIS=%08h; expected FTR=80 CPC=10000 RIS[0]=0",status,fault,pc,ris))
        end
        "ns_debug": begin
          // TRM Table 3-4 and 2.5.1: manager DNS gates the NS debug interface.
          a.dmawfe(0); a.dmaend(); launch(a,1);
          wait_ch_status(0,dma330_pkg::ST_WAIT_EVENT);
          apb_rd(0,12'h000,status);
          if (status[9]) `uvm_fatal("SPEC_SETUP","manager must be secure")
          dbg_exec_ns(1,0,'{8'h01}); vif.wait_clks(100);
          apb_rd(0,12'h100,status);
          if (status[3:0] != dma330_pkg::ST_WAIT_EVENT)
            `uvm_error("SPEC_NS_DEBUG",$sformatf("NS DMAKILL changed CSR=%08h while manager DNS=0; expected channel to remain waiting",status))
        end
        "manager_debug": begin
          // The boot program has thousands of NOPs, no WFE/END in this window.
          // A realtime debug instruction must be serviced during execution.
          apb_rd(0,12'h004,old_pc);
          kill_manager(); vif.wait_clks(256);
          apb_rd(0,12'hD00,debug_status);
          apb_rd(0,12'h000,status); apb_rd(0,12'h004,pc);
          if (debug_status[0] || status[3:0] != dma330_pkg::ST_STOPPED)
            `uvm_error("SPEC_MANAGER_DEBUG",$sformatf("DMAKILL pending while healthy boot program continues: DBGSTATUS=%08h DSR=%08h DPC=%08h->%08h",debug_status,status,old_pc,pc))
        end
        "false_store_lock", "false_store_lock_control": begin
          dma330_asm other=dma330_asm::type_id::create("other_program");
          // Each program has static requirement 0 and dynamic requirement
          // 128 lines. The shared pool is 128 lines, so TRM 2.11.4 load-lock
          // must serialize the loads and avoid resource starvation.
          a.dmawfe(8);
          a.dmamov(RD_CCR,dma330_asm::ccr(1,BS,16,1,BS,16));
          a.dmamov(RD_SAR,32'h20000000); a.dmamov(RD_DAR,32'h30000000);
          repeat(4) a.dmald();
          // Replacing the false conditional store by an actual NOP is a
          // semantic control: these two programs must behave identically.
          if(scenario == "false_store_lock_control") a.dmanop();
          else a.dmast(COND_B); // initial request_type=Single: MUST be a DMANOP
          repeat(64) a.dmanop();
          repeat(4) a.dmald(); repeat(8) a.dmast(); a.dmaend();
          other.dmawfe(9);
          other.dmamov(RD_CCR,dma330_asm::ccr(1,BS,16,1,BS,16));
          other.dmamov(RD_SAR,32'h21000000); other.dmamov(RD_DAR,32'h31000000);
          repeat(8) other.dmald(); repeat(8) other.dmast(); other.dmaend();
          p_sequencer.cfg.mem.write_bytes(32'h11000,other.code);
          launch(a); start_channel(1,32'h11000);
          wait_ch_status(0,dma330_pkg::ST_WAIT_EVENT);
          wait_ch_status(1,dma330_pkg::ST_WAIT_EVENT);
          dbg_exec(1,0,'{8'h34,8'h40}); // wake event 8
          for(int i=0;i<100;i++) begin
            apb_rd(0,12'h400,pc);
            if(pc>=32'h20000080) break; // ch0 has taken load-lock
          end
          if(pc<32'h20000080) `uvm_fatal("SPEC_SETUP","ch0 did not issue its first load")
          dbg_exec(1,0,'{8'h34,8'h48}); // wake event 9
          vif.wait_clks(2000);
          apb_rd(0,12'h040,fault); apb_rd(0,12'h044,ris);
          apb_rd(0,12'h100,status); apb_rd(0,12'h108,pc);
          if(fault!=0 || ris!=0 || status[3:0]!=0 || pc[3:0]!=0)
            `uvm_error("SPEC_FALSE_STORE_LOCK",$sformatf("false DMASTB released load-lock: FTR0=%08h FTR1=%08h CSR0=%08h CSR1=%08h",fault,ris,status,pc))
        end
        "wide_swap": begin
          // Two 128-bit groups, first write burst split at 4 KB. Both the
          // reversal and group staging must survive address/data stalls.
          for(int i=0;i<64;i++) p_sequencer.cfg.mem.write_byte(32'h20000000+i,8'h20+i);
          a.dmamov(RD_CCR,dma330_asm::ccr(1,BS,32/(DATA_W/8),1,2,8,0,0,0,0,4));
          a.dmamov(RD_SAR,32'h20000000); a.dmamov(RD_DAR,32'h30000FF0);
          a.dmald(); a.dmast(); a.dmaend(); launch(a); clean_end();
          for(int i=0;i<32;i++) begin
            bit[7:0] got=p_sequencer.cfg.mem.read_byte(32'h30000FF0+i);
            if(got!=8'h20+(i^15)) `uvm_error("SPEC_SWAP",$sformatf("byte %0d=%02h expected=%02h",i,got,8'h20+(i^15)))
          end
        end
        "reconfig_fields": begin
          // Each iteration changes one field after a load. True destination
          // discontinuities discard data; source-only and non-discontinuous
          // updates must preserve it, independent of bus timing.
          for(int which=0;which<10;which++) begin
            bit[31:0] initial_ccr=dma330_asm::ccr(1,2,2,which==2 ? 0:1,2,1);
            bit[31:0] next_ccr=initial_ccr;
            bit discard=which<4;
            a=dma330_asm::type_id::create("field_probe");
            a.dmamov(RD_CCR,initial_ccr);
            a.dmamov(RD_SAR,32'h20000000); a.dmamov(RD_DAR,32'h30000000);
            a.dmald();
            case(which)
              0: begin next_ccr[30:28]=1; a.dmamov(RD_CCR,next_ccr); end
              1: begin next_ccr[14]=0; a.dmamov(RD_CCR,next_ccr); end
              2: begin next_ccr[17:15]=1; a.dmamov(RD_CCR,next_ccr); end
              3: a.dmamov(RD_DAR,32'h30000002);
              4: a.dmamov(RD_SAR,32'h20001001);
              5: begin next_ccr[3:1]=1; a.dmamov(RD_CCR,next_ccr); end
              6: begin next_ccr[0]=0; a.dmamov(RD_CCR,next_ccr); end
              7: begin next_ccr[17:15]=1; a.dmamov(RD_CCR,next_ccr); end
              8: a.dmamov(RD_DAR,32'h30001000);
              9: begin next_ccr[7:4]=0; next_ccr[21:18]=1; a.dmamov(RD_CCR,next_ccr); end
            endcase
            a.dmast(); a.dmaend(); launch(a); vif.wait_clks(1000);
            apb_rd(0,12'h040,fault); apb_rd(0,12'h100,status);
            if(discard ? fault!=32'h2000 : (fault!=0 || status[3:0]!=0))
              `uvm_error("SPEC_RECONFIG",$sformatf("field %0d discard=%b CSR=%h FTR=%h",which,discard,status,fault))
            kill_channel(0); wait_ch_status(0,dma330_pkg::ST_STOPPED);
          end
        end
        "source_barrier": begin
          for(int i=0;i<8;i++) p_sequencer.cfg.mem.write_byte(32'h20000000+i,8'h70+i);
          p_sequencer.cfg.axi_cfg.add_stall_region(32'h20000000,32'h20000007);
          a.dmamov(RD_CCR,dma330_asm::ccr(1,2,2,1,2,2));
          a.dmamov(RD_SAR,32'h20000000); a.dmamov(RD_DAR,32'h30000000);
          a.dmald(); a.dmamov(RD_SAR,32'h20001001); a.dmasev(0); a.dmast(); a.dmaend();
          launch(a); wait_barrier_pc(32'h10013);
          apb_rd(0,12'h400,pc); apb_rd(0,12'h024,ris);
          if(pc!=32'h20000008 || ris[0]) `uvm_error("SPEC_SOURCE_BARRIER","MOV source committed before read completion")
          p_sequencer.cfg.axi_cfg.clear_stall_regions(); clean_end();
          for(int i=0;i<8;i++)
            if(p_sequencer.cfg.mem.read_byte(32'h30000000+i)!=8'h70+i)
              `uvm_error("SPEC_SOURCE_RETAIN","source discontinuity discarded residual bytes")
        end
        "destination_barrier": begin
          p_sequencer.cfg.axi_cfg.add_stall_region(32'h30000000,32'h3000000F);
          p_sequencer.cfg.axi_cfg.add_stall_region(32'h20000010,32'h2000001F);
          for(int i=0;i<64;i++) p_sequencer.cfg.mem.write_byte(32'h20000000+i,8'h40+i);
          a.dmamov(RD_CCR,dma330_asm::ccr(1,2,4,1,2,2));
          a.dmamov(RD_SAR,32'h20000000); a.dmamov(RD_DAR,32'h30000000);
          a.dmald(); a.dmast(); a.dmald();
          a.dmamov(RD_DAR,32'h30001002); a.dmasev(0);
          a.dmald(); a.dmast(); a.dmaend(); launch(a);
          wait_barrier_pc(32'h10015);
          apb_rd(0,12'h404,pc); apb_rd(0,12'h024,ris);
          if(pc!=32'h30000008 || ris[0]) `uvm_error("SPEC_DEST_BARRIER","MOV destination committed before R/B drain")
          p_sequencer.cfg.axi_cfg.clear_stall_regions(); clean_end();
          for(int i=0;i<6;i++)
            if(p_sequencer.cfg.mem.read_byte(32'h30001002+i)!=8'h60+i)
              `uvm_error("SPEC_DEST_DISCARD","destination discontinuity reused old bytes")
        end
        "manager_resume": begin
          a.dmasev(1); a.dmaend();
          p_sequencer.cfg.mem.write_bytes(32'h10000,a.code);
          reg_wr(rm.INTEN,7); start_channel(0,32'h10000);
          dbg_exec(0,0,'{8'h34,8'h10});
          wait_irq(0); wait_irq(1); wait_irq(2);
          vif.wait_clks(30);
          apb_rd(0,12'h004,pc); apb_rd(0,12'hD00,debug_status);
          if(pc!=32'h8102 || debug_status[0])
            `uvm_error("SPEC_MANAGER_RESUME",$sformatf("DPC=%h DBG=%h; expected program END at 8102",pc,debug_status))
        end
        "manager_stalled": begin
          kill_manager(); vif.wait_clks(50); apb_rd(0,12'h000,status);
          if(status[3:0]!=0) `uvm_error("SPEC_MANAGER_STALLED","kill could not interrupt stalled fetch")
          p_sequencer.cfg.axi_cfg.clear_stall_regions(); vif.wait_clks(1000);
          apb_rd(0,12'h038,fault); apb_rd(0,12'h004,pc);
          if(fault!=0 || pc!=32'h8000) `uvm_error("SPEC_MANAGER_LATE","late refill revived killed manager")
        end
        "cache_crossline": begin
          repeat(3) a.dmanop(); a.dmamov(RD_SAR,32'h12345678); a.dmaend();
          launch(a); clean_end(); apb_rd(0,12'h400,pc);
          if(pc!=32'h12345678) `uvm_error("SPEC_THIRD_LINE","three-line DMAMOV assembled incorrectly")
        end
        "lockup_wait": begin
          dma330_asm b=dma330_asm::type_id::create("lock_b");
          dma330_asm c=dma330_asm::type_id::create("external_wait");
          a.dmamov(RD_CCR,dma330_asm::ccr(1,BS,16,1,BS,16));
          a.dmamov(RD_SAR,32'h20000000); a.dmamov(RD_DAR,32'h30000000);
          repeat(6) a.dmald(); a.dmawfe(8); a.dmald(); a.dmaend();
          b.dmamov(RD_CCR,dma330_asm::ccr(1,BS,16,1,BS,16));
          b.dmamov(RD_SAR,32'h21000000); b.dmamov(RD_DAR,32'h31000000);
          repeat(3) b.dmald(); b.dmaend();
          c.dmawfe(9); c.dmaend();
          p_sequencer.cfg.mem.write_bytes(32'h11000,b.code);
          p_sequencer.cfg.mem.write_bytes(32'h12000,c.code);
          start_channel(2,32'h12000); wait_ch_status(2,dma330_pkg::ST_WAIT_EVENT);
          launch(a); wait_ch_status(0,dma330_pkg::ST_WAIT_EVENT);
          start_channel(1,32'h11000); vif.wait_clks(200);
          dbg_exec(1,0,'{8'h34,8'h40}); vif.wait_clks(200);
          apb_rd(0,12'h040,fault); apb_rd(0,12'h044,ris);
          if(fault || ris) `uvm_error("SPEC_LOCKUP_WAIT","lockup reported while another running thread waits externally")
          kill_channel(2); wait_ch_status(2,dma330_pkg::ST_STOPPED); vif.wait_clks(200);
          apb_rd(0,12'h040,fault); apb_rd(0,12'h044,ris);
          if(fault!=32'h80000000 || ris!=32'h80000000)
            `uvm_error("SPEC_LOCKUP_ALL","lockup not reported after all running channels blocked at LD")
        end
        default: `uvm_fatal("SPEC_CASE",{"unknown case ",scenario})
      endcase
      `uvm_info("SPEC_PROBE_DONE",scenario,UVM_NONE)
    endtask
  endclass

  class dma_spec_review_test extends dma_base_test;
    `uvm_component_utils(dma_spec_review_test)
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    virtual function void configure(dma_env_cfg cfg);
      string scenario;
      void'($value$plusargs("SPEC_CASE=%s",scenario));
      cfg.axi_cfg.set_fast(); cfg.axi_cfg.reorder_en=0; cfg.axi_cfg.interleave_en=0;
      cfg.has_scoreboard=0; cfg.cmodel_en=0;
      cfg.ctrl_vif.boot_manager_ns=0;
      cfg.ctrl_vif.boot_irq_ns='1;
      if (scenario inside {"manager_debug","manager_resume","manager_stalled"}) begin
        for (int i=0;i<4096;i++) cfg.mem.write_byte(32'h8000+i,8'h18);
        cfg.mem.write_byte(32'h9000,0);
        cfg.ctrl_vif.boot_from_pc=1; cfg.ctrl_vif.boot_addr=32'h8000;
        if(scenario=="manager_resume") begin
          cfg.mem.write_byte(32'h8100,8'h34); cfg.mem.write_byte(32'h8101,0);
          cfg.mem.write_byte(32'h8102,0);
        end
        if(scenario=="manager_stalled") cfg.axi_cfg.add_stall_region(32'h8000,32'h8FFF);
      end
      if(scenario=="wide_swap") cfg.axi_cfg.set_slow();
      // A blocked data RID must not prevent fetching the barrier instruction
      // on the distinct instruction RID, especially with four-byte lines.
      if(scenario inside {"source_barrier","destination_barrier"}) begin
        cfg.axi_cfg.reorder_en=1; cfg.axi_cfg.interleave_en=1;
      end
    endfunction
    virtual function dma_base_vseq create_vseq();
      return dma_spec_review_vseq::type_id::create("vseq");
    endfunction
  endclass
endpackage

module dma_spec_review_top;
  import dma_spec_review_pkg::*;
  parameter bit ASYNC=0;
  tb_top #(.ASYNC(ASYNC)) tb();
endmodule
