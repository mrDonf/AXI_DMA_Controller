`timescale 1ns/1ps
module dma_wr_engine_tb;
  import dma330_pkg::*;
  parameter int DATA_W = 64;
  localparam int NUM_CH = 2, NB = DATA_W/8, ID_W = 4, MF_CNT_W = 10;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [NUM_CH-1:0] wq_push = '0, wq_full, ch_flush = '0;
  xfer_t wq_data [NUM_CH];
  logic [MF_CNT_W-1:0] mf_count [NUM_CH];
  logic [DATA_W-1:0] mf_pop_data;
  logic mf_pop_ch;
  logic [NUM_CH-1:0] mf_pop;
  logic [$clog2(NB):0] mf_pop_n;
  logic m_awvalid, m_awready = 1, m_wvalid, m_wready = 0, m_wlast;
  logic [ID_W-1:0] m_awid, m_bid = 0;
  logic [31:0] m_awaddr;
  logic [7:0] m_awlen;
  logic [2:0] m_awsize, m_awprot;
  logic [1:0] m_awburst, m_bresp = 0;
  logic [3:0] m_awcache;
  logic [DATA_W-1:0] m_wdata;
  logic [NB-1:0] m_wstrb;
  logic m_bvalid = 0, m_bready;
  logic [NUM_CH-1:0] wr_busy, wr_active, store_pending, wr_err, wr_beat;
  logic [31:0] wr_err_addr;
  logic ack_valid, ack_ready = 1, ack_burst;
  logic [4:0] ack_periph;
  int supply [NUM_CH], offset [NUM_CH];
  int cycle = 0, writes = 0, last_write = -1;
  bit consecutive = 0, zeros = 1, grouped = 0;
  bit wide_grouped = 0;
  logic [DATA_W-1:0] expected_data;
  logic [NB-1:0] expected_strb;
  dma_wr_engine #(.NUM_CH(NUM_CH), .DATA_W(DATA_W), .ID_W(ID_W),
                  .WQ_DEPTH(8), .WR_OUT(8), .MF_CNT_W(MF_CNT_W)) dut (.*);
  always_comb begin
    for (int k = 0; k < NB; k++)
      mf_pop_data[k*8 +: 8] = 8'(offset[mf_pop_ch] + k + 16*int'(mf_pop_ch));
    expected_data = zeros ? '0 : mf_pop_data;
    expected_strb = '1;
    if (grouped) begin
      expected_data = '0;
      expected_strb = NB'(3 << ((writes % (NB/2))*2));
      for (int k = 0; k < 2; k++)
        expected_data[((writes % (NB/2))*2+k)*8 +: 8] =
          8'(offset[mf_pop_ch] + NB-1 - (writes % (NB/2))*2-k);
    end
    if (wide_grouped) begin
      expected_data = '0;
      expected_strb = NB'(3 << ((writes*2)%NB));
      for (int k=0;k<2;k++)
        expected_data[(((writes*2)%NB)+k)*8 +: 8] =
          8'((writes/8)*16 + 15 - (writes%8)*2-k);
    end
  end
  always @(posedge clk) begin
    if (!rst_n) begin
      cycle = 0; writes = 0; last_write = -1;
      foreach (mf_count[c]) begin mf_count[c] <= 0; offset[c] <= 0; end
    end else begin
      cycle++;
      foreach (mf_count[c]) begin
        if (mf_pop[c] && mf_count[c] < mf_pop_n) $fatal(1, "MFIFO underflow at burst handover");
        mf_count[c] <= MF_CNT_W'(int'(mf_count[c]) + supply[c] - (mf_pop[c] ? int'(mf_pop_n) : 0));
        if (mf_pop[c]) offset[c] <= offset[c] + int'(mf_pop_n);
      end
      if (m_wvalid && m_wready) begin
        if (consecutive && last_write >= 0 && cycle != last_write+1)
          $fatal(1, "avoidable W bubble: cycles %0d -> %0d", last_write, cycle);
        if (m_wdata !== expected_data || m_wstrb !== expected_strb)
          $fatal(1, "wrong W bytes/strobes at handover");
        writes++;
        last_write = cycle;
      end
    end
  end
  AW_STABLE: assert property (@(posedge clk) disable iff (!rst_n)
      m_awvalid && !m_awready |=> m_awvalid && $stable({m_awid,m_awaddr,m_awlen,m_awsize,m_awburst}));
  W_STABLE: assert property (@(posedge clk) disable iff (!rst_n)
      m_wvalid && !m_wready |=> m_wvalid && $stable({m_wdata,m_wstrb,m_wlast}));
  task step(); @(posedge clk); #1; endtask
  task reset_case(bit zero_data);
    rst_n = 0; wq_push = 0; ch_flush = 0; m_wready = 0; m_awready = 1;
    consecutive = 0; zeros = zero_data; grouped = 0; wide_grouped = 0;
    foreach (supply[c]) supply[c] = 0;
    repeat (2) step(); rst_n = 1; step();
  endtask
  task enqueue_group(int addr);
    wq_data[0] = '0;
    wq_data[0].addr = addr;
    wq_data[0].len = 4'(NB/2-1);
    wq_data[0].size = 1;
    wq_data[0].inc = 1;
    wq_data[0].bytes = XBYTES_W'(NB);
    wq_data[0].swap = 3'($clog2(NB));
    wq_push[0] = 1; step(); wq_push = 0;
  endtask
  task enqueue(int ch, int beats, int addr);
    wq_data[ch] = '0;
    wq_data[ch].addr = addr;
    wq_data[ch].len = 4'(beats-1);
    wq_data[ch].size = 3'($clog2(NB));
    wq_data[ch].inc = 1;
    wq_data[ch].bytes = XBYTES_W'(beats*NB);
    wq_data[ch].zero = zeros;
    if (wq_full[ch]) $fatal(1, "unexpected WQ full");
    wq_push[ch] = 1; step(); wq_push = 0;
  endtask
  task wait_writes(int n);
    for (int t = 0; t < 100 && writes < n; t++) step();
    if (writes != n) $fatal(1, "writes=%0d expected=%0d", writes, n);
  endtask
  initial begin
    foreach (wq_data[c]) wq_data[c] = '0;
    reset_case(1);
    for (int n = 0; n < 4; n++) enqueue(0, 1, 32'h1000+n*NB);
    consecutive = 1; m_wready = 1; wait_writes(4); consecutive = 0;
    // Same-channel handover must subtract the current last beat before
    // deciding that the next burst has all of its data.
    reset_case(0);
    supply[0] = NB; step(); supply[0] = 0;
    enqueue(0, 1, 32'h1000); enqueue(0, 1, 32'h2000);
    m_wready = 1; wait_writes(1);
    repeat (4) begin step(); if (m_wvalid || m_awvalid) $fatal(1, "started a burst without its data"); end
    supply[0] = NB; step(); supply[0] = 0; wait_writes(2);
    // A swap group wider than the beat is popped as a whole on its final
    // beat. Handover must subtract that whole group, not just one beat.
    reset_case(0); grouped = 1;
    supply[0] = NB; step(); supply[0] = 0;
    enqueue_group(32'h1000); enqueue_group(32'h2000);
    m_wready = 1; wait_writes(NB/2);
    repeat (3) begin step(); if (m_wvalid || m_awvalid) $fatal(1, "reused a popped swap group"); end
    supply[0] = NB; step(); supply[0] = 0; wait_writes(NB);
    // Multi-beat and cross-channel handovers preserve the stream bytes.
    reset_case(0);
    supply[0] = 3*NB; supply[1] = NB; step(); supply[0] = 0; supply[1] = 0;
    enqueue(0, 2, 32'h1000); enqueue(1, 1, 32'h2000); enqueue(0, 1, 32'h3000);
    consecutive = 1; m_wready = 1; wait_writes(4); consecutive = 0;
    // W may finish before AW. The pending address must stay stable, and
    // the replacement cannot overwrite it until AWREADY is asserted.
    reset_case(1); m_awready = 0;
    enqueue(0, 1, 32'h4000); enqueue(1, 1, 32'h5000);
    m_wready = 1; wait_writes(1);
    repeat (3) begin step(); if (!m_awvalid || m_awaddr != 32'h4000 || m_wvalid)
      $fatal(1, "pending AW lost when W finished first"); end
    m_awready = 1; wait_writes(2);
    // A 128-bit natural group is legal on every supported data-bus width.
    // Two groups, narrow beats, random-like AW/W stalls and MFIFO accounting.
    reset_case(0); wide_grouped=1;
    supply[0]=32; step(); supply[0]=0;
    wq_data[0]='0; wq_data[0].addr=32'h6000;
    wq_data[0].len=15; wq_data[0].size=1; wq_data[0].inc=1;
    wq_data[0].bytes=32; wq_data[0].swap=4;
    wq_push[0]=1; step(); wq_push=0;
    for(int n=0;n<300 && writes<16;n++) begin
      m_awready=(n%5)!=0; m_wready=(n%4)!=0; step();
    end
    if(writes!=16 || mf_count[0]!=0) $fatal(1,"128-bit endian groups did not drain exactly");
    $display("UNIT TEST PASSED: dma_wr_engine_tb DATA_W=%0d", DATA_W);
    $finish;
  end
  initial begin #100000; $fatal(1, "write test timeout"); end
endmodule
