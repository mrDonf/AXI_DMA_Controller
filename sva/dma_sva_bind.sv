//==============================================================================
// dma_sva_bind.sv
//------------------------------------------------------------------------------
// Binds the white-box checkers into every instance of the RTL modules.
// (Interface-level protocol checkers are instantiated in tb_top.)
//==============================================================================
module dma_sva_bind;

  bind dma_sync_fifo     sva_sync_fifo u_sva_sync_fifo (.*);

  bind dma_mfifo         sva_mfifo #(.NUM_CH(NUM_CH), .DATA_W(DATA_W), .LINES(LINES)) u_sva_mfifo (.*);

  bind dma_datapath      sva_datapath #(.NUM_CH(NUM_CH), .MFIFO_LINES(MFIFO_LINES)) u_sva_dp (.*);

  bind dma_cdc_handshake sva_cdc_handshake #(.WIDTH(WIDTH)) u_sva_cdc (.*);

  bind dma_rd_engine     sva_rd_engine #(.NUM_CH(NUM_CH), .ID_W(ID_W)) u_sva_rd (.*);

  bind dma_wr_engine     sva_wr_engine #(.NUM_CH(NUM_CH)) u_sva_wr (.*);

  bind dma_channel       sva_channel u_sva_ch (.*);
  bind dma_manager       sva_manager_cache u_sva_mgr_cache (.*);
  bind dma_fetch_unit    sva_fetch_unit u_sva_fu (.*);

endmodule : dma_sva_bind
