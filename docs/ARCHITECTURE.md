# AXI DMA Controller (DMA-330 / PL330 style) — Architecture

## 1. Overview

`axi_dma330` is a programmable, multi-channel AXI4 DMA controller modelled on the
Arm CoreLink DMA-330 (PL330). Like DMA-330 it is **instruction driven**: each
channel thread runs a small byte-code program (`DMAMOV`, `DMALD`, `DMAST`,
`DMALP`, `DMAWFP`, `DMASEV`, ...) fetched from system memory through the AXI
master. A manager thread starts channels (`DMAGO`) either from its own program
(boot) or from instructions written through the APB debug registers.

| Feature                     | Value (default)                                     |
|-----------------------------|-----------------------------------------------------|
| Channel threads             | `NUM_CH` = 4 (1..8) + 1 manager thread               |
| AXI master                  | AXI4, 32-bit address, `DATA_W` = 64 (32/64/128)     |
| Burst support               | INCR / FIXED, 1..16 beats, any size <= bus width, unaligned start addresses, narrow beats |
| Outstanding transactions    | `RD_OUT` reads + `WR_OUT` writes per channel; AXI ID = channel |
| MFIFO                       | `MFIFO_LINES` = 128 lines x `DATA_W`, **shared** by all channels, allocated line by line; a byte stream per channel |
| Instruction cache           | `IC_LINES` lines x `IC_BEATS` beats, shared         |
| Peripheral interfaces       | `NUM_PERIPH` = 4 (1..32), DMA-330 dr/da protocol    |
| Events / interrupts         | `NUM_EVENTS` = 16 (1..32) + `irq_abort`             |
| Register interface          | Secure + non-secure APB ports, DMA-330 compatible register map |
| Security                    | S/NS manager, channels, events (`CR3`), peripherals (`CR4`); the NS port only sees NS resources |
| Clock domains               | `aclk` (core + AXI, as DMA-330), APB, one per peripheral (CDC optional) |
| Robustness                  | 4 KB crossing bursts split in two (as DMA-330), swap legality check, load-lock + precise MFIFO lock-up detection, lock-up watchdog, bus-error address (`FARn`) |
| Low power                   | AMBA Q-Channel (`qreqn/qacceptn/qdeny/qactive`)     |

## 2. Block diagram

```
                pclk                    aclk (core and AXI)
   APB S  ->[apb_async_bridge]---->+-----------------------------------------+
   APB NS ->[apb_async_bridge]---->| dma_regs  (register map, security, dbg) |
                                   +----+------------------------------------+
                                        | DBGINST -> manager / channel kill
                                   +----v-----+  DMAGO   +--------------------+
                                   | manager  |--------->| channel[0..N-1]    |
                                   +----+-----+          | (thread FSM, PC,   |
                                        |                |  SAR/DAR/CCR/LCx)  |
                                        |  fetch         +--+-------+---------+
                                   +----v---------------+   | ld/st | WFP/flush
                                   | dma_icache (shared)|   |       v
                                   +----+---------------+   |  +----------------+   periph_clk[p]
                                        | refill            |  |dma_periph_ctrl |<-[periph_sync]-> dr/da
                                   +----v-------------------v--+----------------+
                                   |            dma_datapath                   |
                                   |  RQ[ch] -> AR arbiter -> AR   R -> MFIFO (shared pool)
                                   |  WQ[ch] -> select (data ready) -> AW/W   B  |----> AXI4 (same aclk)
                                   +-------------------------------------------+
                                   | dma_event_irq : DMASEV/DMAWFE, irq[], abort |
                                   +-------------------------------------------+
```

## 3. Clocking and CDC

The core runs on the AXI clock (`aclk`), as DMA-330 does, so the AXI master
port has no clock-domain crossing. (Earlier versions had a separate core clock
and an optional AXI async bridge; both are gone.) All CDC logic is in
`rtl/cdc/` and is instantiated by `axi_dma330` only when the matching parameter
is set (`APB_ASYNC`, `PERIPH_ASYNC`).

| Crossing                    | Structure                                | Why |
|-----------------------------|------------------------------------------|-----|
| APB (pclk -> aclk), per port | `dma_apb_async_bridge`: two toggle handshakes (request, response); PREADY held low until the response returns | Low-rate register traffic, multi-bit payload kept quasi-static |
| Peripheral dr/da            | `dma_periph_sync`: valid/ready toggle handshake each way | Request/acknowledge are single events with a 2..3-bit payload |
| Resets                      | `dma_rst_sync` per domain (async assert, sync de-assert) | |

