# Distinguish execution, PC calculation and a real cache refill

<!-- reading-nav -->
[Guide index](README.md) · [Background](00_background.md) · [← Previous: 20. Accept sleep and wake the DMA for an APB access](20_lowpower.md) · [Next: 22. Drain an implicit barrier before changing the transfer stream →](22_reconfiguration.md)
<!-- /reading-nav -->

## Purpose

Read internal phase and architectural CSR together instead of treating all fetch activity as Cache miss.

## Starting conditions

Use the newly recorded small copy; the instruction cache begins cold.

## Minimal sequence

The sequence below is an explanatory sketch. The recorded assembler may emit extra CCR updates or loop setup. The source-run name below identifies the reproducible simulation.

```text
DMAGO -> FETCH/MISS -> EXEC -> UPDATING_PC -> FETCH/RUN
```

## Read the waveform

1. The CSR row reports MISS only for a real per-thread shared-cache refill. FET alone does not imply MISS.
2. Instruction effects occur in EX. UPC calculates and commits the next CPC without reissuing the instruction.
3. The target fetch overlaps PC calculation. A warm fetch can report RUN even while instruction assembly is in progress.

Group brackets separate the thread, shared storage and active interfaces. Inactive interfaces and uninformative constant rows are omitted. A constant needed to explain a stall or security decision stays visible. Pastel state colors distinguish execution, waiting and faults; equal payload values share a color across read/write rows. [WaveDrom conventions and color legend](00_conventions.md) define cell timing, data labels and snapshots.

### Waveform 1

[![Waveform 1](../svg/21_thread_phases_1.svg)](../svg/21_thread_phases_1.svg)

[Open SVG at full size](../svg/21_thread_phases_1.svg) | [WaveDrom JSON](../wavejson/21_thread_phases_1.json)

Source: `direct_copy32`. Core/unit cycle snapshots cover the selected **287.5..437.5 ns** interval. The first cell's right sampling edge is **287.5 ns**.

| Exact VCD time (ns) | Milestone | Meaning |
|---:|---|---|
| 412.5 | AR accepted | ID=0; address=0x10000000; 4 beats x 8 B; INCR |
| 432.5 | RLAST accepted | RESP=0 |

Full values for the short labels in this picture (matching D labels mean matching data):

| Label | Signal(s) | Full value |
|---|---|---|
| A1 | AR.addr | `10000000` |

Useful constant context: `APB.pready=1`; `AR.ready=1 (no back-pressure)`; `AR.len=03`.

### Waveform 2

[![Waveform 2](../svg/21_thread_phases_2.svg)](../svg/21_thread_phases_2.svg)

[Open SVG at full size](../svg/21_thread_phases_2.svg) | [WaveDrom JSON](../wavejson/21_thread_phases_2.json)

Source: `direct_copy32`. Core/unit cycle snapshots cover the selected **337.5..487.5 ns** interval. The first cell's right sampling edge is **337.5 ns**.

| Exact VCD time (ns) | Milestone | Meaning |
|---:|---|---|
| 412.5 | AR accepted | ID=0; address=0x10000000; 4 beats x 8 B; INCR |
| 432.5 | RLAST accepted | RESP=0 |
| 442.5 | AW accepted | ID=0; address=0x20000000; 4 beats x 8 B; INCR |
| 462.5 | WLAST accepted | WSTRB=0xff |
| 467.5 | B response accepted | RESP=0 |

Full values for the short labels in this picture (matching D labels mean matching data):

| Label | Signal(s) | Full value |
|---|---|---|
| A1 | ch0.PC | `00010015` |

Useful constant context: `arready=1 (no back-pressure)`; `awready=1 (no back-pressure)`; `wready=1 (no back-pressure)`.

## Result and rule to remember

Internal enum 10 means UPC; architectural status 3 means Updating PC. The two encodings must be decoded separately.

## Design reference

TRM sections 2.3.3-2.3.4; current channel and cache refill-pending logic.

For source tests, reproduction commands and validation scope, see [Reproduction and validation](99_validation.md).

---

<!-- reading-nav -->
[Guide index](README.md) · [Background](00_background.md) · [← Previous: 20. Accept sleep and wake the DMA for an APB access](20_lowpower.md) · [Next: 22. Drain an implicit barrier before changing the transfer stream →](22_reconfiguration.md)
<!-- /reading-nav -->
