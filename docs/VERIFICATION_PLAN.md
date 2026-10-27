# AXI DMA Controller `axi_dma330` — Verification Plan

| Mục | Giá trị |
|---|---|
| DUT | `axi_dma330` (RTL trong `rtl/`) |
| Phương pháp | UVM-1.2, constrained-random + directed, coverage-driven, SVA, reference model |
| Simulator | QuestaSim 10.7c (UVM-1.2 precompiled) |
| Tài liệu liên quan | [DESIGN_SPEC.md](DESIGN_SPEC.md) (đặc tả), [TESTCASES.md](TESTCASES.md) (chi tiết từng test), [CMODEL.md](CMODEL.md) (C model qua DPI-C) |
| Phiên bản | 1.5 (test cache coherency theo thread, unit RTL và mutation cache/write). 1.4 (kiểm chứng các bản sửa theo TRM DMA-330 r1p2: lệnh `S` một beat, `DMAWFP S/B`, tách 4 KB, load-lock + lock-up chính xác, barrier `DMAFLUSHP`, `CCR` của kênh NS, tag NS của I-cache, mã lỗi, thuộc tính AXI, EXOKAY, `PERIPH_ID`, reset `CCR`, debug khi manager chờ, reset CDC từng domain). 1.3: MFIFO dùng chung, security. 1.2: C reference model qua DPI-C và chương trình ngẫu nhiên cấp ISA. 1.1: bảo vệ AXI, endian swap, watchdog, FAR, Q-Channel, PSLVERR |

---

## 1. Mục tiêu và phạm vi

### 1.1 Mục tiêu

1. Chứng minh DUT thực hiện đúng đặc tả trong `DESIGN_SPEC.md`:
   * tập lệnh DMA-330;
   * dữ liệu chuyển đúng tới từng byte, đúng strobe và thuộc tính AXI;
   * giao thức AXI4, APB, peripheral;
   * event/interrupt, xử lý lỗi, kill, boot, reset.
2. Chứng minh DUT hoạt động trong cả hai cấu hình clock là **sync** và **async**. Cấu hình async bật mọi CDC bridge với tỉ lệ clock không nguyên.
3. Đạt tiêu chí sign-off ở mục 9. Mọi mục chưa phủ phải được phân tích và chứng minh là không thể tới được.

### 1.2 Trong phạm vi

| Nhóm | Nội dung |
|---|---|
| Register | Reset value, quyền truy cập, register map, ID, giá trị cấu hình, địa chỉ không được map |
| ISA | Toàn bộ lệnh kênh và manager, mọi biến thể điều kiện, vòng lặp lồng nhau |
| Datapath | Mọi kích thước beat (1–8 B), độ dài burst (1–16), alignment, INCR/FIXED, độ dài truyền 1 B..4 KB, MFIFO admission |
| AXI | Back-pressure, latency ngẫu nhiên, phản hồi out-of-order giữa các ID, R xen kẽ, SLVERR/DECERR/EXOKAY, tách burst vượt 4 KB, `AxPROT`/`AxCACHE` của dữ liệu và instruction fetch |
| Peripheral | Single/burst/flush, `drlast`, ack đọc/ghi, flush, request trong lúc flush, flush ack thừa, back-pressure `drready`, hai kênh dùng chung một peripheral, `DMAWFP S/B/P`, flush sau ack, reset riêng domain peripheral |
| Event/IRQ | Đồng bộ giữa các thread, event sticky, nhiều thread cùng chờ, chế độ interrupt so với event, `INTCLR`, debug `DMASEV` |
| Manager | Boot từ PC, NS/secure, `dmago_err`, lệnh debug hợp lệ và không hợp lệ, lệnh debug khi manager chờ event |
| Fault | Mọi bit `FTRn`/`FTRD` có thể sinh ra, cách ly lỗi, phục hồi |
| Kill | Kill khi đang truyền, khi cache miss, khi chờ peripheral, khi chờ event, kill kênh đã dừng |
| Reset | Reset giữa lúc đang truyền, giá trị sau reset, chạy lại sau reset |
| CDC | Toàn bộ đường qua domain (APB, AXI, peripheral), kiểm tra ở mức mô phỏng + SVA |
| Bảo vệ giao thức | Endian swap không thực hiện được, kênh NS yêu cầu truy cập secure → `ch_rdwr_err`, không có giao dịch nào ra bus |
| Endian swap | 16/32/64 bit trên copy ngẫu nhiên (kể cả nhóm rộng hơn beat), so dữ liệu bit-exact |
| MFIFO | Load-lock, chờ chỗ, dead-lock giữa các kênh (`lockup_err` / chỉ báo khi `irq_only`), self lock-up (`mfifo_err`) |
| Watchdog | Bus treo → `lockup_err`/`WDSTAT`/`irq_abort`; chế độ chỉ báo; không báo nhầm khi chờ event/peripheral hay khi tải nặng; tắt |
| Báo lỗi | `FARn` cho lỗi đọc, ghi, fetch; xóa bởi `DMAGO` |
| Chương trình ngẫu nhiên | Vòng lặp lồng LC0/LC1, `DMAADDH` bước nhảy lớn, `DMAADNH`, FIXED + không align hai phía, endian swap, `AxPROT/AxCACHE` ngẫu nhiên, quay vòng `SAR`/`DAR` ở đỉnh không gian 32 bit; kỳ vọng do C model tính |
| Trạng thái kiến trúc | `CPC`, `SAR`, `DAR`, `CCR`, `LC0`, `LC1` cuối mỗi job so với C model |
| Low power | Q-Channel: accept khi rảnh, deny khi bận / đang chờ peripheral, tắt clock, đánh thức bằng APB, lõi im lặng khi quiescent |
| APB error | `PSLVERR` cho địa chỉ không tồn tại và ghi vào thanh ghi RO (cấu hình async), không bao giờ có `PSLVERR` (cấu hình sync) |

### 1.3 Ngoài phạm vi (phiên bản này)

| Mục | Ghi chú |
|---|---|
| Cấu hình tham số khác mặc định (`DATA_W` 32/128, `NUM_CH` 1/8, `MFIFO_LINES` khác) | RTL có tham số hóa; TB đã tham số hóa qua `dma_tb_params_pkg` nhưng regression chỉ chạy cấu hình mặc định. Đây là kế hoạch tiếp theo, xem 10.2 |
| CDC structural/formal (Questa CDC, Spyglass) | Hiện mới có kiểm tra CDC bằng mô phỏng và SVA |
| Gate-level simulation, STA, power | |
| Hiệu năng (bandwidth/latency) có số liệu mục tiêu | Chỉ kiểm tra chức năng dưới tải nặng |

---

## 2. Chiến lược

| Kỹ thuật | Áp dụng |
|---|---|
| **Constrained random** | Mỗi "job" (một chương trình DMA) được random: loại job, địa chỉ, độ dài, beat size/len hai phía, INCR/FIXED, prot/cache, tham số 2D, peripheral, số request. Chương trình được sinh tự động bởi `dma_prog_gen` theo cách một driver phần mềm làm |
| **Directed** | Các kịch bản cần thứ tự hoặc thời điểm chính xác: fault, kill, event, boot, reset, góc cạnh peripheral |
| **Reference model + scoreboard** | Dự đoán từng burst AXI (địa chỉ, len, size, burst, cache, prot, strobe, dữ liệu) và chuỗi ack peripheral; so sánh bit-exact |
| **C reference model (DPI-C)** | ISS viết bằng C, giải mã chính byte code trong bộ nhớ. Đối chiếu với dự đoán của generator ở mọi job, so thanh ghi kiến trúc cuối job, và là bộ dự đoán duy nhất cho chương trình ngẫu nhiên cấp ISA (`JOB_RAND`). Chi tiết ở [CMODEL.md](CMODEL.md) |
| **SVA** | Giao thức AXI/APB/peripheral ở biên DUT, bất biến nội bộ (FIFO, MFIFO, CDC, datapath, kênh) được bind vào mọi instance |
| **Kiểm tra trong sequence** | Trạng thái thanh ghi (`CSR`, `FTR`, `FSRC`, `DSR`, `CPC`, `INT_EVENT_RIS`), thời điểm (event ordering), `irq`/`irq_abort` |
| **Coverage** | Code coverage RTL (statement, branch, FEC condition/expression, FSM) + functional covergroup + cover directive |
| **Ma trận cấu hình** | Mọi test chạy ở cả `sync` và `async`, nhiều seed. Có thêm các profile AXI (`fast`/`default`/`slow`) và tắt reorder |
| **Mutation testing** | Cấy lỗi vào RTL để đánh giá khả năng phát hiện lỗi của testbench |

---

## 3. Kiến trúc testbench

```
 tb_top
  ├─ clock/reset gen: aclk 200 MHz (lõi + AXI; nhánh vào DUT có thể bị gate); async: APB 79 MHz, periph 122/92/74/61 MHz
  ├─ DUT axi_dma330 #(APB_ASYNC=PERIPH_ASYNC=ASYNC)
  ├─ protocol SVA: axi4_master_sva, apb_slave_sva x2 (cổng S, NS), dma_periph_sva[p]
  ├─ dma_sva_bind (white-box checkers)
  └─ uvm_test
      └─ dma_env
          ├─ apb_agent (cổng secure: driver, monitor + cg_apb) ── apb_reg_adapter ── dma_reg_block (RAL)
          │                                         uvm_reg_predictor (explicit prediction)
          ├─ apb_ns agent (cổng non-secure: truy cập thô apb_rd/apb_wr, dbg_exec_ns)
          ├─ axi_agent: axi_slave_driver (reactive memory slave), axi_monitor, axi_coverage
          │      └─ axi_mem_model (bộ nhớ thưa, dùng chung với scoreboard)
          ├─ periph_agent[p]: periph_driver, periph_monitor + cg_periph
          ├─ dma_scoreboard (reference model) ◄── dma_cmodel ◄─DPI-C─ model/dma330_ref (ISS)
          ├─ dma_coverage (cg_job, cg_insn, cg_fault)
          └─ dma_virtual_sequencer (apb_sqr, apb_ns_sqr, per_sqr[], rm, sb, cov, cfg, dbg_lock)
```

### 3.1 VIP tự xây dựng

