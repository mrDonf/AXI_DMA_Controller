//==============================================================================
// dma_traffic_vseq.sv - random jobs on several channels in parallel
//------------------------------------------------------------------------------
// Knobs (set by the test before start):
//   ch_mask      : channels that run jobs (in parallel)
//   jobs_per_ch  : sequential jobs per channel
//   kinds        : job kinds to choose from (uniformly)
//   aligned_only : force 8-byte aligned addresses / lengths, full-width beats
//   fixed_mode   : allow FIXED (non-incrementing) source or destination
//   max_bytes    : upper bound on bytes per M2M / FILL job
//   endian_mode  : M2M jobs use a random CCR endian swap (16/32/64-bit)
//   wd_timeout   : enable the watchdog (WD.timeout, x256 clk) during the
//                  traffic and check that it never reports a false lock-up
//==============================================================================
class dma_traffic_vseq extends dma_base_vseq;

  `uvm_object_utils(dma_traffic_vseq)

  bit [dma_tb_params_pkg::NUM_CH-1:0] ch_mask      = '1;
  int unsigned                        jobs_per_ch  = 4;
  dma_job_kind_e                      kinds [$]    = '{JOB_M2M};
  bit                                 aligned_only = 0;
  bit                                 fixed_mode   = 0;
  int unsigned                        max_bytes    = 2048;
  bit                                 endian_mode  = 0;
  int unsigned                        wd_timeout   = 0;
  protected int unsigned              n_swap [4];  // jobs per endian swap size

  function new(string name = "dma_traffic_vseq");
    super.new(name);
  endfunction

  virtual task body();
    // Channel n reports completion on irq[n]
    reg_wr(rm.INTEN, (1 << dma_tb_params_pkg::NUM_CH) - 1);
    if (wd_timeout != 0) reg_wr(rm.WD, wd_timeout << 16);

    for (int ch = 0; ch < dma_tb_params_pkg::NUM_CH; ch++) begin
      if (ch_mask[ch]) begin
        automatic int c = ch;
        fork
          channel_thread(c);
        join_none
      end
    end
    wait fork;

    if (endian_mode) begin
      `uvm_info("TRAFFIC", $sformatf("endian swap jobs: none=%0d 16-bit=%0d 32-bit=%0d 64-bit=%0d",
                                     n_swap[0], n_swap[1], n_swap[2], n_swap[3]), UVM_LOW)
      if (n_swap[1] + n_swap[2] + n_swap[3] == 0)
        `uvm_error("TRAFFIC", "endian_mode produced no job with an endian swap")
    end

    if (wd_timeout != 0) begin
      uvm_reg_data_t v;
      reg_rd(rm.WDSTAT, v);
      if (v != 0) `uvm_error("TRAFFIC", $sformatf("watchdog reported a lock-up during normal traffic: WDSTAT=0x%0h", v))
      else        `uvm_info("TRAFFIC", "watchdog enabled during the whole run: no false lock-up", UVM_LOW)
      reg_wr(rm.WD, 0);
    end
  endtask

  protected task channel_thread(int unsigned ch);
    for (int i = 0; i < jobs_per_ch; i++) begin
      dma_job_kind_e kind = kinds[$urandom_range(kinds.size() - 1)];
      dma_job        job  = dma_job::type_id::create($sformatf("job_ch%0d_%0d", ch, i));
      // Addressing mode chosen up front: a 'dist' cannot override the job's
      // soft "incrementing" defaults, so the mode is applied as a hard value.
      bit s_inc = 1, d_inc = 1;
      if (fixed_mode) begin
        case ($urandom_range(3))
          0: s_inc = 0;                     // peripheral FIFO -> memory
          1: d_inc = 0;                     // memory -> peripheral FIFO
          2: begin s_inc = 0; d_inc = 0; end // FIFO -> FIFO
          default: ;                        // both incrementing
        endcase
      end
      job.max_bytes = max_bytes;
      if (!job.randomize() with {
            ch   == local::ch;
            kind == local::kind;
            if (local::aligned_only) {
              src % 8 == 0;  dst % 8 == 0;  nbytes % 8 == 0;
              src_size == 3; dst_size == 3;
            }
            src_inc == local::s_inc;
            dst_inc == local::d_inc;
            if (local::fixed_mode) nbytes <= 512;
            solve swap before dst_size;
            // DMASTZ ignores the endian swap field, even an illegal value
            if (local::endian_mode && kind == JOB_FILL) swap inside {[1:7]};
            // Endian swap: whole aligned destination beats, group <= beat
            if (local::endian_mode && kind == JOB_M2M) {
              swap dist {1 := 1, 2 := 1, 3 := 1};
              swap <= dst_size;
              dst % (1 << dst_size) == 0;
              nbytes % (1 << dst_size) == 0;
            }
          })
        `uvm_fatal("RAND", "job randomize failed")
      job.periph = ch % dma_tb_params_pkg::NUM_PERIPH;
      if (job.kind == JOB_M2M && job.swap < 4) n_swap[job.swap]++;
      run_job(job);
    end
  endtask

endclass : dma_traffic_vseq
