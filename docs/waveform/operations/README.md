# DMA-330 design guide

Understand the frozen design through **24 operations and 37 WaveDrom illustrations**. Each operation uses one or two focused pictures, followed by measured milestones and decoded data values.

[Repository](../../../README.md) · [Background](00_background.md) · [Waveform conventions](00_conventions.md) · [Validation](99_validation.md)

## Start here

1. Read [Background and prerequisites](00_background.md): architecture, microprograms, CCR, byte lanes, AXI/APB, MFIFO, states, events and faults.
2. Follow [Launch a channel](01_launch.md), then [Copy and completion](02_copy.md) to connect software commands with bus activity.
3. Choose a topic below. Every page follows **purpose → starting conditions → minimal sequence → waveform → result**.

> **Reading the pictures:** cells are pre-edge cycle snapshots. Click an image to enlarge it. State and data colors are additional cues; labels and value tables carry the meaning. See the [timing and color guide](00_conventions.md).

## 1. Start and move data

Launch a channel, follow one complete copy, then vary the transfer shape.

| # | Operation | Figures |
|---:|---|---:|
| 1 | [Launch a channel through the APB debug interface](01_launch.md) | 1 |
| 2 | [Copy a four-beat memory burst and report completion](02_copy.md) | 1 |
| 3 | [Pack and unpack between different beat widths](03_packing.md) | 2 |
| 4 | [Copy between different byte alignments](04_unaligned.md) | 1 |
| 5 | [Split one instruction burst at a 4 KB boundary](05_boundary.md) | 2 |
| 6 | [Use a fixed source or a fixed destination](06_fixed.md) | 2 |
| 7 | [Fill memory with DMASTZ](07_zero.md) | 1 |

## 2. Program and synchronize work

Add loops, byte swapping, peripheral pacing and event synchronization.

| # | Operation | Figures |
|---:|---|---:|
| 8 | [Build a two-dimensional copy using loops and address arithmetic](08_loops.md) | 2 |
| 9 | [Reverse bytes inside endian-swap groups](09_endian.md) | 2 |
| 10 | [Service a memory-to-peripheral request](10_m2p.md) | 1 |
| 11 | [Service a peripheral-to-memory request](11_p2m.md) | 1 |
| 12 | [Select single or burst work and terminate on the final request](12_request_types.md) | 2 |
| 13 | [Synchronize a channel using a sticky event](13_events.md) | 2 |

## 3. Understand control and integration

Study cancellation, faults, shared resources, security, clock crossings and sleep.

| # | Operation | Figures |
|---:|---|---:|
| 14 | [Cancel an instruction-cache response safely](14_cache.md) | 1 |
| 15 | [Kill a channel waiting on an event](15_kill.md) | 1 |
| 16 | [Diagnose a precise program fault and an imprecise bus fault](16_faults.md) | 2 |
| 17 | [Share the bus and MFIFO between channels](17_sharing.md) | 2 |
| 18 | [Execute a non-secure channel program](18_security.md) | 1 |
| 19 | [Pass a peripheral request across unrelated clocks](19_cdc.md) | 1 |
| 20 | [Accept sleep and wake the DMA for an APB access](20_lowpower.md) | 2 |

## 4. Architectural phases and ordering details

Current-revision PC phases, implicit barriers, wide endian groups and precise CCR permission checks.

| # | Operation | Figures |
|---:|---|---:|
| 21 | [Distinguish execution, PC calculation and a real cache refill](21_thread_phases.md) | 2 |
| 22 | [Drain an implicit barrier before changing the transfer stream](22_reconfiguration.md) | 2 |
| 23 | [Swap 128-bit groups across narrower AXI beats](23_swap128.md) | 2 |
| 24 | [Reject a forbidden non-secure CCR before committing it](24_ccr_permissions.md) | 1 |

## Reference and editable sources

| Need | Open |
|---|---|
| Understand signal groups, sampling and pastel colors | [WaveDrom conventions](00_conventions.md) |
| Edit a picture in WaveDrom | [JSON sources](../wavejson/) paired with [SVG images](../svg/) |
| Review recorded checks and publication scope | [Validation record](99_validation.md) |
| Review measured checks and implementation boundaries | [Check results](99_validation.md#validation-record) · [Arm compatibility notes](99_validation.md#implementation-boundaries) |
| Locate source-run names, signal paths and sampled values | `_meta` inside each [WaveJSON file](../wavejson/) |

The architectural baseline is **Arm DMA-330 r1p2 TRM, DDI 0424D**. Read the implementation boundaries before treating workspace behavior as an Arm requirement. All 85 original RTL and testbench source files remain frozen.

This published guide contains only `operations/`, `svg/` and `wavejson/`. Background and reading conventions are included here so every operation can be read directly on GitHub. VCDs, the exhaustive archive, reproduction scripts and new teaching tests remain local.