| VIP | Vai trò | Tính năng |
|---|---|---|
| `apb` (`tb/vip/apb`) | APB requester | Driver APB4; monitor đo số wait state; coverage `cg_apb` (đọc/ghi × wait 0 / 1–3 / ≥4, `pslverr`); RAL adapter; sequence `apb_read_seq`/`apb_write_seq` |
| `axi` (`tb/vip/axi`) | AXI4 slave phản ứng + bộ nhớ | `READY` ngẫu nhiên theo xác suất cho AW/W/AR; latency B/R ngẫu nhiên; khoảng trống giữa các beat R; **phản hồi out-of-order giữa ID**; **R xen kẽ giữa ID**; vùng địa chỉ trả SLVERR/DECERR, chọn riêng cho đọc/ghi; **vùng "stall"** giữ phản hồi B/R vô thời hạn (mô phỏng slave bị treo); profile `set_fast/default/slow`; monitor dựng lại transaction (AW+W+B, AR+R); coverage `cg_burst` |
| `periph` (`tb/vip/periph`) | Peripheral kiểu DMA-330 | Driver gửi request single/burst/flush-ack, có `drlast`; tự trả flush ack (`auto_flush_ack`); chờ ack trước request kế tiếp (`wait_ack`); `daready` ngẫu nhiên (`daready_pct`); gửi lại request bị DMA bỏ khi flush; monitor + `cg_periph` |

Bảng knob (cấu hình) của VIP:

| Knob | Mặc định | Ghi chú |
|---|---|---|
| `axi_cfg.aw/w/ar_ready_pct` | 70 | `fast` = 100, `slow` = 30 |
| `axi_cfg.b_lat`, `r_lat` | 1–8, 1–10 | `fast` = 0–1, `slow` = 2–30 |
| `axi_cfg.r_gap_pct` | 15 | `fast` = 0, `slow` = 40 |
| `axi_cfg.reorder_en`, `interleave_en` | 1, 1 | `+NO_REORDER` tắt cả hai |
| `axi_cfg.err_regions` | rỗng | Do test fault/boot_err thêm vào |
| `per_cfg[p].daready_pct` | 70 | stress = 30 |
| `per_cfg[p].wait_ack` | 1 | Test góc cạnh tắt để gửi request dồn dập |
| `per_cfg[p].auto_flush_ack` | 1 | Test góc cạnh tắt để chèn request vào giữa lúc flush |

### 3.2 Thành phần mô hình hóa DMA

| Thành phần | File | Vai trò |
|---|---|---|
| `dma_reg_block` | `tb/env/dma_reg_model.sv` | RAL: mọi thanh ghi, reset value và giá trị `CR0`/`CR1`/`CRD`/ID tính theo tham số DUT |
| `dma330_asm` | `tb/env/dma330_asm.sv` | Assembler DMA-330: sinh byte code, tự tính jump của vòng lặp, có listing để debug |
| `dma_job` | `tb/env/dma_job.sv` | Đơn vị stimulus và dự đoán: các knob random + chương trình + danh sách op (LD/ST/STZ) + chuỗi ack kỳ vọng |
| `dma_prog_gen` | `tb/env/dma_prog_gen.sv` | Đóng vai driver: cắt burst (một nửa số burst INCR được phép vượt 4 KB để DMA tự tách; `cross_4k` ép luôn vượt; xử lý phần lẻ), xen kẽ LD/ST để MFIFO không bao giờ underrun hay lock-up, sinh 9 loại chương trình; job NS luôn có `x_prot[1] = 1` |
| `dma_scoreboard` | `tb/env/dma_scoreboard.sv` | Reference model và checker (mục 4.1) |
| `dma330_ref` | `model/dma330_ref.{h,c}`, `model/dma330_dpi.c` | C reference model (ISS của một channel thread), DPI-C. Test độc lập `dma330_ref_test.c` (173 kiểm tra) |
| `dma_cmodel` | `tb/env/dma_cmodel.sv`, `tb/dpi/dma330_dpi_pkg.sv` | Wrapper SV: chạy chương trình trong bộ nhớ qua model, đổi sự kiện thành `axi_txn` kỳ vọng và trạng thái thanh ghi cuối |
| `dma_rand_prog` | `tb/env/dma_rand_prog.sv` | Sinh chương trình ngẫu nhiên cấp ISA (`JOB_RAND`); model quyết định chương trình nào hợp lệ |
| `dma_ctrl_if` | `tb/env/dma_ctrl_if.sv` | `irq`, `irq_abort`, chân boot, reset mềm (`pulse_reset`), reset riêng một domain (`pulse_periph_reset`, `pulse_pclk_reset`), `wait_clks`; **mô hình clock controller Q-Channel** (`q_request`, `q_release`, `gate_clock`) điều khiển clock gate (latch) của clock lõi DUT trong `tb_top` |
| `dma_base_vseq` | `tb/seq/dma_base_vseq.sv` | API kiểu driver: `dbg_exec` (nguyên tử nhờ `dbg_lock`), `start_channel`, `kill_channel`, `wait_irq`, `wait_abort`, `run_job`, `dump_state` |

### 3.3 Các loại job (stimulus)

| Job | Chương trình | Mục đích |
|---|---|---|
| `JOB_M2M` | `MOV SAR/DAR`, chuỗi `MOV CCR`/`LD`/`ST` xen kẽ, `WMB`, `SEV`, `END` | Copy độ dài, alignment, hình dạng burst bất kỳ, src/dst khác nhau |
| `JOB_FILL` | `DMASTZ` | Ghi toàn số 0 |
| `JOB_LOOP2D` | `DMALP` lồng 2 cấp, `DMAADDH` (khoảng cách giữa các hàng), `DMAADNH` DAR (ghi ngược hàng) | 2D block copy |
| `JOB_M2P` | `FLUSHP`, `LP { WFP B; LD; STPB }` | Memory → peripheral |
| `JOB_P2M` | `FLUSHP`, `LP { WFP B; LDPB; ST }` | Peripheral → memory (ack phía đọc) |
| `JOB_PERIPH_MIXED` | `LPFE { WFP P; LDS; LDB; STPS; STPB }` | Lệnh có điều kiện, `drlast` kết thúc vòng |
| `JOB_P2M_MIXED` | `LPFE(LC1) { WFP P; LDPS; LDPB; STS; STB }` | Ack đọc single/burst, mã LC1 của `DMALPFE` |
| `JOB_COND_LOOP` | `LPENDS` (điều kiện đúng → lặp), `LPENDB` (điều kiện sai → thoát sớm) | `DMALPEND` có điều kiện |
| `JOB_ISA_MIX` | `NOP`, `LP { LD; RMB; ST; ADNH SAR }`, `WMB`, `SEV`, `KILL` | Lệnh ít gặp, copy theo thứ tự ngược, kết thúc chương trình bằng `DMAKILL` |

| `JOB_RAND` | 1–4 segment copy / fill / reverse, vòng lặp 0–2 cấp, `DMAADDH/ADNH`, barrier, event dư, `END` hoặc `KILL` | Chương trình ngẫu nhiên cấp ISA, không có danh sách op: C model dự đoán |

Mọi job có thể thêm `DMAWFE e` (có thể kèm invalidate) ở đầu và `DMASEV e` ở cuối để test event.

---

## 4. Checker

### 4.1 Scoreboard / reference model

| ID | Kiểm tra |
|---|---|
| SB-01 | Mỗi burst đọc dữ liệu quan sát được khớp burst kỳ vọng kế tiếp của ID đó: `ARADDR`, `ARLEN`, `ARSIZE`, `ARBURST`, `ARCACHE`, `ARPROT` |
| SB-02 | Mỗi burst ghi khớp: `AW*` + `WDATA` + `WSTRB` từng beat. Dữ liệu kỳ vọng lấy từ byte stream của các `DMALD` trước (snapshot bộ nhớ) và đặt đúng lane |
| SB-03 | `DMASTZ`: dữ liệu bằng 0, strobe đúng |
| SB-04 | Phản hồi `OKAY` cho mọi burst của kênh không ở chế độ "ignore" (fault/kill) |
| SB-05 | Instruction fetch (`ARID` toàn bit 1) chỉ đọc trong vùng chương trình đã đăng ký, với `ARPROT[2] = ARPROT[0] = 1` (instruction, privileged) và `ARCACHE = 0110` |
| SB-06 | Chuỗi ack peripheral (`FLUSH`/`SINGLE`/`BURST`) đúng thứ tự cho từng peripheral |
| SB-07 | Hết job: không còn burst hoặc ack kỳ vọng nào chưa xảy ra. Hết test: hàng đợi kỳ vọng rỗng |
| SB-12 | Burst kỳ vọng INCR vượt 4 KB (từ generator hoặc C model) được tách thành hai burst như DMA phát (`split_4k`), kể cả dữ liệu/strobe từng beat; số burst được tách in trong báo cáo |
| SB-08 | Ghi lại thời điểm đọc đầu tiên và ghi cuối cùng của mỗi kênh, dùng cho kiểm tra thứ tự giữa các kênh (event test) |

Kiểm tra bằng C model (tắt bằng `+NO_CMODEL`):

| ID | Kiểm tra |
|---|---|
| SB-09 | `SB_XCHECK`: khi nạp job có danh sách op, C model chạy chính chương trình trong bộ nhớ; số burst đọc / ghi, thuộc tính, `WDATA`, `WSTRB` từng beat và chuỗi ack phải trùng dự đoán của generator, và chương trình phải kết thúc sạch |
| SB-10 | Job `JOB_RAND` (không có danh sách op): toàn bộ burst kỳ vọng lấy từ C model; chương trình phải kết thúc sạch |
| SB-11 | `ARCH` (trong `run_job`): sau khi kênh về Stopped, `CPC` bằng địa chỉ `DMAEND`/`DMAKILL` và `SAR`/`DAR`/`CCR`/`LC0`/`LC1` mà chương trình đã ghi bằng giá trị C model |

Thứ tự được so sánh **theo ID** (theo kênh), vì giữa các kênh không có ràng buộc thứ tự.

Khi test cố tình gây lỗi hoặc kill một kênh, scoreboard đặt kênh đó vào chế độ ignore (`ignore_channel`/`ignore_peripheral`) để bỏ qua traffic không xác định của kênh. Các kênh khác vẫn được kiểm tra đầy đủ, nhờ vậy việc cách ly lỗi cũng được kiểm chứng.

### 4.2 SVA

**Giao thức ở biên DUT** (instantiate trong `tb_top`):

