# DMA Controller Overview — From System Concepts to DMA-330 Design

**Audience:** RTL and verification engineers, firmware developers, and SoC integrators.

**Reading route:** the core discussion in sections 1–16 is the 20–25 minute overview. The added worked-operation/state subsections in sections 9–11, 13 and 14, together with sections 17–27, are optional deeper reference material; reading the complete document takes substantially longer.

**Architectural reference:** Arm DMA Controller DMA-330 r1p2 Technical Reference Manual, DDI 0424D.

**Implementation discussed:** the `axi_dma330` SystemVerilog design in this repository, including its optimized channel instruction-delivery path.

| Reading stage | Sections |
|---|---|
| Understand the problem | [What DMA does](#2-what-a-dma-controller-does) · [Programming models](#3-how-dma-work-is-described) |
| Learn the vocabulary | [Transfer terminology](#4-essential-transfer-terminology) · [DMA-330 system view](#5-dma-330-in-a-system) |
| Understand the hardware | [Architecture](#6-architecture-who-does-what) · [Programmer's model](#7-programmers-model) |
| Follow an operation | [Instructions](#8-instruction-families-and-program-structure) · [Worked copy](#9-worked-example-a-complete-32-byte-memory-copy) · [States](#10-architectural-states-and-optimized-instruction-execution) |
| Understand coordination and exceptions | [Peripheral/events](#11-peripheral-requests-events-and-completion-ordering) · [Alignment and formats](#12-alignment-boundaries-and-changing-formats) · [Faults](#13-faults-cancellation-and-recovery) |
| Apply it to an SoC | [Integration](#14-security-coherency-clocks-and-power) · [Performance/diagnosis](#15-performance-and-diagnostic-interpretation) · [Repository and references](#16-mapping-this-explanation-to-the-repository) |

## 1. Purpose and reading order

This document builds a common understanding of DMA before explaining how a DMA-330-style controller implements it. Read sections 2–5 for the system concepts, sections 6–10 for architecture and execution, and sections 11–15 for synchronization, diagnosis and integration. Section 16 connects the concepts to the RTL and waveform guide.

Three levels of information are distinguished throughout:

| Level | Meaning |
|---|---|
| General DMA concept | A principle shared by many DMA controllers; a particular controller may implement it differently. |
| DMA-330 architectural contract | Software-visible behavior defined by DDI 0424D: instructions, registers, operating states and peripheral protocol. |
| This implementation | Concrete modules, parameter choices, AXI4 integration, internal scheduling and extensions in this workspace. |

The Arm manual defines the architectural contract. The RTL determines this implementation's exact behavior. A selected waveform demonstrates an observed execution; it does not establish a universal cycle count or prove equivalence to the Arm macro.

For detailed work, continue with [microcode and binary encodings](#17-microcode-reference-and-binary-encodings), [complete register map](#18-register-map-access-and-bit-fields), [CCR programming](#19-ccr-programming-byte-accounting-and-discontinuities), [software sequences](#20-software-sequences-and-worked-register-values), [waveform walkthroughs](#21-waveform-walkthroughs-from-the-current-rtl), and [reference coverage](#22-specification-coverage-and-confluence-publication).

For the relationships between blocks, read [manager–channel coordination](#23-how-the-manager-and-channel-threads-work-together), [DMAC transaction and ownership stages](#24-dmac-operation-as-a-pipeline-of-commitments), [Arm MFIFO resource requirements](#25-arm-resource-sharing-and-forward-progress), and [the specification-to-integration contract](#26-applying-the-arm-specification-to-a-complete-system).

The [function and operation coverage map](#27-function-and-operation-coverage-after-review) connects the principal capabilities to their explanations and recorded examples. It also identifies behavior that this document does not claim as an established feature.

For the detailed execution explanation, start with [channel entry/hold/exit conditions](#103-every-channel-phase-entry-retained-work-and-exit), [the four main state flows](#104-four-state-flows-to-recognize) and [manager phases](#105-manager-phases-and-their-separate-flow). Then read [instruction execution contracts](#177-how-to-read-an-instructions-execution-contract) through section 17.12 alongside the encoding catalog.

### 1.1 How to use the reference chapters

Sections 1–16 form the continuous introduction. For the shorter reading route, return to the detailed worked-operation subsections when needed. The later chapters are intended for deeper lookup: open them when writing microcode, decoding a register value, diagnosing a transfer or reviewing a waveform. Reading every encoding table is not a prerequisite for understanding the overview.

The numerical examples are supported by explicit arithmetic rather than unexplained constants. CCR construction, instruction lengths and offsets, little-endian operands and debug-register packing have been cross-checked during authoring. [Section 20.6](#206-how-the-worked-examples-are-calculated-and-cross-checked) explains how to repeat those checks. Figure links resolve to the corresponding saved SVG/JSON pair, and the captions identify the source run and selected interval.

Those checks establish consistency of the examples and their references. They do not mean that every newly written microprogram is automatically correct or that a document-level arithmetic check replaces simulation of its behavior.

## 2. What a DMA controller does

A **Direct Memory Access controller**, or DMAC, moves data between addressable endpoints without requiring the CPU to execute an instruction for every transferred word. The CPU describes or programs the work, establishes the necessary memory visibility, starts the controller and handles completion or errors.

Consider a CPU copying a receive buffer into another memory region. A software loop consumes instruction-fetch, load, store and scheduling resources. A DMA controller issues the data transfers itself while the CPU handles another task or waits for an interrupt. The system still performs the reads and writes: DMA transfers the work to another bus initiator rather than eliminating memory traffic.

The principal responsibilities of a DMAC are:

1. **Generate addresses and transfer shapes:** select the source, destination, increment behavior, beat width and burst length.
2. **Move and buffer payload:** accept read data, preserve byte ordering, and generate correctly positioned write data and byte enables.
3. **Schedule work:** arbitrate channels, use shared buffers and manage outstanding transactions.
4. **Coordinate endpoints:** respond to peripheral requests and synchronize dependent operations.
5. **Report progress and exceptions:** expose status, produce completion notifications and retain fault information.

DMA does not automatically provide CPU cache coherence, application-level ownership, virtual-address translation or rollback. Those properties require a defined system integration and software protocol.

### 2.1 Typical uses

| Transfer | Address behavior | Typical use |
|---|---|---|
| Memory to memory | Source and destination usually increment | Buffer copies and relocation. |
| Memory to peripheral | Memory increments; peripheral FIFO address is usually fixed | Feeding a transmit FIFO. |
| Peripheral to memory | Peripheral FIFO address is usually fixed; memory increments | Draining received data into a buffer. |
| Memory fill | Generate a constant or zero payload | Buffer initialization; this design provides DMASTZ for zero stores. |

A peripheral FIFO can expose one address repeatedly: accessing that address consumes or produces successive FIFO entries. A fixed AXI address therefore does not necessarily mean repeatedly accessing the same logical data item. The peripheral's register contract determines the side effect.

### 2.2 When DMA is useful

DMA is attractive for sustained or repeated movement and when peripheral timing should be decoupled from CPU scheduling. Small transfers may be dominated by setup, cache maintenance and notification overhead. DMA also competes with the CPU and other initiators for interconnect and memory resources. Performance depends on the complete path, not only the DMAC's data-bus width.

## 3. How DMA work is described

Different controllers expose different programming models. Understanding the model prevents incorrect assumptions about their registers and capabilities.

| Model | How work is expressed | Main implication |
|---|---|---|
| Register programmed | Load source, destination, count and mode registers | Simple setup; capabilities depend on the hardware's built-in transfer modes. |
| Descriptor driven | Hardware reads a list or ring of transfer descriptors | Software submits structured jobs, often including scatter-gather segments. |
| Instruction driven | Hardware fetches and executes a small program | Loops, waits, events and address arithmetic express the sequence of work. |

**DMA-330 is instruction driven.** Its program contains load/store instructions, register updates, loops and synchronization instructions. A channel's job is not represented by one universal source/destination/count descriptor. The program determines the total work.

This implementation also uses **internal transfer descriptors** between channel execution and the datapath. These describe individual queued loads or stores. They are hardware queue entries, distinct from a software descriptor ring.

For example, a 512-byte job can execute sixteen iterations of a 32-byte load/store pair. The channel program defines the iteration count; CCR defines each pair's transfer shape; the AXI engines implement the required bus transactions.

## 4. Essential transfer terminology

### 4.1 Byte, beat, burst and job

An address normally identifies a **byte**. A **beat** is one accepted data transfer on a bus channel. A **burst** combines multiple beats under one address request. A **job** is the complete software operation, potentially containing many instructions and bursts.

On a 64-bit bus, eight physical byte lanes are available. This does not require every beat to contain eight meaningful bytes. AXI encodes beat size as `2^AxSIZE` bytes and burst length as `AxLEN + 1` beats. Thus `SIZE=3, LEN=3` describes four eight-byte-sized beats.

For an aligned incrementing transfer, that burst contains 32 useful bytes. Unaligned starts require more care: with eight-byte-sized beats and a start offset of three, the first beat contributes five useful bytes. Three beats then contribute `5 + 8 + 8 = 21` bytes. A program may need a tail transfer to reach its intended byte count.

### 4.2 Addressing and byte lanes

**INCR** advances through an address range. **FIXED** repeatedly accesses the same address. Source and destination settings are independent, which supports combinations such as incrementing memory reads followed by fixed-address FIFO writes.

`WSTRB` identifies valid write lanes. On an eight-lane bus, `0xff` enables all lanes; `0x0c` enables lanes 2 and 3. Lane 0 occupies the least-significant eight data bits. Printed hexadecimal order must not be confused with increasing byte addresses.

Packing and unpacking change transfer shape while preserving the logical byte stream. Eight one-byte reads can supply one eight-byte write. These are not eight independent jobs: the DMA buffer joins the source and destination shapes.

### 4.3 Handshake and completion

AXI uses five independent channels:

| Channel | Information | Accepted when |
|---|---|---|
| AR | Read address and attributes | ARVALID and ARREADY. |
| R | Read payload and response | RVALID and RREADY. |
| AW | Write address and attributes | AWVALID and AWREADY. |
| W | Write payload and strobes | WVALID and WREADY. |
| B | Write response | BVALID and BREADY. |

The sender holds VALID and its payload stable while READY is low. Acceptance occurs at the sampling clock edge. Repeated VALID with READY high can represent a beat every cycle.

An accepted address is not a completed transaction. Read completion requires the accepted final R beat; write completion requires the corresponding B response. WLAST alone identifies the last write-data beat. AW and W are independent, so a checker must not impose an unsupported rule that W always follows an already accepted AW.

**Outstanding work** has been issued but has not fully retired. Transaction IDs associate responses with the correct stream and allow concurrency. Completion of one channel's work does not mean the complete DMAC is idle.

## 5. DMA-330 in a system

DMA-330 combines a **manager thread**, **channel threads**, an instruction-fetch system and a shared data-moving system. Here, a thread is a hardware instruction-execution context rather than an operating-system thread or a dedicated external AXI port.

```text
                        Control and scheduling
 CPU / driver --APB--> Registers / debug interface
                              |
                         Manager thread
                              | DMAGO
                         Channel threads
                         /             \
                instruction fetch    load/store descriptors
                       |                       |
                 Shared I-cache       Read/write queues
                       |                       |
                       +------ AXI master -----+
                                              |
                        Payload movement      |
 Memory / MMIO --AXI read--> Shared MFIFO --AXI write--> Memory / MMIO

 Peripheral --DR/DA request and acknowledgement--> Peripheral control
 Channels   --events and interrupts-------------> Other threads / CPU
```

The conceptual paths share hardware; the drawing does not imply separate physical AXI masters. Instruction fetches and payload reads both use the external read interface, but have different destinations and meanings.

### 5.1 Current implementation profile

The following values describe the default verification configuration, not every possible DMA-330 instance:

| Resource | Current default |
|---|---|
| Channel contexts | Four channels plus one manager. |
| AXI integration | AXI4; 32-bit addresses and 64-bit data. |
| Channel data IDs | 0–3; instruction fetch uses ID 0xf with the default four-bit ID width. |
| Transfer shape | FIXED/INCR; 1–16 beats per descriptor-side burst shape, with supported narrow sizes. |
| MFIFO | 128 shared eight-byte lines: 1024 bytes total. |
| Shared instruction cache | Eight 32-byte lines. |
| Queuing | Four-entry read/write queues and four read/write outstanding slots per channel. |
| Peripheral interfaces | Four request interfaces. |
| Events | Sixteen event numbers and a separate abort indication. |

The original Arm DMA-330 interface is AXI3. This workspace uses AXI4 without WID, its own APB/CDC integration and additional diagnostic/power features. It should be understood as a DMA-330-style architectural implementation, not a pin-, cycle- or resource-identical copy of the Arm macro.

## 6. Architecture: who does what?

### 6.1 Manager and channel threads

The manager executes control instructions, including `DMAGO` to launch a channel at a program address with a selected security state. It can run a memory-resident boot program or execute instructions supplied through the debug register interface. Debug launch is therefore a normal software control mechanism, not only a laboratory feature.

Each channel retains its own PC, source/destination addresses, CCR, loop counters, wait context and fault information. It fetches instructions and submits transfer requests to the shared datapath. A channel blocked on an event can coexist with other channels moving data.

`DMAGO` launches a stopped target. It does not restart a running channel. A faulted channel must first be recovered to Stopped. Launch also does not substitute for initializing every working register required by the new program.

### 6.2 Instruction fetch

Each thread has a local instruction-line buffer backed by a shared instruction cache. Instructions are variable length; for example, DMAMOV occupies six bytes. A boundary-crossing instruction can require additional lines before it is executable.

A local-buffer miss is not automatically an architectural **Cache miss**. A shared-cache hit or instruction assembly may satisfy it without an external refill. This implementation reports Cache miss for a real refill associated with the thread; the cache can serve another thread's hit while a refill waits.

Cache entries carry thread/security context. Invalidation cancels stale instruction delivery and allocation, while already-issued refill traffic still needs protocol-correct retirement. Returned bytes from a killed program must not revive that program.

### 6.3 Datapath and shared MFIFO

The read engine accepts queued descriptors, issues AR requests, tracks responses and extracts useful bytes from R beats. The **MFIFO** stores a logically separate byte stream for each channel in one dynamically allocated pool. The write engine converts those bytes into destination beats and strobes.

Space is reserved before reads are admitted, accounting for data that has not returned yet. Consequently, visible occupancy, reserved capacity and available bytes are different quantities. The default 1024-byte pool is not four permanently assigned 256-byte partitions.

Load-lock protects progress across related loads. Eligible stores, waits, barriers and termination release it; a false conditional store must behave as a NOP rather than releasing it. Programs still need a valid resource budget: loading indefinitely without consuming data can prevent progress. Protocol correctness alone does not establish program liveness.

The current write engine maintains committed write contexts. AW can advance ahead of W, while W bursts retain the required AXI4 ordering. Data admission prevents a selected ordinary burst from depending on future read payload. That reduces one source of blocking; it does not guarantee constant bandwidth under every workload or stalled slave.

## 7. Programmer's model

### 7.1 Channel working registers

| Register | Role |
|---|---|
| CPC | Current channel program counter; interpret with execution phase and fault precision. |
| SAR / DAR | Source and destination byte addresses. |
| CCR | Independent source/destination transfer shapes and attributes, plus endian transformation. |
| LC0 / LC1 | Two finite-loop counters. |
| CSR | Architectural channel state, security and wait information. |
| FTR | Channel fault-type bitmap. |
| FAR | First failing bus address recorded by this implementation; an extension. |

CCR is a per-channel register, not a global channel-enable register. Its key fields are:

| Field | Meaning |
|---|---|
| Source/destination increment | Fixed address or incrementing stream. |
| Source/destination burst size | Log2 of bytes per beat. |
| Source/destination burst length | Encoded beat count minus one. |
| PROT / CACHE attributes | Bus protection and memory/cache attributes. |
| Endian swap | Reverse bytes within groups of 2, 4, 8 or 16 bytes; zero disables swapping. |

The assembler can accept natural beat/iteration counts and encode the minus-one fields. A hand-written program must use the actual instruction encoding rules.

### 7.2 Register access and launch

APB is the CPU's control path. It programs control/debug registers and reads status; it does not carry copy payload. A transfer completes in its access phase when PSEL, PENABLE and PREADY are asserted at PCLK.

Useful register groups are summarized below. Offsets are relative to the appropriate APB register aperture; `n` is the channel number.

| Offset | Register/group | Purpose |
|---|---|---|
| 0x000 / 0x004 | DSR / DPC | Manager status and PC. |
| 0x020 | INTEN | Select event numbers routed to interrupts. |
| 0x024–0x02c | Raw/masked status, INTCLR | Observe flags and acknowledge interrupt-routed flags. |
| 0x030–0x038 | Fault summaries / FTRD | Diagnose manager and channel aborts. |
| 0x040 + 4n | FTRn | Channel fault type. |
| 0x100 / 0x104 + 8n | CSRn / CPCn | Channel status and PC respectively. |
| 0x400 + 0x20n | SARn, DARn, CCRn, LC0n, LC1n | Observe channel working context. |
| 0xd00–0xd0c | DBGSTATUS, DBGCMD, DBGINST0/1 | Submit a debug instruction. |
| 0xe00–0xe14 | Configuration registers | Discover the instantiated capabilities. |

Software normally initializes SAR/DAR/CCR using instructions in the channel program. The presence of readable working-register windows does not imply that arbitrary APB writes are the channel-programming mechanism.

To launch, software makes program/data visible, configures notification, polls DBGSTATUS, stages the encoded DMAGO in DBGINST0/1 and writes DBGCMD. Debug instruction acceptance, manager execution and the target channel's first payload access are distinct milestones.

## 8. Instruction families and program structure

| Family | Instructions | Function |
|---|---|---|
| Set up and calculate | DMAMOV, DMAADDH, DMAADNH | Configure context or adjust addresses. |
| Move payload | DMALD, DMAST, DMALDP, DMASTP | Issue memory-mapped reads/writes; P forms participate in peripheral acknowledgement. |
| Fill | DMASTZ | Issue zero stores without requiring loaded payload. |
| Repeat | DMALP, DMALPEND, DMALPFE | Finite loops and peripheral-controlled repetition. |
| Order data work | DMARMB, DMAWMB | Wait for the channel's read/write work respectively. |
| Coordinate peripherals | DMAWFP, DMAFLUSHP | Acquire request context or resynchronize peripheral request state. |
| Synchronize threads/software | DMAWFE, DMASEV | Wait for or generate an event/interrupt. |
| Lifecycle | DMAGO, DMAEND, DMAKILL | Launch, finish normally or cancel. |

DMAGO is a manager instruction. Channel transfer instructions are not interchangeable with manager control instructions.

The S/B forms are conditional on request context established by DMAWFP. A false condition causes no corresponding transfer. A matching S load/store moves one beat and ignores the CCR burst-length field; a matching B form uses the configured burst length. Decode alone is insufficient evidence that an instruction submitted work.

Loops compact repeated transfers. With a 32-byte pair, sixteen iterations move 512 bytes. Two counters plus address arithmetic can express rows and strides for a two-dimensional copy; no separate 2D descriptor engine is required. The program must still preserve matching source/destination byte accounting.

## 9. Worked example: a complete 32-byte memory copy

Assume aligned memory addresses, a 64-bit data bus, incrementing addresses, four beats on both sides and no endian swap. Program and data addresses below are illustrative, not DMA-330 fixed addresses.

```text
DMAMOV CCR, COPY_8_BYTES_PER_BEAT_4_BEATS
DMAMOV SAR, 0x10000000
DMAMOV DAR, 0x20000000
DMALD
DMAST
DMAWMB
DMASEV E0
DMAEND
```

This is readable assembly-style pseudocode, not a complete binary encoding or a universally accepted assembler syntax. `COPY_8_BYTES_PER_BEAT_4_BEATS` also needs valid protection/cache fields for the intended security context.

Follow the operation in this order:

1. **Prepare and launch.** The driver publishes the program and source data, sets E0's routing and launches a stopped channel.
2. **Fetch and initialize.** The channel obtains instruction bytes and executes the MOVs. Configuration changes can require implicit ordering even during setup.
3. **Submit the load.** DMALD is accepted by admission control. SAR can advance to `0x10000020` before all read data has returned.
4. **Receive bytes.** AR is accepted; four accepted R beats provide the 32-byte stream. RLAST retires the final beat of that burst.
5. **Submit and perform the store.** DMAST can be queued while read work is outstanding. DAR advances on descriptor acceptance. The write engine eventually issues AW/W using available stream bytes.
6. **Retire the write.** WLAST ends its data beats; the associated B response completes the write transaction.
7. **Notify in order.** DMAWMB prevents the program from passing the write barrier prematurely. DMASEV then signals E0 according to INTEN.
8. **Stop normally.** DMAEND enters Completing and reaches Stopped after the channel's data work is idle.

The instruction thread and bus engine are concurrent. These milestones are a causal explanation, not a requirement that every item occupy a separate cycle or that DMALD block until RLAST.

If E0 is interrupt-routed, software acknowledges it and establishes the CPU-side visibility/ownership needed before consuming the destination. A DMA-side barrier does not independently invalidate CPU caches or establish an arbitrary SoC's coherency policy.

### 9.1 Zero fill: a write operation without source data

DMASTZ is a distinct main function, not a normal DMAST after loading a zero buffer. For an aligned 32-byte fill, configure the destination for four eight-byte INCR beats and execute:

```text
DMAMOV CCR, ZERO_DESTINATION_4_BY_8_BYTES
DMAMOV DAR, destination
DMASTZ
DMAWMB
DMASEV E0
DMAEND
```

The symbolic CCR must have legal attributes for the selected thread; its destination fields define the operation. There is no required data DMALD, source-buffer allocation or source payload to consume. Instruction-fetch reads can still appear on AXI, so “zero fill” does not mean AR must remain inactive throughout the program.

AW describes the destination, W supplies zero on enabled byte lanes, and B retires the write transaction. WSTRB still determines which bytes change. A narrow zero store must not overwrite neighboring disabled lanes simply because zero appears in the entire printed WDATA word. The normal WMB/notification/END distinctions continue to apply. See [zero-fill operation](waveform/operations/07_zero.md) and TRM §4.3.18.

### 9.2 Two-dimensional copy: row length is different from stride

Consider three rows of 24 useful bytes each. Source rows begin 40 bytes apart and destination rows begin 32 bytes apart. With eight-byte beats, each row uses three beats. After an ordinary row transfer, the DMA has already advanced SAR/DAR by 24; software adds only the remaining gaps:

```text
source_gap = source_stride - row_bytes = 40 - 24 = 16
dest_gap   = dest_stride   - row_bytes = 32 - 24 = 8

DMAMOV CCR, INCREMENTING_3_BY_8_BYTE_READS_AND_WRITES
DMAMOV SAR, source_base
DMAMOV DAR, destination_base
DMALP LC0, 3
row:
    DMALD
    DMAST
    DMAADDH SAR, 16
    DMAADDH DAR, 8
DMALPEND LC0, row
DMAWMB
DMASEV E0
DMAEND
```

This is a worked program layout, not a newly recorded testcase. It moves 72 payload bytes, not 120 source bytes or 96 destination bytes. Source row starts are S, S+40 and S+80; destination starts are D, D+32 and D+64. Adding the complete stride after LD/ST would double-count the 24-byte advancement.

The example also adds a gap after the last row. Final SAR is S+120 and DAR is D+96, although the last payload ends earlier. Those final pointers are a consequence of this program, not an exact “last byte committed” report. If final pointers must identify the end of the last payload, structure the final-iteration adjustment accordingly.

A DMALP iteration operand of 3 encodes counter value 2. The illustrated loop body occupies eight instruction bytes, so its finite loop-end backward distance is eight. Positive row gaps preserve eight-byte alignment here. Negative strides require the DMAADNH representation and a checked address range; automatic decrement mode is not a CCR feature. See [loop/2D operation](waveform/operations/08_loops.md), §17.4 and TRM §§4.3.1–4.3.2.

### 9.3 Exact-length unaligned copy: balance the byte stream

The recorded unaligned example copies 19 bytes from 0x10000003 to 0x20000005 on a 64-bit bus. The source and destination cannot use an identical beat-count interpretation:

| Piece | Shape | Useful bytes |
|---|---|---:|
| First source load | Two eight-byte-sized INCR beats starting at source lane 3 | 5+8=13. |
| Source tail load | Six one-byte INCR beats starting at 0x10000010 | 6. |
| Destination store | Three eight-byte-sized INCR beats starting at destination lane 5 | 3+8+8=19. |

Initial destination shape must be established before accumulating data that it would later discard under a destination discontinuity. The source-size change for the tail applies its read-ordering rule while preserving the existing destination stream. The first destination strobe is 0xe0; the following two full beats use 0xff. Bytes outside those asserted lanes must remain unchanged.

Useful source data spans 0x10000003 through 0x10000015 inclusive. Destination data spans 0x20000005 through 0x20000017. The final incremented addresses are 0x10000016 and 0x20000018. This accounting explains why rounding 19 up to 24 and issuing three full aligned writes would be incorrect. See [the recorded 19-byte operation](waveform/operations/04_unaligned.md) and §19.4.

### 9.4 Packing, overlap and what a copy operation does not imply

Packing can turn sixteen byte-sized source beats into two eight-byte destination beats; unpacking can do the reverse. Total useful bytes and ordering must match even when beat counts differ. The MFIFO is the bridge between those shapes, not an automatic source of missing bytes. A transiently empty buffer while an admitted read is pending differs from a store whose preceding loads can never supply the requested data.

A generic memory-copy program is not automatically `memmove`. With overlapping ranges, an early destination write may overwrite bytes a later load has not captured. If overlap is required, prove the chosen direction, chunking, address sequence and resource budget, or use a safe staging strategy. DMA-330 supplies address arithmetic and programmable sequencing; it does not infer application-level overlap intent from SAR/DAR alone.

## 10. Architectural states and optimized instruction execution

### 10.1 What software sees

The Arm CSR state names and encodings are:

| CSR[3:0] | Architectural state | Interpretation |
|---|---|---|
| 0x0 | Stopped | No channel program is executing. |
| 0x1 | Executing | Instruction execution/front-end activity without a reported refill miss. |
| 0x2 | Cache miss | The thread is waiting on an actual instruction-cache refill. |
| 0x3 | Updating PC | Calculate/commit the next instruction address. |
| 0x4 | Waiting for event | Wait for the selected event. |
| 0x5 | At barrier | Wait for the required ordering condition. |
| 0x7 | Waiting for peripheral | Wait for a qualifying peripheral request. |
| 0x8 | Killing | Cancel and clean up the channel. |
| 0x9 | Completing | Finish normal outstanding data work. |
| 0xe | Faulting completing | Retire obligations after an abort. |
| 0xf | Faulting | Retain the fault pending recovery. |

Codes 0x6 and 0xa–0xd are reserved. **RUN is not an architectural state name.** The waveform guide uses EXEC as an abbreviation of Executing and COMP for Completing, with a separate numeric CSR row.

### 10.2 What the channel RTL does

Internal FSM values are a separate encoding. C_FETCH can report Executing or Cache miss; C_EXEC reports Executing; C_UPDATING_PC reports Updating PC. C_BARRIER and C_RECONFIG both report At barrier.

The optimized normal path is:

```text
                       complete instruction in valid local line buffer
                           +-----------------------------------+
                           |                                   v
... --> C_EXEC --> C_UPDATING_PC ----------------------------> C_EXEC --> ...
                           |
                           +--> C_FETCH --instruction ready--> C_EXEC
                                fetch work must wait
```

During UPC, `fetch_pc` presents the calculated target. If the front end can deliver the whole instruction from its valid local line buffer, with no suppression condition such as invalidation, the same edge registers the instruction, commits CPC and enters C_EXEC. Otherwise C_FETCH waits for delivery. Instruction side effects remain confined to execution; UPC does not issue the instruction twice.

This bypass changes internal latency, not the software state set. It does not remove architectural Updating PC. A trace must therefore distinguish internal state, CSR, registered CPC and the target supplied to fetch.

Waiting for an event, peripheral or barrier holds the instruction's context. Release enters UPC, then selects the appropriate instruction-delivery path. A channel in a wait state can still have previously submitted bus work retiring in parallel.

### 10.3 Every channel phase: entry, retained work and exit

The following table describes the current RTL's normal next-state conditions. Fault/debug-kill overrides can supersede them. Internal numeric values are shown to decode recorded traces; they are not additional software-visible state codes.

| Internal phase/value | How it is entered | What happens or remains held | Normal exit |
|---|---|---|---|
| C_STOPPED / 0 | Reset or completed END/KILL cleanup | No new instruction fetch; residual channel data is flushed. Working register values can remain visible. | Accepted GO loads PC/NS and selects C_FETCH. |
| C_FETCH / 1 | Initial launch or UPC without fast delivery | Obtain the complete instruction. PC is held; CSR is Executing or Cache miss according to real refill state. | insn_valid selects EXEC; fetch_err selects FAULT_COMPLETING. Otherwise remain here. |
| C_EXEC / 2 | Instruction delivery | Validate and apply the decoded instruction. A load/store can remain here with its request pending. | Instruction-specific: UPC, wait/barrier, RECONFIG, completion, kill or fault. |
| C_WFE / 3 | Valid DMAWFE | Hold the wait's PC and selected event; previously submitted data can continue. | wfe_hit selects UPC. |
| C_WFP / 4 | Valid DMAWFP | Hold peripheral/mode context; wait for peripheral control's grant. | wfp_gnt captures request flags and selects UPC. |
| C_BARRIER / 5 | RMB, WMB or FLUSHP | Hold PC and the selected ordering/flush mode. | Direction idle for RMB/WMB, or accepted flush request after dp_idle for FLUSHP, selects UPC. |
| C_COMPLETING / 6 | DMAEND | Stop issuing instructions; allow queued/in-flight channel data work to finish normally. | dp_idle selects STOPPED. |
| C_KILLING / 7 | Program DMAKILL or authorized debug kill | Cancel queued work and discard eligible payload while retaining committed bus obligations. | dp_idle clears FTR and selects STOPPED. |
| C_FAULT_COMPLETING / 8 | Accepted fetch/execute/data/debug/watchdog abort | Record diagnostics, stop normal execution and perform fault cleanup. | dp_idle selects FAULTING. |
| C_FAULTING / 9 | Fault cleanup completes | Retain diagnosis and remain halted. GO does not recover the context. | Debug kill selects KILLING. |
| C_UPDATING_PC / 10 | Ordinary instruction completion or wait release | Calculate target and commit PC at the edge; no second instruction effect. | Fast delivery selects EXEC, otherwise FETCH. |
| C_RECONFIG / 11 | A discontinuous MOV | Keep the old destination register/CCR value and MOV PC while required data work drains. | Commit MOV when its condition holds, then select UPC. |

Here `dp_idle = !rd_busy && !wr_busy` for that channel. It is not an explicit test for zero MFIFO payload, no shared-cache activity or no activity on any other channel. For example, Completing can reach Stopped with residual bytes that the subsequent cleanup path discards; it is not an instruction to write every remaining buffered byte.

A held phase is not automatically an error. FETCH can wait on code, EXEC on descriptor admission, WFP on the peripheral, BAR on retirement and KILLING on protocol obligations. Inspect the corresponding exit condition before describing the interval as a hang.

### 10.4 Four state flows to recognize

```text
Ordinary buffered instruction:
  EXEC --effect/acceptance--> UPC --fast instruction available--> EXEC

Instruction requiring front-end work:
  EXEC --> UPC --> FETCH --instruction delivered--> EXEC
                  CSR can be Executing, Cache miss, then Executing

An ordered completion sequence:
  EXEC(WMB) --> BARRIER --writes retired--> UPC --> EXEC(SEV)
       --> UPC --> EXEC(END) --> COMPLETING --dp_idle--> STOPPED

Abort and external recovery:
  eligible active phase --> FAULT_COMPLETING --dp_idle--> FAULTING
       --debug KILL--> KILLING --dp_idle--> STOPPED --new GO--> FETCH
```

These are conceptual sequences; UPC can use FETCH between the listed instructions if delivery is not ready. A wait that is already satisfied can still have a visible wait/transition phase. Do not collapse the sequence into “one instruction equals one clock” or assign a fixed duration to Completing.

Descriptor acceptance is the important branch inside EXEC: a true load condition with ld_ready=0 remains EXEC, while ld_ready=1 admits the descriptor and permits address/context progress. The matching distinction applies to stores. SAR/DAR advancement and PC-update scheduling therefore identify issued work, not completed bytes. A false conditional transfer goes through UPC without the corresponding descriptor.

For precise execute-time faults, the invalid instruction does not perform its normal effect. A late data fault has a different relationship to the current PC. Debug kill has final next-state priority for an eligible nonstopped channel, but a next-state override is not an undo mechanism for earlier external handshakes.

### 10.5 Manager phases and their separate flow

| Manager phase | Software state | Purpose and normal progression |
|---|---|---|
| M_BOOT | Stopped during initialization | Capture boot context once, then select FETCH or STOPPED. |
| M_STOPPED | Stopped | Await an accepted manager-directed debug instruction. |
| M_FETCH | Executing or Cache miss | Fetch the manager program; an available debug request can preempt this service point. |
| M_EXEC | Executing | Execute validated GO/SEV/NOP or a manager lifecycle/wait instruction. |
| M_UPDATING_PC | Updating PC | Advance the memory-program PC, then return to FETCH. |
| M_WFE | Waiting for event | Hold the manager's event dependency; release to UPC or service permitted debug work with return context. |
| M_FAULTING | Faulting | Retain FTRD and await debug kill for recovery. |

A memory-program GO follows FETCH → EXEC → UPC → FETCH. An injected debug GO enters manager execution using the latched debug bytes and then returns to the saved Stopped/FETCH/WFE context without adding six to DPC. Channel execution starts independently at the accepted GO edge. The channel local-buffer bypass is not automatically a manager bypass; the present manager leaves its fetch unit's fast-hit output unused.

This is why a diagram that uses one generic “thread FSM” for both contexts would hide important behavior. Section 23 follows the complete manager-to-channel launch and synchronization flow.

## 11. Peripheral requests, events and completion ordering

### 11.1 Peripheral pacing

The DMA-330 **DR/DA interface carries requests and acknowledgements, not payload**. Payload still moves over AXI to or from a memory-mapped peripheral address.

DR travels from the peripheral to the DMA, carrying single/burst request type and a last-request indication. DA travels back, carrying completion or flush messages. Both directions use VALID/READY handshakes. DMAWFP selects the peripheral interface and establishes request context before the program performs its transfer.

For memory-to-peripheral work, a typical flow is WFP, LD from memory, STP to the fixed FIFO address. Peripheral-to-memory uses LDP from the fixed FIFO address followed by ST to memory. P-form acknowledgements are associated with read completion or write-response retirement; observing a grant does not mean the peripheral has already received its completion acknowledgement.

S/B/P selection has precise semantics. WFP single can continue on a burst request while leaving that request pending; WFP burst discards single requests and waits for a burst; WFP periph copies the request's type/last information. These are not three equivalent ways to wait for “any request.” DMAFLUSHP resynchronizes request state through the flush exchange; it does not flush CPU caches.

### 11.2 Events and interrupts

DMASEV sets a sticky flag. With INTEN clear, that number is used as an event and DMAWFE can consume it. With INTEN set, it produces an interrupt and software clears the flag through INTCLR. In this implementation an interrupt-routed flag does not satisfy DMAWFE.

A sticky event can already be present before the wait starts. Conversely, an event is not a general counting semaphore for an unlimited number of queued notifications. Software and programs must assign event numbers and ownership deliberately.

DMASEV alone does not wait for earlier writes. Use a write barrier before a notification that promises DMA-side write completion. DMAEND, DMASEV and CPU-visible buffer readiness are three separate parts of the completion protocol.

### 11.3 Peripheral protocol fields and a complete flush exchange

The two-bit type has direction-dependent meaning. Interpret it together with the accepted handshake, not as a continuously meaningful status bus:

| Type value | DR: peripheral to DMAC | DA: DMAC to peripheral |
|---|---|---|
| 00 | Single request | Single-transfer acknowledgement. |
| 01 | Burst request | Burst-transfer acknowledgement. |
| 10 | Flush acknowledgement | Flush request. |
| 11 | Reserved | Reserved. |

DRLAST accompanies the accepted DR request and marks the final request in a peripheral-controlled series. It is not RLAST or WLAST and does not itself mean that the last AXI payload has retired. Request context must remain stable while DRVALID is high and DRREADY is low; DA type must likewise remain stable under DA back-pressure. See TRM §2.6.2 and Table 2-2.

A peripheral flush has several stages:

1. The channel reaches DMAFLUSHP and orders its earlier reads/writes, including relevant internal acknowledgement retirement.
2. With the drain condition satisfied, it presents the flush request to peripheral control. Queue acceptance can let the instruction progress before the external exchange finishes.
3. Peripheral control clears old pending request context, queues DA type 10 and enters its flushing state.
4. The peripheral accepts that DA message. It supplies a DR type 10 acknowledgement according to its protocol.
5. Peripheral control accepts the flush acknowledgement, leaves flushing and resumes normal request collection. Ordinary request types encountered while flushing are discarded by this implementation.

Thus channel BAR release, DA flush acceptance and DR flush acknowledgement are three observations, not one edge. Software must not assume that an IRQ or completion of DMAFLUSHP's internal queue handshake means the external peripheral has already re-advertised its next valid request.

The current wrapper has one pending-request latch per interface; a pending normal request can lower DRREADY. Arm's macro allows configuration of request-acceptance capability, so the number of interfaces and requests buffered per interface are separate dimensions. A deeper queue cannot be inferred merely from CR0 reporting several peripheral ports.

Peripheral numbers are selected by WFP/LDP/STP/FLUSHP operands rather than permanently wired to a single channel number. If several channels wait on the same peripheral, software must define ownership. This RTL selects the first matching waiting channel in its channel-index loop; it does not promise round-robin fairness for that particular contest. Reusing one peripheral across channels without an ownership protocol can associate a request with an unintended transfer program.

### 11.4 One event, multiple waiters and repeated notifications

TRM §2.7.1 distinguishes two situations. If several contexts are already waiting on the same event, one SEV can release those waiting contexts together. If an event was set earlier, a later WFE can consume the pending flag; another context arriving after consumption must await a new event. A sticky flag is not a permanent broadcast history.

For example, C0 and C1 already waiting on E5 can both be released by one SEV E5. In contrast, if SEV E5 occurs before either wait, C0 may arrive first and consume it; C1's later WFE is not guaranteed to find it still pending. Do not use the latter ordering as an implicit two-consumer barrier.

For interrupt-routed resources, IRQ is level-sensitive while the flag remains set. Writing INTCLR acknowledges that flag; it does not count completed buffers, advance a channel program or resume WFE. Multiple SEVs before acknowledgement can merge into one asserted level. A ring-buffer design therefore needs a separate generation/count/ownership protocol.

## 12. Alignment, boundaries and changing formats

Three boundary problems should be considered independently:

| Boundary | Mechanism | Programming consequence |
|---|---|---|
| Byte-lane alignment | Extract valid input lanes and generate output strobes | Account for useful bytes and any tail. |
| AXI 4 KB boundary | Split a crossing incrementing transfer into legal bursts | One instruction need not correspond to one AR/AW transaction. |
| Instruction-cache line | Assemble instruction bytes across lines | FETCH may be needed even when a previous instruction used the fast path. |

Endian swapping reverses byte order **within the configured group**, not automatically across the whole job. A 16-byte group can span narrower beats; the current implementation buffers 128-bit groups even on a 64-bit bus. Group alignment and complete-group requirements still apply.

Changing transfer context midstream can be a **discontinuity** under TRM §2.11.3. The current RTL uses C_RECONFIG to defer the MOV until the required work drains. Source discontinuities require read ordering; destination discontinuities require read/write ordering and can discard residual destination-formatted bytes.

Changing burst length alone, or an incrementing destination's beat size, does not imply the same discard behavior. Configure ordinary transfers before loading data; consult the field-specific rules before intentionally modifying a stream with residual bytes. Residual MFIFO data is not automatically reusable at an arbitrarily retargeted destination.

## 13. Faults, cancellation and recovery

Errors can arise from invalid instructions/operands, prohibited security attributes, bus responses, impossible store-data requirements or lack of progress. A verification test can intentionally provoke an abort and still pass by checking that abort correctly.

A **precise** abort identifies the offending instruction in the relevant PC. An **imprecise** data-bus error can arrive after the program has advanced. Do not assume the current CPC points to the load/store that caused a late error; use FTR, the implementation's FAR and the transaction context.

```text
normal END:     Executing --> Completing ---------> Stopped
fault:         active -----> Faulting completing --> Faulting
recovery:      Faulting ---> Killing -------------> Stopped
cancel:        active -----> Killing -------------> Stopped
```

Normal completion allows queued data work to finish. Abort/kill cancel work that can still be canceled while preserving protocol obligations for committed transactions. An accepted write context may need its payload even when queued behind another channel. Neither kill nor reset should be interpreted as restoring destination bytes already written.

A practical recovery sequence is to capture status/PC/fault/address context, request debug DMAKILL, wait for Stopped, repair the cause, prepare memory visibility and relaunch an initialized program. Capture diagnosis before lifecycle actions clear it.

The programmable watchdog is a workspace extension. Its timeout counts ticks of 256 core clocks; it is not a raw one-clock-per-count timer. Legitimate event/peripheral waits with no pending data work are treated differently from a channel with outstanding work. A watchdog report cannot force an external slave to return a missing response, so cleanup latency is not universally bounded.

### 13.1 Cancel, restart, reset and pause are different operations

DMAKILL is cancellation with cleanup, not an architectural pause/save command. Stopped SAR/DAR/CPC values alone do not form a resumable checkpoint: address registers can advance on descriptor acceptance, some writes can already be committed, and pending or residual data can be discarded. Retrying from the visible CPC after an imprecise error can repeat or omit payload.

For a planned pause, a program can wait at an intentionally chosen event or peripheral boundary. Its retained context and outstanding work still need analysis. A WFE does not automatically drain writes; place the required barrier before the wait if the paused state is intended to promise data completion. This is a program-level protocol rather than a generic stop/resume register.

For restart after kill/fault, establish a stopped context, determine which application data may have changed, reinitialize the required program registers and publish a valid new program. A successfully drained kill does not mean a partially written destination is pristine. MMIO/FIFO side effects make blind replay particularly dangerous: a second read or write can consume or transmit another item.

Reset abandons controller state under the integration's reset contract. Coordinate the connected bus, CDC bridges, peripheral protocol and software ownership; do not assume resetting only one block safely erases obligations observed by another. For low power, use quiescence acceptance before gating the core clock rather than treating a kill request or one stopped channel as whole-core idle.

## 14. Security, coherency, clocks and power

**Security:** manager state, channel state, event/peripheral permissions and AXI attributes are related but distinct. A non-secure channel cannot request a secure access through CCR. This RTL checks prohibited CCR immediates at DMAMOV before committing the new value. Secure/non-secure APB views are filtered according to the relevant manager/channel permissions. Security tags and permission checks do not replace software ownership of buffers.

**Coherency and addressing:** the driver must give the DMA addresses valid in its bus-visible address space. A CPU virtual pointer is not automatically a DMA address. Platform-specific mapping, IOMMU policy if present, cache cleaning/invalidation and barriers must establish the required visibility. This DMA's instruction cache is separate from CPU data caches; publishing executable DMA code needs the corresponding system maintenance too.

**Clock domains:** the core and external AXI interface use aclk. Optional APB and peripheral bridges cross into their respective domains. The bridges preserve request/response association; crossing latency depends on clock phase and back-pressure. Sample APB on PCLK and peripheral handshakes on the appropriate peripheral clock rather than inferring physical acceptance from a core-grid waveform.

**Reset and sleep:** resets reinitialize controller context and require coordinated endpoint handling; they do not undo memory effects. Q-Channel is a workspace extension for requesting quiescence. The external clock controller must wait for sleep acceptance before gating the DUT clock and restore it for wakeup. One stopped channel does not establish whole-core quiescence: shared cache, other channels, debug and interface work also matter.

### 14.1 Updating executable DMA code safely

The instruction cache's invalidation protocol and the CPU's memory-publication protocol solve different problems. Cache maintenance inside the DMAC prevents stale local/shared instruction bytes from executing; CPU-side publication ensures that newly written program bytes are actually available at the DMA-visible memory address.

A straightforward reuse sequence is: wait for the channel to be Stopped, modify/publish its program, then issue a new valid GO. Accepted launch invalidates that target thread's executable context in this RTL. It does not initialize SAR/DAR/CCR for the new program, so the replacement program still needs its own setup.

A coordinated running-program update can instead use DMAWFE with its invalidation option at an agreed boundary. Establish the owned event/wait protocol, publish the replacement bytes that will execute after wakeup, then signal the event through an authorized producer. Invalidation is requested when the WFE executes; event arrival and code publication must not be allowed to race arbitrarily. Do not overwrite arbitrary currently executing instructions and assume the invalidation option will repair the sequence.

Late cache refills must drain without delivering stale instructions into a killed/invalidated context. This behavior is cancellation/retry, not a successful instruction fetch and not necessarily an instruction-fetch bus error. Thread-tagged maintenance also matters when several contexts execute memory at the same address: updating common program storage does not make maintenance for one thread automatically invalidate all other thread tags.

See the [cache cancellation example](waveform/operations/14_cache.md), TRM §4.3.19 and the actual fetch/cache lifecycle. Program visibility, thread maintenance and permission checks all need to agree before treating an update as safe.

### 14.2 Sleep request, denial and wakeup

For this workspace's Q-Channel extension, an external controller lowers QREQn to request quiescence. The DMAC synchronizes that request. If idle conditions are met, it asserts acceptance by lowering QACCEPTn; if active work prevents acceptance, it asserts QDENY instead. QACTIVE indicates activity/wakeup demand, not a channel completion event.

The current core requires threads to be Stopped or Faulting and requires no data-path busy state, cache activity, pending peripheral acknowledgement, debug command or APB access. A thread simply waiting in WFE/WFP is not treated as an automatically sleep-accepted core in this implementation.

The denied state remains denied until the requester raises QREQn. Becoming idle later while QREQn stays low does not automatically turn that denied request into an acceptance; the requester must complete the denial handshake and try again. Keep the clock running during denial.

Only gate the DUT clock after acceptance. If an APB request or another wake condition arises while gated, the external clock controller must restore the clock so that synchronized request processing and the wake handshake can progress. At the top level, APB PSEL contributes to QACTIVE even before the sleeping core can service the register access. Retained controller state across a clock gate is different from reset or power removal; no retention/isolation contract for an arbitrary power domain follows from this waveform alone. See [low-power operation](waveform/operations/20_lowpower.md).

## 15. Performance and diagnostic interpretation

DMA throughput is limited by the slowest relevant resource: instruction delivery, descriptor admission, MFIFO budget, bus back-pressure, outstanding capacity, endpoint pacing or memory-system service. The UPC-to-EXEC optimization removes avoidable front-end waiting for eligible instructions; it cannot remove mandatory barriers, refill latency or bus stalls.

For illustration, an eight-byte data bus transferring a full useful beat every cycle at 200 MHz carries 1.6 GB/s in that direction. This is arithmetic, not a rated frequency or a measured job result. A memory copy also generates read and write traffic, plus instruction/control overhead; sustainable performance depends on the interconnect and memory controller serving that combination.

Use observed signals to localize a delay:

| Observation | First questions |
|---|---|
| Cache miss persists | Is this thread's refill waiting on AR acceptance or R completion? |
| EXEC/CPC remain held | Is descriptor admission blocked by queue capacity, MFIFO reservation or another owner? |
| WFP persists | Was DR accepted? Is the request type appropriate? Has the core-side grant occurred? |
| Barrier/Completing persists | Which read, write or acknowledgement retirement remains outstanding? |
| WLAST occurred but notification has not | Has B retired? Has the program passed WMB and executed SEV? |
| Fault remains after work drains | Has software captured diagnostics and requested debug kill? |

State alone is rarely a complete diagnosis. Correlate it with the instruction, accepted transactions, queue/buffer context and the correct sampling clock.

## 16. Mapping this explanation to the repository

| Concept | Main implementation source |
|---|---|
| System interfaces and optional CDC | `rtl/top/axi_dma330.sv`, `rtl/cdc/` |
| Register/debug interface | `rtl/core/dma_regs.sv` |
| Manager/channel execution | `rtl/core/dma_manager.sv`, `rtl/core/dma_channel.sv` |
| ISA, CCR and status encodings | `rtl/core/dma330_pkg.sv` |
| Instruction delivery/cache | `rtl/core/dma_fetch_unit.sv`, `rtl/core/dma_icache.sv` |
| Queuing, admission and payload movement | `rtl/core/dma_datapath.sv`, `dma_rd_engine.sv`, `dma_mfifo.sv`, `dma_wr_engine.sv` |
| Peripheral/events | `rtl/core/dma_periph_ctrl.sv`, `rtl/core/dma_event_irq.sv` |
| Diagnostics/power extensions | `rtl/core/dma_watchdog.sv`, `rtl/core/dma_qchannel.sv` |

After this overview, read the waveform material in the same causal order: [launch](waveform/operations/01_launch.md), [copy and completion](waveform/operations/02_copy.md), [thread phases](waveform/operations/21_thread_phases.md), then the topic relevant to your task. The [operation index](waveform/operations/README.md) groups all 24 walkthroughs; each has one or two selected pictures and paired editable WaveJSON.

For deeper reference:

| Reference | Use it for |
|---|---|
| Arm DDI 0424D, Chapter 2 | Architecture, operating states, peripheral protocol, aborts and transfer restrictions. |
| Arm DDI 0424D, Chapter 3 | Register definitions, permissions and state encodings. |
| Arm DDI 0424D, Chapter 4 | Exact instruction encodings and execution semantics. |
| Arm DDI 0424D, Appendix B | MFIFO/resource examples; distinguish Arm organization from this implementation's byte-stream allocation. |
| [DESIGN_SPEC.md](DESIGN_SPEC.md) | Detailed workspace specification and integration differences. |
| [Waveform conventions](waveform/operations/00_conventions.md) | Sampling rules, architectural versus internal labels, colors and data decoding. |
| [Verification plan](VERIFICATION_PLAN.md) | Verification responsibilities and evidence boundaries. |

The local architectural source is `references/DDI0424D_dma330_r1p2_trm.pdf`. Section/page references mean the manual's printed numbering. On Confluence, preserve the heading hierarchy, tables and monospace diagrams; upload any linked waveform images as page attachments if repository-relative links are not available to the intended audience.

## 17. Microcode reference and binary encodings

This section interprets DDI 0424D Chapter 4. It separates the bytes executed by the controller from assembler notation. The worked byte streams are derived from the documented fields and checked against this workspace's assembler/decoder; they are not executable CPU machine code.

### 17.1 Instruction storage and operand conventions

An instruction begins with an eight-bit opcode. Additional bytes contain a register selector, event/peripheral identifier, loop distance or immediate. The maximum instruction length is six bytes. Instructions are byte-addressed; PC advances by the decoded instruction length, not by four bytes or the AXI bus width.

In the notation below, `b0` is the byte at PC, `b1` the byte at PC+1, and so on. Multibyte immediates are least-significant-byte first:

```text
DMAMOV SAR, 0x12345678
Address:    PC   PC+1 PC+2 PC+3 PC+4 PC+5
Bytes:      BC   00   78   56   34   12
Meaning:    op   SAR  -------- imm32 --------
```

The instruction can cross a cache-line boundary. Its six-byte length does not require an eight-byte memory object or an aligned CPU-style instruction address. Legal memory accessibility and instruction publication are still required.

| Operand | Encoding convention | Meaning |
|---|---|---|
| `rd` | 0=SAR, 1=CCR, 2=DAR | DMAMOV destination; other selectors are invalid. |
| `p` / `e` | Five-bit number in b1[7:3] | Peripheral/event number, limited by the instantiated resources. |
| `ch` | Three-bit channel number in b1[2:0] | DMAGO target; unavailable channels are invalid operands. |
| `lc` | One bit | Select LC0 or LC1 for finite loops. |
| `count` | Iterations minus one in an eight-bit operand | Finite loop counts 1–256. |
| `jump` | Unsigned eight-bit backward byte distance | Relative to the address of the loop-end instruction. |

Reserved instruction bits must have their specified fixed values. An event value fitting five bits is not sufficient if the configured DMAC provides fewer events. See TRM §§4.1–4.3 and the operand checks in `dma_channel`/`dma_manager`.

### 17.2 Instruction encoding catalog

The following table covers all instruction families in TRM Table 4-1. `M` means manager; `C` means channel. Hexadecimal bytes are shown in memory order. The encoding of a valid operation is distinguished from whether its request condition is currently satisfied.

| Instruction | Bytes | Encoding | Thread | Essential effect / TRM section |
|---|---:|---|---|---|
| DMAADDH SAR/DAR, imm16 | 3 | b0=54/56; b1=imm[7:0]; b2=imm[15:8] | C | Add a zero-extended halfword; §4.3.1. |
| DMAADNH SAR/DAR, imm16 | 3 | b0=5C/5E; same immediate layout | C | Add `{0xffff, imm16}` modulo 2^32; §4.3.2. |
| DMAEND | 1 | 00 | M,C | Normal termination; channel waits for data work; §4.3.3. |
| DMAFLUSHP p | 2 | 35, `p << 3` | C | Order prior work and resynchronize peripheral request state; §4.3.4. |
| DMAGO ch, address | 6 | A0, ch, address[7:0], [15:8], [23:16], [31:24] | M | Launch a secure target subject to manager permissions; §4.3.5. |
| DMAGO ch, address, ns | 6 | A2 followed by the same operands | M | Launch a non-secure target; §4.3.5. |
| DMAKILL | 1 | 01 | M,C | Stop instruction execution and perform lifecycle cleanup; §4.3.6. |
| DMALD / DMALDS / DMALDB | 1 | 04 / 05 / 07 | C | Unconditional / single-conditioned / burst-conditioned read; §4.3.7. |
| DMALDPS / DMALDPB p | 2 | 25 / 27, `p << 3` | C | Conditional read and peripheral completion acknowledgement; §4.3.8. |
| DMALP LC0/LC1, N | 2 | 20 / 22, N−1 | C | Initialize the finite-loop counter; §4.3.9. |
| DMALPEND, finite | 2 | `0x38 \| (lc << 2) \| cond`, jump | C | Repeat or exit a finite loop; §4.3.10. |
| DMALPEND, forever form | 2 | 2C, jump for the standard unconditional form | C | Exit according to request_last rather than a finite count; §§4.3.10–4.3.11. |
| DMALPFE | 0 | Assembler marker; no separate instruction bytes | C | Mark the start of a peripheral-controlled loop; §4.3.11. |
| DMAMOV rd, imm32 | 6 | BC, rd, imm32 least-significant byte first | C | Update SAR, CCR or DAR, subject to checks/ordering; §4.3.12. |
| DMANOP | 1 | 18 | M,C | Advance without transfer effects; §4.3.13. |
| DMARMB | 1 | 12 | C | Wait for this channel's earlier reads; §4.3.14. |
| DMASEV e | 2 | 34, `e << 3` | M,C | Set an event/interrupt resource; §4.3.15. |
| DMAST / DMASTS / DMASTB | 1 | 08 / 09 / 0B | C | Unconditional / single-conditioned / burst-conditioned store; §4.3.16. |
| DMASTPS / DMASTPB p | 2 | 29 / 2B, `p << 3` | C | Conditional store and peripheral completion acknowledgement; §4.3.17. |
| DMASTZ | 1 | 0C | C | Generate zero payload using destination shape; §4.3.18. |
| DMAWFE e[, invalid] | 2 | 36, `(e << 3) \| (invalid << 1)` | M,C | Wait for event; optional thread instruction-cache invalidation; §4.3.19. |
| DMAWFP p, single/burst/periph | 2 | 30 / 32 / 31, `p << 3` | C | Select request handling and update request flags; §4.3.20. |
| DMAWMB | 1 | 13 | C | Wait for this channel's earlier writes; §4.3.21. |

In the finite-loop formula, `cond=0` is unconditional, `cond=1` is S and `cond=3` is B. DMALPEND's opcode bit 4 distinguishes finite (`nf=1`) from non-finite (`nf=0`) behavior; bit 2 selects the finite counter. The standard DMALPFE sequence uses `nf=0, lc=1, cond=0`, producing 0x2c at its loop end.

**Do not add S/B to a loop started with DMALPFE.** TRM §4.3.10 explicitly restricts this usage. The workspace helper can construct additional raw combinations; that does not make them recommended Arm assembler syntax. In particular, 0x29/0x2b are DMASTP encodings, not alternatives to use casually for a conditional forever-loop end.

### 17.3 Request conditions and acknowledgement timing

The flags `request_type` and `request_last` are channel context established by DMAWFP. They are not AXI signals and do not indicate a byte count already transferred.

| Form | Matching condition | Transfer shape if matched | If not matched |
|---|---|---|---|
| LD/ST without suffix | Always | CCR burst shape | Not applicable. |
| LDS/STS and LDPS/STPS | request_type=Single | One beat; ignore the corresponding CCR length field | Advance as a NOP; issue no transfer. |
| LDB/STB and LDPB/STPB | request_type=Burst | CCR burst shape | Advance as a NOP; issue no transfer. |
| Finite LPENDS/LPENDB | Corresponding request type | Repeat according to the selected finite counter | Exit that conditional loop end. |

P forms require a peripheral operand and generate an acknowledgement associated with the relevant transfer-completion path. A nonmatching P form does not generate the associated data transfer/acknowledgement. For LDP, acknowledgement is associated with completion of the read; for STP, with write-response retirement. Acceptance into peripheral control can precede the external DA handshake. In the current response paths, a peripheral acknowledgement is not a standalone certificate that the AXI response was OKAY; inspect fault/response information when diagnosing error scenarios.

WFP single, burst and periph have different request-consumption rules, described in section 11.1. In the current RTL, S/B selections set request_last=0; periph selection copies the incoming burst/last context. A false conditional store preserves load-lock. See TRM §§2.6.4–2.6.5 and the relevant instruction sections.

### 17.4 Finite loops: encode the count and branch independently

```text
Offset    Bytes    Assembly
0x00      20 03    DMALP LC0, 4
0x02      04      body: DMALD
0x03      08            DMAST
0x04      38 02         DMALPEND LC0, body
0x06      13            DMAWMB
0x07      00            DMAEND
```

The counter receives 3, so four body executions occur. The backward distance is `0x04 - 0x02 = 2`, measured from the loop-end opcode, not from its following instruction. At a taken finite loop end, the counter decreases and the target is selected; when no iterations remain, execution falls through.

For a 32-byte load/store pair this program moves 128 bytes. The compact program does not imply every iteration waits for its B response: queued work can overlap subject to admission and ordering. A jump must fit eight bits; large loop bodies need a different program layout. Two counters support nested finite loops, but software must avoid unintentionally overwriting an active counter.

DMAADDH adds an unsigned 16-bit displacement. DMAADNH adds `0xffff0000 | imm16`: `imm16=0xfff0` means −16, not +65520 and not general sign extension of an arbitrary signed halfword. Arithmetic wraps modulo 2^32. These distinctions matter in negative row strides.

### 17.5 Peripheral-controlled loop template

```text
; Configure memory source, fixed FIFO destination and compatible S/B shapes.
DMALPFE                     ; assembler marker, emits no opcode
    DMAWFP P0, periph
    DMALDS                  ; executes only for a single request
    DMASTPS P0
    DMALDB                  ; executes only for a burst request
    DMASTPB P0
DMALPEND                    ; encoded forever-form end, exits on request_last
DMAWMB
DMASEV E0
DMAEND
```

This is explanatory assembler syntax. The actual assembler must supply the backward distance and obey its label conventions. Only one S/B pair executes for a given request context. The last request still needs its data transfer; `request_last` controls whether the loop repeats after processing that request. Use DMAFLUSHP only where the peripheral synchronization protocol requires a flush, rather than treating it as an arbitrary end-of-job marker.

### 17.6 Complete byte stream for the aligned copy

For a secure channel using secure data attributes, choose CCR=0x000dc037: INCR source/destination, eight bytes per beat, four beats, zero cache/protection fields and no swap. The binary for section 9 is:

| Offset | Memory bytes | Meaning |
|---|---|---|
| 0x00 | BC 01 37 C0 0D 00 | DMAMOV CCR, 0x000dc037. |
| 0x06 | BC 00 00 00 00 10 | DMAMOV SAR, 0x10000000. |
| 0x0c | BC 02 00 00 00 20 | DMAMOV DAR, 0x20000000. |
| 0x12 | 04 | DMALD. |
| 0x13 | 08 | DMAST. |
| 0x14 | 13 | DMAWMB. |
| 0x15 | 34 00 | DMASEV E0. |
| 0x17 | 00 | DMAEND. |

The program is 24 bytes; the payload is 32 bytes. These are independent sizes. For an NS channel using NS data accesses, set both CCR protection bit 1 positions: `0x000dc037 | 0x00800200 = 0x008dc237`. Event/peripheral permissions must also be compatible with that NS program.

Writing instruction bytes into ordinary memory is insufficient if the DMA sees a stale cached copy. Publish the program with the platform's required memory/cache maintenance before launch. Updating a running program requires a defined synchronization and invalidation protocol.

### 17.7 How to read an instruction's execution contract

For every instruction, ask five separate questions: Is it valid for this thread? Are its operands/security legal? Is its request condition true? What resource/handshake allows progress? Which state and PC follow? The encoding catalog answers only part of that contract.

The explanations below refer to the current RTL phase names. Arm defines the instruction's architectural behavior; a different implementation can realize it with different internal phases. UPC normally follows a channel instruction that continues the program, selecting direct EXEC or FETCH as described in section 10.

### 17.8 Register setup and address calculation

**DMAMOV SAR/DAR/CCR:** first decode the destination and validate the immediate's applicable constraints. An NS CCR immediate requesting secure protection faults before committing the new CCR. For a continuous update, commit the working register and select UPC. For a defined discontinuity, enter RECONFIG, retain the MOV PC/old register value, drain the required direction(s), apply the required discard, commit the new value and then select UPC. MOV is not a payload load from memory; the immediate is part of its six instruction bytes.

**DMAADDH and DMAADNH:** calculate the selected address register's new value, then select UPC. The ADDH immediate is zero-extended; ADNH uses the negative-halfword representation described in section 17.4. Neither operation copies payload nor reports how far AXI has completed. This RTL's arithmetic path does not automatically enter the MOV-specific C_RECONFIG tests; program authors must preserve the relevant alignment, endian and ordering rules when arithmetic changes an address.

**DMANOP:** perform no payload/register-transfer operation and progress to the next instruction. It still occupies encoded program space and participates in instruction delivery/PC sequencing. Its existence does not make an otherwise illegal opcode a permitted NOP.

### 17.9 Data instructions: issue first, retire later

**DMALD:** if unconditional, or if its S/B condition matches, form a source descriptor from SAR/CCR. Admission must supply ld_ready, including queue/MFIFO/load-lock eligibility. Until then the thread remains EXEC and must not advance SAR/PC as though the load had been admitted. On acceptance, increment SAR by useful bytes when INCR is enabled and select UPC. The read engine later issues/retire AR/R work and delivers bytes to this channel's stream.

**DMALDP:** use the same conditional read mechanism with an explicit peripheral operand and acknowledgement context. The descriptor records that context so later peripheral completion is associated with the right request. Its acknowledgement is tied to read completion, not to the moment the opcode is decoded. An invalid peripheral or permission can fault before a descriptor is issued.

**DMAST:** form a destination descriptor from DAR/CCR and the channel's loaded stream. A false S/B condition skips the store without consuming data or releasing load-lock. For an executing store, st_ready admits it to the write side; DAR advances on acceptance when INCR is enabled. The write engine starts a legal piece only when its required bytes are available, then manages AW/W/B independently of instruction progress. Impossible data requirements are faults, not an instruction to wait forever for unspecified future loads.

**DMASTP:** adds peripheral acknowledgement context to the conditional store. The write's B-retirement path supplies completion into peripheral control; external DA acceptance can occur later. WFP permission, store admission, WLAST, B and DA must therefore be tracked as separate milestones.

**DMASTZ:** use destination configuration but synthesize zero payload. It does not require a preceding DMALD or consume ordinary loaded source bytes as if they were its zero source. It still needs write-side admission, legal addresses/attributes, valid strobes and normal response retirement. Refer to section 9.1 for a complete sequence.

For all these instructions, the single-beat S form overrides burst count, not byte-lane rules or the beat-size field. A condition-false instruction does not create an AXI transaction merely because its mnemonic appears in a waveform's opcode row.

### 17.10 Loops: deciding the next instruction address

**DMALP:** load LC0 or LC1 with the encoded N−1 count and progress through UPC. It does not itself transfer one row or one burst; its body supplies that work. Initializing a loop counter again inside an unintended nesting arrangement changes the program's behavior even if both instructions are individually legal.

**Finite DMALPEND:** evaluate the optional request condition. A false condition falls through. For a matching condition with the selected counter nonzero, decrement the counter and select the backward target; when the counter is zero, select the sequential instruction. The branch decision is made during execution and the target commits in UPC. Thus the final body iteration is not inferred solely from a counter display of zero.

**DMALPFE/forever-form end:** DMALPFE emits no opcode. The associated non-finite loop end uses request_last to decide whether to branch; it does not consume a finite loop count to determine the total job length. The final request still needs its matching S/B data operations before the loop exits. Follow the Arm restriction against adding S/B to the loop end of a DMALPFE-started loop.

The backward displacement is a byte distance, not an instruction count. A six-byte MOV in the body affects that distance differently from a one-byte LD. A decoded branch target inside an immediate field can turn valid original bytes into an undefined instruction stream.

### 17.11 Wait, barrier and synchronization instructions

**DMAWFP:** validate peripheral permissions, capture its identifier/mode and enter WFP. Wait for the peripheral controller's grant, then record the appropriate request flags and select UPC. It does not move payload by itself. A pending request can make the wait short; a wrong request type can be consumed/retained differently depending on the mode rather than being treated as a universal grant.

**DMAWFE:** validate the selected event, optionally request thread-local instruction invalidation and enter WFE. Keep the instruction PC while waiting. On a matching event-mode flag, select UPC; the event unit performs the consumption/broadcast behavior described in section 11.4. This is valid in manager/channel memory programs, but it is not part of the general real-time debug injection subset.

**DMASEV:** validate resource/security and set the selected event/interrupt flag during execution, then progress to the next instruction. SEV does not implicitly wait for previously submitted data. Use the appropriate producer barrier before SEV when the notification promises completed data. For an interrupt-routed resource, software acknowledgement is through INTCLR, not WFE.

**DMARMB:** enter BARRIER and wait until the channel's prior reads have retired. Then select UPC. It does not require every write or another channel's traffic to be idle.

**DMAWMB:** enter BARRIER and wait until the channel's prior writes have retired. Then select UPC. WLAST alone does not meet that requirement while B/retirement work remains. It is not a CPU cache-maintenance instruction.

**DMAFLUSHP:** enter the flush form of BARRIER, drain both read and write work, then submit the flush through flush_valid/flush_ready. Acceptance clears the channel's request flags and permits UPC. Peripheral control continues the external DA/DR flush exchange separately. The channel finishing this instruction does not turn the pending external handshake into an already completed response. Section 11.3 gives the complete exchange.

### 17.12 Launch and termination instructions

**DMAGO:** the manager validates channel number and launch security, then presents GO/PC/NS to the target. A stopped target starts fetching its own program; an already-active target is not restarted. The manager's instruction can finish while the target still waits for code. There is no matching channel-instruction version that starts another channel by executing GO in its data program.

**DMAEND in a channel:** enter COMPLETING without ordinary fault/kill cancellation, let channel data work retire, perform the thread's lifecycle maintenance and reach Stopped. END does not generate a completion event by itself and does not mean all MFIFO residual bytes will be written somewhere. **DMAEND in the manager** stops the manager program without waiting for all channels it launched.

**DMAKILL in a channel or through channel-directed debug:** enter KILLING, cancel what remains cancelable, preserve committed external obligations and wait for dp_idle before Stopped. **Manager DMAKILL** stops/recovers that manager context; it is not a broadcast kill. Neither form is a lossless save/resume or rollback operation. Section 13.1 distinguishes planned waits, cancellation and restart policy.

Taken together, these contracts explain why “the instruction finished,” “the channel stopped” and “the destination is available to software” are different statements. A complete flow identifies the operation and the observation that establishes each one.

## 18. Register map, access and bit fields

### 18.1 Access conventions and security filtering

All offsets below are byte offsets in the 4 KB APB aperture. Registers are 32-bit accesses. `n` selects an implemented channel, `e` an implemented event and `p` an implemented peripheral. RO means read-only, RW means read/write, WO means write-only and W1C means writing one clears the selected status bit. WO does not imply a portable readable shadow.

For fields marked reserved or read-UNDEFINED by Arm, do not infer a capability from the value returned by this RTL. Write reserved instruction/register bits as specified, normally zero. The workspace often returns zero for undefined/unimplemented fields; that is an implementation choice.

The two APB interfaces have distinct visibility rules. The secure interface can access implemented resources. On the non-secure interface:

| Register group | Visibility gate | Meaning |
|---|---|---|
| Manager, interrupt/control and fault summary/type registers | DSR.DNS | Manager security controls visibility; FTRn belongs to this group even though it describes a channel. |
| CSRn/CPCn and SARn/DARn/CCRn/LC0n/LC1n | CSRn.CNS | Each channel's security controls that channel's readable context. |
| Debug/configuration/WD | DSR.DNS | A non-secure caller cannot use a secure manager's debug interface. |
| Identification | Available on either interface | Identification is not a permission grant. |
| FARn / WDSTAT extensions | Workspace-specific filtering | Consult `dma_regs`; do not assume an architectural Arm rule for added registers. |

Hidden registers read as zero and unauthorized writes have no effect in this integration. CR3/CR4 govern thread access to event/peripheral resources; they are not substitutes for the DNS/CNS register-visibility gates. See TRM Tables 3-1 through 3-6 and the current `dma_regs` implementation.

### 18.2 Complete functional register inventory

The reset column describes current RTL reset behavior or its configuration source. It is not a promise that every architecturally undefined Arm field reads the same way.

| Offset | Register | Access | Current reset/source | Reference |
|---|---|---|---|---|
| 0x000 | DSR | RO | Manager starts stopped/secure before boot behavior | §3.3.1, Table 3-7. |
| 0x004 | DPC | RO | 0; boot/debug execution subsequently determines PC | §3.3.2, Table 3-8. |
| 0x020 | INTEN | RW | 0 | §3.3.3, Table 3-9. |
| 0x024 | INT_EVENT_RIS | RO | 0 | §3.3.4, Table 3-10. |
| 0x028 | INTMIS | RO | 0 | §3.3.5, Table 3-11. |
| 0x02c | INTCLR | WO, write-one action | No stored software value | §3.3.6, Table 3-12. |
| 0x030 | FSRD | RO | 0 | §3.3.7, Table 3-13. |
| 0x034 | FSRC | RO | 0 | §3.3.8, Table 3-14. |
| 0x038 | FTRD | RO | 0 | §3.3.9, Table 3-15. |
| 0x040 + 4n | FTRn | RO | 0 | §3.3.10, Table 3-16. |
| 0x060 + 4n | FARn | RO | 0; first-error address bookkeeping | Workspace extension in architecturally reserved space. |
| 0x100 + 8n | CSRn | RO | Stopped, CNS=0 | §3.3.11, Table 3-17. |
| 0x104 + 8n | CPCn | RO | 0 | §3.3.12, Table 3-18. |
| 0x400 + 0x20n | SARn | RO | 0 | §3.3.13, Table 3-19. |
| 0x404 + 0x20n | DARn | RO | 0 | §3.3.14, Table 3-20. |
| 0x408 + 0x20n | CCRn | RO | 0x00800200 | §3.3.15, Table 3-21. |
| 0x40c + 0x20n | LC0n | RO | 0 | §3.3.16, Table 3-23. |
| 0x410 + 0x20n | LC1n | RO | 0 | §3.3.17, Table 3-24. |
| 0xd00 | DBGSTATUS | RO | Busy=0 | §3.3.18, Table 3-25. |
| 0xd04 | DBGCMD | WO | Command action, not a configuration shadow | §3.3.19, Table 3-26. |
| 0xd08 | DBGINST0 | WO | Local staging reset to 0 | §3.3.20, Table 3-27. |
| 0xd0c | DBGINST1 | WO | Local staging reset to 0 | §3.3.21, Table 3-28. |
| 0xe00 | CR0 | RO | Parameters and boot tie-offs | §3.3.22, Table 3-29. |
| 0xe04 | CR1 | RO | Instruction-cache parameters | §3.3.23, Table 3-30. |
| 0xe08 | CR2 | RO | Boot address | §3.3.24, Table 3-31. |
| 0xe0c | CR3 | RO | Captured event-security tie-offs | §3.3.25, Table 3-32. |
| 0xe10 | CR4 | RO | Captured peripheral-security tie-offs | §3.3.26, Table 3-33. |
| 0xe14 | CRD | RO | Datapath configuration parameters | §3.3.27, Table 3-34. |
| 0xe80 | WD | RW | 0 in this RTL | §3.3.28, Table 3-35; upper timeout field is extended. |
| 0xe84 | WDSTAT | W1C | 0 | Workspace extension. |
| 0xfe0/0xfe4/0xfe8/0xfec | periph_id_0/1/2/3 | RO | Parameterized peripheral ID | §3.3.29, Tables 3-36 through 3-40. |
| 0xff0/0xff4/0xff8/0xffc | pcell_id_0/1/2/3 | RO | Component ID | §3.3.30, Table 3-41. |

Unlisted locations are not additional general-purpose registers. With optional APB_SLVERR enabled, unmapped accesses and writes to RO registers can return PSLVERR. That option is an integration extension, distinct from architecturally hiding a register for security reasons.

### 18.3 DSR, DPC, CSRn and CPCn

| Register | Bits | Field | Interpretation |
|---|---|---|---|
| DSR | [9] | DNS | 0=secure manager; 1=non-secure manager. Established from manager boot security. |
| DSR | [8:4] | Wakeup_event | Event number while the manager waits in DMAWFE. |
| DSR | [3:0] | DMA status | Manager: Stopped=0, Executing=1, Cache miss=2, Updating PC=3, Waiting for event=4, Faulting=15. Other codes are reserved for the manager. |
| DPC | [31:0] | PC | Manager program address; interpret debug-origin execution separately. |
| CSRn | [21] | CNS | Channel NS state selected by DMAGO. |
| CSRn | [15] | dmawfp_periph | Indicates periph-mode DMAWFP context. |
| CSRn | [14] | dmawfp_b_ns | Burst versus single DMAWFP context when periph mode is not selected. |
| CSRn | [8:4] | Wakeup number | Event/peripheral number associated with the current wait. |
| CSRn | [3:0] | Channel status | Full channel state table in section 10.1. |
| CPCn | [31:0] | PC | Channel program counter; a precise abort identifies its offending instruction. |

DSR[31:10], CSRn[31:22], CSRn[20:16] and CSRn[13:9] are reserved/undefined fields. Wakeup and WFP context must be interpreted with the corresponding operating state; retained context does not imply that an old wait is still active.

A driver wanting only the state should mask `CSRn & 0xf`, not compare the entire register against a four-bit constant. For example, a non-secure channel can be Executing while bit 21 is set. Debug manager execution can temporarily operate without advancing the manager's memory-program PC; do not interpret DPC as a CPU-style retirement log.

### 18.4 Interrupt and fault-summary registers

| Register | Active field | Function |
|---|---|---|
| INTEN | One bit per implemented event | 0 routes the number as an event; 1 enables its interrupt output. |
| INT_EVENT_RIS | One flag per implemented event | Raw sticky event/interrupt state, irrespective of interrupt masking. |
| INTMIS | One bit per implemented event | The interrupt-visible state: raw flag AND INTEN. |
| INTCLR | One write-one bit per event | Acknowledge interrupt-routed flags; not a stored enable mask. |
| FSRD | [0] | Manager abort indication; other bits reserved. |
| FSRC | One bit per implemented channel | Identifies channels with an abort condition; inspect FTRn next. |

An INTEN write changes routing/enabling; it is not an interrupt acknowledgement. Writing zero to INTCLR does not clear a flag. In the current event unit, INTCLR acts on interrupt-routed bits and event-mode flags are consumed by WFE. A simultaneous set wins over clearing, so a new notification is not silently discarded by an acknowledgement on the same edge.

An ordinary event IRQ and irq_abort are different reporting paths. Clearing an event flag does not repair a channel fault, and stopping a faulted channel is not the same operation as clearing INTMIS.

### 18.5 Fault-type bit fields

TRM Tables 3-15 and 3-16 define the following cause fields. Set bits form a bitmap, not a single mutually exclusive enum. A debug-origin indicator describes context and is not itself the primary error cause.

| FTRD bit | Name | Manager meaning |
|---:|---|---|
| 0 | undef_instr | Instruction is undefined for manager execution. |
| 1 | operand_invalid | Operand is incompatible with the configuration. |
| 4 | dmago_err | An NS manager attempts to create a secure channel. |
| 5 | mgr_evnt_err | NS manager accesses a secure event/interrupt resource. |
| 16 | instr_fetch_err | Instruction fetch returned a non-OKAY response. |
| 30 | dbg_instr | Erroneous instruction came through the debug interface; apply the manual's validity conditions. |

| FTRn bit | Name | Channel meaning | Arm precision classification |
|---:|---|---|---|
| 0 | undef_instr | Undefined channel instruction. | Precise. |
| 1 | operand_invalid | Invalid/unavailable operand. | Precise. |
| 5 | ch_evnt_err | NS channel accesses a secure event/interrupt. | Precise. |
| 6 | ch_periph_err | NS channel accesses a secure peripheral request resource. | Precise. |
| 7 | ch_rdwr_err | NS programming requests secure data protection attributes. | Precise. |
| 12 | mfifo_err | Transfer has an impossible MFIFO resource requirement under the architectural resource rules. | Imprecise. |
| 13 | st_data_unavailable | Prior loads did not provide the data required by the store. | Precise. |
| 16 | instr_fetch_err | Instruction fetch returned non-OKAY. | Precise. |
| 17 | data_write_err | BRESP returned non-OKAY for data. | Imprecise. |
| 18 | data_read_err | RRESP returned non-OKAY for data. | Imprecise. |
| 30 | dbg_instr | Debug-origin information, valid with the relevant precise abort. | Context qualifier; not a standalone precision selector. |
| 31 | lockup_err | Resource-starvation lock-up. | Imprecise. |

All remaining FTRD/FTRn positions are reserved/undefined in this revision. EXOKAY, SLVERR and DECERR all count as error responses for these DMA accesses; the controller does not initiate an exclusive sequence that would make EXOKAY a normal successful exclusive result.

The workspace reuses `ch_rdwr_err` for certain unsupported/illegal transfer settings as well; consult the actual legality checks when diagnosing this RTL. Do not extrapolate such extended interpretations into a new Arm architectural cause definition. FARn is also an extension: it helps identify a failing address but does not make an imprecise abort precise.

**Source-consistency note:** DDI 0424D §2.8.2's general list describes insufficient prior loads among imprecise abort sources, while Table 3-16 explicitly marks `st_data_unavailable` as precise. This document follows the field-specific table for bit 13 and the current directed probe checks the offending store PC. The wording difference is retained here so the table is not mistaken for evidence that the supplied manual is internally uniform. Data-bus errors remain imprecise; the note does not change their interpretation.

### 18.6 SARn, DARn and loop counters

SARn and DARn use [31:0] as byte addresses. Their register windows are RO: DMAMOV and address-arithmetic instructions modify the execution context. Incrementing loads/stores can update the corresponding address when descriptors are admitted, before bus completion. FIXED mode retains the address for the transfer sequence.

LC0n/LC1n use [7:0] for finite-loop state; [31:8] is reserved/undefined. DMALP loads `N−1`. Consequently, a visible counter value is not a direct completed-iteration count, and zero can still correspond to the final body execution before loop exit. Starting a new program should initialize every loop/register resource it relies on rather than treating a prior stopped context as clean software state.

### 18.7 Debug instruction registers

| Register | Bits | Meaning |
|---|---|---|
| DBGSTATUS | [0] | Debug interface busy; wait until clear before staging another instruction. |
| DBGCMD | [1:0] | Write 00 to request execution; other command values are not the execute operation. |
| DBGINST0 | [31:24] | Instruction byte 1. |
| DBGINST0 | [23:16] | Instruction byte 0. |
| DBGINST0 | [10:8] | Target channel when the debug-thread selector is 1. |
| DBGINST0 | [0] | 0=manager instruction; 1=channel-directed debug instruction. |
| DBGINST1 | [7:0], [15:8], [23:16], [31:24] | Instruction bytes 2, 3, 4 and 5 respectively. |

Other bits are reserved and written as zero. The byte mapping follows Figure 3-22 and the RTL concatenation `{DBGINST1, DBGINST0[31:16]}`. This also resolves the duplicated byte number in the prose of Table 3-28: bits [15:8] carry byte 3, not a second copy of byte 4.

The current implementation uses one shared write-only staging bank for both APB views. Busy writes are ignored; readback must not be used to confirm instruction staging. A manager command is latched on DBGCMD so later register writes cannot corrupt the accepted instruction. Channel-directed debug dispatch supports the permitted debug operations, such as KILL/SEV; it is not arbitrary DMAST execution through a channel register window.

The debug-thread selector and the channel operand inside DMAGO are different selectors. DMAGO is executed by the manager even when its operand names channel 0; its DBGINST0 debug-thread bit must therefore be zero. Section 20 provides exact example words.

### 18.8 Configuration registers

Configuration registers describe the instantiated hardware/tie-offs. They are RO and are not a way to resize the hardware at runtime.

| Register | Bits | Field | Decode |
|---|---|---|---|
| CR0 | [21:17] | num_events | Value+1 event/interrupt outputs. |
| CR0 | [16:12] | num_periph_req | Value+1 interfaces; valid when periph_req is set. |
| CR0 | [6:4] | num_chnls | Value+1 channels; up to eight. |
| CR0 | [2] | mgr_ns_at_rst | Manager NS boot tie-off. |
| CR0 | [1] | boot_en | Boot-from-PC tie-off. |
| CR0 | [0] | periph_req | Peripheral request interface capability present. |
| CR1 | [7:4] | num_i-cache_lines | Value+1 instruction-cache lines. |
| CR1 | [2:0] | i-cache_len | 2/3/4/5 encode 4/8/16/32-byte lines; other values reserved. |
| CR2 | [31:0] | boot address | Configured manager boot start address. |
| CR3 | Bit e | INS | 0=secure event/interrupt; 1=non-secure. |
| CR4 | Bit p | PNS | 0=secure peripheral interface; 1=non-secure. |
| CRD | [29:20] | data_buffer_dep | Value+1 data-buffer lines. |
| CRD | [19:16] | rd_q_dep | Value+1 read-queue depth. |
| CRD | [14:12] | rd_cap | Value+1 read issuing capability. |
| CRD | [11:8] | wr_q_dep | Value+1 write-queue depth. |
| CRD | [6:4] | wr_cap | Value+1 write issuing capability. |
| CRD | [2:0] | data_width | 2=32-bit, 3=64-bit, 4=128-bit; other values reserved. |

CR0's other positions, CR1[3]/[31:8] and CRD[31:30]/[15]/[7]/[3] are reserved. Only implemented CR3/CR4 resource bits are meaningful. Their values come from boot security configuration rather than APB writes.

For the default profile, CR1=0x75 means eight 32-byte lines. CRD reports 128 buffer lines and a 64-bit bus; the implementation's buffer capacity is therefore `128 × 8 = 1024 bytes`. Do not interpret a line count as a byte count. The internal byte-stream allocation may use lines differently from Arm's destination-formatted resource examples in Appendix B.

### 18.9 WD, added diagnostics and identification

| Register/field | Standard or extension? | Function |
|---|---|---|
| WD[0], wd_irq_only | Arm-defined | 0 selects abort/report behavior for contributing lock-up channels; 1 selects IRQ-only reporting. Arm recommends changing WD while channels are stopped. |
| WD[31:16], timeout | Workspace extension; reserved by the base manual | No-progress threshold in ticks of 256 core clocks; zero disables this timer. |
| WD[15:1] | Reserved here | Write zero. |
| WDSTAT, bit n | Workspace extension | Sticky detected-channel indication; W1C, with a simultaneous detection set winning. |
| FARn[31:0] | Workspace extension | First failing bus address bookkeeping since the accepted launch. |

Architectural resource lock-up detection and the programmable elapsed-time watchdog are related diagnostics, not identical mechanisms. An indefinitely legitimate wait should not be treated as an arbitrary transfer timeout. IRQ-only reporting also does not mean all channel programs automatically return to Stopped.

The four peripheral-ID registers each expose one conceptual ID byte in [7:0]. The default RTL ID 0x00341330 yields 0x30, 0x13, 0x34 and 0x00 at 0xfe0, 0xfe4, 0xfe8 and 0xfec. In the conceptual Arm ID, [11:0] is part number, [19:12] designer, [23:20] revision and [24] integration-test configuration; upper bits are reserved.

Component-ID bytes at 0xff0, 0xff4, 0xff8 and 0xffc are 0x0d, 0xf0, 0x05 and 0xb1, combining as 0xb105f00d. Identification values describe the exposed identification profile; matching them is not proof of macro-level implementation equivalence.

## 19. CCR programming, byte accounting and discontinuities

### 19.1 Complete CCR bit layout

TRM §3.3.15 and Table 3-21 define the packed channel control word. The APB view is RO; DMAMOV CCR supplies a new immediate through the instruction stream.

| Bits | Field | Decode and effect |
|---|---|---|
| [31] | Reserved | Do not program as a feature. |
| [30:28] | endian_swap_size | 0=no reversal; 1/2/3/4 reverse 2/4/8/16-byte groups; 5–7 reserved. |
| [27:25] | dst_cache_ctrl | Drives AWCACHE[3], [1], [0] respectively; AWCACHE[2] is fixed low. |
| [24:22] | dst_prot_ctrl | Drives AWPROT[2:0]. |
| [21:18] | dst_burst_len | Store beats minus one, 0–15. |
| [17:15] | dst_burst_size | Log2 bytes per destination beat; 0–4 encode 1/2/4/8/16 bytes. |
| [14] | dst_inc | 0=FIXED, 1=INCR. |
| [13:11] | src_cache_ctrl | Drives ARCACHE[2:0]; ARCACHE[3] is fixed low. |
| [10:8] | src_prot_ctrl | Drives ARPROT[2:0]. |
| [7:4] | src_burst_len | Load beats minus one, 0–15. |
| [3:1] | src_burst_size | Log2 bytes per source beat; 0–4 encode 1/2/4/8/16 bytes. |
| [0] | src_inc | 0=FIXED, 1=INCR. |

The encoded size must be supported by the instantiated interface. A 64-bit data bus does not perform a 16-byte data beat merely because the generic CCR field has an encoding for it. Conversely, the **endian group** can be 16 bytes across several narrower beats in this RTL; group width and bus beat width are separate settings.

The reset value 0x00800200 has both protection fields requesting NS data accesses. It does not set CSR.CNS and does not configure an incrementing multibeat copy. Software must initialize the complete transfer shape it needs.

### 19.2 Protection and cache attributes

For the protection fields:

| AxPROT bit | Meaning | CCR source/destination position |
|---|---|---|
| [0] | 0=unprivileged, 1=privileged | CCR[8] / CCR[22]. |
| [1] | 0=secure, 1=non-secure | CCR[9] / CCR[23]. |
| [2] | 0=data, 1=instruction classification | CCR[10] / CCR[24]. |

A channel with CNS=1 cannot request secure data by clearing either protection bit 1. The current RTL checks that condition at DMAMOV CCR, producing the precise fault illustrated in section 21.6. Setting NS attributes on a secure channel does not change that channel's own security state or its event/peripheral permissions.

Cache attributes describe external transaction behavior, not the local instruction cache. Respect the legal AXI combinations: the manual specifically excludes ARCACHE[2:1]=10 and AWCACHE[3,1]=10. Do not assume all three-bit CCR cache values are equally valid.

The Arm assembler's `SC`/`DC` notation uses AXI attribute values rather than two identical packed three-bit fields. SC retains the permitted source bits; DC maps bit 3 and bits [1:0], with destination bit 2 fixed low. Passing an AXI four-bit cache value directly into a three-bit packed helper without conversion can change its meaning.

### 19.3 Human-readable assembler options versus encoded fields

TRM §4.4.5 provides a field-oriented assembler form for DMAMOV CCR. For example, its options describe source/destination burst counts, sizes, increment mode, protection/cache attributes and endian size. Distinguish those units from the packed register:

| Quantity | Assembler-facing example | Encoded CCR |
|---|---|---|
| Beat size | SS64 / DS64 means 64 **bits** | Size field=3, meaning 8 bytes. |
| Beat count | SB4 / DB4 means four beats | Length field=3. |
| Address mode | SAI/DAI or SAF/DAF | Increment bit=1 or 0. |
| Endian group | ES8 means no byte reversal; ES128 means a 128-bit group | Swap field=0 or 4. |

Those are Arm assembler conventions. The SystemVerilog helper in this repository instead accepts sizes as log2(bytes), counts as natural beat counts and packed three-bit attribute arguments. The source program, helper API and final byte stream should be reviewed together.

For an aligned copy with secure attributes and zero cache controls:

```text
CCR = (1 << 0)        source INCR
    | (3 << 1)        8 bytes/read beat
    | (3 << 4)        4 read beats
    | (1 << 14)       destination INCR
    | (3 << 15)       8 bytes/write beat
    | (3 << 18)       4 write beats
    = 0x000dc037
```

For NS data accesses, OR `(1<<9) | (1<<23)`, giving 0x008dc237. These examples deliberately leave privilege/instruction classification and cache controls at zero; a real platform must select attributes consistent with its memory map.

### 19.4 Useful bytes, tails and 4 KB splitting

For an INCR descriptor, with `S=2^size`, `N=len+1` and start address A, useful bytes are `N*S - (A mod S)`. Incremented SAR/DAR track this useful-byte count, not an unconditional `N*S` for every unaligned start. The S form first overrides N to one; it does not force S to one byte.

Examples:

| Shape | Useful bytes | Interpretation |
|---|---:|---|
| Aligned, size=3, len=3 | 32 | Four full eight-byte beats. |
| Offset 3 within an eight-byte beat, size=3, len=2 | 21 | Five bytes, then eight, then eight. |
| Same offset, S-form size=3 | 5 | One unaligned eight-byte-sized beat, not eight useful bytes or one byte. |
| Aligned byte-sized S form | 1 | One byte. |

Keep the logical load/store byte balance correct when packing or unpacking. A larger destination request cannot manufacture bytes that earlier loads will never supply. Conversely, destination discontinuity rules can discard residual bytes even when they were previously loaded successfully.

AXI4 transaction legality is enforced separately. An aligned 32-byte incrementing descriptor starting at 0x00000ff8 with eight-byte beats must split at 0x1000: one beat in the first burst and three in the second. The instruction describes one logical descriptor; AR/AW tracking and responses describe the split bus operations. Use aligned FIXED transfers when following the Arm programming contract.

### 19.5 Which changes require an implicit barrier?

The following summarizes the current TRM-oriented discontinuity implementation. See §2.11.3, `mov_src_disc`, `mov_dst_disc` and C_RECONFIG in `dma_channel`.

| Change | Required ordering in this RTL | Old residual destination data |
|---|---|---|
| SAR byte-lane alignment changes | Drain reads before committing MOV | Preserved. |
| Source increment or source burst size changes | Drain reads | Preserved. |
| DAR byte-lane alignment changes | Drain reads and writes | Discarded at the destination discontinuity. |
| Endian group or destination increment mode changes | Drain reads and writes | Discarded. |
| Destination burst size changes while FIXED | Drain reads and writes | Discarded. |
| Burst length alone changes | Does not independently trigger this discontinuity | Preserved. |
| Destination burst size changes while INCR | Does not independently trigger this destination discontinuity | Preserved. |
| Only upper address bits change, preserving byte-lane alignment | Does not independently trigger the alignment-discontinuity test | Do not infer an additional automatic dependency barrier. |

While waiting, the old register value remains in effect and CPC remains on the MOV. C_RECONFIG reports architectural At barrier. Once the required direction(s) are idle, the MOV commits and execution passes through UPC. Source-only and destination discontinuities are therefore not interchangeable operations.

Explicit barriers are still required for dependencies not covered by the implicit tests. If a consumer must see a write before another instruction or thread proceeds, choose the synchronization sequence that expresses that requirement; do not rely on incidental queue latency.

For swapping, the current legality checks additionally require DAR aligned to the group and a complete set of groups in an incrementing store's byte count. If the group spans destination beats, the destination must be INCR; a FIXED beat must itself accommodate whole groups. Buffering a 128-bit group on a 64-bit bus therefore does not make a 128-bit-group FIXED store legal on that bus. Invalid settings fault rather than requesting an unsupported AXI beat.

### 19.6 Endian conversion: the source rules still matter

Arm §2.11.2 requires **both SAR and DAR** to be aligned to the configured endian group before the relevant LD/ST operations. If a source uses FIXED addressing, its beat size must also accommodate the endian group; a FIXED destination has the corresponding destination restriction. Recheck those requirements after changing addresses or endian settings.

The earlier DAR/group checks describe the current store-side legality path. Passing those checks is not proof that every source-side Arm programming restriction was dynamically enforced by that same block. Software must satisfy the complete source and destination rules; a permissive simulation result is not permission to write a nonportable program.

Use byte order to verify the result. With input bytes in ascending address order:

```text
Input:          00 01 02 03  04 05 06 07
2-byte groups:  01 00 03 02  05 04 07 06
4-byte groups:  03 02 01 00  07 06 05 04
8-byte group:   07 06 05 04  03 02 01 00
```

The group changes byte positions, not the number of useful payload bytes. A 16-byte group can span two eight-byte bus beats or more narrower beats, but it remains one permutation group. A write strobe identifies valid lanes after positioning; zero in an inactive lane is not an extra payload byte. The [128-bit-group operation](waveform/operations/23_swap128.md) checks complete output bytes rather than judging correctness from one hexadecimal word in isolation.

## 20. Software sequences and worked register values

### 20.1 Discover, prepare, launch and complete

A driver can organize a transfer into four stages:

1. **Discover:** read configuration/IDs through an authorized APB view. Decode count-minus-one fields; allocate only implemented channel, event and peripheral numbers.
2. **Prepare:** obtain an idle/stopped channel, build valid microcode, choose compatible memory attributes, publish program/data and configure the intended event/interrupt route.
3. **Launch:** wait for DBGSTATUS bit 0 to clear, stage the complete debug instruction, then write DBGCMD=0. Do not overwrite a busy staging bank.
4. **Complete:** handle notification or poll the relevant state, check abort information, perform required CPU visibility maintenance and transfer buffer ownership back to software.

Use the platform's required MMIO access ordering. A compiler-visible source-code sequence alone does not define every interconnect/CPU ordering property. Clear stale notification state according to resource ownership before starting a new job; do not unintentionally consume another thread's event.

### 20.2 Exact debug words for DMAGO

To ask a secure manager to launch secure channel 0 at 0x00010000:

```text
Instruction bytes: A0 00 00 00 01 00
DBGINST0 = (byte1 << 24) | (byte0 << 16) | (channel_debug << 8) | thread
         = 0x00a00000                  ; thread=0: manager instruction
DBGINST1 = byte2 | byte3<<8 | byte4<<16 | byte5<<24
         = 0x00010000
DBGCMD   = 0x00000000                  ; execute after staging both words
```

The target channel number is the second instruction byte. `channel_debug` is irrelevant here because thread=0. For an NS target the opcode is A2, producing DBGINST0=0x00a20000; the channel program must use compatible NS protection fields and authorized event/peripheral resources.

DBGSTATUS becoming idle means the debug instruction has been serviced; it is not the DMA job-completion indication. The first instruction may still need a refill, and the first payload operation comes later.

### 20.3 Exact debug words for cancellation

To direct DMAKILL to channel 2:

```text
Instruction byte0 = 0x01
DBGINST0 = (0x01 << 16) | (2 << 8) | 1 = 0x00010201
DBGINST1 = 0
DBGCMD   = 0
```

This selects channel-directed debug, unlike manager DMAGO. Capture FTRn/CPCn/FARn before the kill/restart lifecycle clears context. Then wait for Stopped. Write contexts already committed to AXI can keep KILLING active while their obligations retire; the command is not rollback.

### 20.4 Decode a status value instead of guessing

For a hypothetical CSR value 0x00200004:

```text
state  = CSR & 0xf          = 4       Waiting for event
number = (CSR >> 4) & 0x1f = 0       Event 0
CNS    = (CSR >> 21) & 1   = 1       Non-secure channel
```

Comparing the whole register to 0x4 would incorrectly reject this WFE state. Likewise, internal enum 10 is C_UPDATING_PC, not architectural status 10; its CSR field is 3. The raw internal enum is a verification/debug observation, not a software ABI.

If FSRC indicates channel 0 and FTR0=0x00000080, bit 7 identifies ch_rdwr_err. In the dedicated security probe, CPC0=0x00010000 points to the prohibited MOV CCR. If instead FTR0 has data_write_err set, a later CPC must not automatically be interpreted as the issuing store's address. Precise and imprecise diagnosis require different assumptions.

### 20.5 A compact review checklist

Before running a new program, confirm the selected channel/resources exist; thread/security attributes agree; loop counts and backward distances are legal; loads/stores balance useful bytes; tail handling respects discontinuities; notification follows the required barriers; executable memory is visible; and the recovery path preserves diagnosis before clearing it.

These checks explain different failure classes. A valid instruction encoding does not prove legal permissions. A legal AXI burst does not prove correct byte accounting. Correct payload does not prove correct notification ordering. Review all three layers: microprogram, controller execution and external transactions.

### 20.6 How the worked examples are calculated and cross-checked

#### CCR: move from transfer requirements to field contributions

Start with the required transfer, not a hexadecimal constant. For the aligned 32-byte example, both directions increment, each beat is eight bytes and each burst contains four beats. Therefore size=`log2(8)=3` and encoded length=`4−1=3`.

| Requirement | Shifted field contribution |
|---|---|
| Source increments | `1 << 0 = 0x00000001` |
| Source beat size is eight bytes | `3 << 1 = 0x00000006` |
| Source burst has four beats | `3 << 4 = 0x00000030` |
| Destination increments | `1 << 14 = 0x00004000` |
| Destination beat size is eight bytes | `3 << 15 = 0x00018000` |
| Destination burst has four beats | `3 << 18 = 0x000c0000` |

The fields do not overlap, so their bitwise OR is 0x000dc037. Decode the result back into fields as a second check:

```text
source_size  = (CCR >> 1)  & 0x7 = 3   -> 8 bytes
source_count = ((CCR >> 4) & 0xf) + 1 = 4
dest_size    = (CCR >> 15) & 0x7 = 3   -> 8 bytes
dest_count   = ((CCR >> 18) & 0xf) + 1 = 4
```

Both aligned directions account for `8 × 4 = 32` useful bytes. NS data attributes add bits 9 and 23, giving 0x008dc237. That addition changes protection attributes; it does not change the burst size or count. A nonzero alignment offset or an S-form instruction requires the separate useful-byte rules in section 19.4.

#### Program offsets: accumulate instruction lengths in bytes

Begin at offset zero and add each decoded length. In section 17.6, the three MOV instructions occupy six bytes each, so DMALD starts at offset 18 decimal, or 0x12. The following offsets are:

```text
0x12 + 1 = 0x13   DMAST
0x13 + 1 = 0x14   DMAWMB
0x14 + 1 = 0x15   DMASEV
0x15 + 2 = 0x17   DMAEND
0x17 + 1 = 0x18   end of the 24-byte program
```

For a program base of 0x00010000, the DMAST address is consequently 0x00010013. A loop distance is a separate subtraction from the loop-end opcode address to the body address; do not substitute the address after the loop-end instruction.

To check immediate byte order, rebuild the value as `b2 + (b3<<8) + (b4<<16) + (b5<<24)` for a six-byte MOV. Thus bytes `37 C0 0D 00` reconstruct 0x000dc037, and `00 00 00 10` reconstruct 0x10000000. The reconstruction checks both byte order and operand placement.

#### Debug packing: instruction bytes and dispatch fields are separate

For manager DMAGO to channel 0 at 0x00010000, the six bytes are `A0 00 00 00 01 00`. Put byte 0 into DBGINST0[23:16] and byte 1 into [31:24], producing 0x00a00000. Put bytes 2–5 into successive low-to-high DBGINST1 bytes, producing 0x00010000. The manager debug-thread selector remains zero.

Check the packing in reverse: the hardware instruction is `{DBGINST1, DBGINST0[31:16]}`. Unpacking those words must recover the original six bytes. DBGINST0[10:8] and [0] control channel-directed debug dispatch; they are not appended to that instruction stream. This is why channel-2 DMAKILL uses 0x00010201 in DBGINST0 while DMAGO's target channel is encoded inside its instruction bytes.

#### Figure references: check the pair and the observation being explained

Each embedded figure points to an existing SVG and its matching JSON. For example, `02_copy_1.svg` corresponds to `02_copy_1.json`; the JSON metadata identifies `direct_copy32`, its source interval, sampled signal paths and source-VCD hash. The SVG records the hash of its paired JSON. The filenames and links were checked during authoring.

Use the caption to select the correct observation, then read the actual state/handshake rows. A matching filename proves the intended asset was referenced; behavioral interpretation still requires the sampling convention and transaction context. In Confluence, preserve this association when replacing repository links with attachment links.

## 21. Waveform walkthroughs from the current RTL

The six pictures below reuse saved WaveDrom JSON/SVG pairs from the current recorded RTL revision. They are not hypothetical timing drawings. Each link opens the full-size SVG or editable source; the corresponding operation page contains additional measured values and provenance.

**Read the timing consistently:** one cell is a five-nanosecond core-clock snapshot in these examples, sampled immediately before its right boundary. An accepted condition at that boundary produces the next registered state. The numbered source-cycle row is a ruler for the selected window, not a second hardware clock. A gap explicitly removes idle samples; it does not remove accepted AXI beats. External peripheral handshakes must be interpreted on the peripheral clock. Absolute times below are observations from these runs, not architectural latency requirements.

On the internal row, EX means C_EXEC, UPC means C_UPDATING_PC and END means C_COMPLETING. On the Arm CSR row, EXEC=Executing (1), MISS=Cache miss (2), UPC=Updating PC (3), BAR=At barrier (5), WFP=Waiting for peripheral (7), COMP=Completing (9), FC=Faulting completing (14) and FLT=Faulting (15). The numeric CSR row removes any ambiguity between internal and architectural encodings.

### 21.1 Waveform 1 — execute directly after Updating PC

[![Waveform 1: buffered instruction delivery](waveform/svg/21_thread_phases_1.svg)](waveform/svg/21_thread_phases_1.svg)

[Editable JSON](waveform/wavejson/21_thread_phases_1.json) · [Detailed operation](waveform/operations/21_thread_phases.md)

Source: `direct_copy32`, selected interval 342.5–492.5 ns.

1. Follow an EX → UPC → EX subsequence on the internal-state row. There is no intervening FET when the target instruction qualifies for the local-line-buffer path.
2. During UPC, `fetch_pc` presents the target while registered CPC still identifies the previous instruction. `fetch_fast_hit` qualifies direct delivery. At the edge, the instruction registers and PC commit together, and the channel enters EX.
3. The CSR rows alternate between Executing=1 and Updating PC=3. No additional fast-hit code is exposed to software. The distinct internal CFG phase earlier in the window also maps to the already-defined At barrier=5.
4. `insn_valid` is the front-end delivery indication; descriptor side effects still belong to EX. The optimization must not execute the preceding MOV/LD/ST a second time during UPC.
5. The later WMB holds BAR while writes retire. Instruction-delivery efficiency does not bypass a memory ordering requirement.

This one picture separates three events that are easy to conflate: calculating an address, delivering instruction bytes and executing the instruction. The recorded short-copy program contains seven UPC-to-EXEC transitions; that count is evidence for this program, not a universal issue-rate guarantee.

### 21.2 Waveform 2 — fall back to FETCH and report a true miss

[![Waveform 2: pending fetch and architectural cache miss](waveform/svg/21_thread_phases_2.svg)](waveform/svg/21_thread_phases_2.svg)

[Editable JSON](waveform/wavejson/21_thread_phases_2.json) · [Detailed operation](waveform/operations/21_thread_phases.md)

Source: `direct_loop2d`, selected interval 462.5–612.5 ns.

1. Locate UPC followed by a prolonged FET interval. The next instruction cannot be delivered through the complete local-line-buffer path, so the controller takes the fallback.
2. FET initially reports Executing, then Cache miss while `ic_refill` is active, then Executing again as delivery finishes. The long internal FET phase is therefore not equivalent to one uniform architectural Cache miss interval.
3. RLAST/refill completion and instruction assembly restore the front end. EX executes the instruction; a later UPC selects the loop target. Warm target delivery and additional front-end work are visible as different paths.
4. The registered CPC and fetch target must be read independently. A long wait at one instruction does not prove that payload writes have also stopped; the address/data handshakes elsewhere in the window can belong to already-submitted work.

Short opcode aliases `v1` and `v2` in this picture mean ADDH-S and ADDH-D respectively; the detailed operation page gives their full values. The recorded loop program includes 23 direct UPC-to-EXEC transitions and three UPC-to-FETCH fallbacks. Both paths retain the same Arm-visible state encoding rules.

### 21.3 Waveform 3 — distinguish last data from completion notification

[![Waveform 3: copy, write retirement and notification](waveform/svg/02_copy_1.svg)](waveform/svg/02_copy_1.svg)

[Editable JSON](waveform/wavejson/02_copy_1.json) · [Detailed operation and data labels](waveform/operations/02_copy.md)

Source: `direct_copy32`, selected interval 377.5–527.5 ns.

The measured milestones make the dependency explicit:

| Time (ns) | Accepted milestone | What it establishes |
|---:|---|---|
| 397.5 | AR: 0x10000000, LEN=3, SIZE=3 | A four-beat source burst has been accepted. |
| 422.5 | RLAST | Its final read beat has returned. |
| 432.5 | AW: 0x20000000, LEN=3, SIZE=3 | Destination burst address has been accepted. |
| 452.5 | WLAST, WSTRB=0xff | Final full-width write-data beat has been accepted. |
| 457.5 | B, response OKAY | The write response has retired. |
| 472.5 | IRQ bitmap=1 | The program's subsequent event notification is visible. |

Follow matching D labels from RDATA to WDATA to verify byte identity. Then follow BAR release and subsequent instruction progress. IRQ does not arise from WLAST itself: WMB orders the write work, SEV supplies notification and END supplies normal termination. Internal END and architectural COMP identify Completing before Stopped.

CPU buffer ownership still follows the system's coherency/mapping protocol. This figure establishes the controller-side sequence; it does not show an arbitrary CPU cache being invalidated.

### 21.4 Waveform 4 — a peripheral request permits work; it is not payload

[![Waveform 4: memory-to-peripheral pacing](waveform/svg/10_m2p_1.svg)](waveform/svg/10_m2p_1.svg)

[Editable JSON](waveform/wavejson/10_m2p_1.json) · [Detailed operation](waveform/operations/10_m2p.md)

Source: `direct_m2p`, selected interval 382.5–542.5 ns.

1. The thread reaches WFP after the setup/flush sequence. The peripheral request context is separate from source data; DR carries no payload bytes.
2. The measured burst-request acceptance and core WFP grant occur at 422.5 ns in this synchronous example. An asynchronous bridge need not preserve that same-edge timing.
3. The subsequent source AR is accepted at 447.5 ns, with two eight-byte beats. The peripheral request therefore precedes, rather than substitutes for, the memory read.
4. AW at 472.5 ns addresses the fixed FIFO location 0x40000000. Repeated access to that address services the FIFO rather than advancing through a memory array.
5. WLAST at 482.5 ns and B at 487.5 ns are distinct. Peripheral acknowledgement handling follows transfer retirement; software should not equate initial WFP release with a completed job.

The original test can contain several requests and an earlier flush. Interpret the selected window in that context; not every DA visible in a long test necessarily acknowledges the final application-level job.

### 21.5 Waveform 5 — hold a discontinuous MOV until earlier work retires

[![Waveform 5: destination reconfiguration barrier](waveform/svg/22_reconfiguration_2.svg)](waveform/svg/22_reconfiguration_2.svg)

[Editable JSON](waveform/wavejson/22_reconfiguration_2.json) · [Source/destination comparison](waveform/operations/22_reconfiguration.md)

Source: `spec_destination_barrier`, selected interval 472.5–622.5 ns.

1. Internal CFG and architectural BAR describe the same waiting interval at different abstraction levels. CPC identifies the MOV at 0x00010015; the old DAR remains in effect during the wait.
2. An earlier B response retires at 492.5 ns, but a pending read still matters. Its RLAST is accepted at 507.5 ns. A destination discontinuity must respect both directions, not only the last write-data beat.
3. After the drain condition, the new destination context commits and UPC advances the instruction sequence. Old residual destination bytes are discarded under the discontinuity rule.
4. Later traffic is fresh work: the new AR at 542.5 ns reads from 0x20000020, and AW at 562.5 ns addresses 0x30001002. These are not evidence that old residual bytes survived the MOV.

The independent probe checks register values before releasing stalls and checks final destination memory. That check is needed because merely seeing CFG/BAR in a picture does not establish correct discard behavior. The paired source-only case preserves residual data after draining reads, demonstrating why the two discontinuities need separate explanations.

### 21.6 Waveform 6 — a forbidden CCR immediate faults at MOV

[![Waveform 6: precise CCR security fault](waveform/svg/24_ccr_permissions_1.svg)](waveform/svg/24_ccr_permissions_1.svg)

[Editable JSON](waveform/wavejson/24_ccr_permissions_1.json) · [Detailed operation](waveform/operations/24_ccr_permissions.md)

Source: `spec_ccr_security`, selected interval 312.5–462.5 ns.

The program is `DMAMOV CCR, 0; DMASEV E0; DMAEND`, launched as non-secure. A zero CCR clears both data protection NS bits and therefore attempts prohibited secure data accesses.

1. The instruction is fetched normally; an instruction-cache miss is unrelated to whether the immediate is permitted.
2. At 342.5 ns, FTR records 0x80: bit 7, ch_rdwr_err. CPC remains 0x00010000, the offending MOV address. The old CCR is preserved instead of committing the prohibited value.
3. Internal fault-cleanup states map to architectural FC/FLT. The following SEV does not execute; the probe checks E0 remains unset.
4. This is a precise programming-permission abort, not an error response from a later load/store. No failing payload address is required to identify its instruction.

Use the fault register and the PC together, and recover through debug kill before attempting another launch. This example connects instruction validation, register semantics, security context and the external diagnosis visible to a driver.

## 22. Specification coverage and Confluence publication

### 22.1 What was checked against the supplied reference

The expanded material was authored from `references/DDI0424D_dma330_r1p2_trm.pdf`, 147 PDF pages, SHA-256:

```text
ab5a380b1866a24e297027670a8824cc2c9dd418e69b4a86415dc1647d3e29e5
```

This identifies the input document, not a verification signature for the RTL. Source statements are paraphrased for explanation; instruction names, bit positions and architectural encodings retain their technical meaning.

| Topic in this document | Main manual reference | Workspace cross-check |
|---|---|---|
| Thread operating states | §2.3; Tables 3-7 and 3-17 | Channel/manager status multiplexers. |
| Peripheral request modes and last flag | §§2.6.4–2.6.5 | Peripheral controller and WFP capture logic. |
| Precise/imprecise aborts | §2.8; Tables 3-15/3-16 | Fault generation and diagnostic registers. |
| Byte ordering, discontinuity and resources | §§2.11.1–2.11.4; Appendix B | Descriptor byte calculation, C_RECONFIG and MFIFO admission. |
| Register locations and permissions | Tables 3-1 through 3-6 | `dma_regs` address decoder and DNS/CNS filtering. |
| Field definitions | §§3.3.1–3.3.30 | Register outputs, masks, configuration encoders and extensions. |
| Complete instruction family coverage | Table 4-1; §§4.3.1–4.3.21 | ISA decoder, thread executors and `dma330_asm`. |
| Assembler versus encoded fields | §§4.4.4–4.4.5 | Loop helpers and CCR builder. |
| Current state-name conventions | CSRn Table 3-17 | WaveJSON CSR labels and numeric code rows. |

The waveform source files record VCD provenance, selected intervals and sampled values. The six embedded figures reuse those current-revision artifacts; no new RTL behavior was invented to fit the explanation, and no RTL or existing testbench changes were required for this document expansion.

### 22.2 Suggested Confluence page organization

If a single long page becomes difficult to navigate, keep this file as the master and split its content along the existing boundaries:

| Page | Material | Reader's question |
|---|---|---|
| DMA Controller Overview | Sections 1–16 | What does the controller do, and how does a transfer work? |
| DMA-330 Microcode Reference | Section 17 | What bytes/operands execute, and how do loops and requests work? |
| DMA-330 Register Reference | Sections 18–19 | What do the register fields mean, and what can software modify? |
| Programming and Diagnosis | Section 20 | How do I launch, observe, cancel and diagnose a program? |
| Timing Walkthroughs | Section 21 | Which observed transitions demonstrate the mechanism? |
| Manager and Channel Coordination | Section 23 | How do boot/debug commands launch and synchronize independent contexts? |
| Dataflow, Resources and Integration | Sections 24–26 | What orders progress, what storage is required, and which system assumptions apply? |

Preserve the tables and code blocks. Upload the six SVGs as attachments and retain their numbering/captions; attach matching JSON files for readers who need to edit the drawings. Replace repository-relative links with the corresponding page or attachment links when publishing. Put the Arm document revision and the RTL source-revision link near the page header so a future update does not silently mix different baselines.

The [source-revision record](waveform/operations/source_revision.json) describes the recorded waveform baseline. The [full operation index](waveform/operations/README.md) remains the place to explore cases beyond this reference chapter, including unaligned transfers, 4 KB splitting, events, sharing, cache cancellation, CDC, endian variants and low power.

## 23. How the manager and channel threads work together

### 23.1 A control thread and independent transfer threads

In DMA-330, the manager is a hardware **control-program context**. Channel threads are hardware **transfer-program contexts**. The manager starts and coordinates work, while a channel executes the address setup, loops, loads, stores, peripheral waits and barriers that implement its transfer.

The architectural foundation is TRM §§2.3–2.5, the manager/channel register definitions, and the DMAGO/DMAKILL instruction descriptions. Signal handshakes, debug-return bookkeeping and fast-path differences below describe the current RTL; the conceptual sequence is not a new cycle-accurate specification of the Arm macro.

The manager is not a CPU running an operating-system scheduler. It does not save channel registers into memory each time another channel progresses. Each channel already has persistent hardware context. Nor is the manager an extra payload channel: it has no SAR/DAR/CCR transfer stream of its own.

| Responsibility | Manager | Channel thread |
|---|---|---|
| Program counter and instruction context | DPC and manager fetch context | CPCn and the channel's fetch context. |
| Status and security | DSR, including DNS | CSRn, including CNS. |
| Fault diagnosis | FTRD / FSRD | FTRn / FSRC; FARn is an extension. |
| Start another channel | Execute DMAGO | DMAGO is not a channel instruction. |
| Configure and move payload | No channel load/store datapath context | DMAMOV, LD/ST, loops and address arithmetic. |
| Event synchronization | DMAWFE / DMASEV | DMAWFE / DMASEV. |
| Peripheral pacing | Not a manager transfer operation | DMAWFP, LDP/STP and DMAFLUSHP. |
| Normal finish | Stop the manager's instruction program | Complete the channel's data work, then stop. |

The shared interconnect, instruction cache, event unit and datapath connect these contexts. A manager instruction can launch channel 1 while channel 0 is waiting for read responses. The thread programs proceed independently, subject to shared-resource arbitration and explicit synchronization.

### 23.2 Two ways to supply manager instructions

**Boot program:** after reset, boot configuration selects whether the manager fetches from boot_addr or stays stopped. With boot_from_pc enabled, the memory at that address contains manager instructions. Those instructions can launch several channel programs, wait for their events and issue a final notification without a new APB command for each launch. The boot program must be accessible with the manager's configured security attributes.

**Debug instruction:** software writes an encoded instruction through DBGINST0/1 and requests execution through DBGCMD. The register bank supplies the instruction bytes; there is no requirement that the manager first fetch that debug instruction from boot memory. The channel program named by DMAGO is still fetched from memory.

The register interface can therefore be active while the manager is Stopped. A stopped manager is available for debug control; it is not a disabled DMAC. Conversely, boot execution does not turn the debug interface into an unrestricted second instruction stream. TRM §2.5.1 restricts real-time debug operations to DMAGO, DMASEV and DMAKILL. This RTL also accepts debug DMANOP, an implementation allowance that portable software should not require.

### 23.3 Launch sequence across the actual RTL blocks

The following is a conceptual sequence, not a waveform or a fixed-cycle timing guarantee:

```text
CPU / APB          dma_regs             dma_manager          channel n
    |                  |                    |                    |
    | stage I0/I1 ----->|                    |                    |
    | DBGCMD=0 ------->| latch instruction  |                    |
    |                  | busy=1, dbg_valid->| capture/validate   |
    |                  |                    | execute DMAGO      |
    |                  |                    |--go_valid[n]------>|
    |                  |                    |--go_pc, go_ns----->| if STOPPED:
    |                  |<----dbg_done-------|                    | capture launch
    |                  | clear debug busy  |                    | enter FETCH
    |                  |                    | return/resume      | fetch program
    |                  |                    |                    | execute LD/ST
    |                  |                    |                    | complete later
```

For an authorized manager command, `dma_regs` latches the pending instruction and maintains the debug-valid request until the manager retires it. The manager selects the debug instruction instead of fetched program bytes, validates the channel operand and security, and asserts a one-hot `go_valid[n]` with `go_pc` and `go_ns`.

The core connects those signals directly to the channels. A selected channel accepts the launch only in C_STOPPED. On that edge it loads PC/NS, clears request/fault/address bookkeeping, requests its own instruction-cache maintenance and begins fetching the channel program. It does not receive payload data or a complete source/destination configuration from the manager. The first channel instructions establish SAR/DAR/CCR and any loop context they need.

There is no per-channel ready/acceptance response in this GO wiring. The manager completes its instruction even if a valid target was already active and therefore ignores the launch as specified. This explains an important software distinction: **debug instruction completion is not confirmation that a running channel was restarted.** A driver must establish the target's lifecycle state before issuing GO.

### 23.4 Three completion milestones that software must separate

| Milestone | What has finished | What can still be pending |
|---|---|---|
| APB DBGCMD access completes | The register command was accepted through the APB path | Manager validation/execution, channel startup and all transfer work. |
| DBGSTATUS returns idle | The manager-side debug command has been serviced | Channel fetch, descriptors, bus traffic, event generation and normal END cleanup. |
| Transfer's notification/termination condition is met | The condition expressed by the channel program | Other channels, CPU cache maintenance, or channel END if notification preceded it. |

For example, DMAGO can complete before the target's first code refill returns. A channel's DMASEV can occur before its DMAEND reaches Stopped. Even `WMB; SEV; END` separates write completion, notification and thread termination. Software that wants to reuse the same channel must check Stopped rather than treating the notification alone as a reusable-channel acknowledgement.

The manager does not automatically wait after every GO. If its program needs a dependency, it must express one, normally through a correctly routed event. If it only launches independent work, it can start the next channel immediately after progressing through its own instruction flow.

### 23.5 Coordinating two channels through manager events

Suppose channel 0 produces a staging buffer and channel 1 consumes it. This example uses a secure manager and secure channel launches. Assume both channels are initially Stopped, the programs and buffers have been published, and E1/E2 are clean, owned event-mode resources. Set INTEN[1]=0 and INTEN[2]=0; use a separate E3 with INTEN[3]=1 for the CPU notification. The programs can have this structure:

```text
Manager program                         Channel 0 program
----------------                        -----------------
DMAGO C0, producer_program               initialize SAR / DAR / CCR
DMAWFE E1                               load / store producer data
DMAGO C1, consumer_program               DMAWMB
DMAWFE E2                               DMASEV E1
DMASEV E3                               DMAEND
DMAEND

                                        Channel 1 program
                                        -----------------
                                        initialize SAR / DAR / CCR
                                        read producer buffer / write result
                                        DMAWMB
                                        DMASEV E2
                                        DMAEND
```

1. The manager launches channel 0 and waits at E1. Channel 0 continues on its own; the manager is not executing each of its LD/ST instructions.
2. Channel 0 completes the writes relevant to the dependency before setting E1. Its WMB is what makes E1 a meaningful DMA-side producer-completion signal.
3. The event unit satisfies the manager's wait. A sticky E1 can already have been set before the manager reached WFE; the program does not require a single-cycle pulse coincidence.
4. The manager launches the previously stopped channel 1. Channel 0 can still be finishing its own END sequence; they are different contexts.
5. Channel 1 completes its output writes and signals E2. The manager's second wait releases and it produces E3 for software.

This is explanatory microcode, not a complete tested binary for a specific buffer layout. It expresses two ordered stages. To overlap stages on different buffers, use explicit ownership and enough independent buffer/event context; simply launching both programs before the dependency is satisfied does not make the consumer safe.

In this implementation an interrupt-routed E1 would not satisfy the manager's WFE. Conversely, using the same event number for unrelated transactions can merge notifications because its state is a sticky bit, not a queue of completion records. Event allocation is part of the program protocol.

### 23.6 Debug commands while the manager is already active

Real-time debug must preserve the manager's memory-program context. The current RTL records whether it must return to a fetch or an event wait after servicing a debug instruction:

| Manager situation | Current RTL handling | Effect on the memory-program PC |
|---|---|---|
| Stopped | Capture a manager-directed debug instruction and execute it | Successful nonterminating debug work returns to Stopped; it does not advance a memory program. |
| FETCH, including a stalled refill | Debug command can preempt the fetch boundary | Successful GO/SEV resumes fetching the same program PC. Stale delivery is suppressed/drained. |
| Executing an ordinary instruction / Updating PC | Command remains pending until a service point | The ordinary instruction is not replaced halfway through its effects. |
| WFE | A debug command can be serviced while preserving the wait context | Successful nonterminating debug work returns to the wait rather than skipping the WFE. |
| Faulting | Debug DMAKILL is the recovery operation | Other commands do not recover the manager or resume its program. |

Debug instructions do not add their byte length to DPC. Otherwise, injecting a six-byte DMAGO could incorrectly skip bytes in the manager's boot program. M_UPDATING_PC is used for the memory-resident manager program, not as a retirement step for injected debug instructions.

The current M_WFE logic gives an already satisfied `wfe_hit` priority over taking the pending debug request on that edge. The command remains pending through the register/manager handshake and can be serviced at a later boundary. This is a scheduling detail, not a rule that a debug command must execute on the same edge it was accepted on APB.

A preempted fetch can still have externally committed AXI obligations. Dropping its instruction request prevents late bytes from being executed as stale program context; it does not permit a malformed truncated AXI transaction. The fetch/cache cancellation protocol handles that distinction.

### 23.7 Manager state is not the channel state machine

The manager's architectural state set is smaller: Stopped, Executing, Cache miss, Updating PC, Waiting for event and Faulting. It does not enter channel Completing to wait for the channels it previously launched. It also does not use channel WFP, a channel MFIFO stream or channel write barriers.

The channel's local-buffer optimization must not be assumed to apply to the manager. In the present RTL, the manager overlaps fetch during M_UPDATING_PC but returns to M_FETCH; the new direct UPC-to-EXEC local-hit selection belongs to `dma_channel`. Both report the Arm-defined status codes appropriate to their own phases.

Likewise, the same numeric internal enum is not interchangeable between the two RTL modules. Software reads DSR[3:0] for the manager and CSRn[3:0] for a channel; verification waveforms can additionally display each module's internal phase.

### 23.8 Security and fault ownership across the launch boundary

| Condition | Which context diagnoses it? | Why |
|---|---|---|
| GO names an unimplemented channel | Manager, operand_invalid | Validation fails before a valid launch can be emitted. |
| NS manager attempts to launch a secure channel | Manager, dmago_err | The launch instruction violates manager permissions. |
| Valid GO targets an already-running channel | No restart; target ignores GO | It is not a replacement-program mechanism. |
| NS channel later executes forbidden MOV CCR | Channel, ch_rdwr_err | The fault belongs to the channel program, not the earlier valid GO. |
| Channel data write receives an error | Channel, data_write_err | The datapath associates the response with that channel. |
| Manager boot instruction fetch fails | Manager, instr_fetch_err | The fetch belongs to the manager's program. |

A secure manager may launch secure or NS channels. An NS manager may launch only NS channels. CNS comes from the accepted launch, not merely from which APB port software used. The APB visibility gate and instruction permission checks are separate stages of authorization.

Manager fault does not implicitly roll back or globally kill previously launched channels. A channel fault does not cause the manager to start executing a general-purpose exception handler. The external agent diagnoses FSRD/FSRC/FTRD/FTRn and applies an appropriate recovery policy. If the manager is waiting for an event from a channel that faulted before sending it, ordinary completion will not magically release that wait.

### 23.9 END and KILL are local lifecycle operations

DMAEND in a manager program stops that manager. Channels already launched can continue. DMAEND in a channel allows that channel's data work to complete before it stops. These meanings are related but have different cleanup conditions.

A manager-directed debug DMAKILL stops/recovers the manager; it is not an implicit broadcast kill to all channels. To cancel channel n, use the channel-directed debug selector and channel number. That channel must retire its noncancelable bus work before reaching Stopped. Other channels remain independent unless software or a shared-resource fault policy acts on them.

For a complete controlled shutdown, the driver must separately manage new submissions, manager activity, each affected channel, outstanding transactions and shared-core quiescence. Seeing DSR=Stopped is not proof that no AXI data traffic remains.

### 23.10 How to inspect the relationship in RTL and traces

Start at [dma_regs](../rtl/core/dma_regs.sv) for debug staging, pending/busy state and dispatch. Follow `mgr_dbg_valid`, the latched instruction and `mgr_dbg_done` into [dma_manager](../rtl/core/dma_manager.sv). Then follow `go_valid[n]`, `go_pc` and `go_ns` through [dma330_core](../rtl/core/dma330_core.sv) to the selected [dma_channel](../rtl/core/dma_channel.sv).

For event coordination, follow manager/channel SEV and WFE ports into [dma_event_irq](../rtl/core/dma_event_irq.sv), then the appropriate `wfe_hit` back to its waiting context. Payload requests instead leave the channel through LD/ST descriptor interfaces into the datapath; they do not return through the manager.

A useful observation order is: APB command acceptance → manager execution → GO selection → target state/PC/security capture → channel instruction delivery → descriptor acceptance → bus retirement → event generation → receiver wakeup. This separates control completion from data completion and explains why apparently distant transitions belong to one causal operation.

## 24. DMAC operation as a pipeline of commitments

### 24.1 Submission is not execution, and execution is not visibility

A useful general DMAC model is a pipeline whose stages acquire increasingly concrete obligations:

| Stage | What has become committed | What is not established yet |
|---|---|---|
| Software submission | A valid job/program has been made available and requested | The controller has not necessarily fetched it. |
| Instruction execution | The current operation has passed its operand/permission checks | A descriptor or bus request may still wait for admission. |
| Descriptor acceptance | Queue/buffer resources have been assigned to the operation | External AR/AW/W acceptance may still be pending. |
| Bus acceptance | The relevant external protocol obligation exists | Responses and full payload completion can still be outstanding. |
| Transaction retirement | The corresponding transfer response has been consumed | The whole job, notification or software visibility protocol may still be incomplete. |
| Completion handoff | The chosen program-level completion condition is signaled | CPU-side mapping/cache/ownership actions remain platform dependent. |

The stages can overlap for different instructions and channels. A source address can already point past a queued load while earlier R beats are returning. A channel can have entered a wait state while its write engine continues draining accepted work. These are normal consequences of decoupling, not contradictory state reports.

Cancellation must respect the stage reached. Work still in a cancelable queue can be discarded. An externally committed transaction cannot simply disappear because its software job was canceled. That distinction is why killing a thread can require additional bus activity instead of immediately making every VALID low.

### 24.2 Read, write and cross-channel ordering

DMARMB waits for the channel's earlier read work and supports a dependency such as completing a read before a later write to the same location. DMAWMB waits for the channel's earlier writes and supports a dependency such as completing a write before a later read. See TRM §§4.3.14 and 4.3.21. Neither is a global barrier that stalls every other DMA channel or a CPU instruction that operates on a processor cache.

For a cross-channel dependency, an ordering operation and a synchronization operation serve different purposes:

```text
Producer channel:  write result -> WMB -> SEV E
Consumer context:                      WFE E -> read result
```

The producer's barrier supplies the DMA-side data ordering. The event conveys that the consumer may proceed. Removing WMB can let the producer announce an operation whose writes are still outstanding. Removing the event leaves no explicit cross-thread dependency. Correct memory attributes and system visibility rules remain part of the integration.

AXI IDs associate responses and ordering domains; they do not impose one universal time order across unrelated channels. This AXI4 implementation sends a complete W burst before starting the next W burst, while address issue and responses can be decoupled. Do not infer payload readiness from an AW ID currently visible on the bus: the active W context can belong to an address already queued earlier.

### 24.3 Peripheral flow control and memory-system flow control are separate

An external FIFO has finite storage; the AXI interconnect has finite accepting capacity; the DMAC has finite internal queues and MFIFO space. These are three different sources of back-pressure.

DMAWFP handles peripheral permission to perform work. ARREADY/AWREADY/WREADY and R/B delivery regulate the memory-mapped transport. Internal admission controls protect the DMAC's own storage. A granted request does not make the interconnect ready, and an always-ready AXI slave does not authorize access to a peripheral that has not requested data.

For a receive path, delaying CPU processing can fill destination buffers even when the DMA and peripheral protocol are functioning correctly. A complete system needs a buffer-allocation and overrun policy; DMAC register correctness alone cannot provide it. Similarly, continuous transmit needs both a data-production policy and appropriate peripheral pacing to avoid underflow.

### 24.4 Buffer ownership, repeated work and scatter-gather

A common software ownership cycle is:

```text
FREE -> prepared by software -> DMA-owned -> DMA completion observed
     -> CPU-owned/consumed -> released for reuse -> FREE
```

Define who may modify payload, program bytes and completion flags at each stage. The necessary cache/mapping operations depend on whether the system is coherent and how memory is shared. A driver should not rewrite a DMA-owned program or consume a partially written destination merely because a progress register advanced.

A ring or double-buffer design adds a separate generation/ownership protocol. An event bit alone does not count how many buffers completed; repeated sets can merge while the flag remains asserted. Software counters, distinct resources or another explicit protocol must identify which buffer and generation is ready.

DMA-330 can express repeated address sequences through microcode and software orchestration. That does not imply a native engine that autonomously reads arbitrary linked-list descriptors and loads pointers from them into SAR/DAR. A scatter-gather submission may need a driver to translate segments into microcode, multiple launches or a controller-specific wrapper. Evaluate the actual programming model rather than importing the descriptor semantics of another DMA IP.

## 25. Arm resource sharing and forward progress

### 25.1 Byte count and MFIFO entry count are different budgets

TRM §2.11.4 and Appendix B analyze MFIFO use in **entries**, not just payload bytes. The Arm examples arrange incoming data according to destination formatting. Source/destination alignment and FIXED accesses can therefore change the entry requirement for the same useful byte count.

This workspace presents a densely packed per-channel byte stream in its internal MFIFO. Its 128-line pool is a concrete storage implementation, but its allocation can differ from the Arm examples. Use the Arm restrictions to write legal programs, then use this RTL's reservation/occupancy rules to explain its measured utilization. Dividing bytes by eight is not a universal proof that a program set fits the Arm macro or every implementation.

Distinguish three quantities:

| Quantity | Question answered |
|---|---|
| Useful payload held | How many meaningful data bytes are available to future stores? |
| Owned/occupied entries | How much physical buffer storage currently belongs to the channel? |
| Reserved capacity | How much space is already promised to accepted reads whose data may not have returned? |

Counting only returned payload can admit more future R data than the buffer can hold. Counting only descriptor bytes can miss partially used entry effects. Both program-level resource analysis and correct hardware admission are needed.

### 25.2 Static and dynamic requirements under load-lock

For Arm's analysis, let S_i be channel i's static requirement and P_i its peak entry use. The static term captures the maximum retained requirement at the specified wait/load-lock acquisition boundaries. The dynamic term is `D_i = P_i - S_i`: additional peak demand that can grow while the load-lock serializes loading phases.

The required capacity for a concurrently started program set is:

```text
Required MFIFO entries = sum(S_i) + max(D_i)
Required MFIFO entries <= configured MFIFO depth
```

For example, assume analysis of two programs has already established these hypothetical profiles:

| Program | Static S | Dynamic D | Peak P |
|---|---:|---:|---:|
| A | 1 | 4 | 5 |
| B | 2 | 3 | 5 |

The combined requirement is `1 + 2 + max(4,3) = 7` entries. An eight-entry resource satisfies that model with one entry of headroom. Adding the two peaks would give ten and ignore the serialization supplied by load-lock; taking only the largest peak would give five and ignore simultaneously retained static data.

These numbers are a calculation example, not measured requirements for the current channel programs. S and P must first be derived from the actual loop, wait, alignment and transfer-format behavior. A hypothetical table does not replace that derivation or establish the workspace's exact physical allocation.

### 25.3 What load-lock guarantees

A channel can claim free load-lock on a load. An owning channel can continue its load sequence; another channel attempting a load waits until ownership becomes available. Stores, barriers, waits, normal termination and abort release ownership as defined for the executed operation. A false conditional store is a NOP and must not accidentally release it.

Load-lock is an internal progress/resource mechanism. It is not AXI exclusive access, a CPU mutex visible in memory, or a guarantee that a channel can accumulate unlimited data. It also does not protect an application buffer from another bus master writing it. Those are different synchronization domains.

Program structure matters: retaining payload before waiting for another producer can increase static use, while bounded load/store phases can reduce simultaneous retained demand. Optimizing only burst length without considering these boundaries can increase the total MFIFO requirement.

### 25.4 Resource lock-up versus an event dependency deadlock

Arm §2.8.3 describes resource lock-up detection when queued work is drained and all running channels are blocked from loading because of insufficient MFIFO space or load-lock ownership. In this RTL, the detector also checks relevant busy/release conditions before declaring that contributing channels cannot make progress. WD[0] selects whether to abort/report or only report.

This is different from two programs that each wait for an event the other will never send. That software dependency can deadlock even when the MFIFO is empty. A legitimate WFE/WFP in a running context also prevents interpreting the whole program set as the specific all-load-blocked condition. The programmable timeout extension has its own activity policy; it must not be assumed to solve every application-level wait cycle.

When diagnosing lack of progress, first distinguish: waiting for a real external request, waiting for bus retirement, waiting for temporary resource availability, impossible MFIFO sizing, and cyclic program dependencies. Increasing a watchdog timeout cannot correct an impossible resource budget or a missing event producer.

## 26. Applying the Arm specification to a complete system

### 26.1 Behavioral requirements, implementation mechanisms and timing

The Arm TRM defines instruction/register semantics and describes the Arm implementation's behavior. The same software-visible state can be realized by different internal phases. This workspace's C_RECONFIG and direct UPC-to-EXEC path are implementation mechanisms; they do not create additional architectural CSR codes.

Some Arm descriptions are also specific scheduling characteristics. For example, §§2.10.1–2.10.2 describe round-robin/equal-priority channel service and manager service before the next channel. Do not turn that description into an unverified latency or priority claim for every resource in this RTL. Its shared-cache arbiter rotates across thread requests, its cache can serve hits under a refill, and its read/write/admission resources have separate eligibility and arbitration decisions. Exact cycle/priority equivalence needs analysis of those actual arbiters.

The safe documentation pattern is to state the architectural requirement first, identify the implementing mechanism second, and use a trace or a targeted check for its observed timing. An expected register value alone does not establish that every arbitration or buffer detail matches the Arm macro.

### 26.2 Explicit system responsibilities

| Layer | Responsibilities not supplied by a bare DMA microprogram |
|---|---|
| Driver/application | Channel/event ownership, segment translation, buffer lifecycle and recovery policy. |
| CPU/memory subsystem | Required mapping, permissions, cache visibility and ordering for shared data/program memory. |
| Interconnect/slaves | Legal acceptance/response behavior, address decode, security enforcement and performance under contention. |
| Peripheral | Correct request/last/flush behavior and a defined FIFO access contract. |
| Reset/clock/power integration | Coordinated reset, valid CDC operation and quiescence before clock/power actions. |

For a real-time stream, characterize worst-case request service, buffer capacity and competing traffic. Round-robin service by itself is not a deadline guarantee, especially when instruction refills or an external slave can stall. For correctness, characterize every ownership and completion boundary rather than treating a configured DMA channel as an isolated copy function.

### 26.3 Review questions that connect the whole design

Before declaring an operation understood, answer these questions: Who starts it? Which context owns the instruction? What makes the target channel eligible to launch? When are descriptors accepted? Which bytes and resources are promised? What external response retires the operation? What orders the notification? Who consumes the event? Which context owns a possible fault? What must software observe before reusing the channel or buffer?

The manager–channel launch/event flow in section 23, the commitment stages in section 24 and the MFIFO budget in section 25 provide complementary answers. Together they explain both normal execution and why a controller can be protocol-correct yet still wait indefinitely because its program or system contract is incomplete.

## 27. Function and operation coverage after review

### 27.1 Where the main functions are explained

This map is a documentation review aid, not functional-coverage or sign-off evidence. References in the last column lead to recorded operation examples; the absence of a new figure here does not mean a function requires no verification.

| Main function / operation | Explanation in this document | Recorded example |
|---|---|---|
| Manager launch through APB debug | §§7.2, 20.2, 23.2–23.4 | [Launch](waveform/operations/01_launch.md). |
| Aligned memory copy and ordered completion | §§9, 21.3, 24.1–24.2 | [Copy](waveform/operations/02_copy.md). |
| Source/destination width conversion | §§4.2, 9.4, 19.4 | [Packing/unpacking](waveform/operations/03_packing.md). |
| Unaligned transfer and exact tail | §§9.3, 19.4 | [Nineteen-byte copy](waveform/operations/04_unaligned.md). |
| AXI 4 KB splitting | §§12, 19.4 | [Boundary split](waveform/operations/05_boundary.md). |
| Fixed-address source/destination | §§2.1, 4.2, 11.1, 19.5 | [FIXED transfers](waveform/operations/06_fixed.md). |
| Zero fill | §9.1 | [DMASTZ](waveform/operations/07_zero.md). |
| Finite loops, strides and 2D layout | §§9.2, 17.4 | [Loops/2D](waveform/operations/08_loops.md). |
| Endian group conversion | §§19.1, 19.6 | [Endian variants](waveform/operations/09_endian.md). |
| Memory-to-peripheral | §§11.1, 17.5, 21.4 | [M2P](waveform/operations/10_m2p.md). |
| Peripheral-to-memory | §§11.1, 17.3 | [P2M](waveform/operations/11_p2m.md). |
| Single/burst selection and last request | §§17.3–17.5 | [Request types](waveform/operations/12_request_types.md). |
| Event/interrupt synchronization | §§11.2, 11.4, 23.5 | [Late/sticky events](waveform/operations/13_events.md). |
| Instruction cancellation/invalidation | §§6.2, 14.1, 23.6 | [Cache cancellation](waveform/operations/14_cache.md). |
| Kill and lifecycle cleanup | §§13.1, 20.3, 23.9 | [Kill](waveform/operations/15_kill.md). |
| Precise/imprecise diagnosis | §§13, 18.5, 20.4 | [Fault cases](waveform/operations/16_faults.md). |
| Multiple channels and MFIFO admission | §§6.3, 24.2, 25 | [Sharing](waveform/operations/17_sharing.md). |
| Secure/non-secure execution | §§14, 18.1, 19.2, 23.8 | [NS execution](waveform/operations/18_security.md). |
| Peripheral clock crossing | §§14, 24.3 | [CDC](waveform/operations/19_cdc.md). |
| Sleep entry and wakeup | §14.2 | [Q-Channel](waveform/operations/20_lowpower.md). |
| Channel fast path and Arm status | §§10.2, 21.1–21.2 | [Thread phases](waveform/operations/21_thread_phases.md). |
| Implicit discontinuity ordering | §§19.5, 21.5 | [Reconfiguration](waveform/operations/22_reconfiguration.md). |
| 128-bit groups across narrow beats | §§19.6, 25.1 | [Wide swap](waveform/operations/23_swap128.md). |
| CCR permission check before commit | §§19.2, 21.6 | [CCR security fault](waveform/operations/24_ccr_permissions.md). |

The manager boot/debug return paths, explicit peripheral flush exchange, reset/restart policy and resource-budget analysis are described from the supplied specification and RTL in addition to the selected timing gallery. The six embedded pictures in section 21 do not independently establish every case in this table.

### 27.2 Capabilities that must not be inferred from the overview

| Potential assumption | Actual scope of this document/design |
|---|---|
| “DMA” means arbitrary data processing | The documented transformations are byte positioning, packing/unpacking, endian grouping and zero generation. There is no documented microcode arithmetic engine for CRC, encryption or compression. |
| Any DMA automatically walks a scatter-gather descriptor ring | This is an instruction-driven controller. Segment translation/submission needs the programming/orchestration described in §24.4. |
| A bus-visible peripheral address automatically proves a complete peripheral-to-peripheral feature | Such a program needs compatible source/destination pacing, byte counts and acknowledgement semantics. No dedicated end-to-end P2P example is established by this overview. |
| An ordinary copy is overlap-safe or atomic | Neither property follows from its name. Direction, chunking, side effects and visibility need a proved program/system contract. |
| WFE is a generic hardware pause and GO resumes it | WFE is an event wait; GO to an active channel does not restart it. Kill/relaunch is a different lifecycle. |
| Correct current timing is an Arm-required fixed latency | FIFO depth, arbitration, memory service, CDC phase and the local-hit optimization affect observations. Architectural state codes are not cycle counts. |
| Passing the described simulations proves all legal Arm programs | The recorded examples and assertions provide evidence for their scope. They are not exhaustive formal proof, system coherency sign-off or CDC metastability analysis. |

### 27.3 Scope of this review update

This update fills operation-level explanation gaps with exact-length/tail, zero-fill, stride, flush, multi-waiter, code-publication and sleep/restart flows. It also adds explicit instruction execution contracts and channel/manager state entry/hold/exit conditions. Two source-sensitive details are clarified: endian programming must satisfy the Arm source rules as well as destination legality checks, and the supplied manual's general abort list and field-specific st_data_unavailable classification have different wording. It adds worked arithmetic and protocol sequencing without changing the RTL, existing testbenches or saved timing data.

New explanatory code layouts are labeled as examples rather than claimed as newly simulated programs. Existing waveform links continue to reference their recorded source runs and byte-value tables. Future RTL changes should trigger a new source-baseline check and waveform regeneration before treating this documentation as timing evidence for the new revision.
