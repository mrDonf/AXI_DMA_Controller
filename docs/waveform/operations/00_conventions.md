# WaveDrom sources and reading conventions

[Operation guide](README.md) | [Background](00_background.md)

## One operation, one or two pictures

The guide contains twenty named operations and thirty illustrations. Choose a topic from the [categorized operation index](README.md). VCDs and the superseded exhaustive gallery are kept locally and are not published.

Each operation starts with the purpose, starting configuration and a minimal program sketch. Read the numbered explanation, then use the picture and its short milestone table to follow the mechanism. A second picture is a deliberate comparison, such as read-side versus write-side page splitting; it is not simply the next arbitrary slice of a long simulation.

## JSON and SVG are a pair

For example:

- [02_copy_1.json](../wavejson/02_copy_1.json) is standard WaveJSON input.
- [02_copy_1.svg](../svg/02_copy_1.svg) is rendered from that exact file using WaveDromPy, the Python implementation of the WaveDrom renderer.
- [02_copy.md](02_copy.md) explains the operation and decodes the short address/data labels.

Copy the complete JSON into the [WaveDrom editor](https://wavedrom.com/editor.html). It contains standard `signal`, grouped signal arrays, `wave`, `data`, `head`, `foot` and `config` fields. `_meta` supplies trace provenance and full values; it is ignored by the waveform renderer. The format follows the [WaveDrom WaveJSON specification](https://github.com/wavedrom/schema/blob/master/WaveJSON.md). The command-line renderer is [WaveDromPy](https://github.com/wallento/wavedrompy).

The SVG uses WaveDrom's own waveform shapes, buses, group brackets, grid and labels. A white canvas and a source-JSON hash are added to the SVG container; no separate hand-drawn signal paths are used.

## Color guide

Colors use the standard WaveDrom default-skin bus symbols `2..9`, as demonstrated in the [official tutorial](https://wavedrom.com/tutorial.html). They are encoded in the saved JSON, so copying it into the online editor preserves the same pastel fills. Text stays dark on a light background. Clock, cycle ruler and handshake wires remain neutral so the functional highlights are easy to locate.

| State or role | Color | WaveDrom symbol |
|---|---|---|
| STOP / inactive context | White | `2` |
| FET (FETCH), addresses | Pastel blue `#b9e0ff` | `5` |
| EX (EXEC), store opcode | Soft green `#cdfdc5` | `7` |
| WFE / WFP | Pale amber `#ffffb4` | `3` |
| BAR (BARRIER), memory barrier opcode | Soft peach `#ffe0b9` | `4` |
| END / completion, event notification | Pale cyan `#ccfdfe` | `6` |
| KILL, loop counters/control | Light lavender `#f0c1fb` | `8` |
| FC / FLT, nonzero fault register | Soft rose `#f5c2c0` | `9` |

Payload words use a separate six-color identity cycle: blue, cyan, green, lavender, peach, amber. The same full-width value has the **same color on RDATA and WDATA within a picture**, including when one occurrence uses a short D label and another prints the full value. Colors repeat after six distinct values; the D labels and decoded values remain the identity reference. Payload never uses the fault-rose color. A green payload cell therefore identifies data; it does not declare success.

State labels, hexadecimal values, D labels and the timestamp tables remain present. Color is an additional cue, so the explanation can still be followed in grayscale or with difficulty distinguishing particular hues. Unknown/invalid regions retain their hatching. The JSON's `_meta.colors` records the palette, state mapping and payload-color assignments.

## Why these pictures are compact

Signals are grouped into short functional blocks: Thread, MFIFO, AXI read, AXI write, APB, Event and Peripheral. A bracket containing only one signal is omitted to avoid a long vertical group label colliding with nearby groups.

The exporter omits an AXI interface when its VALID never becomes active in the selected interval. It filters instruction-cache traffic from data-focused examples; the launch example explicitly retains instruction fetching. Uninformative constant rows move to JSON context, and useful constants such as LEN, WSTRB or READY are summarized below the picture. `VALID (RDY=1)` means READY stayed high in the shown interval, so a separate all-high READY row is unnecessary.

Constants that explain a mechanism stay visible: a stalled address, an external wait state or the NS/PROT settings in the security example. Peripheral pictures show only the relevant request/acknowledgement lanes, rather than four unrelated clock waveforms and packed idle-lane noise. The JSON records every omitted row and why it was omitted.

The source-cycle row identifies the original simulation cycles. `|` explicitly marks omitted **idle** cycles; accepted AXI beats are never collapsed. Each picture has at most 32 displayed cycle columns. Local source VCDs retain all clocks and all time between excerpts.

## Timing: cycle snapshots rather than continuous-time reconstruction

These WaveDroms are educational **cycle snapshots**. One column corresponds to one 5 ns core cycle, or one 10 ns clock cycle in the cache-unit example. The footer states the period and the exact time of the first column's **right** sampling edge.

Each displayed signal value is sampled immediately **before the right edge** of its column. For a synchronous VALID/READY pair, the transfer is accepted at that right edge. A drop in VALID shown at the next column does not cancel the transfer at the previous column's right edge. The sampled internal state describes the state occupied before that edge; state transitions after the edge appear in the next cell.

The displayed `sample clock` is a timing ruler for those snapshots. It is not the gated DUT clock and is not a claim that every external clock has the same phase. This distinction matters in the sleep example, where the ruler continues while DUT clock enable is low.

Asynchronous APB and peripheral pins are snapshots on the chosen core grid. An external handshake can occur **between** displayed core edges. Therefore physical sub-cycle CDC timing must be read from the exact timestamp table, which samples APB on PCLK and DR/DA on the appropriate peripheral clock, or from a locally regenerated VCD. These pictures illustrate request ordering and captured context; they do not model analog metastability or turn a core-grid snapshot into an external handshake event.

## Labels and invalid data

`A1`, `A2`, ... abbreviate addresses that would overlap in one cycle. `D1`, `D2`, ... abbreviate full data words. Equal D labels in the same picture mean equal full values, allowing the reader to follow bytes from RDATA to WDATA. Their full values are decoded below each figure and retained in JSON `_meta.value_labels`. They are labels, not replacement stimulus data.

Bus `x` regions denote invalid/don't-care display intervals or source unknowns. `_meta.lanes[].samples` distinguishes a deliberately masked invalid value (`null`) from a recorded unknown bit string. The source VCD remains authoritative. Opcode labels are shown only when the thread is executing; non-matching S/B instructions still need the condition/descriptor discussion in the text.

The thread state labels are implementation states, not CSR codes: FET=FETCH, EX=EXEC, BAR=BARRIER, WFE=event wait, WFP=peripheral wait, END=completion, KILL=cancellation, FC=fault completion, FLT=faulting. Small numerical fields use decimal; wider bus labels use hexadecimal without `0x`. Milestone tables put explicit `0x` on addresses.

## Edit a waveform online

Open the matching JSON, copy its complete contents into the [WaveDrom editor](https://wavedrom.com/editor.html), and render it there. For example, [02_copy_1.json](../wavejson/02_copy_1.json) corresponds to [02_copy_1.svg](../svg/02_copy_1.svg).

The `_meta` object is provenance for the recorded illustration and is ignored by the renderer. An edited waveform is an illustration variant; it is no longer evidence that the changed values occurred in the recorded simulation. The original source-run names, VCD hashes and sample values remain available in the published JSON. VCDs and authoring scripts are not included in this publication.

[← Guide index](README.md) · [Validation and implementation boundaries](99_validation.md)