| Checker | Assertion | Nội dung |
|---|---|---|
| `axi4_master_sva` | `AXI_M_NO_VALID_IN_RESET`, `AXI_M_VALID_KNOWN` | Không có VALID khi reset; VALID không phải X |
| | `AXI_M_AW/W/AR_STABLE`, `AXI_S_B/R_STABLE` | Payload và VALID giữ nguyên cho tới khi có handshake |
| | `AXI_M_AW/AR_LEN`, `_SIZE`, `_BURST` | LEN ≤ 15, SIZE ≤ độ rộng bus, BURST ∈ {FIXED, INCR} |
| | `AXI_M_AW_4KB`, `AXI_M_AR_4KB` | Burst không vượt biên 4 KB |
| | `AXI_M_W_KNOWN`, `AXI_M_WLAST_POSITION` | `WSTRB/WLAST` không X; `WLAST` đúng ở beat `AWLEN+1` (AW và W ghép theo thứ tự) |
| | cover `AXI_C_AW_BACKPRESSURE`, `AXI_C_W_BEFORE_AW`, `AXI_C_R_INTERLEAVE`, `AXI_C_FIXED_BURST` | |
| `apb_slave_sva` | `APB_M_SETUP_TO_ACCESS`, `APB_M_ENABLE_NEEDS_SEL`, `APB_M_STABLE`, `APB_M_ENABLE_DROP` | Giao thức phía requester |
| | `APB_S_READY_BOUNDED`, `APB_S_RDATA_KNOWN`, `APB_S_NO_SLVERR` | DUT luôn trả `PREADY` trong thời gian giới hạn; `PRDATA` không X; không có `PSLVERR` |
| | cover `APB_C_WAIT_STATE` | Có wait state (cấu hình async) |
| `dma_periph_sva` | `PER_M_DR_STABLE`, `PER_M_DR_TYPE` | Request ổn định; `drtype ≠ 11` |
| | `PER_S_DA_STABLE`, `PER_S_DA_TYPE`, `PER_S_DA_KNOWN` | Ack ổn định; `datype ≠ 11`; không X |
| | cover `PER_C_FLUSH`, `PER_C_BURST_ACK`, `PER_C_SINGLE_ACK` | |

**White-box** (`dma_sva_bind`, bind vào mọi instance):

| Module | Assertion | Nội dung |
|---|---|---|
| `dma_sync_fifo` | `FIFO_NO_OVERFLOW`, `FIFO_NO_UNDERFLOW` | Mọi queue/tracker/ack queue |
| `dma_mfifo` | `MFIFO_ALLOC_HAS_LINE`, `MFIFO_NO_UNDERFLOW`, `MFIFO_PUSH_NONZERO`, `MFIFO_LINES_OWNED`, `MFIFO_OFF_HAS_LINE`, `MFIFO_BYTES_FIT`; cover `MFIFO_C_FULLISH`, `MFIFO_C_POOL_FULL` | Push cần line mới luôn có line trống; chỉ pop byte đang có; mỗi line đang dùng thuộc đúng một danh sách; byte lưu nằm gọn trong line của kênh |
| `dma_datapath` | `DP_POOL_NOT_OVERCOMMITTED`, `DP_LINES_RESERVED`, `DP_LOCKUP_ONLY_ON_LOAD`, `DP_DLOCK_ONLY_ON_LOAD`, `DP_LOADLOCK_OWNER`, `DP_ONE_LOAD`; cover `DP_C_WAIT_FOR_SPACE`, `DP_C_DEADLOCK`, `DP_C_LOCK_WAIT` | Tổng line đặt chỗ ≤ `MFIFO_LINES`; line thật của kênh ≤ line đã đặt; lock-up chỉ báo cho `DMALD` đang thực thi; chỉ chủ load-lock (hoặc ai cũng được khi lock rảnh) được nhận load, mỗi chu kỳ một load |
| `dma_cdc_handshake` | `CDC_DATA_STABLE`, cover `CDC_C_TRANSFER` | Payload ổn định khi qua domain |
| `dma_rd_engine` | `RD_BEAT_HAS_BURST`, `RD_RLAST_POSITION` | Mỗi beat R thuộc về một burst đang bay; `RLAST` đúng ở beat cuối |
| `dma_channel` | `CH_ONE_REQ`, `CH_NO_REQ_FLUSHING`, `CH_FAULT_FLUSHES` | Không phát LD và ST cùng lúc; không phát request khi đang flush; kênh lỗi luôn bật flush |
| `dma_wr_engine` | `WR_W_NEEDS_BURST`, `WR_AW_NEEDS_BURST` | AW/W chỉ xuất hiện khi có burst đang chạy |

**Q-Channel** (`dma_lpi_sva`, instantiate trong `tb_top`, clock không bị gate):

| Assertion | Nội dung |
|---|---|
| `LPI_D_KNOWN`, `LPI_D_ACCEPT_OR_DENY` | Output không X; không bao giờ đồng thời accept và deny |
| `LPI_D_ACCEPT_ON_REQ`, `LPI_D_DENY_ON_REQ` | `qacceptn` hạ / `qdeny` lên chỉ khi `qreqn = 0` |
| `LPI_D_EXIT_ON_REQ`, `LPI_D_DENY_RELEASE` | `qacceptn` lên / `qdeny` hạ chỉ khi `qreqn = 1` |
| `LPI_D_QUIESCENT` | Khi `qacceptn = 0`: không có `AWVALID`, `WVALID`, `ARVALID`, `DAVALID` |
| `LPI_D_APB_HELD`, `LPI_D_APB_NS_HELD` | Khi `qacceptn = 0`: không có APB transfer nào hoàn tất trên cả hai cổng (phải chờ đánh thức) |
| `LPI_C_REQ_ONLY_RUN`, `LPI_C_EXIT_ANSWERED` | Nghĩa vụ của controller (kiểm tra mô hình TB) |
| cover `LPI_C_ACCEPTED`, `LPI_C_DENIED`, `LPI_C_WAKEUP` | |

**APB**: với `APB_SLVERR = 1`, `APB_S_NO_SLVERR` được thay bằng `APB_S_SLVERR_IN_ACCESS` (PSLVERR chỉ ở pha access) và cover `APB_C_SLVERR`.

Ngoài ra, `vopt` chạy với `+acc` và mọi `** Error` trong log (kể cả từ SVA) đều làm test FAIL.

### 4.3 Kiểm tra trong sequence

Các test directed đọc thanh ghi và so với giá trị kỳ vọng: `CSRn` (status, `wakeup_number`, `CNS`), `FSRC`/`FSRD`, `FTRn`/`FTRD` (đúng bit), `CPCn` (lệnh gây lỗi), `DSR`/`DPC`, `INT_EVENT_RIS`, `INTEN` sau reset, `irq`/`irq_abort`, thứ tự thời gian (event).

---

## 5. Danh sách hạng mục kiểm chứng (verification items)

Cột "Test" dùng tên rút gọn (bỏ tiền tố `dma_` và hậu tố `_test`). Mô tả từng test ở [TESTCASES.md](TESTCASES.md).

### 5.1 Register và cấu hình

| ID | Hạng mục | Phương pháp | Test | Coverage / kiểm tra |
|---|---|---|---|---|
| VP-REG-01 | Reset value của mọi thanh ghi | `uvm_reg_hw_reset_seq` | reg | RAL |
| VP-REG-02 | Quyền truy cập RW/RO/WO, bit reserved | `uvm_reg_bit_bash_seq` | reg | RAL |
| VP-REG-03 | `CR0`/`CR1`/`CRD`/`CR2` khớp tham số và chân boot | Reset check + đọc trực tiếp | reg, boot | RAL, sequence |
| VP-REG-04 | Peripheral ID (mặc định của DUT, r1p2 `0x00341330`: TB không truyền tham số) / PrimeCell ID | Đọc | reg | RAL, `0xB105F00D` |
| VP-REG-10 | `CCRn` reset `0x0080_0200` (TRM) | Đọc sau reset | reg | sequence |
| VP-REG-05 | Địa chỉ không được map đọc về 0 | APB thô | reg | sequence |
| VP-REG-06 | `DBGCMD ≠ 0` bị bỏ qua | Directed | reg | `DBGSTATUS`, `DSR` |
| VP-REG-07 | APB qua async bridge (wait state) | Mọi test ở cấu hình async | tất cả | `APB_C_WAIT_STATE`, `cg_apb.cp_wait` |
| VP-REG-08 | `PSLVERR`: địa chỉ không map, thanh ghi của kênh không tồn tại, ghi vào RO (không có tác dụng); ghi hợp lệ không lỗi | Directed, APB thô | reg (async: `APB_SLVERR=1`, sync: `=0`) | `APB_C_SLVERR`, `cg_apb.cp_err` |
| VP-REG-09 | `WD` (bit reserved), `WDSTAT` (W1C), `FARn` reset 0 | RAL reset + bit-bash | reg | RAL |

### 5.2 Tập lệnh

| ID | Hạng mục | Test | Coverage |
|---|---|---|---|
| VP-ISA-01 | `DMAMOV SAR/DAR/CCR`, `DMALD`, `DMAST`, `DMAWMB`, `DMASEV`, `DMAEND` | mọi test traffic | `cg_insn` |
| VP-ISA-02 | `DMASTZ` | fill, stress | `cg_insn.I_STZ` |
| VP-ISA-03 | `DMALP`/`DMALPEND` LC0, LC1, lồng nhau | loop2d, isa | `cg_insn.I_LP/I_LPEND` |
| VP-ISA-04 | `DMAADDH` SAR/DAR, `DMAADNH` SAR/DAR | loop2d, isa | `cg_insn.I_ADDH/I_ADNH` |
| VP-ISA-05 | `DMANOP`, `DMARMB`, `DMAKILL` kết thúc chương trình | isa, boot | `cg_insn.I_NOP/I_RMB/I_KILL` |
| VP-ISA-06 | Lệnh có điều kiện `S`/`B` (LD, ST, LDP, STP, LPEND); dạng `S` chuyển một beat (`AxLEN = 0`), scoreboard kiểm độ dài | periph, periph_corner (6), stress | `cg_insn`, branch `cond_ok`, SB-01/02 |
| VP-ISA-07 | `DMALPFE` LC0/LC1 + `drlast`; `DMAWFP B` xóa `request_last` dù request có `drlast` | periph, periph_corner (8) | branch `req_last` |
| VP-ISA-08 | `DMAWFP S/B/P` (TRM 2.6.5): B bỏ request single và chờ tiếp; S đi tiếp với request burst và để nó lại cho `DMAWFP` sau | periph, periph_corner (5, 6) | `CSR[14]/[15]`, `SAR` |
| VP-ISA-09 | `DMAWFE` (kể cả invalidate), `DMASEV` | event | `cg_insn.I_WFE` |
| VP-ISA-10 | `DMAFLUSHP` (chỉ kênh), là barrier: flush không vượt trước ack `DMASTPB` trước đó | periph, periph_corner (7) | `PER_C_FLUSH`, thứ tự ack SB-06 |
| VP-ISA-11 | `DMAGO` secure/NS | mọi test, boot | `dmago_err` |
| VP-ISA-12 | Lệnh vắt qua hai cache line | traffic (chương trình dài), fault (straddle) | FSM `F_NEXT` |

