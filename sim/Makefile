#===============================================================================
# QuestaSim flow for the AXI DMA (DMA-330 style)
#
#   make model                      C reference model: unit test + DPI library
#   make build                      model + compile + optimise both snapshots
#   make sim TEST=dma_m2m_aligned_test CFG=async SEED=7
#   make gui TEST=dma_fault_test    interactive run with waveforms
#   make regress [JOBS=12] [SEEDS=3] parallel regression (python)
#   make cov                        regression with merged coverage
#   make clean
#===============================================================================
QUESTA  ?= C:/questasim64_10.7c
BIN     := $(QUESTA)/win64
UVM_LIB := $(QUESTA)/uvm-1.2
UVM_SRC := $(QUESTA)/verilog_src/uvm-1.2/src
UVM_DPI := $(UVM_LIB)/win64/uvm_dpi

TEST    ?= dma_m2m_aligned_test
CFG     ?= sync
SEED    ?= 1
JOBS    ?= 12
SEEDS   ?= 1
VOPT_J  ?= 8
VERB    ?= UVM_LOW
MODEL_CC ?= gcc
MODEL   := ../model
MODEL_LIB := dma330_ref

VLOG_OPTS := -sv -svinputport=var -timescale 1ns/1ps -L $(UVM_LIB) +incdir+$(UVM_SRC) -quiet
SUPPRESS  := -suppress 12036
ASYNC_sync  := 0
ASYNC_async := 1

.PHONY: build model compile opt sim gui regress cov clean

build: opt

work:
	$(BIN)/vlib work

# C reference model (DPI-C): known-answer unit test first, then the shared library
model:
	mkdir -p logs
	TMP=logs TEMP=logs $(MODEL_CC) -O2 -Wall -Wextra -o logs/dma330_ref_test $(MODEL)/dma330_ref_test.c $(MODEL)/dma330_ref.c
	./logs/dma330_ref_test | tail -3
	TMP=logs TEMP=logs $(MODEL_CC) -O2 -Wall -Wextra -shared -static-libgcc -o $(MODEL_LIB).dll $(MODEL)/dma330_ref.c $(MODEL)/dma330_dpi.c

compile: work model
	$(BIN)/vlog $(VLOG_OPTS) -f rtl.f
	$(BIN)/vlog $(VLOG_OPTS) -f tb.f

# One snapshot per CDC configuration, each with parallel code generation.
# (Built one after the other: they share the 'work' library index.)
opt: compile
	$(BIN)/vopt tb_top -L $(UVM_LIB) -o tb_sync  -GASYNC=0 +acc=npr -j $(VOPT_J) $(SUPPRESS)
	$(BIN)/vopt tb_top -L $(UVM_LIB) -o tb_async -GASYNC=1 +acc=npr -j $(VOPT_J) $(SUPPRESS)

sim:
	mkdir -p logs/$(CFG)
	$(BIN)/vsim -c tb_$(CFG) -L $(UVM_LIB) -sv_lib $(UVM_DPI) -sv_lib $(MODEL_LIB) $(SUPPRESS) \
	  +UVM_TESTNAME=$(TEST) -sv_seed $(SEED) +UVM_VERBOSITY=$(VERB) \
	  -l logs/$(CFG)/$(TEST)_$(CFG)_s$(SEED).log -do "run -all; quit -f"

gui:
	$(BIN)/vsim tb_$(CFG) -L $(UVM_LIB) -sv_lib $(UVM_DPI) -sv_lib $(MODEL_LIB) $(SUPPRESS) \
	  +UVM_TESTNAME=$(TEST) -sv_seed $(SEED) -classdebug -msgmode both \
	  -do "add wave -r /tb_top/u_dut/*; run -all"

regress:
	python run_regression.py -j $(JOBS) --seeds $(SEEDS) --vopt-j $(VOPT_J)

cov:
	python run_regression.py --cov -j $(JOBS) --seeds $(SEEDS) --vopt-j $(VOPT_J)

clean:
	rm -rf work logs cov transcript *.wlf *.vstf modelsim.ini $(MODEL_LIB).dll
