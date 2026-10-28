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

Source: `direct_underflow`. Core/unit cycle snapshots cover the selected **307.5..467.5 ns** interval. The first cell's right sampling edge is **307.5 ns**.

| Exact VCD time (ns) | Milestone | Meaning |
|---:|---|---|
| 387.5 | FTR | 0x2000 |

### Waveform 2

[![Waveform 2](../svg/16_faults_2.svg)](../svg/16_faults_2.svg)

[Open SVG at full size](../svg/16_faults_2.svg) | [WaveDrom JSON](../wavejson/16_faults_2.json)

Source: `dma_fault_test_sync`. Core/unit cycle snapshots cover the selected **3597.5..3757.5 ns** interval. The first cell's right sampling edge is **3597.5 ns**.

| Exact VCD time (ns) | Milestone | Meaning |
|---:|---|---|
| 3607.5 | B response accepted | RESP=0 |
| 3607.5 | WLAST accepted | WSTRB=0x01 |
| 3617.5 | AW accepted | ID=0; address=0x200cbb6b; 5 beats x 1 B; INCR |
| 3637.5 | B response accepted | RESP=0 |
| 3642.5 | AR accepted | ID=0; address=0x100f363a; 15 beats x 2 B; INCR |
| 3647.5 | AW accepted | ID=0; address=0x200cbb70; 5 beats x 1 B; INCR |
| 3672.5 | WLAST accepted | WSTRB=0x20 |
| 3677.5 | AR accepted | ID=3; address=0xe0000000; 16 beats x 8 B; INCR |
| 3687.5 | B response accepted | RESP=0 |
| 3687.5 | FTR | 0x40000 |
| 3697.5 | AW accepted | ID=0; address=0x200cbb75; 5 beats x 1 B; INCR |
| 3712.5 | WLAST accepted | WSTRB=0x04 |

Full values for the short labels in this picture (matching D labels mean matching data):

| Label | Signal(s) | Full value |
|---|---|---|
| A1 | AR.addr | `100f363a` |
| A2 | AW.addr | `200cbb6b` |
| A3 | AW.addr | `200cbb70` |
| A4 | AW.addr | `200cbb75` |
| D1 | rdata | `bdbcbfbeb9b8bbba` |
| D2 | rdata | `b5b4b7b6b1b0b3b2` |
| D3 | rdata | `4c4d4e4f48494a4b` |
| D4 | rdata | `adacafaea9a8abaa` |
| D5 | rdata | `a5a4a7a6a1a0a3a2` |
| D6 | rdata | `3435363730313233` |
| D7 | rdata | `9d9c9f9e99989b9a` |
| D8 | rdata | `9594979691909392` |
| D9 | rdata | `8d8c8f8e89888b8a` |
| D10 | wdata | `6200000000000000` |
| D11 | wdata | `0000000000000061` |
| D12 | wdata | `0000000000006000` |
| D13 | wdata | `0000640000000000` |
| D14 | wdata | `006b000000000000` |
| D15 | wdata | `6a00000000000000` |
| D16 | wdata | `0000000000000069` |
| D17 | wdata | `0000000000006800` |
| D18 | wdata | `00000000006f0000` |
| D19 | wdata | `000000006e000000` |
| D20 | wdata | `0000006d00000000` |
| D21 | wdata | `0053000000000000` |
| D22 | wdata | `5200000000000000` |
| D23 | wdata | `0000000000000051` |

Useful constant context: `AW.len=04`; `bready=1 (no back-pressure)`.

## Result and rule to remember

Fault cause, program location and bus-error address are related evidence, but they are not interchangeable.

## Design reference

TRM §2.8 and Table 3-16; FAR is a workspace extension.

For source tests, reproduction commands and validation scope, see [Reproduction and validation](99_validation.md).

---

<!-- reading-nav -->
[Guide index](README.md) · [Background](00_background.md) · [← Previous: 15. Kill a channel waiting on an event](15_kill.md) · [Next: 17. Share the bus and MFIFO between channels →](17_sharing.md)
<!-- /reading-nav -->