### 5.3 Datapath và AXI

| ID | Hạng mục | Test | Coverage |
|---|---|---|---|
| VP-DP-01 | Beat size 1/2/4/8 B, phía nguồn × phía đích | m2m_unaligned, multi_ch | `cg_job.x_size` |
| VP-DP-02 | Burst len 1, 2–4, 5–15, 16 | m2m_* | `cg_job.cp_src/dst_len`, `cg_burst.x_dir_len_size` |
| VP-DP-03 | Địa chỉ không align ở nguồn/đích (mọi tổ hợp) | m2m_unaligned | `cg_job.x_align`, `cg_burst.x_dir_align` |
| VP-DP-04 | INCR/FIXED mọi tổ hợp src × dst | fixed_addr | `cg_job.x_inc`, `AXI_C_FIXED_BURST` |
| VP-DP-05 | Độ dài truyền 1–8 B, 9–128, 129–1024, > 1024 | traffic | `cg_job.cp_bytes` |
| VP-DP-06 | Beat hẹp (narrow) | m2m_unaligned | `cg_burst.cp_narrow` |
| VP-DP-07 | Nhiều kênh truyền song song, phân xử AR/W | multi_ch, stress | branch arbiter |
| VP-DP-08 | MFIFO đầy, LD bị chặn chờ chỗ | stress, mfifo_share | `MFIFO_*`/`DP_*` assertion, branch `fits` |
| VP-DP-09 | Write chỉ bắt đầu khi đủ dữ liệu | mọi test | `WR_*` assertion, scoreboard |
| VP-AXI-01 | Back-pressure AW/W/AR, latency B/R | mọi test (default), stress (slow) | `AXI_C_AW_BACKPRESSURE` |
| VP-AXI-02 | Phản hồi out-of-order giữa ID | multi_ch, stress | scoreboard theo ID |
| VP-AXI-03 | R xen kẽ giữa ID | multi_ch, stress | `AXI_C_R_INTERLEAVE` |
| VP-AXI-04 | W đi trước AW | mọi test | `AXI_C_W_BEFORE_AW` |
| VP-AXI-05 | `AxPROT` = `CCR.x_prot`; `ARCACHE = {0, src_cache}`, `AWCACHE = {dst_cache[2], 0, dst_cache[1:0]}`; instruction fetch `ARPROT = 1x1`, `ARCACHE = 0110` | traffic, boot, mọi test (fetch) | scoreboard SB-01/02, `SB_IFETCH` |
| VP-AXI-06 | SLVERR/DECERR/EXOKAY ở đọc, ghi; SLVERR ở fetch | fault, boot_err | `cg_burst.cp_resp`, `cg_fault` |
| VP-AXI-07 | Không burst nào vượt 4 KB trên bus | mọi test | `AXI_M_*_4KB` |
| VP-AXI-08 | Burst đọc/ghi vượt 4 KB được tách thành hai burst (TRM 2.10.5); ack `DMALDP`/`DMASTP` theo burst sau | m2m_unaligned (job có hướng từ `0x…FC0`/`0x…FC5`), mọi test M2M/fill (generator cho phép vượt với xác suất 1/2) | scoreboard `split_4k` (số burst được tách in trong báo cáo), `AXI_M_*_4KB` |
| VP-DP-10 | Endian swap 16/32/64 bit, scoreboard đảo byte theo stream; kể cả nhóm rộng hơn beat (dst INCR) | endian | `cg_job.cp_swap`, số job "group wider than the beat" |
| VP-DP-11 | Endian swap không thực hiện được (INCR không chứa trọn nhóm, FIXED beat hẹp hơn nhóm, nhóm rộng hơn bus, `DAR` không align) → `ch_rdwr_err` | fault | `cg_fault.rdwr_err` |
| VP-DP-12 | `DMASTZ` bỏ qua trường swap (kể cả giá trị 5–7, `DAR` không align) | endian | scoreboard |
| VP-MF-01 | MFIFO dùng chung: một kênh load 7/8 pool (896 B, gấp 3.5 lần phần chia tĩnh cũ) trước khi store, align và không align | mfifo_share (1) | so bộ nhớ, `MFIFO_C_FULLISH` |
| VP-MF-02 | `DMALD` không vừa vì kênh khác giữ pool thì chờ, không lỗi; chạy tiếp khi kênh kia giải phóng | mfifo_share (2) | `DP_C_WAIT_FOR_SPACE`, `CSR`/`CPC`/`FSRC` |
| VP-MF-03 | Dead-lock hai kênh (A giữ line rồi chờ load-lock, B giữ load-lock và chờ chỗ, không store) → cả hai `lockup_err`, `CPC` tại `DMALD`; kênh thứ ba đang chờ nhưng không giữ line thì không bị lỗi và chạy xong; pool trống lại, mọi kênh chạy được | mfifo_share (3) | `DP_C_DEADLOCK`, `cg_fault.lockup_err` |
| VP-MF-06 | Dead-lock với `WD.irq_only = 1`: chỉ `WDSTAT` (đúng hai kênh) + `irq_abort`, không kênh nào abort; `DMAKILL` + W1C hạ `irq_abort` | mfifo_share (4) | `WDSTAT`, `FSRC` |
| VP-MF-07 | Load-lock (TRM 2.11.4): ba kênh, mỗi kênh load hơn nửa pool trước khi store (thỏa quy tắc tĩnh + động của TRM) → cả ba chạy xong, không lỗi | mfifo_share (5) | `DP_LOADLOCK_OWNER`, `DP_C_LOCK_WAIT`, so bộ nhớ |
| VP-MF-04 | Self lock-up: một kênh load nhiều hơn toàn bộ pool mà không store → `mfifo_err` | fault | `cg_fault.mfifo_err` |
| VP-MF-05 | Kênh có stream rỗng trả line dùng dở và bắt đầu lại ở offset 0; line của kênh bị flush/kill về pool | mọi test traffic (không align), kill, fault | `DP_LINES_RESERVED`, `MFIFO_LINES_OWNED` |

### 5.4 Peripheral

| ID | Hạng mục | Test | Coverage |
|---|---|---|---|
| VP-PER-01 | Memory → peripheral, ack burst khi có B | periph, stress | `PER_C_BURST_ACK`, SB-06 |
| VP-PER-02 | Peripheral → memory, ack khi RLAST | periph | SB-06 |
| VP-PER-03 | Ack single | periph | `PER_C_SINGLE_ACK` |
| VP-PER-04 | Flush request / flush ack | periph | `PER_C_FLUSH` |
| VP-PER-05 | Flush ack khi DMA không yêu cầu bị bỏ qua | periph_corner | branch `flushing` |
| VP-PER-06 | Request dồn dập → `drready = 0` | periph_corner | branch `dr_ready` |
| VP-PER-07 | Request đến trong lúc flush bị bỏ | periph_corner | `SAR` không đổi |
| VP-PER-08 | Hai kênh chờ cùng một peripheral | periph_corner | branch `grant_wfp` |
| VP-PER-11 | Reset riêng một domain peripheral (sau số transfer lẻ mỗi chiều): không request ảo tới `DMAWFP`, không ack ảo tới peripheral | periph_corner (9), async | `CSR`, SB-06 |
| VP-PER-09 | Back-pressure `daready` | stress (`daready_pct = 30`) | ack queue đầy |
| VP-PER-10 | Peripheral ở domain clock riêng | async | `CDC_*` |

### 5.5 Event và interrupt

| ID | Hạng mục | Test |
|---|---|---|
| VP-EVT-01 | `DMAWFE`/`DMASEV` giữa hai kênh: kênh chờ chỉ đọc sau khi kênh báo đã ghi xong | event (part 1) |
| VP-EVT-02 | Một `DMASEV` debug thả hai kênh cùng chờ | event (part 2) |
| VP-EVT-03 | Event sticky: `DMASEV` trước `DMAWFE` | event (part 3) |
| VP-EVT-04 | Event cấu hình interrupt không thả `DMAWFE`; `INTCLR`, đổi `INTEN` | event (part 4) |
| VP-EVT-05 | `irq[n]` báo hoàn tất job, `INTCLR` | mọi test traffic |
| VP-EVT-06 | Manager `DMAWFE`/`DMASEV` | boot |
| VP-EVT-07 | `DMAWFE` có invalidate cache | event (part 3) |

### 5.6 Manager, boot, security

