//==============================================================================
// dma_apb_async_bridge.sv
//------------------------------------------------------------------------------
// APB slave (pclk domain) -> APB master (clk domain) asynchronous bridge.
//
//   pclk domain                                  clk domain
//   APB slave  --[ request  handshake: addr/wdata/write ]-->  APB master FSM
//   (PREADY=0) <--[ response handshake: rdata/slverr    ]--   (to register file)
//
// One transfer is in flight at a time; the pclk-side holds PREADY low until the
// response arrives. Both directions use dma_cdc_handshake, so every multi-bit
// field is quasi-static while it crosses.
//==============================================================================
module dma_apb_async_bridge #(
  parameter int ADDR_W = 12,
  parameter int DATA_W = 32
) (
  // APB slave side (pclk domain)
  input  logic              pclk,
  input  logic              presetn,
  input  logic              s_psel,
  input  logic              s_penable,
  input  logic              s_pwrite,
  input  logic [ADDR_W-1:0] s_paddr,
  input  logic [DATA_W-1:0] s_pwdata,
  output logic              s_pready,
  output logic [DATA_W-1:0] s_prdata,
  output logic              s_pslverr,

  // APB master side (clk domain)
  input  logic              clk,
  input  logic              rst_n,
  output logic              m_psel,
  output logic              m_penable,
  output logic              m_pwrite,
  output logic [ADDR_W-1:0] m_paddr,
  output logic [DATA_W-1:0] m_pwdata,
  input  logic              m_pready,
  input  logic [DATA_W-1:0] m_prdata,
  input  logic              m_pslverr
);

  localparam int REQ_W = 1 + ADDR_W + DATA_W;   // {write, addr, wdata}
  localparam int RSP_W = 1 + DATA_W;            // {slverr, rdata}

  //----------------------------------------------------------------------------
  // pclk domain: launch request, wait for response
  //----------------------------------------------------------------------------
  logic             req_src_valid, req_src_ready;
  logic             rsp_dst_valid, rsp_dst_ready;
  logic [RSP_W-1:0] rsp_dst_data;
  logic             launched;   // request of the current APB transfer was sent

  assign req_src_valid = s_psel && !launched;
  assign rsp_dst_ready = s_psel && s_penable;          // consumed in access phase

  assign s_pready  = s_psel && s_penable && rsp_dst_valid;
  assign {s_pslverr, s_prdata} = rsp_dst_valid ? rsp_dst_data : '0;

  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn)
      launched <= 1'b0;
    else if (s_pready)                                  // transfer completes
      launched <= 1'b0;
    else if (req_src_valid && req_src_ready)
      launched <= 1'b1;
  end

  //----------------------------------------------------------------------------
  // Clock-domain crossings
  //----------------------------------------------------------------------------
  logic             req_dst_valid, req_dst_ready;
  logic [REQ_W-1:0] req_dst_data;
  logic             rsp_src_valid, rsp_src_ready;
  logic [RSP_W-1:0] rsp_src_data;

  dma_cdc_handshake #(.WIDTH(REQ_W)) u_req_cdc (
    .src_clk   (pclk),
    .src_rst_n (presetn),
    .src_valid (req_src_valid),
    .src_ready (req_src_ready),
    .src_data  ({s_pwrite, s_paddr, s_pwdata}),
    .dst_clk   (clk),
    .dst_rst_n (rst_n),
    .dst_valid (req_dst_valid),
    .dst_ready (req_dst_ready),
    .dst_data  (req_dst_data)
  );

  dma_cdc_handshake #(.WIDTH(RSP_W)) u_rsp_cdc (
    .src_clk   (clk),
    .src_rst_n (rst_n),
    .src_valid (rsp_src_valid),
    .src_ready (rsp_src_ready),
    .src_data  (rsp_src_data),
    .dst_clk   (pclk),
    .dst_rst_n (presetn),
    .dst_valid (rsp_dst_valid),
    .dst_ready (rsp_dst_ready),
    .dst_data  (rsp_dst_data)
  );

  //----------------------------------------------------------------------------
  // clk domain: replay the transfer as an APB master
  //----------------------------------------------------------------------------
  typedef enum logic [1:0] {M_IDLE, M_SETUP, M_ACCESS} mstate_e;
  mstate_e mstate;

  // The request payload stays stable until req_dst_ready, so it can drive the
  // APB master outputs directly.
  assign {m_pwrite, m_paddr, m_pwdata} = req_dst_data;
  assign m_psel    = (mstate != M_IDLE);
  assign m_penable = (mstate == M_ACCESS);

  // Response is pushed and the request popped in the same cycle the APB
  // access completes. The response channel is guaranteed idle (checked in
  // M_IDLE before starting).
  assign rsp_src_valid = (mstate == M_ACCESS) && m_pready;
  assign rsp_src_data  = {m_pslverr, m_prdata};
  assign req_dst_ready = rsp_src_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mstate <= M_IDLE;
    end else begin
      case (mstate)
        M_IDLE:   if (req_dst_valid && rsp_src_ready) mstate <= M_SETUP;
        M_SETUP:  mstate <= M_ACCESS;
        M_ACCESS: if (m_pready) mstate <= M_IDLE;
        default:  mstate <= M_IDLE;
      endcase
    end
  end

endmodule : dma_apb_async_bridge