Rules followed everywhere: only single bits pass through `dma_sync_2ff`;
multi-bit buses cross only while held stable by a handshake; no combinational
logic between domains. SVA checks handshake payload stability.

## 4. Thread architecture

### 4.1 Channel thread (`dma_channel`)
```
STOPPED --DMAGO--> FETCH --> EXEC --> UPDATING_PC --> FETCH
                               +--> WFE        (DMAWFE)
                     ^               +--> WFP        (DMAWFP)
                     |               +--> BARRIER    (DMARMB / DMAWMB)
                     +---------------+--> COMPLETING (DMAEND)  --> STOPPED
                                     +--> KILLING    (DMAKILL) --> STOPPED
any fault ----> FAULT_COMPLETING --> FAULTING --(debug DMAKILL)--> KILLING
```
* Loads and stores are **issued**, not executed in place: `DMALD` pushes a burst
  descriptor (`xfer_t`) into the channel's read queue and the thread moves on.
  The thread only waits where the ISA demands it (barriers, `DMAEND`, events,
  peripheral requests) or when a queue is full.
* Each thread has a private one-line instruction buffer (`dma_fetch_unit`);
  instructions that straddle cache lines are assembled from up to three lines.
* Updating PC is an explicit phase in both manager and channel threads
  (architectural status 3). It calculates/commits the next sequential or branch
  address and overlaps the next fetch. Event/peripheral/barrier wakeups pass
  through it; debug instructions leave the manager's program PC unchanged.
* FETCH is an internal control state. Its architectural status is Executing
  except when the shared I-cache reports a real refill for that thread
  (AR pending or R collection), which reports Cache miss (2). Waiting for a
  shared-cache hit or instruction assembly does not itself report Cache miss.
* Faults stop the program, flush the channel's queued requests and drop its
  returning read data, wait for in-flight AXI bursts to retire, then park in
  FAULTING until the debugger sends `DMAKILL`.

### 4.2 Manager thread (`dma_manager`)
Runs `DMAGO`, `DMASEV`, `DMAWFE`, `DMANOP`, `DMAEND`, `DMAKILL` (`DMAFLUSHP` is
channel only: undefined in the manager), from memory (`boot_from_pc`) or one at
a time from DBGINST0/1; debug instructions are also taken while the manager
waits in `DMAWFE` (it then returns to the wait), or while executing a boot program (it resumes the same PC). A non-secure manager cannot
start a secure channel (`dmago_err`, FTRD[4]) or use a secure event
(`mgr_evnt_err`, FTRD[5]); a missing channel / event number is
`operand_invalid`. An accepted `DMAGO` invalidates only the stopped target
channel's cache and local line buffer; a running target sees a complete NOP.
`DMAWFE invalid`, `DMAEND` and `DMAKILL` maintain only the issuing thread.
Entries carry both thread ID and NS tags. An invalidated lookup/refill returns
a retry after draining any outstanding AXI read, without allocating old bytes.

### 4.3 Security
* Manager: S/NS from `boot_manager_ns` (`DSR.DNS`). Channel: S/NS from the
  `ns` bit of its `DMAGO` (`CSRn.CNS`). Event e: NS when `CR3[e]` = 1, peripheral
  p: NS when `CR4[p]` = 1 (`boot_irq_ns` / `boot_periph_ns`, sampled after reset).
* A non-secure channel faults on a secure event (`ch_evnt_err`), a secure
  peripheral (`ch_periph_err`) or a secure access requested in CCR
  (`AxPROT[1]` = 0: `ch_rdwr_err`). NS threads fetch with `ARPROT[1]` = 1 and
  the instruction cache tags every line with its thread ID and the NS state of its fill.
* The secure APB port sees everything. DNS gates NS access to control, fault,
  debug, configuration and WD registers (TRM Tables 3-1, 3-4, 3-5). With DNS=1
  the complete control registers are visible; channel state/AXI registers
  follow CNS. Both ports share write-only DBGINST0/1; writes while debug busy
  are ignored. Simultaneous accesses prioritize the secure port.

## 5. Data path (`dma_datapath`)