| ID | Hạng mục | Test |
|---|---|---|
| VP-MGR-01 | Boot từ PC, manager NS, chương trình gồm NOP, GO×2, WFE×2, SEV, END/KILL | boot |
| VP-MGR-08 | Lệnh debug (`DMASEV`) được nhận khi manager đang chờ trong `DMAWFE`; manager quay lại chờ và được chính event đó thả | boot |
| VP-MGR-02 | Kênh khởi động bởi manager NS chạy NS (`CSR.CNS`, `AxPROT[1]`) | boot |
| VP-MGR-03 | `dmago_err` (manager NS → kênh secure): `FTRD = 0x4000_0010` (bit 4, so giá trị cố định) | boot |
| VP-MGR-04 | `DMAKILL` debug tới manager đang dừng không ảnh hưởng | boot |
| VP-MGR-05 | Lỗi fetch khi boot, phục hồi | boot_err |
| VP-MGR-06 | Lệnh debug manager không hợp lệ (`DMAWFE`), `DMAGO` tới kênh không tồn tại, event sai | fault |
| VP-MGR-07 | Manager lỗi bỏ qua mọi lệnh debug trừ `DMAKILL` | fault |
| VP-SEC-01 | `CR3`/`CR4`/`CR0[2]`/`DSR.DNS` theo chân boot, đọc giống nhau trên hai cổng | security |
| VP-SEC-02 | Cổng NS: thanh ghi của kênh secure đọc 0, của kênh NS đọc như cổng S (`FTR`, `FAR`, `CSR`, `CPC`, `SAR`, `DAR`, `CCR`, `LC0`, `LC1`) | security |
| VP-SEC-03 | Cổng NS, manager secure: `INTEN`/`INT_EVENT_RIS`/`INTMIS`/`FSRC` đọc 0, ghi `INTEN`/`INTCLR` bị bỏ qua (TRM Table 3-1). Manager NS: `INTEN` chỉ đổi bit NS, `INT_EVENT_RIS`/`INTMIS` chỉ thấy bit NS, `INTCLR` chỉ xóa bit NS. `WD` đọc 0, ghi bị bỏ qua | security |
| VP-SEC-04 | Mỗi cổng có `DBGINST0/1` riêng | security |
| VP-SEC-05 | Lệnh debug từ cổng NS tới manager secure (`DMAGO`), kênh secure (`DMAKILL` khi đang chạy, `DMASEV`, `DMAKILL` khi Faulting) bị bỏ qua | security |
| VP-SEC-06 | Kênh NS: `DMASEV`/`DMAWFE` event secure → `ch_evnt_err`; `DMAWFP`/`DMAFLUSHP`/`DMALDP`/`DMASTP` peripheral secure → `ch_periph_err`; `DMALD`/`DMAST` với `CCR` yêu cầu truy cập secure → `ch_rdwr_err`; debug `DMASEV` event secure → `ch_evnt_err` + `dbg_instr`; `FTRn` đọc và `DMAKILL` qua cổng NS, `FSRC` trên cổng S | security |
| VP-SEC-13 | I-cache tách line secure / NS: chương trình nằm trong vùng chỉ-secure (đọc NS trả 0); kênh NS cùng địa chỉ chạy `DMAEND` (byte 0); kênh secure đang chờ, sau khi bị đánh thức không chạy line NS mà fetch lại và chạy đúng chương trình | security |
| VP-SEC-07 | Kênh NS dùng được event/peripheral NS; kênh secure dùng được mọi event/peripheral | security |
| VP-SEC-08 | Lỗi của kênh/manager secure không thấy được từ cổng NS (`FSRC`, `FTRn`, `FSRD`, `FTRD`, `DPC`) | security |
| VP-SEC-09 | Manager NS (sau reset với `boot_manager_ns = 1`): cổng NS tự chạy một job hoàn chỉnh (`DMAGO`, `INTEN`, `INTCLR`, `CSR`), scoreboard kiểm `AxPROT[1] = 1` | security |
| VP-SEC-10 | Manager NS: `DMAGO` kênh secure → `dmago_err` (từ cả hai cổng), `DMASEV` event secure → `mgr_evnt_err`, thấy và xóa được từ cổng NS; `DMASEV` event NS hợp lệ | security |
| VP-SEC-11 | Hai cổng truy cập cùng chu kỳ: cổng secure trước, cổng NS chờ (`pready_ns = 0`) | security (sync), `APB_S_READY_BOUNDED` |
| VP-SEC-12 | `PSLVERR` trên cổng NS giống cổng secure (`APB_SLVERR`) | security (async) + `APB_C_SLVERR` của `u_apb_ns_sva` |

### 5.7 Fault

| ID | Bit | Kịch bản | Test |
|---|---|---|---|
| VP-FLT-01 | FTRn[0] | Opcode `0xFF`; `DMAGO` trong kênh; lệnh debug không hợp lệ | fault |
| VP-FLT-02 | FTRn[1] | `DMAMOV` thanh ghi 3; `DMASEV 20`; `DMAWFP P7`, `DMALDP P9`, `DMASTP P9`; debug `DMASEV 20` | fault |
| VP-FLT-03 | FTRn[5] | Kênh NS dùng event secure | security |
| VP-FLT-04 | FTRn[6] | Kênh NS dùng peripheral secure | security |
| VP-FLT-05 | FTRn[7] | Burst size 16 B phía đọc / phía ghi | fault |
| VP-FLT-06 | FTRn[12] | 3 × `DMALD` 128 B liên tiếp không có store | fault |
| VP-FLT-07 | FTRn[13] | `DMAST` không có dữ liệu | fault |
| VP-FLT-08 | FTRn[16] | Fetch SLVERR; lệnh vắt sang line lỗi; lỗi ở beat đầu/cuối của line | fault |
| VP-FLT-09 | FTRn[17] | DECERR, EXOKAY khi ghi | fault |
| VP-FLT-10 | FTRn[18] | SLVERR, EXOKAY khi đọc | fault |
| VP-FLT-11 | FTRn[30] | Debug `DMANOP`, debug `DMASEV` event sai gửi tới kênh | fault |
| VP-FLT-12 | FTRD[*] | operand_invalid (kênh sai, event sai), undef, mgr_evnt_err, dmago_err, fetch_err, dbg_instr | fault, boot, boot_err |
| VP-FLT-13 | – | Kênh khác vẫn chạy đúng trong lúc có lỗi (cách ly) | fault (bystander) |
| VP-FLT-14 | – | `DMAKILL` xóa lỗi, kênh dùng lại được; `irq_abort` hạ | fault |
| VP-FLT-15 | – | `CPC` trỏ đúng lệnh lỗi | fault |
| VP-FLT-16 | – | Lệnh debug thứ hai tới kênh đang lỗi: vẫn Faulting | fault |
| VP-FLT-17 | – | Lệnh debug tới kênh không tồn tại bị bỏ qua | fault |
| VP-FLT-18 | FTRn[7] | Swap không thực hiện được (4 kiểu); kênh NS yêu cầu `ARPROT`/`AWPROT` secure | fault, security |
| VP-FLT-19 | – | `FARn` = địa chỉ beat lỗi đọc / burst lỗi ghi / PC fetch lỗi; = 0 sau job không lỗi | fault |
| VP-FLT-20 | FTRn[31] | `lockup_err` do watchdog; do dead-lock MFIFO | watchdog, mfifo_share |

### 5.7b Watchdog và low power

| ID | Hạng mục | Test |
|---|---|---|
| VP-WD-01 | Bus treo (giữ R) → `lockup_err`, `WDSTAT[n]`, `FSRC[n]`, `irq_abort`; kênh ở Fault completing cho tới khi bus trả lời; phục hồi bằng `DMAKILL` | watchdog (A) |
| VP-WD-02 | `irq_only = 1`: chỉ `WDSTAT` + `irq_abort`, không abort; transfer hoàn tất đúng dữ liệu; W1C hạ `irq_abort` | watchdog (B) |
| VP-WD-03 | Chờ event / chờ peripheral 3000 chu kỳ với timeout 512: không báo | watchdog (C) |
| VP-WD-04 | `timeout = 0`: không bao giờ báo | watchdog (D) |
| VP-WD-05 | Bật watchdog (4096 chu kỳ) suốt stress test với AXI chậm: không báo nhầm | stress |
| VP-WD-06 | Mọi kênh treo cùng lúc: mỗi kênh được báo; không báo lại khi chưa có progress | watchdog (E) |
| VP-WD-07 | Kênh treo trong lúc Killing: chỉ báo, không fault | watchdog (F) |
| VP-WD-08 | Kênh treo trong lúc Fault completing: chỉ báo, giữ loại lỗi gốc | watchdog (G) |
| VP-LP-01 | Rảnh → accept; `qactive = 0`; tắt clock; APB đánh thức (`qactive`), truy cập hoàn tất đúng | lowpower (1, 5) |
| VP-LP-02 | Đang truyền → deny; transfer không bị ảnh hưởng | lowpower (2) |
| VP-LP-03 | Kênh chờ peripheral → deny | lowpower (3) |
| VP-LP-04 | Kênh đang Faulting không cản quiescence | lowpower (4) |
| VP-LP-05 | Không có hoạt động AXI / peripheral khi quiescent | mọi test lowpower (`LPI_D_QUIESCENT`) |

### 5.8 Kill và reset

| ID | Hạng mục | Test |
|---|---|---|
| VP-KILL-01 | Kill khi đang truyền 4 KB dưới back-pressure nặng | kill |
| VP-KILL-02 | Kill khi fetch lệnh đầu tiên đang cache miss | kill |
| VP-KILL-03 | Kill khi chờ peripheral | kill |
| VP-KILL-04 | Kill khi chờ event | kill |
| VP-KILL-05 | Kill kênh đã dừng: không tác dụng | kill |
| VP-KILL-06 | Kênh dùng lại được sau kill, `FTR = 0` | kill |
| VP-RST-01 | Reset khi cả 4 kênh đang truyền | reset |
| VP-RST-02 | Sau reset: `DSR`/`CSR` Stopped, `INTEN = 0`, `irq`/`irq_abort` = 0 | reset |
| VP-RST-03 | Truyền đúng sau reset | reset |

### 5.9 CDC

| ID | Hạng mục | Phương pháp |
|---|---|---|
| VP-CDC-01 | APB async bridge (hai cổng): đọc/ghi đúng ở tỉ lệ clock 79/200 MHz | Mọi test ở cấu hình async + `CDC_DATA_STABLE`; security async cho cổng NS |
| VP-CDC-02 | Lõi chạy bằng `aclk`: không có CDC trên AXI (đã bỏ AXI async bridge) | Kiểm bằng cấu trúc (`axi_dma330` nối thẳng `dma330_core` ra cổng AXI) |
| VP-CDC-03 | Peripheral sync ở 4 clock khác nhau | periph/stress async |
| VP-CDC-04 | Reset synchronizer | Mọi test, reset test |
| VP-CDC-05 | Reset riêng một domain (v1.4): mỗi cầu CDC được reset nguyên khối ở cả hai phía. Reset `pclk` riêng sau số transfer lẻ và chẵn trên mỗi cổng APB: các lần đọc sau đó đúng, không có phản hồi ảo; reset `periph_rst_n[p]` riêng sau số transfer lẻ: không request ảo tới `DMAWFP`, không ack ảo | reg (async), periph_corner (9) | M37, M39 |

### 5.10 C reference model

