//==============================================================================
// dma_env.sv - DMA verification environment
//
//            +-------------------------- dma_env ---------------------------+
//            |  apb_agent --(RAL adapter/predictor)-- dma_reg_block          |
//   APB  <-->|     |              (secure port)                             |
//   APB NS<->|  apb_ns agent      (non-secure port, raw accesses)           |
//            |  axi_agent (memory slave) --mon--> dma_scoreboard <-- jobs   |
//   AXI  <-->|     |                                   ^                    |
//            |  periph_agent[p] -------mon-------------+                    |
//   dr/da<-->|                                                              |
//            |  dma_coverage    dma_virtual_sequencer                       |
//            +--------------------------------------------------------------+
//==============================================================================
class dma_env extends uvm_env;

  `uvm_component_utils(dma_env)

  dma_env_cfg                       cfg;
  apb_pkg::apb_agent                apb;
  apb_pkg::apb_agent                apb_ns;
  axi_pkg::axi_agent                axi;
  dma_periph_pkg::periph_agent      per [dma_tb_params_pkg::NUM_PERIPH];
  dma_reg_block                     rm;
  apb_pkg::apb_reg_adapter          adapter;
  uvm_reg_predictor #(apb_pkg::apb_seq_item) predictor;
  dma_scoreboard                    sb;
  dma_coverage                      cov;
  dma_virtual_sequencer             vsqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(dma_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "dma_env_cfg not set")

    // Agents
    uvm_config_db #(apb_pkg::apb_config)::set(this, "apb", "cfg", cfg.apb_cfg);
    apb = apb_pkg::apb_agent::type_id::create("apb", this);
    uvm_config_db #(apb_pkg::apb_config)::set(this, "apb_ns", "cfg", cfg.apb_ns_cfg);
    apb_ns = apb_pkg::apb_agent::type_id::create("apb_ns", this);

    cfg.axi_cfg.mem = cfg.mem;
    uvm_config_db #(axi_pkg::axi_config)::set(this, "axi", "cfg", cfg.axi_cfg);
    axi = axi_pkg::axi_agent::type_id::create("axi", this);

    foreach (per[p]) begin
      uvm_config_db #(dma_periph_pkg::periph_config)::set(this, $sformatf("per%0d", p), "cfg", cfg.per_cfg[p]);
      per[p] = dma_periph_pkg::periph_agent::type_id::create($sformatf("per%0d", p), this);
    end

    // Register model
    rm = dma_reg_block::type_id::create("rm");
    rm.build(dma_tb_params_pkg::NUM_CH, dma_tb_params_pkg::NUM_EVENTS,
             expected_cr0(), expected_cr1(), expected_crd(), dma_tb_params_pkg::PERIPH_ID,
             cfg.apb_slverr);
    adapter   = apb_pkg::apb_reg_adapter::type_id::create("adapter");
    predictor = uvm_reg_predictor #(apb_pkg::apb_seq_item)::type_id::create("predictor", this);

    if (cfg.has_scoreboard) begin
      sb = dma_scoreboard::type_id::create("sb", this);
      sb.mem       = cfg.mem;
      sb.cmodel_en = cfg.cmodel_en;
    end
    cov  = dma_coverage::type_id::create("cov", this);
    vsqr = dma_virtual_sequencer::type_id::create("vsqr", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    // RAL: front door through the APB agent, explicit prediction from monitor
    rm.default_map.set_sequencer(apb.sqr, adapter);
    rm.default_map.set_auto_predict(0);
    predictor.map     = rm.default_map;
    predictor.adapter = adapter;
    apb.mon.ap.connect(predictor.bus_in);

    if (cfg.has_scoreboard) begin
      axi.mon.ap_write.connect(sb.wr_imp);
      axi.mon.ap_read.connect(sb.rd_imp);
      foreach (per[p]) per[p].mon.ap.connect(sb.per_imp);
    end

    vsqr.apb_sqr    = apb.sqr;
    vsqr.apb_ns_sqr = apb_ns.sqr;
    foreach (per[p]) vsqr.per_sqr[p] = per[p].sqr;
    vsqr.rm  = rm;
    vsqr.cfg = cfg;
    vsqr.sb  = sb;
    vsqr.cov = cov;
  endfunction

  //----------------------------------------------------------------------------
  // Configuration register values implied by the DUT parameters
  //----------------------------------------------------------------------------
  // (dma_tb_params_pkg is imported by dma_env_pkg)
  function uvm_reg_data_t expected_cr0();
    return (uvm_reg_data_t'(NUM_EVENTS - 1) << 17) | (uvm_reg_data_t'(NUM_PERIPH - 1) << 12) |
           (uvm_reg_data_t'(NUM_CH - 1) << 4) | 1;
  endfunction

  function uvm_reg_data_t expected_cr1();
    return (uvm_reg_data_t'(IC_LINES - 1) << 4) | $clog2(IC_BEATS * DATA_W / 8);
  endfunction

  function uvm_reg_data_t expected_crd();
    return (uvm_reg_data_t'(MFIFO_LINES - 1) << 20) | (uvm_reg_data_t'(RQ_DEPTH - 1) << 16) |
           (uvm_reg_data_t'(RD_OUT - 1) << 12) | (uvm_reg_data_t'(WQ_DEPTH - 1) << 8) |
           (uvm_reg_data_t'(WR_OUT - 1) << 4) | $clog2(DATA_W / 8);
  endfunction

endclass : dma_env