### 5.1 Read side (`dma_rd_engine`)
* Per-channel read queue → round-robin AR arbiter (instruction refills have
  priority) → registered AR output (stable ARVALID/payload).
* An issued burst moves to the channel's read tracker. R beats are matched by
  RID; each channel has its own beat counter so read data **interleaving
  between IDs** is supported.
* The valid byte lanes of every beat (narrow / unaligned) are shifted down and
  pushed into the channel's MFIFO stream.
* An INCR burst that crosses 4 KB is issued as two AR bursts (TRM 2.10.5); the
  queue entry leaves with its second piece. Any RRESP other than OKAY is an
  error. `DMALDS`/`DMALDPS` read one beat.

### 5.2 MFIFO (`dma_mfifo`)
One pool of `MFIFO_LINES` lines of `DATA_W/8` bytes, **shared by all channels
and allocated dynamically** (as in DMA-330). Each channel sees its own
**byte stream**, stored in a linked list of pool lines (`hd`/`tl` per channel,
`nxt`/`own` per line): a push that starts or spills into a new line takes the
lowest free line, a pop that empties the head line frees it, a flush returns
all lines of the channel at once. Up to one bus width of bytes can be pushed
and popped per cycle at any byte offset, so source and destination shapes are
fully decoupled.

Admission control (in `dma_datapath`, per channel):

| Counter    | + when                  | - when                    | Used for |
|------------|-------------------------|---------------------------|----------|
| held       | DMALD accepted (`need` lines) | a pop frees a line   | DMALD issued only if `sum(held) + need <= MFIFO_LINES`, so AXI R never stalls on space |
| reserved   | DMALD accepted (bytes)  | bytes popped onto W       | an empty stream gives back its last line and restarts at offset 0 |
| unclaimed  | DMALD accepted          | DMAST accepted            | DMAST needing more data than will ever arrive: `st_data_unavailable` |

`need = ceil((res_off + bytes) / NB) - (res_off != 0)`. **Load-lock** (TRM
2.11.4): only the owner of the load-lock (taken by an accepted DMALD, given up
on DMAST*, barriers, DMAWFP/DMAWFE, DMAEND, abort) may load; others pause at
their DMALD. One DMALD is accepted per cycle, round robin over the channels
whose load fits and may load. A load that cannot be accepted yet waits. A
stuck load (not accepted, no store pending) that never fits even in an empty
pool faults with `mfifo_err`; when every channel holding lines is stuck no line
can ever be freed (precise lock-up detection): the stuck holders abort with
`lockup_err`, or with `WD.irq_only = 1` are only reported in `WDSTAT` /
`irq_abort`.

### 5.3 Write side (`dma_wr_engine`)
* Per-channel write queue; a burst is **started only when all of its data is
  already in the MFIFO** — W never waits on R, so one slow channel can never
  block the shared W channel (no head-of-line blocking, no deadlock).
* AW and W of the active burst are driven concurrently; strobes are generated
  per beat; unused lanes are zero. 4 KB crossing bursts are split as on the
  read side; AWCACHE = {CCR[27], 0, CCR[26:25]}; any BRESP other than OKAY is
  an error.
* Endian swap groups wider than the beat (INCR, TRM 2.11.2) are reversed from
  the MFIFO head and popped with their last beat.
* B responses are matched by BID to a per-channel tracker; `DMASTP` sends its
  peripheral acknowledge when the B response arrives (`DMALDP` on RLAST).

## 6. Peripheral request interface (`dma_periph_ctrl`)

DMA-330 compatible handshake per peripheral:

| Signal            | Direction | Meaning |
|-------------------|-----------|---------|
| `drvalid/drready` | P → DMA   | request; `drtype` 00 single, 01 burst, 10 flush acknowledge; `drlast` last request |
| `davalid/daready` | DMA → P   | acknowledge; `datype` 00 single done, 01 burst done, 10 flush request |

`DMAWFP periph` consumes the latched request and copies its type into the
channel's request_type flag (used by the `S`/`B` conditional instructions) and
its `last` flag (ends a `DMALPFE` loop). `DMAWFP single` continues on any
request but leaves a burst request latched; `DMAWFP burst` drops single
requests and waits for a burst one; both set request_last = 0 (TRM 2.6.5).
`DMAFLUSHP` first waits at a barrier for the channel's transfers (so it never
overtakes an acknowledge), then clears the latch, sends a flush request and
ignores requests until the peripheral acknowledges the flush. The S forms of
DMALD/DMAST/DMALDP/DMASTP move one beat.