| ID | Hạng mục | Phương pháp | Test | Coverage / kiểm tra |
|---|---|---|---|---|
| VP-CM-01 | Dự đoán của generator và của C model (giải mã độc lập từ byte code) trùng nhau cho mọi loại job | `SB_XCHECK` ở mọi `load_job` | mọi test chạy job, boot | SB-09 |
| VP-CM-02 | Trạng thái kiến trúc cuối job (`CPC`, `SAR`, `DAR`, `CCR`, `LC0`, `LC1`) | `check_arch_state` qua RAL | mọi test dùng `run_job` | SB-11 |
| VP-CM-03 | Chương trình ngẫu nhiên: vòng lặp lồng LC0/LC1, `DMAADDH` (kể cả imm ≥ 0x8000), `DMAADNH`, FIXED/INCR, không align hai phía, endian swap, `AxPROT/AxCACHE`, `DMASTZ` kèm swap bất kỳ | `JOB_RAND` + C model làm bộ dự đoán duy nhất | rand_prog, cmodel_mix | SB-10, `cg_insn` |
| VP-CM-04 | `SAR`/`DAR` quay vòng qua 2³² | Kernel ở `0xFFFF_F000` / `0xFFFF_E000` (kênh 0) | rand_prog, cmodel_mix | SB-10, SB-11 |
| VP-CM-05 | Model được kiểm trước khi dùng làm chuẩn | `dma330_ref_test` (known-answer tính tay từ đặc tả) chạy trong mỗi lần build, dừng nếu fail | build | 173 kiểm tra (gồm MFIFO theo line, security event/peripheral/`CCR`, lệnh `S` một beat, `DMAWFP S/B/P`, swap rộng hơn beat, `AWCACHE`) |
| VP-CM-06 | Lock-up MFIFO theo line của pool dùng chung; trường hợp phụ thuộc thời gian (offset line) được model báo `DM_EV_UNSURE` để bộ sinh loại bỏ | `dma330_ref_test` | build | `test_mfifo_lines` |

---

## 6. Mô hình coverage

### 6.1 Functional coverage

| Covergroup | Vị trí | Coverpoint / cross |
|---|---|---|
| `cg_job` | `dma_coverage` | `cp_kind` (9 loại job), `cp_ch`, `cp_src/dst_size` (0–3), `cp_src/dst_len` (1, 2–4, 5–15, 16), `cp_src/dst_off` (align/không align), `cp_src/dst_inc`, `cp_swap` (none/16/32/64), `cp_bytes` (4 khoảng); cross `x_size`, `x_align`, `x_inc` (chỉ tính job M2M) |
| `cg_insn` | `dma_coverage` | Mỗi lớp lệnh trong chương trình đã chạy (bỏ `I_UNDEF`) |
| `cg_fault` | `dma_coverage` | `cp_ch_fault` (12 bit FTRn, gồm `lockup_err`), `cp_mgr_fault` (5 bit FTRD) |
| `cg_burst` | `axi_coverage` | `cp_dir`, `cp_len`, `cp_size`, `cp_burst`, `cp_align`, `cp_narrow`, `cp_resp` (OKAY/SLVERR/DECERR); cross dir×len×size, dir×burst, dir×align |
| `cg_apb` | `apb_monitor` | `cp_kind` (R/W), `cp_wait` (0, 1–3, ≥4), `cp_err`; cross kind×wait |
| `cg_periph` | `periph_monitor` | `cp_dir` (req/ack), `cp_req` (single/burst/flush_ack), `cp_ack` (single/burst/flush), `cp_last` |

### 6.2 Code coverage

* Chỉ instrument RTL: `+cover=bcesf` cho các DU trong `rtl/`. VIP và UVM không được instrument.
* Loại trừ tự động: `-coverexcludedefault` (nhánh `default` của case không thể tới) và `-nofsmresettrans` (chuyển trạng thái FSM do reset bất đồng bộ).
* Mục tiêu theo design unit:
  * statement 100 %;
  * branch ≥ 98 %;
  * FSM state/transition 100 %;
  * FEC condition/expression ≥ 90 %.
  * Phần còn thiếu phải có lý do (mục 9.3).

### 6.3 Cover directive

`AXI_C_*`, `APB_C_WAIT_STATE`, `APB_C_SLVERR`, `PER_C_*`, `MFIFO_C_*`, `DP_C_*`, `CDC_C_TRANSFER`, `LPI_C_*`.

---

## 7. Cấu hình chạy

| Cấu hình | Tham số DUT | Clock |
|---|---|---|
| `sync` | `APB_ASYNC = PERIPH_ASYNC = 0`, `APB_SLVERR = 0` | Mọi giao diện ở 200 MHz |
| `async` | cả 2 bằng 1, `APB_SLVERR = 1` | `aclk` (lõi + AXI) 200 MHz, APB 79.4 MHz, peripheral 122 / 92.6 / 74.6 / 60.2 MHz |

Tham số chung: `NUM_CH=4`, `NUM_PERIPH=4`, `NUM_EVENTS=16`, `DATA_W=64`, `ID_W=4`, `MFIFO_LINES=128` (dùng chung), `IC_LINES=8`, `IC_BEATS=4`, các queue/tracker sâu 4. Chân boot mặc định: `boot_irq_ns`/`boot_periph_ns` toàn 1 (mọi event/peripheral dùng được cho cả hai thế giới); `dma_security_test` đặt `0x00FF`/`0b0011`.

Plusargs:
* `+AXI_PROFILE=fast|slow|default`;
* `+NO_REORDER`;
* `+NO_CMODEL` (tắt C model: không đối chiếu, không kiểm thanh ghi; hai test chỉ dựa vào model sẽ báo fatal);
* `+UVM_TESTNAME`, `+UVM_VERBOSITY`;
* seed qua `-sv_seed`.

---

## 8. Quy trình chạy và tiêu chí PASS

```sh
cd sim
make build                                  # vlog 1 lần + vopt cho 2 snapshot (sync, async)
make sim TEST=dma_fault_test CFG=async SEED=7
make regress JOBS=12 SEEDS=3                # regression song song
make cov                                    # regression + coverage merge + HTML
python run_regression.py -t dma_stress_test -c async --seeds 10 -j 16
```

* Trước khi compile, `run_regression.py` chạy test độc lập của C model và biên dịch `sim/dma330_ref.dll` bằng gcc (`$CC`, `PATH`, hoặc MSYS2 ucrt64); không có compiler hoặc có `--no-cmodel` thì build với `+define+DMA_NO_CMODEL` và bỏ hai test cần model.
* Compile một lần, chạy `vopt -j N` cho từng cấu hình, rồi chạy nhiều tiến trình `vsim` song song (mỗi cặp test/cấu hình/seed là một tiến trình). `vsim` nạp thư viện bằng `-sv_lib`.
* Một test **PASS** khi log có `*** TEST PASSED ***` và không có `** Error`/`** Fatal` nào. Điều kiện này bao gồm `UVM_ERROR`/`UVM_FATAL`, lỗi SVA và watchdog 10 triệu chu kỳ.
* Kết quả: `sim/logs/<cfg>/<test>_<cfg>_s<seed>.log`, bảng tổng hợp in ra console, coverage ở `sim/cov/merged.ucdb`, HTML ở `sim/cov/html/index.html`, tóm tắt ở `sim/logs/cov_summary.txt`.

---

## 9. Tiêu chí sign-off và kết quả hiện tại

### 9.1 Tiêu chí

| # | Tiêu chí | Ngưỡng |
|---|---|---|
| 1 | Regression đầy đủ (25 test × 2 cấu hình × ≥ 3 seed) | 100 % PASS |
| 2 | Không có assertion fail | 0 |
| 3 | Statement / FSM state / FSM transition (theo design unit) | 100 % (statement: ngoại lệ đã giải thích ở 9.3) |
| 4 | Branch (theo design unit) | ≥ 98 %, phần thiếu được giải thích |
| 5 | FEC condition / expression | ≥ 90 %, phần thiếu được giải thích |
| 6 | Covergroup bin | ≥ 95 %, phần thiếu được giải thích |
| 7 | Mọi hạng mục VP ở mục 5 có test và đã PASS | 100 % |
| 8 | Mutation testing: mọi lỗi cấy vào RTL bị phát hiện | 100 % |

### 9.2 Kết quả

**Bản sửa `Codex_rtl`, 2026-10-27:** 150/150 lượt UVM PASS (25 test × sync/async × seed 1–3), C model 173/173 kiểm tra PASS. Thêm `dma_cache_test`, 9 cấu hình unit RTL và kiểm tra 5 mutation cache/fetch/write. Các assertion mới kiểm tra invalidate khi END/KILL ở manager và channel. Xem [RTL_REVIEW_FIXES.md](RTL_REVIEW_FIXES.md) để biết lệnh chạy, phạm vi tham số và giới hạn xác nhận.

**Kết quả coverage lịch sử v1.4** (24 test × sync/async × 3 seed; chưa đo lại coverage sau bản sửa `Codex_rtl`):

| Chỉ số | Kết quả | Đạt |
|---|---|---|
| Regression | 144 / 144 PASS có coverage (~235 s với 4 tiến trình song song, seed 1–3) | ✔ |
| Statement | 99.90 % (1008/1009) | ✔ (dòng còn thiếu: swap 128 bit, xem 9.3) |
| Branch | 99.40 % (664/668) | ✔ |
| FEC condition | 92.81 % (155/167) | ✔ |
| FEC expression | 95.49 % (339/355) | ✔ |
| FSM state / transition | 100 % (19/19) / 100 % (28/28) | ✔ |
| Covergroup bin | 100 % (188/188) | ✔ |
| Cover directive | 100 % (45/45) | ✔ |
| Assertion | 154, 0 fail; 149 đã pass ít nhất một lần | ✔ (5 assertion vacuous, xem 9.3) |
| Mutation | 6/6 lỗi (v1.0), 9/9 lỗi (v1.1), 4/4 lỗi (v1.2, C model), 12/12 lỗi (v1.3, MFIFO dùng chung + security), 23/23 lỗi (v1.4, khác biệt so với TRM; M13 cấy lại theo mã mới) bị phát hiện | ✔ |
| C model | `dma330_ref_test`: 173 kiểm tra, 0 fail (compile với `-Wall -Wextra` không cảnh báo) | ✔ |

Mutation cho v1.4 (`sim/run_mutation.py M17..M39`, bản sao cây thư mục, 24 test, cấu hình sync, seed 1; M37 và M39 chạy ở cấu hình async). Mỗi mutant khôi phục lại đúng một hành vi cũ mà review TRM đã chỉ ra:

