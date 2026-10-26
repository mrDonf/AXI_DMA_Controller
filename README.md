# AXI DMA Controller — DMA-330 (PL330) style

Programmable multi-channel AXI4 DMA controller with a DMA-330 compatible
instruction set and register map, a core that runs on the AXI clock (as
DMA-330), a shared dynamically allocated MFIFO, TrustZone-style security with a
secure and a non-secure APB port, optional clock-domain crossing on the APB and
peripheral interfaces, and a UVM-1.2 verification environment with in-house
VIPs, SVA and a C reference model (DPI-C).

Behaviour checked against the DMA-330 r1p2 TRM (v1.4): single-beat S forms,
DMAWFP single/burst semantics, 4 KB crossing bursts split in two, load-lock and
precise MFIFO lock-up detection, DMAFLUSHP as a barrier, NS checks of CCR,
NS-tagged instruction cache, TRM fault codes, AXI attributes and IDs. The
remaining differences are listed in DESIGN_SPEC section 9.

Industry-grade features beyond the basic DMA-330 behaviour:

* hardware AXI protocol protection (an endian swap the data path cannot do
  faults the channel instead of reaching the bus)
* CCR endian swap (16/32/64/128-bit, groups wider than the beat)
* programmable lock-up watchdog (`WD[31:16]`, `WDSTAT`, `FTR.lockup_err`)
* clock-domain crossings reset on both sides when either domain is reset
* per-channel bus-error address registers (`FARn`)
* AMBA Q-Channel low-power interface (`qreqn/qacceptn/qdeny/qactive`)
* optional APB error response (`APB_SLVERR`)
* elaboration-time parameter checking

Documentation (`docs/`):

| Document | Content |
|---|---|
| [DESIGN_SPEC.md](docs/DESIGN_SPEC.md) | Design specification (Vietnamese): parameters, ports, architecture, global operation, register map, ISA, software sequences (initialization, transfers, interrupts, fault recovery) |
| [VERIFICATION_PLAN.md](docs/VERIFICATION_PLAN.md) | Verification plan: strategy, testbench, checkers, SVA, verification items, coverage model, sign-off status |
| [TESTCASES.md](docs/TESTCASES.md) | Test case specification for every test |
| [CMODEL.md](docs/CMODEL.md) | C reference model through DPI-C: architecture, event protocol, modelled semantics, random-program generator (Vietnamese) |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Short architecture overview (English) |
| [SDC_CONSTRAINTS.md](docs/SDC_CONSTRAINTS.md) | Synthesis / STA constraints: clocks (aclk 800 MHz, pclk 200 MHz), CDC timing strategy and derivation, I/O budgets (Vietnamese) |

## Directory layout

```
rtl/
  common/   dma_sync_fifo, dma_rr_arbiter
  cdc/      dma_sync_2ff, dma_rst_sync, dma_cdc_handshake,
            dma_apb_async_bridge, dma_periph_sync
  core/     dma330_pkg            ISA, status/fault codes, CCR, burst maths
            dma_regs              register file, secure + non-secure APB ports, debug interface
            dma_manager           manager thread (DMAGO, boot, debug)
            dma_channel           channel thread (DMA-330 ISA executor)
            dma_fetch_unit        per-thread instruction line buffer
            dma_icache            shared instruction cache
            dma_datapath          rd_engine + shared mfifo (line reservation) + wr_engine
            dma_rd_engine / dma_wr_engine / dma_mfifo
            dma_event_irq         events / interrupts
            dma_periph_ctrl       peripheral request interface
            dma330_core           single-clock core (aclk)
  top/      axi_dma330            top level, optional APB / peripheral CDC
sva/        AXI4 / APB / peripheral protocol checkers, white-box checkers + binds
model/      C reference model (instruction-set simulator of a channel thread),
            DPI-C layer, stand-alone known-answer test
tb/
  dpi/        DPI-C import package of the C model
  vip/apb     APB requester VIP (driver, monitor, coverage, RAL adapter)
  vip/axi     AXI4 reactive memory slave VIP (back-pressure, reorder,
              interleave, error injection), monitor, coverage
  vip/periph  DMA-330 peripheral VIP (dr/da handshake, flush handling)
  env/        register model, DMA-330 assembler, program generator,
              random-program generator, C-model wrapper, scoreboard, coverage, env
  seq/        virtual sequences (traffic, events, boot, faults, kill, shared MFIFO, security)
  tests/      test library
  tb_top.sv
sim/        Makefile, run_regression.py, file lists
syn/        constraints/axi_dma330.sdc  flat SDC (OpenROAD/OpenSTA, Yosys, DC, Genus)
docs/       DESIGN_SPEC, VERIFICATION_PLAN, TESTCASES, CMODEL, ARCHITECTURE, SDC_CONSTRAINTS
```

## Running (QuestaSim 10.7c, UVM-1.2)

Needs a C compiler for the reference model (`$CC`, `gcc` on `PATH`, or MSYS2
`C:/msys64/ucrt64/bin/gcc.exe`); the Questa install here has none. Without one,
`run_regression.py` builds with `+define+DMA_NO_CMODEL` and skips the two tests
that need the model (`--no-cmodel` forces that).

