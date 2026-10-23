// SVA checkers
../sva/axi4_master_sva.sv
../sva/apb_slave_sva.sv
../sva/dma_periph_sva.sv
../sva/dma_internal_sva.sv
../sva/dma_lpi_sva.sv
../sva/dma_sva_bind.sv
// Interfaces
../tb/vip/apb/apb_if.sv
../tb/vip/axi/axi_if.sv
../tb/vip/periph/dma_periph_if.sv
../tb/env/dma_ctrl_if.sv
// VIP packages
+incdir+../tb/vip/apb
+incdir+../tb/vip/axi
+incdir+../tb/vip/periph
../tb/vip/apb/apb_pkg.sv
../tb/vip/axi/axi_pkg.sv
../tb/vip/periph/dma_periph_pkg.sv
// DPI-C import of the C reference model (library: model/ -> dma330_ref.dll)
../tb/dpi/dma330_dpi_pkg.sv
// Environment, sequences, tests
+incdir+../tb/env
+incdir+../tb/seq
../tb/env/dma_tb_params_pkg.sv
../tb/env/dma_env_pkg.sv
../tb/seq/dma_seq_pkg.sv
../tb/tests/dma_test_pkg.sv
../tb/tb_top.sv