| Mutant | Hành vi cũ được khôi phục | Test phát hiện |
|---|---|---|
| M13 | Kênh NS dùng được event secure (cấy lại theo mã mới) | security |
| M17 | Lệnh `S` chuyển cả burst của `CCR` | periph, periph_corner, stress, cmodel_mix |
| M18 | `DMAWFP` single/burst xử lý như `DMAWFP periph` | periph_corner |
| M19 | `DMAWFP S/B` chép `drlast` vào `request_last` | periph_corner |
| M20 | Burst vượt 4 KB không được tách | 15 test (kiểm tra burst của scoreboard, `AXI_M_*_4KB`) |
| M21 | Không có load-lock | 15 test (assertion `DP_LOADLOCK_OWNER`), mfifo_share (load-lock deadlock thật) |
| M22 | Dead-lock báo `mfifo_err`, bỏ qua `WD.irq_only` | mfifo_share |
| M23 | `DMAFLUSHP` không chờ transfer của kênh | periph_corner |
| M24 | Kênh NS yêu cầu được đọc secure | security |
| M25 | I-cache không tag NS | security |
| M26 | Bit `dmago_err` / `mgr_evnt_err` của `FTRD` đổi chỗ | boot |
| M27 | `AWCACHE = {0, dst_cache}` | 23 test (scoreboard) |
| M28 | Instruction fetch unprivileged | 23 test (`SB_IFETCH`) |
| M29 | `PERIPH_ID` cũ `0x330` | reg |
| M30 | `CCR` reset về 0 | reg |
| M31 | `EXOKAY` ở R không phải lỗi | fault |
| M32 | Swap rộng hơn beat bị từ chối | endian |
| M33 | Nhóm swap rộng hơn beat được pop từng beat | endian |
| M34 | Event ngoài phạm vi báo thêm `ch_evnt_err` | fault. Lần chạy đầu **không phát hiện**: kiểm tra chỉ đòi bit kỳ vọng được set. Đã thêm tham số `exact` cho `run_fault` (FTR phải đúng một bit) |
| M35 | Không nhận lệnh debug khi manager chờ event | boot, cmodel_mix, mfifo_share, security |
| M36 | Cổng NS thấy event NS khi manager secure | security |
| M37 | Phía core của peripheral synchronizer chỉ reset bằng `aresetn` (nối dây trước v1.4), async | periph_corner (kịch bản 9). Lần định nghĩa đầu (bỏ liên kết `aresetn` ở cả hai phía) **không phát hiện**, vì hai phía vẫn nhất quán; đã viết lại cho đúng lỗi gốc |
| M38 | `EXOKAY` ở B không phải lỗi | fault |
| M39 | Phía core của APB bridge chỉ reset bằng `aresetn`, async | reg (VP-CDC-05). Cần test reset riêng domain `pclk`, thêm ở v1.4 |

Code coverage theo design unit của khối mới ở v1.3: `dma_mfifo` 100 % statement/branch/FEC; `dma_regs` 100 % statement/branch/FEC condition, 96.97 % FEC expression; `dma_datapath` 100 % statement/branch/FEC condition. Phần FEC expression còn thiếu của `dma_datapath` là theo từng kênh (ví dụ self lock-up chỉ xảy ra ở kênh victim 1..3 của `dma_fault_test`, không ở kênh 0).

Mutation cho v1.3 (`sim/run_mutation.py`, bản sao cây thư mục, 24 test, cấu hình sync, seed 1):

| Mutant | Lỗi cấy vào RTL | Test phát hiện |
|---|---|---|
| M5 | Line đã pop hết không bao giờ về pool | 23/24 test |
| M6 | Head không chuyển sang line mới khi line duy nhất được trả và line mới được lấy trong cùng chu kỳ | endian, kill, loop2d, multi_ch, rand_prog |
| M7 | Đặt chỗ bỏ qua line đang dùng dở (đặt thiếu) | 22/24 test (SVA `MFIFO_ALLOC_HAS_LINE`, `DP_LINES_RESERVED`) |
| M8 | Kênh có stream rỗng không trả line dùng dở | mfifo_share (lần chạy đầu **không phát hiện**; đã bổ sung kênh C vào kịch bản deadlock) |
| M9 | Không bao giờ báo deadlock | mfifo_share |
| M10 | Cổng NS thấy thanh ghi của kênh secure | security |
| M11 | Ghi `INTEN` từ cổng NS đổi cả bit secure | security |
| M12 | Lệnh debug từ cổng NS tới được kênh secure | security |
| M13 | Kênh NS dùng được event secure | security |
| M14 | Một `DBGINST0` chung cho hai cổng | security |
| M15 | Cổng NS không chờ khi hai cổng truy cập cùng chu kỳ | security (kịch bản truy cập đồng thời) |
| M16 | Cổng NS thấy manager secure | security |

Mutation testing, đo khi bộ test còn 13 test (số test fail / 13):

| Lỗi cấy vào RTL | Test phát hiện |
|---|---|
| Sai phép xoay byte khi pop MFIFO | 12 / 13 |
| Sai `WSTRB` khi địa chỉ không align | 8 / 13 |
| Sai điều kiện kết thúc vòng lặp | 3 / 13 |
| Sai loại ack peripheral | 2 / 13 |
| Sai cập nhật `SAR` | 2 / 13 |
| `DMAWFE` không xóa event | 1 / 13 |

Mutation cho các tính năng của phiên bản 1.1 (test liên quan × 2 cấu hình):

| Lỗi cấy vào RTL | Test | Kết quả |
|---|---|---|
| Bỏ endian swap trên WDATA | endian | 2/2 fail |
| Bỏ kiểm tra 4 KB phía load | fault | 2/2 fail |
| Watchdog không bao giờ báo | watchdog | 2/2 fail |
| Watchdog giám sát cả trạng thái chờ event/peripheral | watchdog | 2/2 fail (báo nhầm ở phần C) |
| Watchdog abort cả kênh đang Killing / Fault completing | watchdog | 2/2 fail (phần F, G) |
| Q-Channel bỏ qua trạng thái kênh khi tính idle | lowpower | 2/2 fail |
| Không giữ `PREADY` khi quiescent | lowpower | 2/2 fail (sau khi bổ sung kiểm tra thứ tự và `LPI_D_APB_HELD`) |
| `PSLVERR` không báo khi ghi vào RO | reg | 1/2 fail (chỉ cấu hình async có `APB_SLVERR = 1`, đúng kỳ vọng) |
| `FAR` lưu sai địa chỉ cho lỗi ghi | fault | 2/2 fail |

Mutation cho C model (v1.2). Bốn lỗi được cấy vào RTL (bản sao cây thư mục), mỗi lỗi chạy 22 test ở cấu hình sync, seed 1, ở hai chế độ: **môi trường cũ** (20 test cũ, `+NO_CMODEL`) và **môi trường mới** (22 test, C model bật):

| Lỗi cấy vào RTL | Môi trường cũ | Môi trường mới (test fail) | Cơ chế phát hiện |
|---|---|---|---|
| `DMAADDH` mở rộng dấu imm16 khi bit 15 = 1 | không phát hiện | `rand_prog`, `cmodel_mix` | Bước nhảy `DMAADDH` ≥ 0x8000 chỉ có trong chương trình ngẫu nhiên (test cũ dùng gap ≤ 64) |
| Đọc `LC1` trả về `LC0` | không phát hiện | `periph`, `stress`, `cmodel_mix` | `ARCH`: so thanh ghi cuối job. Lỗi không đổi traffic bus nên scoreboard không thấy |
| `DMAKILL` trong chương trình làm `CPC` tiến lên | không phát hiện | `isa`, `stress`, `rand_prog`, `cmodel_mix` | `ARCH`: `CPC` phải đứng tại lệnh `DMAKILL` |
| Bộ cộng `SAR` chỉ có carry 31 bit (sai khi địa chỉ quay vòng qua 2³²) | không phát hiện | `rand_prog`, `cmodel_mix` | Kernel ở `0xFFFF_F000`: địa chỉ burst kế tiếp và `SAR` cuối sai |

Cả bốn lỗi đều nằm ở loại hành vi mà scoreboard dựa trên danh sách op không thể thấy (trạng thái thanh ghi) hoặc stimulus theo khuôn không bao giờ tạo ra (imm16 lớn, quay vòng địa chỉ).

Ghi chú: các mutation "watchdog không bao giờ báo" và "abort cả kênh đang Killing/Faulting" mất 200–300 s thay vì vài giây, vì test chờ `irq_abort` tới khi hết timeout 400 000 chu kỳ.

Lần chạy đầu, mutation "không giữ `PREADY`" không bị phát hiện. Testbench đã được bổ sung: truy cập APB trong lúc ngủ phải hoàn tất **sau** khi được đánh thức, lệnh ghi trong lúc ngủ không được mất, và thêm assertion `LPI_D_APB_HELD`.

### 9.3 Các mục chưa phủ (đã phân tích)

| Mục | Lý do |
|---|---|
| Opcode `0x28`/`0x2A` (`DMALPFE` LC0 không điều kiện) trong `decode_op` | `0x2A` trùng nghĩa với `0x28`, assembler không sinh ra; branch thiếu của `case` |
| `endian_swap` kiểu 128 bit (`CCR.swap = 4`) trong `dma330_pkg` | Chỉ có nghĩa khi `DATA_W = 128`; cần chạy cấu hình 128 bit (mục 10.2). Đây là statement duy nhất chưa phủ |
| `dma_periph_ctrl`: `DMAFLUSHP` được hoàn tất khi ack queue đầy (`flush_ready = 0`) | Flush chỉ được gửi sau khi mọi ack trước đã vào queue (barrier, 4.5), nên ack queue sâu 4 gần như không bao giờ đầy lúc đó; phần tử còn thiếu của một branch, hành vi back-pressure vẫn đúng theo thiết kế |
| Watchdog: bộ đếm đạt timeout rồi progress quay lại đúng chu kỳ báo, hoặc trạng thái `Stopped`/`Killing` ở các nhánh `wd_can_fault` | Cửa sổ một chu kỳ; phần tử còn thiếu của FEC condition, hành vi đã đúng theo thiết kế |
| Assertion có 0 lần pass (vacuous): `AXI_S_B_STABLE`, `AXI_S_R_STABLE`, `CDC_DATA_STABLE` ở `u_rsp_cdc` của hai APB bridge và ở `u_dr_cdc` của peripheral 3 | Điều kiện tiền đề (`bvalid && !bready`, `rvalid && !rready`, phía đích chưa nhận payload CDC) hiếm khi xảy ra vì DUT luôn sẵn sàng nhận B/R và phía lõi nhận request ngay. Không có assertion nào fail |
| Số event/peripheral ngoài phạm vi tại `dma_event_irq`/`dma_periph_ctrl` | Đã bị kênh/manager lọc thành lỗi trước đó; không thể tới được |
| APB bridge bị back-pressure / bin `cg_apb.long_w` (≥ 4 wait) | Requester chỉ phát một transfer mỗi lần; độ trễ async là 1–3 chu kỳ `pclk` |
| `PSLVERR` ở cấu hình sync | Với `APB_SLVERR = 0` DUT không bao giờ sinh `PSLVERR` (đúng đặc tả); trường hợp có lỗi được kiểm tra ở cấu hình async |
| Lỗi dữ liệu khi kênh đã ở `FAULTING` | Kênh chỉ vào Faulting khi mọi burst đã retire |
| `dbg_fault` khi kênh đang `FAULT_COMPLETING` | Cửa sổ thời gian vài chu kỳ; hành vi giống trường hợp Faulting (đã test) |
| Fetch unit: kill rồi khởi động lại trước khi response I-cache về | Đã có directed test `dma_fetch_unit_tb`: đổi PC trước response cũ, bỏ lỗi/fill cũ rồi fetch đúng PC mới |

