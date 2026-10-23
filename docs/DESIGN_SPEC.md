# AXI DMA Controller `axi_dma330` — Đặc tả thiết kế (Design Specification)

| Mục | Giá trị |
|---|---|
| Tên IP | `axi_dma330` (top), `dma330_core` (lõi đơn clock) |
| Tham chiếu | Arm CoreLink DMA-330 (PL330) TRM — tập lệnh, register map, giao thức peripheral |
| Ngôn ngữ | SystemVerilog-2012 (synthesizable) |
| Phiên bản tài liệu | 1.1 (thêm: bảo vệ giao thức AXI, endian swap, watchdog, FAR, Q-Channel, PSLVERR) |
| Tài liệu liên quan | [VERIFICATION_PLAN.md](VERIFICATION_PLAN.md), [TESTCASES.md](TESTCASES.md), [ARCHITECTURE.md](ARCHITECTURE.md) (tóm tắt tiếng Anh) |

Quy ước: tên tín hiệu, thanh ghi, lệnh giữ nguyên tiếng Anh. `clk` là clock lõi DMA. "Thread" là một luồng thực thi chương trình (manager hoặc channel). Số hex viết `0x...`, số bit viết `[msb:lsb]`.

---

## Mục lục

1. [Tổng quan](#1-tổng-quan)
2. [Tham số cấu hình](#2-tham-số-cấu-hình)
3. [Giao diện (port list)](#3-giao-diện-port-list)
4. [Kiến trúc](#4-kiến-trúc)
5. [Hoạt động tổng thể (global operation)](#5-hoạt-động-tổng-thể-global-operation)
6. [Programmer's model: register map](#6-programmers-model-register-map)
7. [Tập lệnh (ISA)](#7-tập-lệnh-isa)
8. [Trình tự phần mềm (software sequences)](#8-trình-tự-phần-mềm-software-sequences)
9. [Khác biệt so với Arm DMA-330 và giới hạn](#9-khác-biệt-so-với-arm-dma-330-và-giới-hạn)

---

## 1. Tổng quan

`axi_dma330` là DMA controller nhiều kênh, **điều khiển bằng chương trình** giống DMA-330. Mỗi kênh DMA (channel thread) chạy một chương trình byte-code (`DMAMOV`, `DMALD`, `DMAST`, `DMALP`, `DMAWFP`, `DMASEV`, ...) được nạp từ bộ nhớ hệ thống qua chính cổng AXI master của DMA. Một manager thread khởi động các kênh bằng lệnh `DMAGO`. CPU gửi `DMAGO` qua thanh ghi debug trên APB, hoặc manager tự chạy chương trình khởi động (boot) từ bộ nhớ.

### 1.1 Tính năng chính

| Tính năng | Mô tả |
|---|---|
| Kênh DMA | `NUM_CH` channel thread (mặc định 4, tối đa 8) + 1 manager thread |
| Cổng bus | 1 AXI4 master 32-bit address, `DATA_W` = 32/64/128 bit (mặc định 64) |
| Burst | INCR và FIXED, 1–16 beat, beat size từ 1 byte tới độ rộng bus; địa chỉ bắt đầu không cần align; beat hẹp (narrow) |
| Outstanding | Mỗi kênh tối đa `RD_OUT` burst đọc và `WR_OUT` burst ghi đang chờ phản hồi; AXI ID = số kênh |
| Thứ tự phản hồi | Hỗ trợ phản hồi out-of-order giữa các ID và R data xen kẽ (interleave) giữa các ID |
| Bộ đệm dữ liệu | MFIFO riêng cho mỗi kênh, dạng byte-stream: `MFIFO_LINES × DATA_W/8` byte (mặc định 256 B/kênh) |
| Instruction cache | Dùng chung, fully associative, `IC_LINES` line × `IC_BEATS` beat (mặc định 8 × 32 B) |
| Peripheral | `NUM_PERIPH` giao diện request/acknowledge kiểu DMA-330 (`drvalid/drtype/drlast`, `davalid/datype`) |
| Event/IRQ | `NUM_EVENTS` event/interrupt (mặc định 16) + `irq_abort` |
| Thanh ghi | APB slave 12-bit địa chỉ, register map tương thích DMA-330 |
| Security | Bit NS cho manager/kênh, kiểm tra `DMAGO` (`dmago_err`), `AxPROT[1]` |
| Clock domain | 4 loại: core, APB, AXI, mỗi peripheral một clock; CDC bridge chỉ được sinh khi bật tham số tương ứng |
| Xử lý lỗi | Phát hiện lỗi lệnh, operand, AXI SLVERR/DECERR, fetch lỗi, MFIFO lock-up; mỗi kênh lỗi bị cách ly |
| Bảo vệ giao thức AXI | Burst vượt biên 4 KB hoặc endian swap sai bị chặn ngay khi thực thi lệnh (kênh lỗi `ch_rdwr_err`), không bao giờ phát ra bus |
| Endian swap | `CCR[30:28]`: đảo byte theo nhóm 16/32/64/128 bit trên dữ liệu ghi (tương thích DMA-330) |
| Watchdog | Phát hiện kênh bị treo (bus không phản hồi), timeout lập trình được; abort kênh (`lockup_err`) hoặc chỉ báo `irq_abort` |
| Báo lỗi | `FARn`: địa chỉ của lỗi bus đầu tiên trên mỗi kênh; `WDSTAT`: kênh bị watchdog phát hiện |
| Low power | AMBA Q-Channel (`qreqn/qacceptn/qdeny/qactive`): DMA chấp nhận tắt clock khi rảnh, tự yêu cầu đánh thức khi có truy cập APB |
| APB error | Tham số `APB_SLVERR`: `PSLVERR` cho địa chỉ không tồn tại và ghi vào thanh ghi read-only |
| Kiểm tra cấu hình | Tham số sai bị báo `$fatal` ngay lúc elaboration |

### 1.2 Sơ đồ khối mức hệ thống

```
                     +---------------------------------------------------------------+
   CPU (APB) ------->|  axi_dma330                                                    |
                     |   [APB async bridge]--> dma_regs (register map, debug)         |
   irq[], irq_abort<-|                              |                                 |
                     |              manager thread --DMAGO--> channel thread[0..N-1]   |
                     |                    \                /        |                 |
                     |                     +- dma_icache -+         | LD/ST           |
                     |                            |                 v                 |
                     |                     dma_datapath: rd_engine -> MFIFO -> wr_engine
                     |                            |                                    |
                     |                    [AXI async bridge] -------------------------+--> AXI4 interconnect
                     |   dma_periph_ctrl <-[periph sync]-> dr/da  <---------------------+--> Peripheral[0..P-1]
                     +---------------------------------------------------------------+
```

---

## 2. Tham số cấu hình

| Tham số | Mặc định | Khoảng hợp lệ | Ý nghĩa / ràng buộc |
|---|---|---|---|
| `NUM_CH` | 4 | 1..8 | Số channel thread. Số kênh trong lệnh `DMAGO` chỉ có 3 bit |
| `NUM_PERIPH` | 4 | 1..32 | Số giao diện peripheral (số peripheral trong lệnh có 5 bit) |
| `NUM_EVENTS` | 16 | 1..32 | Số event/interrupt |
| `DATA_W` | 64 | 32, 64, 128 | Độ rộng dữ liệu AXI |
| `ID_W` | 4 | ≥ log2(NUM_CH+1) | Độ rộng AxID. ID toàn bit 1 dành riêng cho instruction fetch, vì vậy `NUM_CH-1 < 2^ID_W - 1` |
| `RQ_DEPTH` | 4 | 1..16 | Độ sâu read queue của mỗi kênh (số `DMALD` đã nhận nhưng chưa phát AR) |
| `WQ_DEPTH` | 4 | 1..16 | Độ sâu write queue của mỗi kênh |
| `RD_OUT` | 4 | 1..8 | Số burst đọc outstanding tối đa của mỗi kênh |
| `WR_OUT` | 4 | 1..8 | Số burst ghi outstanding tối đa của mỗi kênh (chờ B) |
| `MFIFO_LINES` | 32 | lũy thừa 2, `NUM_CH*MFIFO_LINES ≤ 1024` | Số line MFIFO của mỗi kênh; dung lượng = `MFIFO_LINES*DATA_W/8` byte |
| `IC_LINES` | 8 | 1..16 | Số line instruction cache |
| `IC_BEATS` | 4 | lũy thừa 2 | Số beat mỗi line; line = `IC_BEATS*DATA_W/8` byte (phải ≥ 8 và là lũy thừa 2) |
| `PERIPH_ID` | `0x0000_0330` | 32 bit | Giá trị trả ở `periph_id_0..3`. Đặt `0x0004_1330` nếu cần driver Linux `pl330` nhận ra |
| `APB_ASYNC` | 0 | 0/1 | 1: `pclk` khác domain với `clk`, sinh `dma_apb_async_bridge` |
| `AXI_ASYNC` | 0 | 0/1 | 1: `aclk` khác domain với `clk`, sinh `dma_axi_async_bridge` |
| `PERIPH_ASYNC` | 0 | 0/1 | 1: mỗi peripheral có clock riêng, sinh `dma_periph_sync` |
| `AFIFO_AW` | 3 | ≥ 2 | Độ sâu mỗi FIFO trong AXI async bridge = `2^AFIFO_AW` |
| `APB_SLVERR` | 0 | 0/1 | 1: trả `PSLVERR` khi truy cập địa chỉ không được map hoặc ghi vào thanh ghi read-only (truy cập đó không có tác dụng). 0: không bao giờ báo lỗi (giống DMA-330) |

Khi một tham số `*_ASYNC = 0`, clock/reset của domain đó không được dùng; nên nối chúng vào `clk`/`rst_n`.

Các tham số không hợp lệ (ví dụ `NUM_CH > 8`, `MFIFO_LINES` không phải lũy thừa 2, `ID_W` quá nhỏ, `RD_OUT > 8`) dừng elaboration bằng `$fatal` kèm thông báo.

Cấu hình đã được verify bằng regression: giá trị mặc định ở bảng trên, với hai chế độ clock là "sync" (cả 3 tham số `*_ASYNC = 0`, `APB_SLVERR = 0`) và "async" (cả 3 bằng 1, `APB_SLVERR = 1`).

---

## 3. Giao diện (port list)

### 3.1 Clock và reset

| Port | Hướng | Mô tả |
|---|---|---|
| `clk`, `rst_n` | in | Clock lõi DMA. Reset tích cực mức thấp, assert bất đồng bộ, deassert được đồng bộ bên trong (`dma_rst_sync`) |
| `pclk`, `presetn` | in | Clock/reset của APB. Chỉ dùng khi `APB_ASYNC=1` |
| `aclk`, `aresetn` | in | Clock/reset của AXI. Chỉ dùng khi `AXI_ASYNC=1` |
| `periph_clk[P-1:0]`, `periph_rst_n[P-1:0]` | in | Clock/reset của từng peripheral. Chỉ dùng khi `PERIPH_ASYNC=1` |

### 3.2 Cấu hình boot (tĩnh)

DMA chỉ lấy mẫu các chân này một lần, ở chu kỳ đầu tiên sau khi reset nhả. Chúng phải ổn định trước khi `rst_n` được deassert.

| Port | Mô tả |
|---|---|
| `boot_from_pc` | 1: manager tự chạy chương trình tại `boot_addr` sau reset. 0: manager ở trạng thái Stopped, chờ lệnh debug |
| `boot_addr[31:0]` | Địa chỉ chương trình boot của manager; đọc lại ở `CR2` |
| `boot_manager_ns` | Trạng thái security của manager sau reset (1 = non-secure); đọc lại ở `CR0[2]` và `DSR[9]` |

### 3.3 APB4 slave (domain `pclk`)

`psel`, `penable`, `pwrite`, `paddr[11:0]`, `pwdata[31:0]` → `pready`, `prdata[31:0]`, `pslverr`.

* Chế độ sync: zero wait state (`pready = 1`).
* Chế độ async: `pready` bị giữ ở 0 cho tới khi transfer hoàn thành ở domain lõi, thường mất vài chu kỳ `pclk`.
* `pslverr` luôn bằng 0 nếu `APB_SLVERR = 0`. Nếu `APB_SLVERR = 1`, `pslverr = 1` ở chu kỳ hoàn tất của truy cập tới địa chỉ không được map (kể cả thanh ghi của kênh không tồn tại) hoặc lệnh ghi vào thanh ghi read-only; truy cập đó bị bỏ qua.
* Khi DMA ở trạng thái quiescent (Q-Channel `Q_STOPPED`), `pready` bị giữ ở 0 cho tới khi DMA thoát khỏi trạng thái này.
* Đọc địa chỉ không được map trả về 0. Ghi vào thanh ghi read-only hoặc địa chỉ không được map bị bỏ qua.
* `paddr[1:0]` bị bỏ qua: mọi truy cập đều là word 32 bit.

### 3.4 AXI4 master (domain `aclk`)

Đủ 5 kênh AW, W, B, AR, R theo AXI4 (không có `AxQOS`, `AxREGION`, `AxUSER`).

| Tín hiệu | Giá trị DMA phát ra |
|---|---|
| `AxID` | Số kênh (0..`NUM_CH-1`) cho dữ liệu; `{ID_W{1'b1}}` cho instruction fetch |
| `AxLEN` | 0..15 (tối đa 16 beat) |
| `AxSIZE` | 0..log2(`DATA_W`/8) |
| `AxBURST` | `01` INCR hoặc `00` FIXED (FIXED chỉ dùng cho dữ liệu) |
| `AxLOCK` | 0 |
| `AxCACHE` | Dữ liệu: `{1'b0, CCR.x_cache[2:0]}`. Instruction fetch: `4'b0010` |
| `AxPROT` | Dữ liệu: `CCR.x_prot` OR `{1'b0, NS_kênh, 1'b0}`. Instruction fetch: `{1'b1, NS_thread, 1'b0}` |
| `WSTRB` | Theo địa chỉ và kích thước từng beat; byte lane không được strobe có `WDATA = 0` |

DMA tuân thủ: burst không vượt qua biên 4 KB, với điều kiện chương trình tuân thủ (xem 8.11). Không xen kẽ W giữa các burst. W có thể đi trước AW.

### 3.5 Giao diện peripheral (domain `periph_clk[p]`)

Mỗi peripheral `p` có hai kênh valid/ready:

| Port | Hướng | Mô tả |
|---|---|---|
| `drvalid[p]`, `drready[p]` | P→DMA, DMA→P | Bắt tay request |
| `drtype[p][1:0]` | P→DMA | `00` single request, `01` burst request, `10` acknowledge cho flush, `11` reserved |
| `drlast[p]` | P→DMA | Đánh dấu request cuối cùng (kết thúc vòng `DMALPFE`) |
| `davalid[p]`, `daready[p]` | DMA→P, P→DMA | Bắt tay acknowledge |
| `datype[p][1:0]` | DMA→P | `00` single hoàn thành, `01` burst hoàn thành, `10` yêu cầu flush, `11` reserved |

Quy tắc: payload phải giữ nguyên khi `valid=1 && ready=0`, và `valid` không được hạ trước khi có handshake. SVA kiểm tra cả hai phía.

### 3.6 Interrupt (domain `clk`)

| Port | Mô tả |
|---|---|
| `irq[NUM_EVENTS-1:0]` | Interrupt mức cao: `irq[e] = INT_EVENT_RIS[e] & INTEN[e]`. Xóa bằng cách ghi `INTCLR` |
| `irq_abort` | Mức cao khi manager hoặc bất kỳ kênh nào đang ở trạng thái lỗi (Fault completing / Faulting) |

Hai tín hiệu này ở domain `clk`. Nếu interrupt controller chạy clock khác thì phải đồng bộ phía nhận. Vì là tín hiệu mức nên dùng một bộ 2FF là đủ.

`irq_abort` cũng bật khi `WDSTAT ≠ 0` (watchdog phát hiện kênh bị treo).

### 3.7 Low-power Q-Channel (AMBA LPI)

| Port | Hướng | Mô tả |
|---|---|---|
| `qreqn` | in | Yêu cầu quiescence từ clock controller (tích cực thấp). Bất đồng bộ, được đồng bộ 2FF vào `clk`. **Phải bằng 1 khi reset**; nối lên 1 nếu không dùng |
| `qacceptn` | out | 0: DMA chấp nhận, đã quiescent, controller được phép tắt `clk` |
| `qdeny` | out | 1: DMA từ chối vì đang bận |
| `qactive` | out | 1: DMA có việc hoặc có truy cập APB đang chờ; controller nên bật lại clock. Là tín hiệu bất đồng bộ (OR giữa trạng thái lõi và `psel`) |

`qacceptn`/`qdeny` ở domain `clk`; controller phải đồng bộ nếu chạy clock khác.

---

## 4. Kiến trúc

### 4.1 Phân cấp module

```
axi_dma330                         top, CDC tùy chọn
 ├─ dma_rst_sync (x 3+P)           đồng bộ reset từng domain
 ├─ dma_apb_async_bridge           (APB_ASYNC)   2 x dma_cdc_handshake
 ├─ dma_axi_async_bridge           (AXI_ASYNC)   5 x dma_async_fifo
 ├─ dma_periph_sync [P]            (PERIPH_ASYNC) 2 x dma_cdc_handshake
 └─ dma330_core                    toàn bộ ở domain clk
     ├─ dma_regs                   register file APB, giao diện debug
     ├─ dma_manager                manager thread
     │   └─ dma_fetch_unit
     ├─ dma_channel [NUM_CH]       channel thread
     │   └─ dma_fetch_unit
     ├─ dma_icache                 instruction cache dùng chung + dma_rr_arbiter
     ├─ dma_datapath
     │   ├─ dma_rd_engine          RQ, AR arbiter, read tracker, R → MFIFO
     │   ├─ dma_mfifo [NUM_CH]     byte-stream buffer
     │   └─ dma_wr_engine          WQ, chọn burst, AW/W, B tracker
     ├─ dma_event_irq              event flag, interrupt
     ├─ dma_periph_ctrl            request latch, ack queue, flush
     ├─ dma_watchdog               phát hiện kênh bị treo
     └─ dma_qchannel               AMBA Q-Channel (low power)
```

Thư viện dùng chung: `dma_sync_fifo` (FIFO đồng bộ có flush), `dma_rr_arbiter` (round-robin), `dma_sync_2ff`.

Quy ước index thread trong lõi: kênh `0..NUM_CH-1`, manager là `NUM_CH`.

### 4.2 Clock domain và CDC

```
          pclk                     clk (core)                          aclk
 APB ->[apb_async_bridge]-> +------------------------------+ ->[axi_async_bridge]-> AXI4
                            |         dma330_core          |
 periph_clk[p] dr/da <->[periph_sync]                      |
                            +------------------------------+--> irq[], irq_abort
```

| Đường qua domain | Cấu trúc | Lý do chọn |
|---|---|---|
| APB `pclk → clk` | `dma_apb_async_bridge`: một toggle handshake cho request `{write, addr, wdata}` và một cho response `{slverr, rdata}`. Mỗi lần chỉ có 1 transfer đang chạy; `PREADY = 0` cho tới khi có response | Băng thông thanh ghi thấp; bus nhiều bit được giữ ổn định (quasi-static) khi qua domain |
| AXI `clk ↔ aclk` | `dma_axi_async_bridge`: 5 FIFO bất đồng bộ dùng con trỏ gray (AW, W, AR theo chiều lõi→bus; B, R theo chiều ngược lại), độ sâu `2^AFIFO_AW` | Đủ băng thông, chạy được ở mọi tỉ lệ clock, giữ thứ tự trên từng kênh AXI |
| Peripheral `periph_clk[p] ↔ clk` | `dma_periph_sync`: valid/ready dùng toggle handshake mỗi chiều (request 3 bit, ack 2 bit) | Request/ack là sự kiện rời rạc, payload nhỏ |
| Reset | `dma_rst_sync` cho mỗi domain: assert bất đồng bộ, deassert đồng bộ | |

Quy tắc CDC áp dụng ở mọi nơi:
1. Chỉ tín hiệu 1 bit hoặc mã gray mới đi qua `dma_sync_2ff`.
2. Bus nhiều bit chỉ đi qua domain khi được handshake giữ ổn định.
3. Không có logic tổ hợp giữa hai domain.

SVA kiểm tra hai điều: con trỏ gray chỉ đổi tối đa 1 bit mỗi lần (`AFIFO_*GRAY_ONEHOT`), và payload ổn định trong lúc handshake (`CDC_DATA_STABLE`).

Độ trễ CDC điển hình:
* Handshake: ~2 chu kỳ đích + ~2 chu kỳ nguồn cho mỗi transfer.
* Async FIFO: 2–3 chu kỳ đích từ lúc ghi tới lúc đọc được.

### 4.3 Register file — `dma_regs`

* Decode APB, mux đọc thanh ghi, lưu `INTEN`, `DBGINST0/1`, `WD`.
* Thanh ghi trạng thái (`DSR`, `CSRn`, `CPCn`, `SARn`...) không có flop riêng ở đây; chúng được nối thẳng từ manager/kênh.
* Phát lệnh debug:
  * Lệnh cho **manager** được chốt vào `dbg_mgr_busy` (đọc ở `DBGSTATUS[0]`) cho tới khi manager báo xong.
  * Lệnh cho **channel** có hiệu lực ngay trong chu kỳ ghi `DBGCMD`:
    * `DMAKILL` → kill kênh;
    * `DMASEV` với số event hợp lệ → set event;
    * mọi lệnh khác, hoặc `DMASEV` có số event sai → kênh bị lỗi `FTC_DBG_INSTR` + `FTC_UNDEF_INSTR`;
    * nếu số kênh ≥ `NUM_CH`, lệnh bị bỏ qua.
* Mọi lệnh ghi `DBGCMD` đều bị bỏ qua khi `DBGSTATUS[0] = 1`, kể cả lệnh dành cho channel.

### 4.4 Manager thread — `dma_manager`

```
 M_BOOT --boot_from_pc=1--> M_FETCH <--> M_EXEC --DMAWFE--> M_WFE --event--> M_FETCH
   |                           ^           |
   +--boot_from_pc=0--> M_STOPPED <--------+  (DMAEND / DMAKILL / lệnh debug xong)
                          |   ^
          lệnh debug -----+   +---- M_FAULTING <--- mọi lỗi (thoát bằng DMAKILL debug)
                       (M_EXEC)
```

* Lệnh hợp lệ: `DMAGO`, `DMASEV`, `DMAWFE`, `DMAFLUSHP`, `DMANOP`, `DMAEND`, `DMAKILL`.
* Qua giao diện debug chỉ được phép `DMAGO`, `DMASEV`, `DMAKILL`, `DMANOP`. Lệnh khác gây lỗi `undef_instr` + `dbg_instr`.
* `M_BOOT` kéo dài một chu kỳ sau reset. Trong chu kỳ đó manager lấy mẫu `boot_manager_ns`, `boot_addr`, `boot_from_pc`.
* Lệnh debug chỉ được nhận khi manager ở `M_STOPPED` (thực thi) hoặc `M_FAULTING` (chỉ `DMAKILL` có tác dụng, lệnh khác bị bỏ qua nhưng vẫn được báo xong). Khi manager đang chạy chương trình boot, lệnh debug phải chờ và `DBGSTATUS` = busy.
* Kiểm tra khi thực thi `DMAGO`:
  * số kênh ≥ `NUM_CH` → `operand_invalid`;
  * manager non-secure mà `DMAGO` yêu cầu kênh secure (`ns=0`) → `dmago_err`.
* `DMAGO` hợp lệ làm hai việc: phát `go_valid` tới kênh, và **invalidate toàn bộ instruction cache cùng line buffer của mọi thread**. Nhờ vậy kênh không bao giờ chạy code cũ.
* Nếu kênh không ở trạng thái Stopped, `DMAGO` bị kênh bỏ qua (như DMA-330).

### 4.5 Channel thread — `dma_channel`

Trạng thái kiến trúc của mỗi kênh: `PC (CPC)`, `SAR`, `DAR`, `CCR`, `LC0`, `LC1` (8 bit), `NS`, cờ `request_type` (single/burst), cờ `request_last`, `wakeup_number`, `FTR`.

```
 C_STOPPED --DMAGO--> C_FETCH <--> C_EXEC --+--> C_WFE        (DMAWFE)  --event------> C_FETCH
                         ^                  +--> C_WFP        (DMAWFP)  --request----> C_FETCH
                         |                  +--> C_BARRIER    (DMARMB/WMB) --idle----> C_FETCH
                         +------------------+--> C_COMPLETING (DMAEND)  --dp idle---> C_STOPPED
                                            +--> C_KILLING    (DMAKILL) --dp idle---> C_STOPPED
 mọi lỗi ---------> C_FAULT_COMPLETING --dp idle--> C_FAULTING --DMAKILL debug--> C_KILLING
 DMAKILL debug (mọi trạng thái trừ STOPPED) ------------------------------------> C_KILLING
```

`dp idle` nghĩa là kênh không còn request nào trong RQ/WQ, không còn burst đọc hoặc ghi nào outstanding.

Đặc điểm thực thi:
* **LD/ST được issue, không thực thi tại chỗ.**
  * `DMALD`: đẩy một mô tả burst (`xfer_t`) vào RQ của kênh, tăng `SAR` (nếu INCR) theo số byte của burst, rồi đi tiếp sang lệnh sau.
  * `DMAST`: đẩy vào WQ, tăng `DAR`.
  * Thread chỉ dừng ở những chỗ ISA yêu cầu: barrier, `DMAEND`, `DMAWFE`, `DMAWFP`. Ngoài ra thread dừng khi queue đầy, hoặc khi `DMALD` chưa có chỗ trong MFIFO.
* Lệnh có điều kiện `S`/`B`: so sánh với cờ `request_type`. Nếu điều kiện sai, lệnh tương đương `DMANOP`.
* Vòng lặp:
  * `DMALP` nạp `LCx = iter-1`.
  * `DMALPEND` giảm `LCx` và nhảy lùi `jump` byte nếu `LCx ≠ 0`.
  * `DMALPFE` nhảy lùi cho tới khi peripheral báo `drlast`.
* Mỗi lệnh mất khoảng 3 chu kỳ `clk` khi trúng line buffer (FETCH → insn valid → EXEC).
* **Bảo vệ giao thức AXI**: khi thực thi `DMALD`/`DMAST`, kênh kiểm tra burst sắp phát. Burst bị từ chối và kênh lỗi `ch_rdwr_err` (FTR[7]) nếu:
  * burst size lớn hơn độ rộng bus;
  * burst INCR vượt biên 4 KB (tính từ địa chỉ bắt đầu đã align theo beat size);
  * (chỉ với store, trừ `DMASTZ`) endian swap không hợp lệ: mã > 4, nhóm swap lớn hơn beat size, hoặc `DAR` không align theo nhóm swap.

  Vì vậy DMA không bao giờ phát giao dịch AXI bất hợp lệ, dù chương trình sai.
* **FAR**: kênh lưu địa chỉ của lỗi bus đầu tiên kể từ `DMAGO`. `FAR` được xóa về 0 bởi `DMAGO`.
  * Lỗi đọc: địa chỉ của beat R bị lỗi.
  * Lỗi ghi: địa chỉ bắt đầu của burst nhận BRESP lỗi.
  * Lỗi fetch: PC của lệnh không fetch được.
* **Watchdog**: tín hiệu `wd_fault` (xem 4.10) đưa kênh đang chạy chương trình (Executing, Cache miss, chờ event/peripheral, At barrier, Completing) vào `Fault completing` với lỗi `lockup_err` (FTR[31]). Kênh đang `Killing` hoặc đang lỗi chỉ được báo qua `WDSTAT`; loại lỗi ban đầu của kênh được giữ nguyên.
* Lỗi phát hiện lúc execute: xem bảng 5.9.
* Ở các trạng thái `STOPPED/KILLING/FAULT_*`, kênh bật `dp_flush`. Khi đó datapath:
  * bỏ các request còn trong RQ/WQ;
  * bỏ R data trả về cho kênh này;
  * xóa MFIFO của kênh, trừ khi đang có burst của kênh trên W;
  * vẫn chờ mọi burst đang outstanding hoàn tất phản hồi.

### 4.6 Instruction fetch — `dma_fetch_unit` + `dma_icache`

```
 thread ── fetch_req ──> dma_fetch_unit (1 line buffer / thread) ── miss ──> dma_icache (shared) ── refill ──> rd_engine (AR ưu tiên)
```

* **Fetch unit** (mỗi thread một bộ): giữ một line (`IC_BEATS*DATA_W/8` byte, mặc định 32 B).
  * Lệnh nằm trọn trong line → trả lệnh ở chu kỳ sau.
  * Lệnh vắt sang line kế tiếp (lệnh dài tối đa 6 byte) → đọc thêm line sau rồi ghép lại.
  * Nếu thread bỏ `fetch_req` khi đang miss (bị kill), kết quả trả về muộn sẽ bị bỏ (cờ `aborted`).
* **I-cache**:
  * Fully associative, `IC_LINES` line, thay thế round-robin, blocking: mỗi lần chỉ xử lý một lookup hoặc refill.
  * Các thread được phục vụ theo round-robin.
  * Refill dùng một burst INCR, `ARLEN = IC_BEATS-1`, `ARSIZE` bằng độ rộng bus, `ARID` toàn bit 1.
  * Refill có `RRESP` lỗi ở bất kỳ beat nào → thread nhận `fetch_err`, line không được ghi vào cache.
* **Invalidate**: `DMAGO`, hoặc `DMAWFE` có cờ invalidate (byte1[1]) ở bất kỳ thread nào, sẽ xóa toàn bộ valid bit của cache và line buffer.

### 4.7 Datapath — `dma_datapath`

```
           +--------------------------- dma_datapath -----------------------------+
 DMALD --->| admission (reserved) -> RQ[ch] -> AR arbiter -> AR reg ----------------|--> AR
           |                                      ^ i-cache refill (ưu tiên)       |
           |                          read tracker[ch] <- R (theo RID) <-----------|--- R
           |                                 | lane extract                        |
           |                            MFIFO[ch] (byte stream)                    |
           |                                 | pop + rotate                        |
 DMAST --->| admission (unclaimed) -> WQ[ch] -> chọn burst đã đủ data -> AW + W ---|--> AW, W
           |                          B tracker[ch] <- B (theo BID) <--------------|--- B
           |   ack DMALDP (RLAST), ack DMASTP (B) ---> dma_periph_ctrl             |
           +-----------------------------------------------------------------------+
```

#### 4.7.1 Read engine — `dma_rd_engine`

* Mỗi kênh có RQ (`RQ_DEPTH`) và read tracker (`RD_OUT`).
* AR arbiter:
  * refill instruction cache được ưu tiên tuyệt đối;
  * sau đó round-robin giữa các kênh có request, tracker chưa đầy và không bị flush.
* AR được đăng ký (registered): `ARVALID` và payload ổn định cho tới khi có `ARREADY`. Có thể phát AR liên tiếp mỗi chu kỳ.
* Phân luồng R:
  * `RID` toàn bit 1 → đưa sang I-cache.
  * Ngược lại `RID` = số kênh. Mỗi kênh có bộ đếm beat riêng, vì vậy R của các ID khác nhau được phép xen kẽ.
* Với mỗi beat dữ liệu, tính địa chỉ beat và số byte hợp lệ (`beat_addr`, `beat_bytes`), dịch các byte lane hợp lệ về byte 0 rồi đẩy vào MFIFO của kênh.
* `RRESP[1] = 1` (SLVERR/DECERR) → `rd_err` của kênh.
* R không bao giờ bị chặn vì thiếu chỗ trong MFIFO, vì chỗ đã được dành trước khi issue. R chỉ bị chặn khi cần đẩy ack `DMALDP` mà ack queue của peripheral đã đầy.

#### 4.7.2 MFIFO — `dma_mfifo`

* Gồm `DATA_W/8` bank rộng 1 byte × `MFIFO_LINES` hàng. Byte thứ p của stream nằm ở bank `p % NB`, hàng `(p / NB) % LINES`.
* Mỗi chu kỳ push tối đa NB byte và pop tối đa NB byte, ở mọi offset.
* Vì dữ liệu lưu theo **thứ tự stream** chứ không theo byte lane, phía nguồn và phía đích có thể khác nhau hoàn toàn về size, length và alignment.

#### 4.7.3 Kiểm soát nhận lệnh (admission control)

Hai bộ đếm byte cho mỗi kênh:

| Bộ đếm | Tăng khi | Giảm khi | Dùng để |
|---|---|---|---|
| `reserved` | `DMALD` được nhận (+bytes) | byte được pop ra W | Chỉ nhận `DMALD` khi `reserved + bytes ≤ dung lượng MFIFO` → R không bao giờ stall vì thiếu chỗ |
| `unclaimed` | `DMALD` được nhận (+bytes) | `DMAST` được nhận (−bytes) | Phát hiện `DMAST` cần nhiều byte hơn số sẽ có |

Hai lỗi tương ứng:
* `DMALD` không vừa MFIFO **và** kênh không còn store nào đang chờ (tức không gì có thể giải phóng chỗ) → lỗi `mfifo_err` (phát hiện lock-up).
* `DMAST`/`DMASTP` (không phải `DMASTZ`) có `bytes > unclaimed` → lỗi `st_data_unavailable`.

#### 4.7.4 Write engine — `dma_wr_engine`

* Mỗi kênh có WQ (`WQ_DEPTH`) và B tracker (`WR_OUT`).
* **Một burst chỉ được bắt đầu khi toàn bộ dữ liệu của nó đã nằm trong MFIFO** (hoặc là `DMASTZ`). Nhờ vậy W không bao giờ chờ R. Một kênh chậm không thể chặn kênh W dùng chung, nên không có head-of-line blocking và không có deadlock.
* Chọn burst kế tiếp: round-robin giữa các kênh đã đủ dữ liệu, B tracker chưa đầy và không bị flush.
* AW và W của burst đang chạy được phát song song (AXI cho phép bên nào đi trước cũng được). Trên W mỗi lúc chỉ có một burst; giữa hai burst có 1 chu kỳ nghỉ.
* `WSTRB = ((1 << nbytes) - 1) << lane`. Byte lane không có strobe có `WDATA = 0`, để `WDATA` luôn ổn định khi chờ `WREADY`.
* **Endian swap**: nếu `CCR.endian_swap = k ≠ 0` lúc `DMAST`, mỗi nhóm `2^k` byte đã align trên bus được đảo thứ tự byte: byte i của nhóm chuyển sang vị trí `i XOR (2^k − 1)`.
  * Phần cứng chỉ gồm đi dây cố định và một mux 5 ngõ trên `WDATA`.
  * Kênh đã bảo đảm burst align theo nhóm, nên `WSTRB` luôn phủ trọn nhóm và không cần đổi.
  * Phía đọc và MFIFO không thay đổi.
* B được ghép với kênh theo `BID`. `BRESP[1] = 1` → `wr_err` của kênh.

#### 4.7.5 Tính số byte của một burst

```
bytes(addr, size, len, inc) = inc ? (len+1)*2^size - (addr mod 2^size)
                                  : (len+1)*(2^size - (addr mod 2^size))
```

Với INCR có địa chỉ không align, chỉ beat đầu bị ngắn lại. Với FIXED, mọi beat đều dùng cùng một byte lane. Sau mỗi `DMALD`/`DMAST` dạng INCR, `SAR`/`DAR` tăng đúng bằng `bytes`.

### 4.8 Peripheral controller — `dma_periph_ctrl`

Với mỗi peripheral `p`:
* **Request latch**: giữ 1 request đang chờ `{burst, last}`.
  * `drready = 1` khi latch rỗng, hoặc khi đang flush.
  * Request nhận được trong lúc flush bị bỏ, trừ `drtype = 10` (flush ack), vốn dùng để kết thúc flush.
  * Flush ack nhận ngoài lúc flush cũng bị bỏ qua.
* **DMAWFP**: kênh có số nhỏ nhất đang chờ `p` sẽ lấy request trong latch. Kênh đó nhận cờ `request_type` (với `DMAWFP P`) và `last`.
* **Ack queue** (sâu 4) phát ra `da`, theo đúng thứ tự đẩy vào:
  * `10`: flush request (`DMAFLUSHP`);
  * `01`: burst xong (`DMALDPB`/`DMASTPB`);
  * `00`: single xong (`DMALDPS`/`DMASTPS`).
  * Mỗi chu kỳ chỉ đẩy được một ack, theo ưu tiên: flush > ack đọc > ack ghi. Nguồn thua bị back-pressure.
* **Thời điểm ack**:
  * ack của `DMALDP` được đẩy khi beat RLAST của burst đọc về;
  * ack của `DMASTP` được đẩy khi nhận B của burst ghi.
* **DMAFLUSHP** (từ kênh hoặc manager): xóa request đang chờ, đẩy flush request vào ack queue, rồi bỏ mọi request cho tới khi peripheral trả `drtype=10`. Khi chạy trong kênh, lệnh còn xóa `request_type/last` của kênh đó.

### 4.9 Event và interrupt — `dma_event_irq`

* Mỗi event `e` có một flag (đọc ở `INT_EVENT_RIS[e]`).
* `DMASEV e` (từ thread hoặc từ debug) set flag.
* `INTEN[e] = 1`: flag là **interrupt** → `irq[e] = 1`. Phần mềm xóa bằng `INTCLR[e]`.
* `INTEN[e] = 0`: flag là **event**:
  * thread đang `DMAWFE e` được thả và flag tự xóa;
  * mọi thread cùng chờ `e` trong cùng chu kỳ được thả cùng lúc;
  * nếu chưa có ai chờ, flag được giữ lại (sticky), và `DMAWFE e` sau đó đi qua ngay.
* Một event đang cấu hình là interrupt thì **không** thả `DMAWFE`.
* Nếu set và clear xảy ra cùng chu kỳ, set thắng.
* `INTCLR` chỉ xóa các bit có `INTEN = 1`.

### 4.10 Watchdog — `dma_watchdog`

* **Active**: kênh không ở `Stopped`, `Waiting for event`, `Waiting for peripheral`, `Faulting`, hoặc vẫn còn giao dịch AXI trong queue / đang chờ phản hồi. Chờ event và chờ peripheral là chờ hợp lệ (có thể vô hạn) nên không bị giám sát.
* **Progress**: một trong các sự kiện sau:
  * một lệnh hoàn tất (CPC đổi);
  * status đổi;
  * một handshake AXI mang ID của kênh (AR, R, AW, W, B);
  * instruction cache trả line cho kênh.
* **Bộ đếm**: một prescaler chung tạo tick mỗi 256 chu kỳ `clk`. Mỗi kênh có bộ đếm 16 bit, tăng theo tick khi active mà không có progress, và về 0 khi có progress.
* **Khi đạt `WD.timeout`**: bộ đếm dừng ở giá trị timeout và kênh bị báo **một lần**. Muốn báo lại thì kênh phải có progress hoặc trở thành inactive trước. Kênh được báo ngay cả khi progress quay lại đúng ở chu kỳ đó, vì nó đã thực sự đứng yên suốt khoảng timeout.
  * `WDSTAT[ch]` được set (sticky, ghi 1 để xóa) và `irq_abort` bật.
  * Nếu `WD.irq_only = 0`: kênh lỗi `lockup_err` (FTR[31]) và vào `Fault completing`.
* **Cấu hình**: `WD.timeout = 0` (mặc định sau reset) tắt watchdog. Thời gian phát hiện nằm trong khoảng `timeout×256` … `timeout×256 + 255` chu kỳ.
* **Bus treo vĩnh viễn**: burst đang bay không bao giờ hoàn tất, nên kênh ở mãi `Fault completing`. Phần mềm vẫn biết nhờ `irq_abort`, `WDSTAT` và `FTRn[31]`, và có thể cô lập hoặc reset slave/interconnect. Khi bus phản hồi trở lại, kênh tự đi tiếp tới `Faulting`.

### 4.11 Low-power Q-Channel — `dma_qchannel`

```
 Q_RUN --qreqn=0 & idle--> Q_STOPPED (qacceptn=0) --qreqn=1--> Q_RUN
   |
   +----qreqn=0 & busy--> Q_DENIED (qdeny=1)     --qreqn=1--> Q_RUN
```

* **Idle** khi thỏa mãn tất cả các điều kiện sau:
  * manager và mọi kênh ở `Stopped` hoặc `Faulting`;
  * datapath không còn giao dịch nào;
  * I-cache không lookup/refill;
  * ack queue của mọi peripheral rỗng;
  * không có lệnh debug đang chờ;
  * không có truy cập APB.

  Kênh đang chờ event/peripheral **không** được xem là idle, vì chương trình vẫn đang chạy.
* **Ở `Q_STOPPED`**, lõi không nhận việc mới: APB bị giữ `PREADY = 0`, request của peripheral bị giữ `DRREADY = 0`. Controller có thể tắt `clk`. `qactive` bật khi có truy cập APB, để controller bật lại clock và kéo `qreqn` lên.
* **Reset**: vào `Q_RUN`.

### 4.12 Tổng hợp tài nguyên lưu trữ (mặc định)

| Khối | Dung lượng |
|---|---|
| MFIFO | 4 kênh × 256 B = 1 KB |
| I-cache | 8 × 32 B = 256 B + tag |
| Line buffer | 5 thread × 32 B |
| RQ/WQ/tracker | 4 kênh × (4 + 4 + 4 + 4) mô tả burst (~60 bit/mục) |
| AXI async bridge | 5 FIFO × 8 mục (W: 64+8+1 bit, R: 64+4+2+1 bit) |

---

## 5. Hoạt động tổng thể (global operation)

### 5.1 Reset và khởi động

1. Mọi reset (`rst_n`, `presetn`, `aresetn`, `periph_rst_n`) nên được assert **cùng lúc**. Lý do: CDC bridge có state ở cả hai domain; nếu chỉ reset một phía, các toggle/con trỏ ở hai phía sẽ lệch nhau.
2. Mỗi reset được đồng bộ trong domain của nó. Sau khi tất cả được deassert:
   * các thread và datapath về trạng thái ban đầu: mọi kênh `Stopped`, MFIFO rỗng, cache invalid, `INTEN = 0`, mọi flag event bằng 0;
   * manager ở `M_BOOT` một chu kỳ, lấy mẫu chân boot.
3. Nếu `boot_from_pc = 1`: manager fetch lệnh tại `boot_addr` và chạy chương trình boot, thường gồm `DMAGO` các kênh, `DMAWFE`/`DMASEV` để đồng bộ, rồi kết thúc bằng `DMAEND`. Nếu fetch lỗi, manager vào `Faulting` (`FTRD[16]`) và `irq_abort` bật.
4. Nếu `boot_from_pc = 0`: manager `Stopped`, chờ phần mềm gửi lệnh qua debug.

### 5.2 Khởi động một kênh

```
 CPU                 dma_regs           manager              channel n           icache / AXI
  | DBGINST0/1 ------>|                   |                     |                    |
  | DBGCMD = 0 ------>| dbg_mgr_busy=1 -->| M_STOPPED->M_EXEC   |                    |
  |                   |                   | DMAGO: go_valid[n] ->| C_STOPPED->C_FETCH |
  |                   |                   | ic_inv_all ---------------------------------> invalidate
  |                   |<-- dbg_done ------| -> M_STOPPED        | fetch miss -------> AR (ARID=1111)
  | DBGSTATUS=0 <-----|                   |                     |<------ line ------ R x IC_BEATS
  |                   |                   |                     | EXEC DMAMOV ...    |
```

1. CPU poll `DBGSTATUS` cho tới khi bằng 0.
2. CPU ghi `DBGINST0` (byte 0..1 của lệnh, chọn thread manager), `DBGINST1` (byte 2..5), rồi ghi `DBGCMD = 0`.
3. Manager thực thi `DMAGO`, sau đó:
   * kênh n nhận PC và NS, xóa `FTR` và các cờ request, chuyển sang `C_FETCH`;
   * cache bị invalidate;
   * manager quay về `Stopped` và `DBGSTATUS` trở về 0.
4. Kênh fetch lệnh đầu tiên (cache miss → refill qua AR với ưu tiên cao nhất), rồi thực thi tuần tự.

### 5.3 Luồng dữ liệu memory → memory

Ví dụ: chương trình `DMAMOV SAR/DAR/CCR; DMALP 8 { DMALD; DMAST }; DMAWMB; DMASEV 0; DMAEND`.

```
 channel      datapath (RQ/AR)        AXI slave        MFIFO[ch]       datapath (WQ/W)      AXI slave
 DMALD #1 --> reserve 128B, RQ <-- AR(id=ch) -------->|
 DMAST #1 --> WQ (unclaimed -128)                      |
 DMALD #2 --> reserve? 256<=256 ok --> AR ------------>|
 DMAST #2 --> WQ                                       |
 DMALD #3 --> (chờ: MFIFO đã được hứa hết) ...         |
                                   R beat x16 <--------| push 8B/beat -> count=128
                                                                    WQ head đủ 128B -> AW + W x16 --->
                                                                    pop 8B/beat -> reserved -=
 DMALD #3 được nhận ...                                                                 B(id=ch) <---
 DMAWMB: chờ wr_busy=0 (mọi B đã về)
 DMASEV 0 -> INT_EVENT_RIS[0]=1 -> irq[0] (nếu INTEN[0]=1)
 DMAEND  -> Completing (chờ rd/wr idle) -> Stopped
```

Các điểm then chốt:
* Thread chạy trước datapath. `DMALD`/`DMAST` chỉ là lệnh issue, nên nhiều burst đọc được phát liên tiếp, giới hạn bởi `RQ_DEPTH`, `RD_OUT` và dung lượng MFIFO.
* Burst ghi chỉ khởi động khi đủ dữ liệu. Vì vậy W luôn chạy liên tục từ beat đầu tới WLAST, không có beat nào phải chờ dữ liệu.
* Độ dài, size và alignment hai phía có thể khác nhau. Chương trình chỉ cần bảo đảm tổng byte `DMALD` bằng tổng byte `DMAST`.

### 5.4 Phân xử và thứ tự giữa các kênh

| Tài nguyên | Chính sách |
|---|---|
| AR | I-cache refill > round-robin các kênh |
| W (và AW) | Round-robin các kênh có burst đầu WQ đã đủ dữ liệu |
| I-cache | Round-robin các thread đang miss |
| R / B | Tách theo ID. Mỗi kênh nhận dữ liệu và phản hồi theo đúng thứ tự đã phát (yêu cầu của AXI cho cùng ID) |
| Ack queue peripheral | flush > ack đọc > ack ghi |
| Request peripheral | Kênh có số nhỏ nhất đang `DMAWFP` trên peripheral đó |

Giữa các kênh không có thứ tự ràng buộc. Nếu cần thứ tự giữa hai kênh, dùng `DMASEV`/`DMAWFE` (xem 8.8).

### 5.5 Luồng truyền theo nhịp peripheral

Ví dụ memory → peripheral FIFO, mỗi request là một burst:

```
 channel                         periph_ctrl[p]                    peripheral
 DMAFLUSHP P ------------------> ackq: FLUSH -------- da=10 ------> (xóa FIFO nội bộ)
                                 flushing=1   <------ dr=10 ------- flush ack
 DMALP N {
   DMAWFP P, burst  ---- chờ ---> latch request <---- dr=01 (burst) -
   DMALD             (burst đọc từ memory)
   DMASTPB P         (burst ghi vào FIFO địa chỉ cố định)
 }                               B về -> ackq: BURST -- da=01 ----> peripheral biết burst đã xong
 DMALPEND
```

* Peripheral chỉ được gửi request kế tiếp khi `drready = 1`. Thường peripheral chờ ack trước, vì DMA chỉ nhận một request vào latch mỗi lần.
* `DMAWFP P`: kiểu (single/burst) lấy từ request. Sau đó các lệnh có hậu tố `S`/`B` tự chọn đường đi. Ví dụ `DMALDS; DMALDB; DMASTPS; DMASTPB`: mỗi request chỉ chạy một lệnh trong mỗi cặp.
* `DMALPFE` lặp tới khi request có `drlast = 1`.
* Peripheral → memory dùng `DMALDP` thay cho `DMASTP`. Khi đó ack được gửi khi burst đọc kết thúc (RLAST).

### 5.6 Event, đồng bộ và interrupt

* Đồng bộ giữa các thread: thread A chạy `DMAWFE e` (với `INTEN[e] = 0`), thread B chạy `DMASEV e` khi xong việc. Thread A chỉ đọc dữ liệu sau khi B đã báo.
* Báo CPU: chương trình chạy `DMAWMB` rồi `DMASEV e` với `INTEN[e] = 1`; `irq[e]` bật cho tới khi CPU ghi `INTCLR`.
* `DMAWMB` trước `DMASEV` là bắt buộc nếu muốn interrupt nghĩa là dữ liệu đã ghi xong. Lý do: `DMASEV` không tự chờ các burst đang bay.

### 5.7 Barrier và kết thúc chương trình

| Lệnh | Chờ điều kiện |
|---|---|
| `DMARMB` | Mọi `DMALD` trước đó đã nhận đủ R (RQ rỗng, read tracker rỗng) |
| `DMAWMB` | Mọi `DMAST` trước đó đã nhận B (WQ rỗng, không có burst đang chạy, B tracker rỗng) |
| `DMAEND` | Cả đọc lẫn ghi đều idle (trạng thái `Completing`), sau đó `Stopped` |
| `DMAKILL` (trong chương trình) | Như `DMAEND` nhưng đi qua trạng thái `Killing` |

### 5.8 Xử lý lỗi (fault)

```
 phát hiện lỗi --> FTR |= bit lỗi --> C_FAULT_COMPLETING (flush queue, bỏ R data,
                                       chờ burst đang bay retire) --> C_FAULTING
 irq_abort = 1, FSRC[n] = 1  ...  CPU: đọc FTRn/CPCn --> DMAKILL (debug) --> C_KILLING --> C_STOPPED, FTR=0
```

* Kênh lỗi bị cách ly: các kênh khác vẫn chạy bình thường. Tài nguyên dùng chung (AR, W, cache) không bị kẹt, vì burst đang bay vẫn được hoàn tất.
* `CPCn` giữ địa chỉ lệnh gây lỗi (với lỗi phát hiện lúc execute hoặc fetch).
* Lỗi đến từ AXI (`RRESP`/`BRESP`) là bất đồng bộ: `CPC` lúc đó trỏ tới lệnh đang thực thi chứ không phải lệnh `DMALD`/`DMAST` đã gây lỗi.
* Manager lỗi → `M_FAULTING`, `FSRD = 1`, `irq_abort = 1`. Chỉ `DMAKILL` gửi qua debug mới đưa manager về `Stopped` và xóa `FTRD`.
* Với lỗi bus, `FARn` cho biết địa chỉ chính xác của lỗi đầu tiên.

### 5.9 Bảng nguồn lỗi

| Bit FTRn | Tên | Điều kiện |
|---|---|---|
| 0 | `undef_instr` | Opcode không hợp lệ; `DMAGO` trong chương trình kênh; lệnh debug không hợp lệ cho kênh |
| 1 | `operand_invalid` | `DMAMOV` với thanh ghi đích > 2 |
| 5 | `ch_evnt_err` | `DMASEV`/`DMAWFE` có số event ≥ `NUM_EVENTS` |
| 6 | `ch_periph_err` | `DMAWFP`/`DMAFLUSHP`/`DMALDP`/`DMASTP` có số peripheral ≥ `NUM_PERIPH` |
| 7 | `ch_rdwr_err` | Khi thực thi `DMALD`/`DMAST`: burst size lớn hơn độ rộng bus; burst INCR vượt biên 4 KB; endian swap không hợp lệ (store) |
| 12 | `mfifo_err` | `DMALD` không vừa MFIFO và không có store nào đang chờ (lock-up) |
| 13 | `st_data_unavailable` | `DMAST` cần nhiều byte hơn số byte đã load mà chưa store |
| 16 | `instr_fetch_err` | AXI trả lỗi khi refill line chứa lệnh |
| 17 | `data_write_err` | `BRESP` = SLVERR/DECERR |
| 18 | `data_read_err` | `RRESP` = SLVERR/DECERR |
| 30 | `dbg_instr` | Lỗi do lệnh từ giao diện debug |
| 31 | `lockup_err` | Watchdog: kênh không có progress trong `WD.timeout × 256` chu kỳ (khi `WD.irq_only = 0`) |

| Bit FTRD | Tên | Điều kiện |
|---|---|---|
| 0 | `undef_instr` | Opcode không phải lệnh manager; lệnh debug không thuộc {GO, SEV, KILL, NOP} |
| 1 | `operand_invalid` | `DMAGO` tới kênh ≥ `NUM_CH`; `DMAFLUSHP` có số peripheral sai |
| 4 | `mgr_evnt_err` | `DMASEV`/`DMAWFE` có số event sai |
| 5 | `dmago_err` | Manager non-secure gửi `DMAGO` cho kênh secure |
| 16 | `instr_fetch_err` | Lỗi AXI khi fetch chương trình manager |
| 30 | `dbg_instr` | Lỗi do lệnh debug |

### 5.10 Kill

* `DMAKILL` gửi tới kênh qua debug có tác dụng ở mọi trạng thái trừ `Stopped`. Gửi tới kênh đang Stopped thì không có tác dụng.
* Kênh vào `Killing`: xóa request trong queue, bỏ dữ liệu R, chờ mọi burst đang bay hoàn tất, sau đó xóa `FTR` và về `Stopped`. `CPC`, `SAR`, `DAR` giữ giá trị cuối cùng để debug.
* Kill có thể xảy ra giữa một chuỗi request–ack của peripheral. Lúc đó peripheral có thể chưa nhận ack cho request đã gửi, nên chương trình tiếp theo dùng peripheral đó phải bắt đầu bằng `DMAFLUSHP`.

### 5.11 Watchdog và bus bị treo

1. Phần mềm bật watchdog: `WD = timeout << 16` (abort) hoặc `(timeout << 16) | 1` (chỉ báo).
2. Nếu một slave không trả R/B, kênh liên quan dừng progress. Sau khoảng `timeout × 256` chu kỳ: `WDSTAT[n] = 1`, `irq_abort = 1`. Ở chế độ abort, kênh vào `Fault completing` với `FTRn[31]`.
3. Các kênh khác tiếp tục chạy nếu phần bus của chúng không bị ảnh hưởng.
4. Khi bus hoạt động lại:
   * chế độ abort: kênh vào `Faulting`; phần mềm dùng `DMAKILL` như mọi lỗi khác;
   * chế độ chỉ báo: transfer tiếp tục bình thường.

   Phần mềm ghi 1 vào `WDSTAT[n]` để hạ `irq_abort`.

### 5.12 Quản lý năng lượng (Q-Channel)

1. Clock controller kéo `qreqn = 0`.
2. DMA trả lời:
   * nếu idle: `qacceptn = 0`, controller tắt `clk`;
   * nếu bận: `qdeny = 1`; controller phải kéo `qreqn = 1` để quay về `Q_RUN` rồi thử lại sau.
3. Nếu CPU truy cập APB trong lúc clock tắt:
   * `qactive = 1`, `PREADY` vẫn bằng 0;
   * controller bật lại clock và kéo `qreqn = 1`;
   * DMA trả `qacceptn = 1` và hoàn tất truy cập APB.
4. Interrupt (`irq`, `irq_abort`) giữ nguyên giá trị trong lúc clock tắt.

### 5.13 Security

* Manager có bit NS, khởi tạo từ chân `boot_manager_ns`.
* `DMAGO` mang cờ `ns` (opcode `0xA2`); cờ này trở thành NS của kênh (`CSRn[21]`).
* Manager non-secure không được khởi động kênh secure (`dmago_err`).
* Kênh NS phát `AxPROT[1] = 1` trên mọi giao dịch, kể cả instruction fetch.
* Thiết kế chỉ có một cổng APB: không có cổng APB non-secure riêng như DMA-330.

---

## 6. Programmer's model: register map

Tất cả thanh ghi rộng 32 bit, địa chỉ là offset trong vùng APB 4 KB. RO = read-only, WO = write-only, RW = read/write. "n" là số kênh.

### 6.1 Bảng tổng hợp

| Offset | Tên | Loại | Reset | Mô tả |
|---|---|---|---|---|
| 0x000 | `DSR` | RO | 0x0000_0000 (*) | Trạng thái manager |
| 0x004 | `DPC` | RO | `boot_addr` | PC của manager |
| 0x020 | `INTEN` | RW | 0 | 1: event e là interrupt; 0: event e là event |
| 0x024 | `INT_EVENT_RIS` | RO | 0 | Trạng thái flag event/interrupt (raw) |
| 0x028 | `INTMIS` | RO | 0 | `INT_EVENT_RIS & INTEN` |
| 0x02C | `INTCLR` | WO | – | Ghi 1 để xóa interrupt e (chỉ tác dụng khi `INTEN[e] = 1`) |
| 0x030 | `FSRD` | RO | 0 | [0] manager đang lỗi |
| 0x034 | `FSRC` | RO | 0 | [n] kênh n đang lỗi |
| 0x038 | `FTRD` | RO | 0 | Loại lỗi của manager (bảng 5.9) |
| 0x040 + 4n | `FTRn` | RO | 0 | Loại lỗi của kênh n |
| 0x060 + 4n | `FARn` | RO | 0 | Địa chỉ lỗi bus đầu tiên của kênh n (mở rộng) |
| 0x100 + 8n | `CSRn` | RO | 0 | Trạng thái kênh n |
| 0x104 + 8n | `CPCn` | RO | 0 | PC của kênh n |
| 0x400 + 0x20n | `SARn` | RO | 0 | Source address |
| 0x404 + 0x20n | `DARn` | RO | 0 | Destination address |
| 0x408 + 0x20n | `CCRn` | RO | 0 | Channel control |
| 0x40C + 0x20n | `LC0_n` | RO | 0 | Loop counter 0 (8 bit) |
| 0x410 + 0x20n | `LC1_n` | RO | 0 | Loop counter 1 (8 bit) |
| 0xD00 | `DBGSTATUS` | RO | 0 | [0] 1 = đang thực thi lệnh debug của manager |
| 0xD04 | `DBGCMD` | WO | – | Ghi `[1:0] = 00` để thực thi `DBGINST0/1`; giá trị khác bị bỏ qua |
| 0xD08 | `DBGINST0` | RW | 0 | Xem 6.4 (các bit reserved đọc về 0) |
| 0xD0C | `DBGINST1` | RW | 0 | Byte 2..5 của lệnh |
| 0xE00 | `CR0` | RO | theo tham số | Cấu hình |
| 0xE04 | `CR1` | RO | theo tham số | Cấu hình I-cache |
| 0xE08 | `CR2` | RO | `boot_addr` | Địa chỉ boot |
| 0xE0C | `CR3` | RO | 0 | (không dùng) |
| 0xE10 | `CR4` | RO | 0 | (không dùng) |
| 0xE14 | `CRD` | RO | theo tham số | Cấu hình datapath |
| 0xE80 | `WD` | RW | 0 | Watchdog: `[0] irq_only`, `[31:16] timeout` (×256 clk, 0 = tắt); bit khác reserved |
| 0xE84 | `WDSTAT` | W1C | 0 | `[n]` kênh n bị watchdog phát hiện treo; ghi 1 để xóa (mở rộng) |
| 0xFE0..0xFEC | `periph_id_0..3` | RO | `PERIPH_ID` | Mỗi word chứa 1 byte (byte k ở `[7:0]`) |
| 0xFF0..0xFFC | `pcell_id_0..3` | RO | 0x0D, 0xF0, 0x05, 0xB1 | PrimeCell ID = `0xB105F00D` |

(*) `DSR[9]` phản ánh `boot_manager_ns`. Nếu `boot_from_pc = 1`, manager bắt đầu chạy ngay sau reset.

### 6.2 Thanh ghi trạng thái

**DSR**

| Bit | Tên | Mô tả |
|---|---|---|
| [3:0] | `dmastatus` | 0 Stopped, 1 Executing, 2 Cache miss, 4 Waiting for event, 15 Faulting |
| [8:4] | `wakeup_event` | Event mà manager đang chờ |
| [9] | `dns` | Manager non-secure |

**CSRn**

| Bit | Tên | Mô tả |
|---|---|---|
| [3:0] | `channel_status` | 0 Stopped, 1 Executing, 2 Cache miss, 4 Waiting for event, 5 At barrier, 7 Waiting for peripheral, 8 Killing, 9 Completing, 14 Faulting completing, 15 Faulting |
| [8:4] | `wakeup_number` | Event hoặc peripheral mà kênh đang chờ |
| [14] | `dmawfp_b_ns` | Đang chờ trong `DMAWFP B` |
| [15] | `dmawfp_periph` | Đang chờ trong `DMAWFP P` |
| [21] | `CNS` | Kênh non-secure |

Mã 3 (Updating PC) có trong DMA-330 nhưng không bao giờ xuất hiện ở thiết kế này.

**CCRn** (nạp bằng `DMAMOV CCR`)

| Bit | Trường | Mô tả |
|---|---|---|
| [0] | `src_inc` | 1 INCR, 0 FIXED |
| [3:1] | `src_burst_size` | log2(byte/beat), ≤ log2(`DATA_W`/8) |
| [7:4] | `src_burst_len` | Số beat − 1 (0..15) |
| [10:8] | `src_prot` | → `ARPROT` (bit 1 bị OR với NS của kênh) |
| [13:11] | `src_cache` | → `ARCACHE[2:0]` |
| [14] | `dst_inc` | |
| [17:15] | `dst_burst_size` | |
| [21:18] | `dst_burst_len` | |
| [24:22] | `dst_prot` | → `AWPROT` |
| [27:25] | `dst_cache` | → `AWCACHE[2:0]` |
| [30:28] | `endian_swap_size` | 0: không swap; 1: 16 bit; 2: 32 bit; 3: 64 bit; 4: 128 bit (cần `DATA_W = 128`); 5–7: không hợp lệ. Áp dụng cho dữ liệu ghi của `DMAST`/`DMASTP` (`DMASTZ` bỏ qua trường này). Yêu cầu nhóm swap ≤ `dst_burst_size` và `DAR` align theo nhóm |
| [31] | – | Reserved, bị bỏ qua |

### 6.3 Thanh ghi cấu hình

| Thanh ghi | Bit | Nội dung (mặc định) |
|---|---|---|
| `CR0` | [0] | 1: có peripheral request |
| | [1] | `boot_from_pc` |
| | [2] | `boot_manager_ns` |
| | [7:4] | `NUM_CH − 1` (3) |
| | [16:12] | `NUM_PERIPH − 1` (3) |
| | [21:17] | `NUM_EVENTS − 1` (15) |
| `CR1` | [2:0] | log2(byte/line I-cache) (5 → 32 B) |
| | [7:4] | `IC_LINES − 1` (7) |
| `CRD` | [2:0] | log2(`DATA_W`/8) (3 → 64 bit) |
| | [6:4] | `WR_OUT − 1` |
| | [11:8] | `WQ_DEPTH − 1` |
| | [14:12] | `RD_OUT − 1` |
| | [19:16] | `RQ_DEPTH − 1` |
| | [29:20] | `NUM_CH*MFIFO_LINES − 1` (tổng số line MFIFO) |

Giá trị mặc định: `CR0 = 0x001E_3031` khi `boot_from_pc = 0` và `boot_manager_ns = 0`; `CR1 = 0x0000_0075`; `CRD = 0x07F3_3333`.

### 6.4 Giao diện debug

**DBGINST0**

| Bit | Trường | Mô tả |
|---|---|---|
| [0] | `debug_thread` | 0 manager, 1 channel |
| [10:8] | `channel_number` | Kênh nhận lệnh (khi `debug_thread = 1`) |
| [23:16] | `instruction_byte0` | Opcode |
| [31:24] | `instruction_byte1` | |

**DBGINST1** `[31:0]` = byte 5..2 của lệnh (byte 2 ở `[7:0]`).

Lệnh debug được phép:

| Thread | Lệnh | Kết quả |
|---|---|---|
| Manager | `DMAGO` | Khởi động kênh |
| Manager | `DMASEV` | Set event |
| Manager | `DMAKILL` | Dừng manager; đây là cách duy nhất để thoát `Faulting` |
| Manager | `DMANOP` | Không làm gì |
| Manager | Lệnh khác | Manager lỗi (`undef_instr` + `dbg_instr`) |
| Channel | `DMAKILL` | Kill kênh |
| Channel | `DMASEV` | Set event (số event sai → kênh lỗi) |
| Channel | Lệnh khác | Kênh lỗi (`undef_instr` + `dbg_instr`) |

---

## 7. Tập lệnh (ISA)

Lệnh được mã hóa little-endian: byte 0 là opcode, các byte sau là operand. Ký hiệu: `cs` = điều kiện (`x=1` nghĩa là có điều kiện, `bs=1` là B, `bs=0` là S); `P` = số peripheral 5 bit; `E` = số event 5 bit.

| Lệnh | Byte | Mã hóa | Thread | Chức năng |
|---|---|---|---|---|
| `DMAEND` | 1 | `00` | M, C | Kết thúc chương trình; kênh chờ datapath idle |
| `DMAKILL` | 1 | `01` | M, C | Dừng thread |
| `DMALD[S\|B]` | 1 | `04` / `05` (S) / `07` (B) | C | Issue một burst đọc từ `SAR` theo `CCR.src_*`; `SAR += bytes` |
| `DMAST[S\|B]` | 1 | `08` / `09` / `0B` | C | Issue một burst ghi tới `DAR` theo `CCR.dst_*`; `DAR += bytes` |
| `DMASTZ` | 1 | `0C` | C | Ghi burst toàn số 0 (không dùng MFIFO) |
| `DMARMB` | 1 | `12` | C | Read memory barrier |
| `DMAWMB` | 1 | `13` | C | Write memory barrier |
| `DMANOP` | 1 | `18` | M, C | Không làm gì |
| `DMALP LCx, n` | 2 | `20`/`22`, `n-1` | C | `LC0`/`LC1 = n-1` (n = 1..256) |
| `DMALDP<S\|B> P` | 2 | `25`/`27`, `P<<3` | C | `DMALD` + ack cho peripheral khi đọc xong |
| `DMASTP<S\|B> P` | 2 | `29`/`2B`, `P<<3` | C | `DMAST` + ack cho peripheral khi có B |
| `DMALPEND[S\|B] LCx` | 2 | `0 0 1 1 1 lc bs x` (`38`/`3C`, cond `39/3B/3D/3F`), `jump` | C | Nếu `LCx ≠ 0`: giảm `LCx`, `PC -= jump` |
| `DMALPFE` | 2 | `0 0 1 0 1 lc bs x` (`28`/`2C`, cond `2D/2F`), `jump` | C | Lặp cho tới khi peripheral gửi `drlast` |
| `DMAWFP P, S\|B\|P` | 2 | `30` (S) / `32` (B) / `31` (P), `P<<3` | C | Chờ request của peripheral; đặt `request_type` |
| `DMASEV E` | 2 | `34`, `E<<3` | M, C | Báo event E |
| `DMAFLUSHP P` | 2 | `35`, `P<<3` | M, C | Flush peripheral P |
| `DMAWFE E[, invalid]` | 2 | `36`, `E<<3 \| inv<<1` | M, C | Chờ event E; `invalid` = invalidate I-cache |
| `DMAADDH SAR\|DAR, imm16` | 3 | `54`/`56`, imm[7:0], imm[15:8] | C | `SAR/DAR += zero_extend(imm16)` |
| `DMAADNH SAR\|DAR, imm16` | 3 | `5C`/`5E`, imm | C | `SAR/DAR += {16'hFFFF, imm16}` (cộng một số âm) |
| `DMAMOV SAR\|CCR\|DAR, imm32` | 6 | `BC`, `0`/`1`/`2`, imm32 | C | Nạp thanh ghi |
| `DMAGO Cn, pc[, ns]` | 6 | `A0` / `A2` (ns), `n`, pc32 | M | Khởi động kênh n tại `pc` |

* `jump` của `DMALPEND`/`DMALPFE` = (địa chỉ lệnh `LPEND`) − (địa chỉ lệnh đầu tiên của thân vòng lặp), tối đa 255.
* `DMALPFE` có điều kiện phải dùng mã LC1 (`2D`/`2F`), vì mã LC0 (`29`/`2B`) trùng với `DMASTP`.

---

## 8. Trình tự phần mềm (software sequences)

Mã giả kiểu C, với `RD(off)` / `WR(off, v)` là truy cập 32 bit tới `DMA_BASE + off`.

### 8.1 Tích hợp phần cứng và power-up

1. Cấp các clock (`clk`, và nếu dùng: `pclk`, `aclk`, `periph_clk[]`). Ở chế độ async, tỉ lệ giữa các clock là tùy ý.
2. Đặt chân boot ổn định: `boot_from_pc`, `boot_addr`, `boot_manager_ns`.
3. Assert đồng thời mọi reset trong ít nhất 2 chu kỳ của clock chậm nhất, rồi deassert. Thứ tự deassert không quan trọng, vì mỗi domain tự đồng bộ.
4. Chờ ít nhất 3 chu kỳ của mỗi clock để reset synchronizer nhả, rồi mới truy cập APB. Không truy cập APB khi lõi còn trong reset.
5. Nếu `boot_from_pc = 1`, chương trình boot phải được nạp vào bộ nhớ **trước** khi reset nhả.

### 8.2 Khởi tạo driver

```c
#define DSR        0x000
#define DPC        0x004
#define INTEN      0x020
#define INT_RIS    0x024
#define INTMIS     0x028
#define INTCLR     0x02C
#define FSRD       0x030
#define FSRC       0x034
#define FTRD       0x038
#define FTR(n)     (0x040 + 4*(n))
#define CSR(n)     (0x100 + 8*(n))
#define CPC(n)     (0x104 + 8*(n))
#define SAR(n)     (0x400 + 0x20*(n))
#define DAR(n)     (0x404 + 0x20*(n))
#define DBGSTATUS  0xD00
#define DBGCMD     0xD04
#define DBGINST0   0xD08
#define DBGINST1   0xD0C
#define FAR(n)     (0x060 + 4*(n))
#define WD         0xE80
#define WDSTAT     0xE84
#define CR0        0xE00
#define CR1        0xE04
#define CRD        0xE14

int dma_init(void)
{
    /* 1. Nhận dạng IP */
    uint32_t pcell = 0, pid = 0;
    for (int k = 0; k < 4; k++) {
        pcell |= (RD(0xFF0 + 4*k) & 0xFF) << (8*k);
        pid   |= (RD(0xFE0 + 4*k) & 0xFF) << (8*k);
    }
    if (pcell != 0xB105F00D) return -ENODEV;

    /* 2. Đọc cấu hình phần cứng */
    uint32_t cr0 = RD(CR0), crd = RD(CRD);
    num_ch     = ((cr0 >> 4)  & 0x7)  + 1;
    num_periph = ((cr0 >> 12) & 0x1F) + 1;
    num_events = ((cr0 >> 17) & 0x1F) + 1;
    bus_bytes  = 1u << (crd & 0x7);
    mfifo_bytes_per_ch = ((((crd >> 20) & 0x3FF) + 1) / num_ch) * bus_bytes;

    /* 3. Trạng thái sạch: manager và các kênh dừng, không có lỗi */
    if (!(cr0 & 0x2) && (RD(DSR) & 0xF) != 0) return -EBUSY;   /* không boot từ PC */
    for (int n = 0; n < num_ch; n++)
        if ((RD(CSR(n)) & 0xF) != 0) dma_kill_channel(n);       /* xem 8.9 */
    if (RD(FSRD) & 1) dma_kill_manager();

    /* 4. Interrupt: event 0..num_ch-1 báo hoàn tất kênh tương ứng,
          các event còn lại dùng để đồng bộ giữa các kênh */
    WR(INTEN, (1u << num_ch) - 1);
    WR(INTCLR, 0xFFFFFFFF);

    /* 5. Watchdog: báo kênh treo sau ~1 triệu chu kỳ (4096 x 256), abort kênh */
    WR(WD, 4096u << 16);
    WR(WDSTAT, 0xFF);

    /* 6. Đăng ký ISR cho irq[0..num_ch-1] và irq_abort */
    return 0;
}
```

### 8.3 Gửi lệnh debug

Chuỗi DBGINST0 → DBGINST1 → DBGCMD phải **nguyên tử**. Nếu nhiều context (nhiều CPU core hoặc ISR) cùng dùng DMA, phải bảo vệ chuỗi này bằng mutex/spinlock.

```c
static void dma_dbg_exec(int to_channel, int ch, const uint8_t insn[6])
{
    lock(&dma_dbg_lock);
    while (RD(DBGSTATUS) & 1) ;                       /* chờ lệnh manager trước xong */
    WR(DBGINST0, (insn[1] << 24) | (insn[0] << 16) | ((ch & 7) << 8) | (to_channel & 1));
    WR(DBGINST1, insn[2] | (insn[3] << 8) | (insn[4] << 16) | (insn[5] << 24));
    WR(DBGCMD, 0);
    unlock(&dma_dbg_lock);
}

void dma_go(int ch, uint32_t pc, int ns)              /* DMAGO qua manager */
{
    uint8_t i[6] = { 0xA0 | (ns << 1), ch, pc, pc >> 8, pc >> 16, pc >> 24 };
    dma_dbg_exec(0, 0, i);
}
void dma_kill_channel(int ch) { uint8_t i[6] = {0x01}; dma_dbg_exec(1, ch, i); }
void dma_kill_manager(void)   { uint8_t i[6] = {0x01}; dma_dbg_exec(0, 0,  i); }
void dma_sev(int ev)          { uint8_t i[6] = {0x34, ev << 3}; dma_dbg_exec(1, 0, i); }
```

Ví dụ giá trị thanh ghi:

| Hành động | DBGINST0 | DBGINST1 |
|---|---|---|
| `DMAGO C0, 0x0001_0000` (secure) | `0x00A0_0000` | `0x0001_0000` |
| `DMAGO C2, 0x0003_0000, ns` | `0x02A2_0000` | `0x0003_0000` |
| `DMAKILL` kênh 2 | `0x0001_0201` | – |
| `DMAKILL` manager | `0x0001_0000` | – |
| `DMASEV E9` (qua kênh 0) | `0x4834_0001` | – |

### 8.4 Truyền memory → memory

Ví dụ: copy 1024 byte từ `0x1000_0000` tới `0x2000_0000` trên kênh 0, bus 64 bit, burst 16 × 8 B = 128 B, 8 lần lặp. Báo xong bằng event 0.

`CCR = 0x003D_C0F7`: src INCR, size 3, len 15; dst INCR, size 3, len 15; prot/cache = 0.

Nếu muốn giao dịch bufferable/modifiable, đặt `src_cache = dst_cache = 3`, tức `CCR |= (3 << 11) | (3 << 25)`.

```
addr  bytes                  lệnh
0000  BC 00 00 00 00 10      DMAMOV SAR, 0x10000000
0006  BC 02 00 00 00 20      DMAMOV DAR, 0x20000000
000C  BC 01 F7 C0 3D 00      DMAMOV CCR, 0x003DC0F7
0012  20 07                  DMALP  LC0, 8
0014  04                     DMALD
0015  08                     DMAST
0016  38 02                  DMALPEND LC0          (jump = 0x16 - 0x14)
0018  13                     DMAWMB
0019  34 00                  DMASEV E0
001B  00                     DMAEND
```

Trình tự phần mềm:

```c
void dma_m2m(int ch, uint32_t prog_addr)
{
    write_program(prog_addr, prog, sizeof prog);   /* + cache clean nếu CPU có D-cache */
    dma_go(ch, prog_addr, 0);
    /* hoàn tất: interrupt irq[ch] (8.6) hoặc polling (8.5) */
}
```

Với độ dài/địa chỉ bất kỳ, driver tách đoạn cần copy thành các burst hợp lệ, gồm phần thân lặp và các phần lẻ ở đầu/cuối. Phần lẻ dùng `DMAMOV CCR` với size hoặc len khác (xem `dma_prog_gen::split`). Tổng byte `DMALD` phải bằng tổng byte `DMAST`.

### 8.5 Chờ hoàn tất bằng polling

```c
int dma_wait_poll(int ch)
{
    for (;;) {
        uint32_t st = RD(CSR(ch)) & 0xF;
        if (st == 0)  return 0;              /* Stopped: DMAEND đã xong */
        if (st >= 14) return -EIO;           /* Faulting / Fault completing */
    }
}
```

### 8.6 Interrupt handler

```c
void dma_isr(void)                           /* irq[0..NUM_EVENTS-1] */
{
    uint32_t mis = RD(INTMIS);
    WR(INTCLR, mis);                         /* xóa trước, tránh mất event mới */
    for (int e = 0; e < 32; e++)
        if (mis & (1u << e)) complete_job(e);   /* event e <-> kênh/job */
}

void dma_abort_isr(void)                     /* irq_abort */
{
    uint32_t wds = RD(WDSTAT);
    if (wds) {
        log("watchdog: channels %02x made no progress (bus hung?)", wds);
        WR(WDSTAT, wds);                     /* W1C */
    }
    if (RD(FSRD) & 1) {
        log("manager fault FTRD=%08x DPC=%08x", RD(FTRD), RD(DPC));
        dma_kill_manager();
    }
    uint32_t fsrc = RD(FSRC);
    for (int n = 0; n < num_ch; n++) {
        if (!(fsrc & (1u << n))) continue;
        /* đợi Fault completing -> Faulting (burst đang bay đã retire).
           Với lockup_err trên bus treo vĩnh viễn, trạng thái này có thể
           không bao giờ đến: dùng timeout và reset slave/hệ thống. */
        if (!wait_status(n, 15, TIMEOUT_US)) { escalate_bus_hang(n); continue; }
        log("ch%d fault FTR=%08x CPC=%08x FAR=%08x SAR=%08x DAR=%08x",
            n, RD(FTR(n)), RD(CPC(n)), RD(FAR(n)), RD(SAR(n)), RD(DAR(n)));
        dma_kill_channel(n);
        while ((RD(CSR(n)) & 0xF) != 0) ;    /* Killing -> Stopped, FTR = 0 */
        fail_job(n);
    }
}
```

### 8.7 Truyền theo nhịp peripheral

**Memory → peripheral** (TX FIFO tại địa chỉ cố định `FIFO`, mỗi request là một burst `B` byte):

```
DMAMOV SAR, buf
DMAMOV DAR, FIFO
DMAMOV CCR, {src INCR size s len L, dst FIXED size s len L}
DMAFLUSHP P
DMALP LC0, N
    DMAWFP P, burst
    DMALD
    DMASTPB P              ; ack "burst xong" khi B về
DMALPEND LC0
DMAWMB
DMASEV E
DMAEND
```

**Peripheral → memory**: đổi `DMALD` thành `DMALDPB P`, đổi `DMASTPB P` thành `DMAST`; src FIXED, dst INCR. Ack được gửi khi burst đọc kết thúc.

**Số lượng do peripheral quyết định** (single hoặc burst, dừng khi `drlast`):

```
DMAFLUSHP P
loop:
    DMAWFP P, periph        ; request_type lấy từ drtype
    DMALDS                  ; chỉ chạy khi request là single
    DMALDB                  ; chỉ chạy khi request là burst
    DMASTPS P
    DMASTPB P
DMALPFE (LC1 encoding)       ; lặp tới khi drlast = 1
```

Với CCR chung, lệnh single và burst dùng cùng hình dạng burst. Nếu muốn single chỉ là 1 beat, dùng `DMAMOV CCR` riêng trước mỗi lệnh.

Phía peripheral:
* trả `drtype = 10` khi nhận flush request (`datype = 10`);
* chỉ gửi request khi `drready = 1`;
* thường chờ ack tương ứng (`datype = 00/01`) trước khi gửi request tiếp theo.

### 8.8 Đồng bộ hai kênh bằng event

Kênh 1 chỉ bắt đầu đọc vùng dữ liệu sau khi kênh 0 đã ghi xong. Dùng event 8, với `INTEN[8] = 0`.

```
kênh 0:  ... DMAST ... ; DMAWMB ; DMASEV E8 ; DMASEV E0 ; DMAEND
kênh 1:  DMAWFE E8 ; DMAMOV SAR,... ; DMALD ... ; DMAWMB ; DMASEV E1 ; DMAEND
```

* Thứ tự `dma_go` của hai kênh không quan trọng, vì event được giữ lại nếu `DMASEV` đến trước `DMAWFE`.
* Nhiều kênh có thể cùng chờ một event; một `DMASEV` thả tất cả.
* CPU có thể tự thả kênh bằng `dma_sev(8)`.
* Nếu chương trình của kênh được CPU sửa trong khi kênh khác đang chạy, dùng `DMAWFE E, invalid` để kênh bỏ instruction cache cũ.

### 8.9 Dừng (abort) một kênh

```c
void dma_abort(int ch)
{
    dma_kill_channel(ch);
    while ((RD(CSR(ch)) & 0xF) != 0) ;   /* Killing -> Stopped */
    /* Dữ liệu đích có thể chỉ được ghi một phần (SAR/DAR cho biết đã đi tới đâu).
       Nếu kênh dùng peripheral, chương trình kế tiếp phải bắt đầu bằng DMAFLUSHP. */
}
```

### 8.10 Chế độ boot từ PC

1. Viết chương trình manager vào bộ nhớ tại `boot_addr`, ví dụ:
   ```
   DMAGO C0, prog0, ns
   DMAGO C1, prog1, ns
   DMAWFE E12            ; prog1 kết thúc bằng DMASEV E12
   DMASEV E11            ; báo CPU (INTEN[11] = 1)
   DMAEND
   ```
2. Đặt `boot_from_pc = 1`, `boot_addr`, `boot_manager_ns`, rồi nhả reset.
3. CPU khởi tạo `INTEN` sớm nhất có thể. Event nào bị báo trước khi `INTEN` được set vẫn được giữ lại trong `INT_EVENT_RIS`, và sẽ thành interrupt ngay khi bit `INTEN` được bật.
4. Nếu manager non-secure: mọi `DMAGO` trong chương trình phải có cờ `ns`, nếu không manager báo lỗi `dmago_err`.
5. Trong lúc manager chạy chương trình boot, lệnh debug cho manager bị trì hoãn (`DBGSTATUS = 1`) cho tới khi manager dừng.

### 8.11 Endian swap

Ví dụ: copy một buffer gồm các word 32 bit big-endian sang little-endian, với bus 64 bit, burst 16 × 8 B, swap 32 bit:

`CCR = 0x003DC0F7 | (2 << 28) = 0x203DC0F7`

Điều kiện: `DAR` align 4 byte, `dst_burst_size ≥ 2`, độ dài là bội của 4. Nếu vi phạm, kênh báo `ch_rdwr_err` ngay ở lệnh `DMAST` và không ghi gì ra bus.

### 8.12 Low power (phía clock controller)

```c
/* Vào trạng thái tắt clock */
qreqn = 0;
wait(!qacceptn || qdeny);
if (qdeny) { qreqn = 1; wait(!qdeny); /* thử lại sau */ }
else       { gate_dma_clock(); }

/* Đánh thức (khi qactive = 1 hoặc khi cần) */
ungate_dma_clock();
qreqn = 1;
wait(qacceptn);
```

Phần mềm DMA không cần thay đổi: một truy cập APB trong lúc DMA đang ngủ chỉ bị kéo dài cho tới khi controller đánh thức DMA.

### 8.13 Quy tắc viết chương trình (checklist cho driver)

1. **4 KB**: mọi burst (INCR) phải nằm trọn trong một trang 4 KB. DMA không tự cắt burst; burst vi phạm làm kênh lỗi `ch_rdwr_err` thay vì phát giao dịch AXI bất hợp lệ.
2. **Burst size** ≤ độ rộng bus (`CRD[2:0]`), nếu không kênh lỗi `ch_rdwr_err`.
3. **Cân bằng byte**: tổng byte `DMALD` = tổng byte `DMAST`/`DMASTP`. Mỗi `DMAST` chỉ được dùng byte đã được `DMALD` trước đó; nếu không sẽ lỗi `st_data_unavailable`.
4. **Ngân sách MFIFO**: số byte đã `DMALD` mà chưa `DMAST` không được vượt dung lượng MFIFO của kênh (`mfifo_bytes_per_ch`). Nếu vượt mà không còn store nào đứng sau, kênh lỗi `mfifo_err`. Cách an toàn là xen kẽ LD/ST như ví dụ 8.4.
5. **Endian swap**: `CCR[30:28]` ≤ `dst_burst_size`, `DAR` align theo nhóm swap; `CCR[31] = 0`.
6. **DMALPFE có điều kiện** dùng mã LC1.
7. **Kết thúc bằng `DMAWMB; DMASEV; DMAEND`** nếu interrupt phải có nghĩa là dữ liệu đã ghi xong.
8. **Chương trình phải có mặt trong bộ nhớ trước `DMAGO`**. Với CPU có D-cache, phải clean cache trước. `DMAGO` tự invalidate instruction cache của DMA.
9. **Peripheral**: bắt đầu bằng `DMAFLUSHP P` để xóa request cũ và đồng bộ với peripheral.
10. **Vùng chương trình** của mỗi kênh không được bị ghi đè trong khi kênh đang chạy.

### 8.14 Reset mềm và khởi tạo lại

DMA không có bit soft reset. Có hai cách khởi tạo lại:
* Dùng `DMAKILL` cho mọi kênh rồi cho manager (8.9), sau đó chạy lại `dma_init()`.
* Assert reset hệ thống cho mọi domain (8.1). Sau reset: `INTEN = 0`, mọi flag event bị xóa, `FTR`/`FTRD` = 0, mọi thread `Stopped`, và cache invalid.

---

## 9. Khác biệt so với Arm DMA-330 và giới hạn

| Mục | Thiết kế này |
|---|---|
| MFIFO | Chia tĩnh cho từng kênh; DMA-330 chia động một MFIFO chung |
| APB | Một cổng APB; security chỉ còn bit NS của manager/kênh, kiểm tra `DMAGO` và `AxPROT[1]`. Không có cổng APB non-secure, không có `CR3`/`CR4` (đọc về 0) |
| Endian swap `CCR[30:28]` | Hỗ trợ 16/32/64/128 bit trên dữ liệu ghi. Cấu hình swap không hợp lệ gây lỗi `ch_rdwr_err` (DMA-330: không xác định) |
| Watchdog | `WD[0] irq_only` giống DMA-330; thêm `WD[31:16] timeout` lập trình được và `WDSTAT`. Phát hiện mọi trường hợp kênh không có progress (kể cả bus treo) và báo `lockup_err` (FTR[31]). Lock-up do MFIFO vẫn được phát hiện ngay bằng `mfifo_err` |
| 4 KB | Driver phải tự bảo đảm như DMA-330. Thêm bảo vệ phần cứng: burst vi phạm gây `ch_rdwr_err` thay vì phát giao dịch bất hợp lệ |
| Nhận dạng | `PERIPH_ID` là tham số |
| `DMALPFE` có điều kiện | Chỉ dùng được mã LC1 (`0x2D`/`0x2F`), vì `0x29`/`0x2B` được decode là `DMASTP`. `0x2A` (bs=1, x=0) là `DMALPFE` LC0 không điều kiện, tương đương `0x28` |
| Status code 3 (Updating PC) | Không dùng |
| `PSLVERR` | Mặc định luôn bằng 0; tùy chọn `APB_SLVERR = 1` để báo lỗi truy cập |
| Mở rộng không có trong DMA-330 | `FARn`, `WDSTAT`, `WD.timeout`, Q-Channel, `APB_SLVERR` |
| Interrupt | `irq[]` ở domain `clk` |
| `DMAGO` | Invalidate toàn bộ instruction cache (DMA-330 chỉ invalidate line liên quan) |
| AXI | Không có `AxQOS`/`AxREGION`/`AxUSER`; mọi giao dịch dữ liệu có `AxLOCK = 0`, `AxCACHE[3] = 0` |
