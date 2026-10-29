# Diagnose a precise program fault and an imprecise bus fault

<!-- reading-nav -->
[Guide index](README.md) · [Background](00_background.md) · [← Previous: 15. Kill a channel waiting on an event](15_kill.md) · [Next: 17. Share the bus and MFIFO between channels →](17_sharing.md)
<!-- /reading-nav -->

## Purpose

Use FTR, CPC and FAR for the right purpose instead of treating every abort PC as precise.

## Starting conditions

First issue DMAST without loaded bytes. Then inspect a data-read SLVERR from the original fault test.

## Minimal sequence

The sequence below is an explanatory sketch. The recorded assembler may emit extra CCR updates or loop setup. The source-run name below identifies the reproducible simulation.

```text
; precise example
DMAMOV DAR, 0x20000000
DMAMOV CCR, one_8byte_beat
DMAST ; no preceding LD
; recovery: read FTR/CPC, KILL, repair/restart
```

## Read the waveform

1. The unavailable-data store sets FTR[13] and keeps CPC at offset 0x0c; the direct test checks both exactly.
2. A non-OKAY data response sets data_read_err or data_write_err. Those bus aborts are imprecise.
3. For an imprecise abort, the current CPC may point beyond the instruction that issued the request. FAR is this workspace's separate first-error bus address.
4. Save diagnosis before KILL. Repair the cause, then start a new checked copy; do not treat restart as a continuation of the failed transfer.

Group brackets separate the thread, shared storage and active interfaces. Inactive interfaces and uninformative constant rows are omitted. A constant needed to explain a stall or security decision stays visible. Pastel state colors distinguish execution, waiting and faults; equal payload values share a color across read/write rows. [WaveDrom conventions and color legend](00_conventions.md) define cell timing, data labels and snapshots.

### Waveform 1

[![Waveform 1](../svg/16_faults_1.svg)](../svg/16_faults_1.svg)

[Open SVG at full size](../svg/16_faults_1.svg) | [WaveDrom JSON](../wavejson/16_faults_1.json)

Arm CSR labels: `EXEC` = Executing (`0x1`); `MISS` = Cache miss (`0x2`); `UPC` = Updating PC (`0x3`); `BAR` = At barrier (`0x5`); `FC` = Faulting completing (`0xe`); `FLT` = Faulting (`0xf`).

Source: `direct_underflow`. Core/unit cycle snapshots cover the selected **297.5..457.5 ns** interval. The first cell's right sampling edge is **297.5 ns**.

| Exact VCD time (ns) | Milestone | Meaning |
|---:|---|---|
| 377.5 | FTR | 0x2000 |

### Waveform 2

[![Waveform 2](../svg/16_faults_2.svg)](../svg/16_faults_2.svg)

[Open SVG at full size](../svg/16_faults_2.svg) | [WaveDrom JSON](../wavejson/16_faults_2.json)

Arm CSR labels: `EXEC` = Executing (`0x1`); `UPC` = Updating PC (`0x3`); `BAR` = At barrier (`0x5`); `FC` = Faulting completing (`0xe`).

Source: `dma_fault_test_sync`. Core/unit cycle snapshots cover the selected **3507.5..3667.5 ns** interval. The first cell's right sampling edge is **3507.5 ns**.

| Exact VCD time (ns) | Milestone | Meaning |
|---:|---|---|
| 3517.5 | B response accepted | RESP=0 |
| 3532.5 | WLAST accepted | WSTRB=0x40 |
| 3537.5 | AW accepted | ID=0; address=0x200cbb61; 5 beats x 1 B; INCR |
| 3552.5 | RLAST accepted | RESP=0 |
| 3557.5 | AR accepted | ID=3; address=0xe0000000; 16 beats x 8 B; INCR |
| 3557.5 | B response accepted | RESP=0 |
| 3557.5 | WLAST accepted | WSTRB=0x08 |
| 3567.5 | AW accepted | ID=0; address=0x200cbb66; 5 beats x 1 B; INCR |
| 3582.5 | WLAST accepted | WSTRB=0x01 |
| 3587.5 | B response accepted | RESP=0 |
| 3597.5 | AW accepted | ID=0; address=0x200cbb6b; 5 beats x 1 B; INCR |
| 3597.5 | FTR | 0x40000 |
| 3617.5 | AR accepted | ID=0; address=0x100f363a; 15 beats x 2 B; INCR |
| 3617.5 | AW accepted | ID=0; address=0x200cbb70; 5 beats x 1 B; INCR |

Full values for the short labels in this picture (matching D labels mean matching data):

| Label | Signal(s) | Full value |
|---|---|---|
| A1 | AR.addr | `100f363a` |
| A2 | AW.addr | `200cbb66` |
| A3 | AW.addr | `200cbb6b` |
| A4 | AW.addr | `200cbb70` |
| D1 | rdata | `4c4d4e4f48494a4b` |
| D2 | rdata | `bdbcbfbeb9b8bbba` |
| D3 | rdata | `b5b4b7b6b1b0b3b2` |
| D4 | rdata | `adacafaea9a8abaa` |
| D5 | rdata | `a5a4a7a6a1a0a3a2` |
| D6 | rdata | `9d9c9f9e99989b9a` |
| D7 | rdata | `9594979691909392` |
| D8 | rdata | `8d8c8f8e89888b8a` |
| D9 | rdata | `8584878681808382` |
| D10 | rdata | `fdfcfffef9f8fbfa` |
| D11 | rdata | `f5f4f7f6f1f0f3f2` |
| D12 | rdata | `edecefeee9e8ebea` |
| D13 | rdata | `e5e4e7e6e1e0e3e2` |
| D14 | rdata | `dddcdfded9d8dbda` |
| D15 | wdata | `0000000000770000` |
| D16 | wdata | `0000000076000000` |
| D17 | wdata | `0000007500000000` |
| D18 | wdata | `0000740000000000` |
| D19 | wdata | `007b000000000000` |
| D20 | wdata | `7a00000000000000` |
| D21 | wdata | `0000000000000079` |
| D22 | wdata | `0000000000007800` |
| D23 | wdata | `00000000007f0000` |
| D24 | wdata | `000000007e000000` |
| D25 | wdata | `0000007d00000000` |
| D26 | wdata | `00007c0000000000` |
| D27 | wdata | `0063000000000000` |
| D28 | wdata | `6200000000000000` |
| D29 | wdata | `0000000000000061` |
| D30 | wdata | `0000000000006000` |
| D31 | wdata | `0000000000670000` |
| D32 | wdata | `0000000066000000` |
| D33 | wdata | `0000006500000000` |
| D34 | wdata | `0000640000000000` |

Useful constant context: `AW.len=04`; `rready=1 (no back-pressure)`; `bready=1 (no back-pressure)`.

## Result and rule to remember

Fault cause, program location and bus-error address are related evidence, but they are not interchangeable.

## Design reference

TRM §2.8 and Table 3-16; FAR is a workspace extension.

For source tests, reproduction commands and validation scope, see [Reproduction and validation](99_validation.md).

---

<!-- reading-nav -->
[Guide index](README.md) · [Background](00_background.md) · [← Previous: 15. Kill a channel waiting on an event](15_kill.md) · [Next: 17. Share the bus and MFIFO between channels →](17_sharing.md)
<!-- /reading-nav -->
