//==============================================================================
// dma_sva_bind.sv
//------------------------------------------------------------------------------
// Binds the white-box checkers into every instance of the RTL modules.
// (Interface-level protocol checkers are instantiated in tb_top.)
//==============================================================================
module dma_sva_bind;

  bind dma_sync_fifo     sva_sync_fifo u_sva_sync_fifo (.*);

  bind dma_mfifo         sva_mfifo #(.DATA_W(DATA_W), .LINES(LINES)) u_sva_mfifo (.*);

  bind dma_async_fifo    sva_async_fifo #(.ADDR_W(ADDR_W)) u_sva_async_fifo (.*);

  bind dma_cdc_handshake sva_cdc_handshake #(.WIDTH(WIDTH)) u_sva_cdc (.*);

  bind dma_rd_engine     sva_rd_engine #(.NUM_CH(NUM_CH), .ID_W(ID_W)) u_sva_rd (.*);

  bind dma_wr_engine     sva_wr_engine u_sva_wr (.*);

  bind dma_channel       sva_channel u_sva_ch (.*);

endmodule : dma_sva_bind
