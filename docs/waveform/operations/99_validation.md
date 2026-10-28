# Validation record and implementation boundaries

[Guide index](README.md) · [Background](00_background.md) · [WaveDrom conventions](00_conventions.md)

## Publication scope

The GitHub guide contains 20 operation walkthroughs with 30 actual WaveDrom SVGs and 30 same-name JSON files. Background and conventions are included in this directory. VCDs, the superseded exhaustive gallery, authoring scripts and new teaching tests are retained locally rather than published.

Every illustration identifies its source run and time window. Each JSON's `_meta` records source signal paths, pre-edge values, sampling times, display masks, omitted context and the source-VCD SHA-256. The SVG also records the paired JSON hash. These metadata preserve a connection to the recorded simulation without distributing its VCD.

## Validation record

The following results were measured during authoring; they are not checks a reader can reproduce from images alone.

| Check | Recorded result |
|---|---|
| Original simulations | 64 PASS runs, using the original UVM environment and unit tests plus new directed teaching scenarios |
| Displayed sample consistency | 12,505 pre-edge samples compared with local source VCDs after the documented masks |
| WaveDrom outputs | All 30 SVGs rendered from the paired JSON and successfully rasterized for visual review |
| Sampling, encoding and color tests | 7 tests passed |
| Source freeze | All 82 original RTL and pre-existing testbench source hashes unchanged |
| Reading structure | 20 operation pages, each with one or two focused figures |

The independent checker reported **zero protocol violations** over 421,316 active AXI cycles, 57,938 AR/AW bursts, 149,047 read beats, 141,325 write beats, 141,321 strobe checks, 27,444 write responses, 152,567 stall-stability cycles and 10,206 APB accesses. These are observed counts, not coverage percentages or new sign-off claims. Strobe checks establish legal asserted lanes; payload correctness also relies on the original scoreboard/reference-model checks.

The current publication changes presentation and packaging. It does not change RTL or pre-existing testbenches. The figures illustrate selected behavior and do not replace the repository's [verification plan](../../VERIFICATION_PLAN.md) or [test specification](../../TESTCASES.md).

## Implementation boundaries

The baseline is **Arm DMA Controller DMA-330 r1p2 Technical Reference Manual, DDI 0424D**. The supplied local reference is `references/DDI0424D_dma330_r1p2_trm.pdf`; section citations use its printed labels. The [existing design specification, section 9](../../DESIGN_SPEC.md) describes workspace differences. In particular:

| Topic | Workspace behavior to keep in mind |
|---|---|
| Bus interface | AXI4 without WID; Arm DMA-330 describes AXI3. Descriptor lengths remain 1–16 beats. |
| Fetch ID | Shared instruction-fetch ID `f`; data IDs `0..3` identify channels in this build. |
| APB/peripheral integration | Two APB views, optional asynchronous bridges/PSLVERR, and one pending peripheral request latch per interface. |
| Mid-program control changes | Some SAR/DAR/CCR changes retain the MFIFO byte stream instead of inserting Arm's discontinuity barrier/discard behavior. See TRM §2.11.3. |
| Unaligned FIXED access | Accepted by this RTL; Arm treats it as a programming error. Teaching FIXED examples are aligned. |
| Endian capability | Swap group cannot exceed the instantiated data width; 128-bit swap requires a 128-bit build. |
| Cache lifecycle | Thread/NS tags and thread-local END/KILL/WFE maintenance are concrete implementation mechanisms. |
| Fault diagnosis | Data-bus errors are imprecise; current CPC need not identify the originating load/store. FAR, WDSTAT and watchdog fields are workspace extensions. |
| Low power | Q-Channel is a workspace extension, not a feature established by this DMA-330 manual. |

A passing waveform illustrates the observed case; it is not proof of complete Arm IP equivalence or a timing bound. The figures are sampled explanations, not continuous-time CDC analysis. The validation record above states the measured scope.

[← Guide index](README.md) · [WaveDrom conventions](00_conventions.md)
