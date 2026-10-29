# DMA Controller Overview — From System Concepts to DMA-330 Design

**Audience:** RTL and verification engineers, firmware developers, and SoC integrators.

**Reading time:** sections 1–16 are the 20–25 minute overview. Sections 17–22 are an extended technical reference for focused study and lookup.

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

### 1.1 How to use the reference chapters

Sections 1–16 form the continuous introduction. The later chapters are intended for deeper lookup: open them when writing microcode, decoding a register value, diagnosing a transfer or reviewing a waveform. Reading every encoding table is not a prerequisite for understanding the overview.

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

## 14. Security, coherency, clocks and power

**Security:** manager state, channel state, event/peripheral permissions and AXI attributes are related but distinct. A non-secure channel cannot request a secure access through CCR. This RTL checks prohibited CCR immediates at DMAMOV before committing the new value. Secure/non-secure APB views are filtered according to the relevant manager/channel permissions. Security tags and permission checks do not replace software ownership of buffers.

**Coherency and addressing:** the driver must give the DMA addresses valid in its bus-visible address space. A CPU virtual pointer is not automatically a DMA address. Platform-specific mapping, IOMMU policy if present, cache cleaning/invalidation and barriers must establish the required visibility. This DMA's instruction cache is separate from CPU data caches; publishing executable DMA code needs the corresponding system maintenance too.

**Clock domains:** the core and external AXI interface use aclk. Optional APB and peripheral bridges cross into their respective domains. The bridges preserve request/response association; crossing latency depends on clock phase and back-pressure. Sample APB on PCLK and peripheral handshakes on the appropriate peripheral clock rather than inferring physical acceptance from a core-grid waveform.

**Reset and sleep:** resets reinitialize controller context and require coordinated endpoint handling; they do not undo memory effects. Q-Channel is a workspace extension for requesting quiescence. The external clock controller must wait for sleep acceptance before gating the DUT clock and restore it for wakeup. One stopped channel does not establish whole-core quiescence: shared cache, other channels, debug and interface work also matter.

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

P forms require a peripheral operand and generate an acknowledgement associated with successful transfer completion. A nonmatching P form does not generate the associated data transfer/acknowledgement. For LDP, acknowledgement is associated with completion of the read; for STP, with write-response retirement. Acceptance into peripheral control can precede the external DA handshake.

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

Preserve the tables and code blocks. Upload the six SVGs as attachments and retain their numbering/captions; attach matching JSON files for readers who need to edit the drawings. Replace repository-relative links with the corresponding page or attachment links when publishing. Put the Arm document revision and the RTL source-revision link near the page header so a future update does not silently mix different baselines.

The [source-revision record](waveform/operations/source_revision.json) describes the recorded waveform baseline. The [full operation index](waveform/operations/README.md) remains the place to explore cases beyond this reference chapter, including unaligned transfers, 4 KB splitting, events, sharing, cache cancellation, CDC, endian variants and low power.