## 7. Register map (APB, 4 KB)

| Offset          | Register         | Notes |
|-----------------|------------------|-------|
| 0x000 / 0x004   | DSR / DPC        | manager status / PC |
| 0x020           | INTEN            | 1: event n is an interrupt |
| 0x024 / 0x028 / 0x02C | INT_EVENT_RIS / INTMIS / INTCLR | |
| 0x030 / 0x034 / 0x038 | FSRD / FSRC / FTRD | fault status / type |
| 0x040 + 4n      | FTRn             | channel fault type |
| 0x100 + 8n      | CSRn / CPCn      | channel status / PC |
| 0x400 + 0x20n   | SARn, DARn, CCRn, LC0_n, LC1_n | CCRn resets to 0x0080_0200 |
| 0xD00..0xD0C    | DBGSTATUS, DBGCMD, DBGINST0, DBGINST1 | debug instruction interface |
| 0xE00..0xE14    | CR0..CR4, CRD    | configuration |
| 0xFE0..0xFFC    | peripheral / component ID | default DMA-330 r1p2: 0x00341330 / 0xB105F00D |

## 8. Instruction set

All DMA-330 instructions are implemented with DMA-330 encodings:
`DMAADDH DMAADNH DMAEND DMAFLUSHP DMAGO DMAKILL DMALD[S|B] DMALDP<S|B> DMALP
DMALPEND[S|B] DMALPFE DMAMOV DMANOP DMARMB DMASEV DMAST[S|B] DMASTP<S|B> DMASTZ
DMAWFE DMAWFP<S|B|P> DMAWMB`.

## 9. Conformance and integration profile

TRM fixes include conditional-store load-lock, implicit DMAMOV discontinuity
barriers/discard, real-time manager debug, DNS-gated APB control/debug/config
access, precise NS CCR faults at MOV, and CR1-valid 4/8/16/32-byte cache lines.
128-bit endian groups are supported on every bus width. Instruction assembly
handles a six-byte MOV spanning three four-byte lines. AW can run ahead of W;
the cache serves another thread's hit while a refill waits on AR/R.

The integration profile remains AXI4 (no WID), one all-ones instruction-fetch
ID, optional asynchronous APB bridges instead of pclken, and a one-entry
peripheral request latch. FARn, WDSTAT, watchdog timeout, Q-Channel and optional
PSLVERR are extensions. The densely packed internal byte-stream MFIFO can use
a different number of entries from the destination-formatted examples in Arm
Appendix B. This is not a pin/cycle/resource-identical copy of the Arm macro.
See DESIGN_SPEC section 9 and RTL_SPEC_FIXES.md for the exact contract and
validation evidence.

## 10. Verification

UVM-1.2 environment with three in-house VIPs (APB requester, reactive AXI4
memory slave with back-pressure / out-of-order / interleaving / error
injection, DMA-330 peripheral), a register model, a DMA-330 assembler and a
transaction-level reference model (scoreboard checks every AXI burst
bit-exactly, every peripheral acknowledge and every instruction fetch). SVA
covers the AXI/APB/peripheral protocols, CDC structures and data-path
invariants (including the shared MFIFO pool and its line reservation). See `sim/` for the QuestaSim flow (`make build`, `make regress`).

A second, independent reference is a C instruction-set simulator of one
channel thread (`model/dma330_ref.c`) reached through DPI-C. It decodes the
byte code that is actually in memory, so it shares nothing with the program
generator. It (a) cross-checks the generator-based prediction of every job,
(b) is compared with the final `CPC/SAR/DAR/CCR/LC0/LC1` registers of every
job, and (c) is the only predictor for random instruction streams
(`dma_rand_prog`: random kernels, loop nests, addressing modes, alignment,
endian swap, 32-bit address wrap-around). The model has no memory of its own
and uses DPI imports only (`NEED_CODE` / `LD` events are answered with
`dma330_dpi_supply`), so it needs no C compiler inside the simulator. See
[CMODEL.md](CMODEL.md) (Vietnamese).

Full specification (Vietnamese): [DESIGN_SPEC.md](DESIGN_SPEC.md).