From `sim/` (Git Bash / MSYS make, or plain `python`):

```sh
make model                                   # C model: unit test + DPI library
make build                                   # model + vlog + vopt (sync and async snapshots)
make sim TEST=dma_periph_test CFG=async SEED=5
make gui TEST=dma_fault_test                 # waveforms
make regress JOBS=12 SEEDS=3                 # parallel regression
make cov                                     # regression + merged coverage UCDB

python run_regression.py -t dma_stress_test -c async --seeds 10 -j 16

python run_mutation.py                       # plant RTL bugs in a copy: old vs new environment
```

Speed-ups: one compile, `vopt -j N` parallel code generation, and N
independent `vsim` processes in parallel (one per test/config/seed). Use
`--fast` to drop `+acc` visibility for maximum simulation speed.

Configurations:
* `sync`  — every interface on the core clock (CDC logic bypassed)
* `async` — APB 79 MHz, AXI 135 MHz, peripherals 61..122 MHz, core 200 MHz
  (exercises the APB/AXI async bridges and peripheral synchronizers)

Plusargs: `+AXI_PROFILE=fast|slow|default`, `+NO_REORDER`, `+NO_CMODEL`.

The C model also runs in every other test: it cross-checks the generator-based
prediction of each job (`SB_XCHECK`) and the final `CPC/SAR/DAR/CCR/LC0/LC1`
registers (`ARCH`).

## Tests

| Test | Purpose |
|------|---------|
| dma_reg_test | UVM reset / bit-bash of the register map, IDs, unmapped reads |
| dma_m2m_aligned_test | aligned 64-bit memory copies |
| dma_m2m_unaligned_test | any alignment, beat size and burst length on both sides; bursts across 4 KB |
| dma_multi_ch_test | all channels concurrently |
| dma_fixed_addr_test | FIXED (non-incrementing) source or destination |
| dma_fill_test | DMASTZ zero fill |
| dma_loop2d_test | nested DMALP, DMAADDH / DMAADNH 2D transfers |
| dma_periph_test | WFP / LDP / STP / FLUSHP / conditional S-B (S = one beat) / DMALPFE + drlast |
| dma_event_test | DMASEV / DMAWFE ordering, multi-waiter, sticky events |
| dma_boot_test | manager boots from memory, non-secure channels, debug instruction while the manager waits, dmago_err |
| dma_fault_test | every fault type (incl. EXOKAY), fault isolation, recovery |
| dma_kill_test | DMAKILL while transferring / waiting for peripheral / event |
| dma_stress_test | all job kinds on all channels under heavy back-pressure |
| dma_isa_test | DMANOP, DMARMB, DMAADNH on SAR, DMAKILL as program end, nested loops |
| dma_periph_corner_test | stray flush ack, back-to-back requests (drready=0), request during flush, two channels on one peripheral, DMAWFP single/burst, flush after an acknowledge, peripheral-only reset |
| dma_boot_err_test | manager boot instruction-fetch error and recovery |
| dma_reset_test | system reset in the middle of traffic on all channels, recovery |
| dma_endian_test | CCR endian swap (16/32/64-bit, also wider than the beat) on random copies |
| dma_watchdog_test | lock-up watchdog: hung bus abort, report-only mode, no false alarm, disabled |
| dma_lowpower_test | Q-Channel: accept / deny, core clock gating, wake-up on APB access |
| dma_rand_prog_test | random instruction streams (loop nests, FIXED/INCR, unaligned, endian swap, address wrap-around); C model is the only predictor |
| dma_cmodel_mix_test | every job kind plus random streams on a choked AXI slave and slow peripherals; C model cross-check and register compare |
| dma_mfifo_share_test | shared MFIFO: one channel using most of the pool, waiting for space, load-lock, inter-channel lock-up (abort / report only) |
| dma_security_test | two APB ports, CR3/CR4, NS thread checks (events, peripherals, CCR prot), NS register view, NS-tagged instruction cache |

## Coverage

`make cov` (or `python run_regression.py --cov --seeds 3`) instruments only the
RTL (`+cover=bcesf`, unreachable case defaults and implicit async-reset FSM
transitions excluded) and merges all runs into `sim/cov/merged.ucdb`
(HTML in `sim/cov/html/index.html`). Last result, 22 tests x 2 configs x 3 seeds (132 runs, all passing):

| Metric (by design unit) | Coverage |
|---|---|
| Statements | 99.9 % (only the 128-bit endian-swap line, needs `DATA_W=128`) |
| Branches | 98.9 % |
| FSM states / transitions | 100 % / 100 % |
| FEC conditions / expressions | 92.2 % / 96.0 % |
| Covergroup bins | 100 % |
| Cover directives | 95.6 % |

Known structurally unreachable items: the non-canonical `DMALPFE` encoding
0x2A, event / peripheral numbers out of range at the event unit (filtered
upstream), DMA-side B/R async FIFOs never full (the core always drains them),
APB bridge back-pressure with this requester, `PSLVERR` in the sync configuration (`APB_SLVERR=0`), a
data error while already FAULTING (impossible: outstanding bursts retire first).