---

## 10. Rủi ro và kế hoạch tiếp theo

### 10.1 Lỗi đã tìm thấy

| Loại | Lỗi | Phát hiện bởi |
|---|---|---|
| RTL | `DBGINST0` lưu cả bit reserved | `dma_reg_test` (bit-bash) |
| RTL | X-propagation trên `BREADY`/`RREADY` do đọc đầu tracker rỗng | SVA `AXI_M_VALID_KNOWN` / X-check |
| RTL | `WDATA` thay đổi ở lane không được strobe khi chờ `WREADY` | SVA `AXI_M_W_STABLE` |
| TB | `fixed_mode` không bao giờ sinh FIXED (`soft` thắng `dist`) | Coverage `x_inc` |
| TB | `disable <block>` trong `wait_irq` hủy cả các thread khác | Treo test multi-channel |
| TB | Ánh xạ clock sai cho mảng instance peripheral | Lỗi trong cấu hình async |
| TB | Hai `vopt` song song trên cùng thư viện làm hỏng snapshot | Regression |
| TB | `set_timeout(50ms)` bị UVM precompiled hiểu thành 50 µs | Timeout sai |
| SVA | `AXI_M_NO_VALID_IN_RESET` luôn vacuous: `default disable iff (!aresetn)` tắt đúng lúc điều kiện của nó đúng | Báo cáo assertion có 0 pass; sửa bằng `disable iff (1'b0)` riêng cho assertion này |
| TB | Mutation "không giữ `PREADY` khi quiescent" không bị phát hiện | Mutation test; bổ sung kiểm tra thứ tự APB và assertion `LPI_D_APB_HELD` |
| TB | Race khi gây lỗi manager trong lúc kênh khác dùng debug | Fault test (giải bằng `dbg_lock`) |
| TB | Trang "đỉnh bộ nhớ" dùng chung giữa các kênh: kênh này nạp lại dữ liệu ngẫu nhiên vào nguồn trong lúc kênh khác đang đọc, nên dự đoán của C model (lấy lúc nạp job) lệch dữ liệu DUT đọc thật | `dma_rand_prog_test` (SB_WR); giới hạn kernel đỉnh bộ nhớ cho một kênh |
| TB | Chuỗi/comment "v_new reset" do thay thế nhầm (đúng là "after reset") | Review môi trường (đọc code) |
| TB | `AFIFO_C_FULL` của FIFO AW (AXI async bridge, đã bỏ ở v1.3) không còn phủ sau khi thêm enum `JOB_RAND` làm đổi lời giải random của test cũ; sự kiện hiếm phụ thuộc seed | Cover directive 42/45 → profile AXI `choke` trong `cmodel_mix` đưa về 43/45 |
| RTL | v1.4, review TRM r1p2 (2026-10-25): `DMALDS`/`DMASTS`/`DMALDPS`/`DMASTPS` chuyển cả burst của `CCR` thay vì một beat | Review đối chiếu TRM (mô phỏng tái hiện); mutant M17 |
| RTL | `DMAWFP` single/burst không phân biệt loại; `DMAWFP S/B` chép `drlast` | Review TRM; M18, M19 |
| RTL | Burst INCR vượt 4 KB bị chặn bằng `ch_rdwr_err` thay vì tự tách (mọi `memcpy` ở địa chỉ bất kỳ có thể fault) | Review TRM; M20 |
| RTL | Không có load-lock: dead-lock MFIFO giữa các kênh với chương trình thỏa quy tắc dung lượng của TRM; lỗi báo `mfifo_err` thay vì `lockup_err`/`irq_only` | Review TRM; M21, M22 |
| RTL | `DMAFLUSHP` có thể vượt trước ack `DMASTP` đang chờ | Review TRM; M23 |
| RTL | Kênh NS: `AxPROT[1]` bị OR lặng lẽ thay vì lỗi `ch_rdwr_err`; I-cache dùng chung line giữa secure và NS (lỗ hổng TrustZone) | Review TRM; M24, M25 |
| RTL | `FTRD` đảo bit `dmago_err`/`mgr_evnt_err`; `AWCACHE` sai; fetch unprivileged và `ARCACHE` sai; `PERIPH_ID`, reset `CCR`; EXOKAY không là lỗi; swap hợp lệ bị từ chối; event/peripheral ngoài phạm vi báo `ch_evnt_err`/`ch_periph_err`; `DMAFLUSHP` chạy trong manager; debug không được nhận khi manager chờ event; quyền cổng NS với `INTEN`/`RIS`/`INTMIS`/`INTCLR`/`FSRC` khi manager secure | Review TRM; M26..M36, M38 |
| RTL | CDC: reset một domain không đưa toggle handshake về cùng trạng thái → transfer ảo (APB và peripheral). Đã tái hiện bằng mô phỏng ở v1.4 | Review đọc code; M37, M39 và test reset riêng domain |
| TB | Scoreboard, generator và C model được viết theo hành vi cũ (burst đầy đủ cho lệnh `S`, lỗi 4 KB, `ch_evnt_err` cho số event sai...) nên cùng "đồng ý" với RTL sai | Review TRM; cập nhật cả ba |
| TB | `run_fault` chỉ kiểm bit kỳ vọng được set, bỏ sót bit thừa | M34; thêm `exact` |
| TB | Mutant M37 định nghĩa sai (vẫn nhất quán hai phía nên không phải lỗi) | Mutation không phát hiện; viết lại, thêm M39 |

### 10.2 Việc tiếp theo

Từ review môi trường kiểm thử (2026-10-23), theo mức ưu tiên. Mục 1–3 đã làm bằng C model (xem [CMODEL.md](CMODEL.md)).

| # | Đề xuất | Trạng thái |
|---|---|---|
| 1 | Bộ dự đoán độc lập với generator (giải mã byte code) | Đã làm: C model, `SB_XCHECK` |
| 2 | Kiểm trạng thái kiến trúc cuối job (`CPC/SAR/DAR/CCR/LC0/LC1`) | Đã làm: `ARCH` |
| 3 | Chương trình ngẫu nhiên cấp ISA (vòng lặp lồng, FIXED + không align, quay vòng địa chỉ) | Đã làm: `JOB_RAND` |
| 4 | Dữ liệu nguồn ngẫu nhiên trong **mọi** test (hiện chỉ test mới dùng `randomize_region`; test cũ dùng mẫu theo địa chỉ `default_byte`) | Chưa |
| 5 | Chuỗi dữ liệu giữa kênh/job (đích của job này là nguồn của job kia), nguồn và đích chồng lấn | Chưa: vùng địa chỉ mỗi kênh tách rời |
| 6 | Ma trận tham số DUT: `dma_tb_params_pkg` là `localparam` nên `vopt -G` không đổi được; VIP AXI lại có macro `AXI_DATA_W` riêng (hai nguồn sự thật, dễ lệch). Cần một nguồn tham số duy nhất (macro hoặc package sinh tự động) | Chưa |
| 7 | Tần số và pha clock, thời điểm nhả reset theo seed (hiện cố định 200/79/122… MHz, reset nhả ở 103 ns) | Chưa |
| 8 | Coverage phía DUT thay cho phía stimulus: `cg_job` lấy mẫu knob, `cg_insn` lấy mẫu byte đã assemble. Thiếu: số kênh hoạt động đồng thời, RQ/WQ/MFIFO đầy, outstanding chạm `RD_OUT/WR_OUT`, cross trạng thái kênh × sự kiện | Chưa |
| 9 | SVA còn thiếu: `WDATA = 0` ở lane không strobe (đặc tả 4.7.4 cam kết), `WSTRB` hợp lệ theo beat, outstanding ≤ `RD_OUT/WR_OUT`, `AWLOCK = 0`, `AxCACHE[3] = 0`, ID hợp lệ | Chưa |
| 10 | Mutation testing có script và danh sách patch trong repo (các đợt v1.0/v1.1 làm thủ công trên bản sao, số liệu ghi tay) | Một phần: `sim/run_mutation.py` chạy M1..M39 (v1.2..v1.4; tùy chọn `--configs async` cho M37, M39); các lỗi v1.0/v1.1 chưa được đưa vào |
| 11 | `run_regression.py`: xuất JUnit/JSON, in lệnh tái lập seed, bắt `UVM_WARNING`; để `Makefile` gọi script thay vì lặp logic build (hiện cờ coverage chỉ có ở Python) | Chưa |
| 12 | Đưa thư mục vào git (cần cho review/CI, và `/ultrareview`) | Chưa |
| 13 | Dùng khả năng dự đoán lỗi của C model (`FTR`/`CPC` cho chương trình cố ý sai) trong một test fault ngẫu nhiên | Model đã có, chưa có test |

Các việc đã có từ trước:

1. Chạy regression với `DATA_W = 32` và `128`, `NUM_CH = 1` và `8`, `MFIFO_LINES = 32` và `1024`. TB đã tham số hóa sẵn qua `dma_tb_params_pkg`.
4. Security: `WDSTAT` từ cổng NS chưa có test directed; RTL đơn giản, đã review.
5. Cấp phát MFIFO công bằng: một `DMALD` lớn có thể bị các `DMALD` nhỏ của kênh khác vượt mặt lâu dài (không có giữ chỗ). Chưa có test đo độ trễ tối đa.
2. Chạy CDC structural bằng công cụ chuyên dụng.
3. Đo hiệu năng: băng thông với `AXI_PROFILE=fast`, độ trễ từ `DMAGO` tới AR đầu tiên.
4. Tăng số seed cho `dma_stress_test` (≥ 50) trong regression đêm.
