`timescale 1ns/1ps
// Measure address-latency hiding with prequeued, data-ready bursts. This is
// an observation of a performance limitation, not an AXI protocol violation.
module dma_write_perf_tb;
  import dma330_pkg::*;
  localparam int NUM_CH=2, DATA_W=64, ID_W=4, MF_CNT_W=10;
  parameter int ADDRESS_LATENCY=8;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic [NUM_CH-1:0] wq_push=0, wq_full, ch_flush=0;
  xfer_t wq_data[NUM_CH];
  logic [MF_CNT_W-1:0] mf_count[NUM_CH];
  logic [DATA_W-1:0] mf_pop_data=0;
  logic mf_pop_ch;
  logic [NUM_CH-1:0] mf_pop;
  logic [3:0] mf_pop_n;
  logic m_awvalid, m_awready=1, m_wvalid, m_wready, m_wlast;
  logic [ID_W-1:0] m_awid, m_bid=0;
  logic [31:0] m_awaddr;
  logic [7:0] m_awlen;
  logic [2:0] m_awsize, m_awprot;
  logic [1:0] m_awburst, m_bresp=0;
  logic [3:0] m_awcache;
  logic [DATA_W-1:0] m_wdata;
  logic [7:0] m_wstrb;
  logic m_bvalid=0, m_bready;
  logic [NUM_CH-1:0] wr_busy, wr_active, store_pending, wr_err, wr_beat;
  logic [31:0] wr_err_addr;
  logic ack_valid, ack_ready=1, ack_burst;
  logic [4:0] ack_periph;
  int cycle=0, aws=0, beats=0;
  int ready_at[4], wr_idx=0, rd_idx=0;
  int first_aw=-1, last_w=-1, first_w=-1;
  bit release_data=0;
  dma_wr_engine #(.NUM_CH(NUM_CH),.DATA_W(DATA_W),.ID_W(ID_W),
                  .WQ_DEPTH(8),.WR_OUT(8),.MF_CNT_W(MF_CNT_W)) dut(.*);

  assign m_wready=release_data && rd_idx<wr_idx && cycle>=ready_at[rd_idx%4];
  always @(posedge clk) begin
    if (rst_n) begin
      cycle++;
      if (m_bvalid && m_bready) m_bvalid<=0;
      if (m_awvalid && m_awready) begin
        if (first_aw<0) first_aw=cycle;
        aws++;
        ready_at[wr_idx%4]=cycle+ADDRESS_LATENCY+1; wr_idx++;
      end
      if (m_wvalid && m_wready) begin
        if (first_w<0) first_w=cycle;
        beats++;
        last_w=cycle;
        if (m_wlast) begin rd_idx++; m_bvalid<=1; end
      end
    end
  end
  task step(); @(posedge clk); #1; endtask
  initial begin
    foreach(wq_data[c]) begin wq_data[c]='0; mf_count[c]=0; end
    repeat(2) step(); rst_n=1; step();
    for(int n=0;n<4;n++) begin
      wq_data[0]='0; wq_data[0].addr=32'h1000+n*128;
      wq_data[0].len=15; wq_data[0].size=3; wq_data[0].inc=1;
      wq_data[0].bytes=128; wq_data[0].zero=1;
      wq_push[0]=1; step(); wq_push=0;
    end
    release_data=1;
    for(int n=0;n<1000 && beats<64;n++) step();
    if(aws!=4 || beats!=64) $fatal(1,"performance probe did not complete");
    if(last_w-first_w+1!=64) $fatal(1,"AW latency was not hidden between ready bursts");
    $display("PERF_OBSERVATION latency=%0d AWs=%0d beats=%0d W_window=%0d cycles utilization=%0.2f%%",ADDRESS_LATENCY,aws,beats,last_w-first_w+1,100.0*beats/(last_w-first_w+1));
    $display("PERF_PROBE_DONE"); $finish;
  end
endmodule
