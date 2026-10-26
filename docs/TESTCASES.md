# AXI DMA Controller `axi_dma330` — Đặc tả testcase

| Mục | Giá trị |
|---|---|
| Test library | `tb/tests/dma_test_pkg.sv` |
| Virtual sequence | `tb/seq/*.sv` |
| Tài liệu liên quan | [VERIFICATION_PLAN.md](VERIFICATION_PLAN.md) (mã VP-xxx), [DESIGN_SPEC.md](DESIGN_SPEC.md), [CMODEL.md](CMODEL.md) (C model qua DPI-C) |

---

## 1. Quy ước chung

### 1.1 Cấu trúc một test

```
dma_base_test
  build_phase : tạo cfg (APB/AXI/periph), đọc plusargs, configure(cfg), tạo env
  run_phase   : watchdog 10 triệu clk -> chờ reset nhả + 20 clk -> create_vseq().start() -> 200 clk
  report_phase: "*** TEST PASSED ***" nếu không có UVM_ERROR/UVM_FATAL
```

Test con override một hoặc nhiều hook sau:
* `configure()`: chỉnh knob VIP;
* `create_vseq()`: chọn virtual sequence;
* `tune()` (với test traffic): chỉnh knob của `dma_traffic_vseq`;
* `end_of_elaboration_phase()`: chuẩn bị bộ nhớ và chân boot trước khi reset nhả.

### 1.2 Bản đồ bộ nhớ dùng trong test

| Vùng | Địa chỉ |
|---|---|
| Chương trình kênh n | `0x0001_0000 + n*0x1_0000` (job chẵn/lẻ cách nhau `0x8000`; chương trình lỗi/kill ở `+0x4000`) |
| Nguồn của kênh n | `0x1000_0000 + n*0x0100_0000` (vùng 1 MB) |
| Đích của kênh n | `0x2000_0000 + n*0x0100_0000` (vùng 1 MB) |
| FIFO của peripheral p | `0x4000_0000 + p*0x1000` |
| Chương trình boot của manager | `0x0000_8000` |
| Vùng gây lỗi AXI | `0xE000_0000` (SLVERR đọc), `0xE001_0000` (DECERR ghi), `0xE002_0000` (SLVERR fetch), `0xE00F_0000` (boot lỗi) |

### 1.3 Luồng chuẩn của một job (`run_job`)

1. `dma_prog_gen::build(job)` sinh chương trình và danh sách op kỳ vọng (job `JOB_RAND`: `dma_rand_prog` sinh chương trình, không có danh sách op), nạp vào bộ nhớ của AXI slave, đăng ký vùng chương trình với scoreboard, sample `cg_job`/`cg_insn`.
1b. `sb.model_job(job)`: **C reference model** (DPI-C) giải mã và chạy chính chương trình đó trong bộ nhớ, rồi đối chiếu với danh sách op và chuỗi ack mà generator đã dự đoán (`SB_XCHECK`).
2. `sb.add_job(job)`: reference model dự đoán mọi burst AXI và mọi ack peripheral (từ danh sách op; với `JOB_RAND` từ C model).
3. Nếu job dùng peripheral: chạy song song `periph_req_seq` trên agent của peripheral tương ứng.
4. `DMAGO` qua debug (`DBGINST0/1` + `DBGCMD`, poll `DBGSTATUS`).
5. Chờ `irq[ch]` (timeout 400 000 clk), ghi `INTCLR`, poll `CSR[ch]` tới khi bằng Stopped.
5b. `check_arch_state(job)`: đọc `CPC`, và `SAR`/`DAR`/`CCR`/`LC0`/`LC1` mà chương trình đã ghi, so với giá trị cuối của C model (`ARCH`).
6. `sb.job_done(job)`: kiểm tra không còn burst hoặc ack kỳ vọng nào bị thiếu.

Kiểm tra chung cho **mọi** test:
* toàn bộ SVA ở mục 4.2 của verification plan;
* scoreboard (mục 4.1);
* C model: đối chiếu dự đoán của generator (`SB_XCHECK`) và trạng thái thanh ghi cuối job (`ARCH`) trong mọi test có chạy job qua `load_job`/`dma_boot_test` (tắt bằng `+NO_CMODEL`);
* watchdog;
* `report_phase` không có lỗi.

### 1.4 Lệnh chạy

```sh
cd sim
make sim TEST=<test> CFG=sync|async SEED=<n>      # một test
make gui TEST=<test> CFG=async                      # có waveform
python run_regression.py -t <test> -c sync async --seeds 5 -j 8
```

---

## 2. Bảng tổng hợp

| TC | Test | Loại | Thời lượng điển hình* | Nhóm VP chính |
|---|---|---|---|---|
| TC-01 | `dma_reg_test` | Directed | ngắn | REG |
| TC-02 | `dma_m2m_aligned_test` | Random | ngắn | DP, ISA-01 |
| TC-03 | `dma_m2m_unaligned_test` | Random + 1 job có hướng | trung bình | DP-01..06, AXI-08 |
| TC-04 | `dma_multi_ch_test` | Random | trung bình | DP-07, AXI-02/03 |
| TC-05 | `dma_fixed_addr_test` | Random | trung bình | DP-04 |
| TC-06 | `dma_fill_test` | Random | ngắn | ISA-02 |
| TC-07 | `dma_loop2d_test` | Random | trung bình | ISA-03/04 |
| TC-08 | `dma_periph_test` | Random | trung bình | PER, ISA-06/07/08 |
| TC-09 | `dma_event_test` | Directed + random | ngắn | EVT |
| TC-10 | `dma_boot_test` | Directed | ngắn | MGR-01..04, MGR-08 |
| TC-11 | `dma_fault_test` | Directed | dài | FLT, MGR-06/07, AXI-06 |
| TC-12 | `dma_kill_test` | Directed | trung bình | KILL |
| TC-13 | `dma_stress_test` | Random | dài | Tất cả, AXI-01, PER-09 |
| TC-14 | `dma_isa_test` | Random | trung bình | ISA-03/04/05 |
| TC-15 | `dma_periph_corner_test` | Directed | trung bình | PER-05..08, PER-11, ISA-06/07/08/10 |
| TC-16 | `dma_boot_err_test` | Directed | ngắn | MGR-05 |
| TC-17 | `dma_reset_test` | Directed + random | ngắn | RST |
| TC-18 | `dma_endian_test` | Random | ngắn | DP-10 |
| TC-19 | `dma_watchdog_test` | Directed | trung bình | WD, FLT-20 |
| TC-20 | `dma_lowpower_test` | Directed + random | trung bình | LP |
| TC-21 | `dma_rand_prog_test` | Random (chương trình ngẫu nhiên, C model) | trung bình | CM-01..05 |
| TC-22 | `dma_cmodel_mix_test` | Random (mọi loại job + chương trình ngẫu nhiên) | trung bình | CM-01..05, AXI-01 |
| TC-23 | `dma_mfifo_share_test` | Directed | trung bình | MF-01..07, DP-08, FLT-20 |
| TC-24 | `dma_security_test` | Directed | trung bình | SEC-01..13 |

\* Toàn bộ 144 lần chạy (24 test × 2 cấu hình × 3 seed) mất khoảng 3–4 phút với 4 tiến trình song song.

Ma trận test × tính năng:

| Tính năng \ TC | 01 | 02 | 03 | 04 | 05 | 06 | 07 | 08 | 09 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Register / RAL | ● | | | | | | | | | ○ | ○ | | | | | ○ | ● |
| M2M copy | | ● | ● | ● | ● | ○ | | | ● | ● | ○ | ○ | ● | ○ | | ○ | ● |
| Alignment / size | | | ● | ● | ○ | ○ | | | ○ | ○ | | | ● | | | | ○ |
| FIXED | | | | | ● | | | ○ | | | | | ○ | | ○ | | |
| Loop / 2D | | ○ | ○ | ○ | ○ | ○ | ● | ● | | | | | ● | ● | ○ | | |
| Peripheral | | | | | | | | ● | | ○ | ○ | ○ | ● | | ● | | |
| Event / IRQ | | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ● | ● | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| Manager / boot | | | | | | | | | | ● | ● | | | | | ● | |
| Fault | | | | | | | | | | ○ | ● | | | | | ● | |
| Kill | | | | | | | | | | ○ | ● | ● | | ○ | | ● | |
| Reset | ○ | | | | | | | | | | | | | | | | ● |
| Back-pressure nặng | | | | | | | | | | | | ● | ● | | | | |

● trọng tâm của test, ○ được dùng hoặc kiểm tra phụ. Mọi test đều chạy ở cả cấu hình sync và async.

---

## 3. Chi tiết testcase

### TC-01 `dma_reg_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Register map đúng DMA-330: reset value, quyền truy cập, ID, cấu hình, địa chỉ không được map, `DBGCMD` reserved |
| Sequence | `dma_reg_vseq` |
| VP | REG-01..07 |

Trình tự:
1. `uvm_reg_hw_reset_seq` trên toàn bộ RAL: đọc mọi thanh ghi và so với reset value. Reset value của `CR0`/`CR1`/`CRD`/ID được tính từ tham số DUT.
2. `uvm_reg_bit_bash_seq`: ghi/đọc từng bit của các thanh ghi RW (`INTEN`, `DBGINST0`, `DBGINST1`, `WD`), kiểm tra bit reserved và thanh ghi RO.
3. Ghép `pcell_id_0..3` → phải bằng `0xB105F00D`.
4. `DSR` và mọi `CSRn` phải ở Stopped; mọi `CCRn = 0x0080_0200` (reset value của TRM). `periph_id_0..3` là giá trị mặc định của DUT (r1p2 `0x30, 0x13, 0x34, 0x00`; `tb_top` không truyền tham số `PERIPH_ID`), kiểm bằng RAL ở bước 1.
5. Ghi `DBGINST0 = 0x0001_0000` (`DMAKILL` manager), rồi `DBGCMD = 01` (giá trị reserved). Kỳ vọng `DBGSTATUS[0] = 0` và `DSR` vẫn Stopped.
6. Đọc APB thô ở `0x200`, `0x8F0`, `0xC00` (không được map): kỳ vọng 0.
7. `PSLVERR` (VP-REG-08). Kỳ vọng `PSLVERR = APB_SLVERR`, tức 1 ở cấu hình async và 0 ở cấu hình sync:
   * đọc/ghi 4 địa chỉ không được map (gồm `0xE88`) và `CSR` của kênh `NUM_CH` (không tồn tại);
   * ghi giá trị đảo vào 6 thanh ghi RO (`DSR`, `FTRD`, `FTR0`, `FAR0`, `CR0`, `PCELL_ID0`); đọc lại thanh ghi đó phải không đổi;
   * ghi hợp lệ vào `INTEN` không bao giờ có `PSLVERR`.

   Ở cấu hình async, bit-bash bỏ qua các thanh ghi chỉ có field RO, vì ghi vào chúng hợp lệ trả lỗi.

Tiêu chí PASS: không có lỗi RAL, mọi so sánh đúng.

---

### TC-02 `dma_m2m_aligned_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Copy memory → memory cơ bản, dữ liệu 64 bit align |
| Sequence | `dma_traffic_vseq`: `ch_mask = 1` (kênh 0), `jobs_per_ch = 6`, `aligned_only = 1` |
| Ràng buộc | `src`, `dst`, `nbytes` chia hết cho 8; beat size 8 B ở cả hai phía; burst len 1..16 ngẫu nhiên; độ dài 8..2048 B |
| VP | ISA-01, DP-02, DP-05, EVT-05 |

Trình tự: 6 job `JOB_M2M` liên tiếp trên kênh 0 (luồng 1.3).

Kiểm tra: scoreboard so từng burst đọc/ghi (địa chỉ, len, size, cache, prot, dữ liệu, strobe); `irq[0]` cho mỗi job.

---

### TC-03 `dma_m2m_unaligned_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Copy với alignment, beat size và burst len bất kỳ, phía nguồn và đích khác nhau |
| Sequence | `dma_traffic_vseq`: kênh 0, `cross_4k = 1`, 1 job có hướng + 16 job ngẫu nhiên |
| Ràng buộc | `src`/`dst` bất kỳ trong vùng của kênh; `src_size`, `dst_size` ∈ 0..3; `src_beats`, `dst_beats` ∈ 1..16; `nbytes` 1..2048 (25 % ≤ 64 B) |
| VP | DP-01, DP-02, DP-03, DP-05, DP-06, AXI-08 |

Job có hướng đầu tiên: copy 512 B, burst 16 × 8 B, `src = 0x…0FC0` (align), `dst = 0x…0FC5` (không align): burst đầu của mỗi phía vượt biên 4 KB và được DMA tách thành hai burst AXI (TRM 2.10.5). Ở mọi job M2M/fill, generator cho phép burst vượt 4 KB với xác suất 1/2.

Điểm cần chú ý:
* Generator cắt phần lẻ ở đầu/cuối thành burst byte (size 0).
* Scoreboard tách burst kỳ vọng vượt 4 KB như DMA (SB-12); báo cáo cuối test in số burst đã tách (> 0).
* Chương trình đổi `CCR` giữa các burst khi hình dạng burst thay đổi.
* Có burst không align và beat hẹp, nên MFIFO phải xoay byte đúng giữa hai phía.

Kiểm tra: scoreboard (dữ liệu và `WSTRB` từng beat); coverage `x_size`, `x_align`.

---

### TC-04 `dma_multi_ch_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | 4 kênh chạy đồng thời: phân xử AR/W, ID khác nhau, phản hồi out-of-order, R xen kẽ |
| Sequence | `dma_traffic_vseq`: `ch_mask = 0xF`, 8 job mỗi kênh, mỗi kênh một thread song song |
| VP | DP-07, AXI-02, AXI-03, AXI-04, EVT-05 |

Kiểm tra: scoreboard so theo ID (mỗi kênh đúng thứ tự riêng); `wait_irq` của 4 kênh chạy song song (mỗi watchdog được hủy độc lập); cover `AXI_C_R_INTERLEAVE`.

---

### TC-05 `dma_fixed_addr_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Địa chỉ FIXED (FIFO) ở nguồn, đích hoặc cả hai |
| Sequence | `dma_traffic_vseq`: `fixed_mode = 1`, 4 kênh × 6 job, `nbytes ≤ 512` |
| Ràng buộc | Mỗi job chọn đều một trong 4 chế độ: src FIXED, dst FIXED, cả hai FIXED, cả hai INCR. Chế độ được áp dưới dạng ràng buộc cứng |
| VP | DP-04, AXI `ARBURST/AWBURST = FIXED` |

Điểm cần chú ý: với FIXED không align, mọi beat dùng cùng lane và cùng số byte; `SAR`/`DAR` không tăng.

Kiểm tra: scoreboard; coverage `x_inc` đủ 4 ô; cover `AXI_C_FIXED_BURST`.

---

### TC-06 `dma_fill_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | `DMASTZ`: ghi toàn số 0 không qua MFIFO, xen với copy thường |
| Sequence | `dma_traffic_vseq`: `kinds = {JOB_FILL, JOB_M2M}`, 4 kênh × 6 job |
| VP | ISA-02 |

Kiểm tra: `WDATA = 0`, `WSTRB` đúng, không có burst đọc nào cho job FILL.

---

### TC-07 `dma_loop2d_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Vòng lặp lồng nhau, `DMAADDH`/`DMAADNH`, truyền khối 2D |
| Sequence | `dma_traffic_vseq`: `kinds = {JOB_LOOP2D}`, 4 kênh × 8 job |
| Ràng buộc | `rows` 1..8, `row_bursts` 1..4, `src_gap`/`dst_gap` 0..64 (bội của 8), `dst_reverse` ngẫu nhiên (ghi các hàng theo thứ tự ngược bằng `DMAADNH DAR`); toàn khối nằm trong một trang 4 KB |
| VP | ISA-03, ISA-04 |

Chương trình mẫu:
```
DMAMOV SAR/DAR/CCR
DMALP LC1, rows
  DMALP LC0, row_bursts
    DMALD ; DMAST
  DMALPEND LC0
  DMAADDH SAR, src_gap
  DMAADDH DAR, dst_gap   | DMAADNH DAR, -(row + stride)
DMALPEND LC1
DMAWMB ; DMASEV ; DMAEND
```

Kiểm tra: scoreboard trải phẳng các vòng lặp thành danh sách op và so từng burst.

---

### TC-08 `dma_periph_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Truyền theo nhịp peripheral: WFP/LDP/STP/FLUSHP, lệnh có điều kiện, `DMALPFE` + `drlast`, ack đọc và ack ghi |
| Sequence | `dma_traffic_vseq`: `kinds = {JOB_M2P, JOB_P2M, JOB_PERIPH_MIXED, JOB_P2M_MIXED, JOB_COND_LOOP}`, 4 kênh × 8 job, kênh n dùng peripheral n |
| VP | PER-01..04, ISA-06, ISA-07, ISA-08, ISA-10 |

Kịch bản theo loại job:

| Job | Request peripheral gửi | Ack kỳ vọng |
|---|---|---|
| M2P | N × burst | FLUSH, N × BURST (khi có B) |
| P2M | N × burst | FLUSH, N × BURST (khi RLAST) |
| PERIPH_MIXED | N × (single \| burst ngẫu nhiên), request cuối có `drlast` | FLUSH, chuỗi SINGLE/BURST tương ứng; request single chuyển 1 beat (`DMALDS`/`DMASTPS`), burst chuyển một burst `CCR` |
| P2M_MIXED | Như trên, `DMALPFE` dùng mã LC1 | Ack đọc SINGLE/BURST; single 1 beat |
| COND_LOOP | 3 × single; thân vòng `DMAWFP S; DMALDS; DMASTPS` (1 beat mỗi lần) | `DMALPENDS` LC1 lặp 2 lần (điều kiện đúng); `DMALPENDB` LC0 thoát sau lần 1 (điều kiện sai) |

Kiểm tra: scoreboard (burst và chuỗi ack); SVA `PER_*`; peripheral VIP trả flush ack và chờ ack trước request kế tiếp.

---

### TC-09 `dma_event_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Đồng bộ giữa các thread bằng event; sự khác nhau giữa event và interrupt |
| Sequence | `dma_event_vseq` (`INTEN = 0x000F`: event 0..3 là interrupt báo hoàn tất) |
| VP | EVT-01..05, EVT-07, ISA-09 |

| Phần | Trình tự | Kiểm tra |
|---|---|---|
| 1 | Kênh 0: `DMAWFE E8` rồi copy. Kênh 1: copy, `DMAWMB`, `DMASEV E8`. Start kênh 0, chờ 200 clk, rồi mới start kênh 1 | Kênh 0 ở trạng thái Waiting for event với `CSR.wakeup_number = 8`; không có burst đọc nào của kênh 0 trước khi kênh 1 được start; burst đọc đầu tiên của kênh 0 đến **sau** burst ghi cuối của kênh 1 |
| 2 | Kênh 2 và 3 cùng `DMAWFE E9`; một lệnh debug `DMASEV E9` | Cả hai kênh được thả và hoàn tất |
| 3 | Debug `DMASEV E10` trước; sau đó kênh 0 chạy `DMAWFE E10, invalid` | Kênh đi qua ngay (event sticky); `INT_EVENT_RIS[10] = 0` sau đó (event đã được dùng) |
| 4 | `INTEN[13] = 1`; kênh 1 `DMAWFE E13`; debug `DMASEV E13` | `irq[13]` bật nhưng kênh **vẫn chờ**; sau `INTCLR` và `INTEN[13] = 0`, một `DMASEV E13` mới thả kênh |

---

### TC-10 `dma_boot_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Manager tự boot từ bộ nhớ, ở chế độ non-secure; đồng bộ manager–kênh; `dmago_err` |
| Chuẩn bị (trước reset) | Hai job M2M cho kênh 0 và 1 (`ns = 1`, nên `CCR` có `x_prot[1] = 1`); kênh 1 kết thúc bằng `DMASEV E12`. Chương trình manager ở `0x8000`: `DMANOP; DMAGO C0,ns; DMAGO C1,ns; DMAWFE E12; DMAWFE E13; DMASEV E11;` rồi `DMAEND` hoặc `DMAKILL` (chọn ngẫu nhiên). Chân boot: `boot_from_pc = 1`, `boot_addr = 0x8000`, `boot_manager_ns = 1` |
| Sequence | `dma_boot_vseq` |
| VP | MGR-01..04, MGR-08, ISA-11, EVT-06, FLT-12 (`dmago_err`) |

Trình tự và kiểm tra:
1. `INTEN = E11 | E0..3`. Poll `DSR` tới khi manager chờ event 13 (`DSR[3:0] = 4`, `DSR[8:4] = 13`); gửi debug `DMASEV E13`: lệnh phải được nhận ngay (`DBGSTATUS = 0` sau 20 clk), manager quay lại chờ và được chính event 13 thả; chờ `irq[11]` (manager báo xong).
2. Với mỗi job: chờ `irq`, `INTCLR`, `CSR` Stopped, scoreboard `job_done`; `CSR[21]` (CNS) = 1. Mọi burst của hai kênh có `AxPROT[1] = 1`.
3. `DSR`: Stopped và `DNS = 1`; `DPC` = địa chỉ của lệnh `DMAEND`/`DMAKILL`; `CR0[1]` và `CR0[2]` bằng 1.
4. Debug `DMAKILL` tới manager đang dừng: `DSR` vẫn Stopped.
5. Debug `DMAGO C2` secure từ manager NS: `irq_abort`, `FTRD = 0x4000_0010` (`dmago_err` là bit 4, giá trị cố định theo TRM); sau `DMAKILL`, `FSRD = 0`.

---

### TC-11 `dma_fault_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Sinh ra mọi loại lỗi của kênh và manager; kiểm tra báo lỗi, cách ly và phục hồi |
| Sequence | `dma_fault_vseq` |
| Thiết lập | Kênh victim chọn ngẫu nhiên trong 1..3 theo seed; kênh 0 là bystander chạy 6 job M2M song song suốt test. Vùng lỗi AXI: đọc SLVERR, ghi DECERR, fetch SLVERR, đọc/ghi EXOKAY, line lỗi (straddle), beat cuối của line lỗi, beat đầu của line lỗi |
| VP | FLT-01..17, MGR-06, MGR-07, AXI-06 |

Với mỗi kịch bản lỗi của kênh (`run_fault`):
1. Ghi chương trình lỗi, đặt kênh victim vào chế độ ignore của scoreboard, gửi `DMAGO`.
2. Chờ `irq_abort`, rồi poll tới khi `CSR` = Faulting.
3. Kiểm tra `FSRC[victim] = 1`, bit lỗi kỳ vọng trong `FTR[victim]`, và `CPC` = PC lệnh lỗi (với lỗi undef).
4. `DMAKILL` kênh: `CSR` Stopped, `FTR = 0`, `irq_abort = 0`.

| # | Kịch bản | Chương trình | Bit kỳ vọng |
|---|---|---|---|
| 1 | Opcode không hợp lệ | `DCB 0xFF` | FTR[0], kiểm tra `CPC` |
| 2 | `DMAGO` trong kênh | `DMAGO C1, 0x1000` | FTR[0] |
| 3 | `DMAMOV` thanh ghi sai | `BC 03 ...` | FTR[1] |
| 4 | Event quá lớn | `DMASEV 20` | FTR[1] (operand_invalid) |
| 5 | Peripheral quá lớn | `DMAWFP P7, B` | FTR[1] |
| 6 | Load size 16 B > bus | `CCR` src size 4; `DMALD` | FTR[7] |
| 7 | Store size 16 B > bus | `CCR` dst size 4; `DMALD; DMAST` | FTR[7] |
| 9 | Store không có dữ liệu | `DMAST` | FTR[13] |
| 10 | Lỗi đọc | SAR = vùng SLVERR; `LD; ST; WMB; END` | FTR[18] |
| 11 | Lỗi ghi | DAR = vùng DECERR | FTR[17] |
| 12 | Lỗi fetch | chương trình ở vùng SLVERR | FTR[16] |
| 12a | Đọc EXOKAY | SAR = vùng EXOKAY; `LD; ST; WMB; END` | FTR[18], `FAR = 0xE003_0000` |
| 12b | Ghi EXOKAY | DAR = vùng EXOKAY + 0x100 | FTR[17], `FAR = 0xE003_0100` |
| 13 | `DMALDP P9` | | FTR[1] |
| 14 | `DMASTP P9` | | FTR[1] |
| 15 | Lệnh 6 byte vắt sang line lỗi | `DMAMOV` tại `STRADDLE − 2` | FTR[16] |
| 16 | Refill lỗi ở beat cuối | | FTR[16] |
| 17 | Refill lỗi ở beat đầu (DECERR) | | FTR[16] |
| 18 | Debug `DMANOP` tới kênh | (gửi hai lần: lần hai kênh vẫn Faulting) | FTR[0] + FTR[30] |
| 19 | Debug `DMASEV E20` tới kênh | | FTR[1] + FTR[30] |
| 20 | Debug tới kênh 6 (không tồn tại) | | Không lỗi, `FSRC = 0` |
| 20a | Swap 64 bit, dst INCR 3 × 4 B (12 B, không trọn nhóm) | `CCR.swap = 3` | FTR[7], không có AW |
| 20b | Swap 64 bit, dst FIXED beat 4 B | `CCR.swap = 3`, `dst_inc = 0` | FTR[7] |
| 20c | Swap 128 bit trên bus 64 bit | `CCR.swap = 4` | FTR[7] |
| 20d | Swap 32 bit với `DAR` lệch 2 byte | `CCR.swap = 2`, `DAR = dst + 2` | FTR[7] |
| 8 | MFIFO self lock-up (chạy sau khi bystander xong) | 128 B/burst; `DMALD` × (`MFIFO_BYTES/128` + 1) = 9, không store | FTR[12] |

Với kịch bản 10, 11, 12 còn kiểm tra thêm `FAR`: lỗi đọc thì `FAR = 0xE000_0000` (beat lỗi đầu tiên), lỗi ghi thì `FAR = 0xE001_0000` (burst lỗi), lỗi fetch thì `FAR = 0xE002_0000` (PC). Sau phần phục hồi, `FAR` của kênh victim phải bằng 0 (`DMAGO` đã xóa).

Kịch bản lỗi manager (giữ `dbg_lock` để không kênh nào được `DMAGO` trong lúc manager lỗi):

| # | Lệnh debug | Bit kỳ vọng | Kiểm tra thêm |
|---|---|---|---|
| 21 | `DMAGO C7` | FTRD[1] + FTRD[30] | Debug `DMANOP` khi đang lỗi không xóa lỗi; `DMAKILL` → `DSR` Stopped |
| 22 | `DMAWFE` (không phải lệnh debug hợp lệ) | FTRD[0] + FTRD[30] | như trên |
| 23 | `DMASEV E31` | FTRD[1] + FTRD[30] | như trên |

Kịch bản 8 chạy sau khi bystander xong: với MFIFO dùng chung, kênh chiếm gần hết pool (và giữ load-lock) làm kênh khác phải chờ, nên không thể đòi hỏi cách ly ở kịch bản này (xem TC-23).

Burst vượt 4 KB không còn là lỗi (DMA tự tách, TC-03).

Cuối test: xóa vùng lỗi, chạy 2 job M2M trên kênh victim (phục hồi). Bystander phải hoàn tất 6 job đúng dữ liệu (cách ly lỗi).

---

### TC-12 `dma_kill_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | `DMAKILL` ở mọi trạng thái chờ; kênh sạch và dùng lại được |
| Sequence | `dma_kill_vseq`, kênh chọn ngẫu nhiên 0..3 theo seed |
| VP | KILL-01..06 |

| # | Kịch bản | Cách tạo | Kiểm tra |
|---|---|---|---|
| 1 | Kill giữa lúc truyền | AXI profile `slow`, job 4096 B, kill sau 1500 clk | `CSR` Stopped, `FTR = 0`; các burst đang bay đều hoàn tất (SVA/AXI không treo) |
| 2 | Kill khi đang cache miss | `ar_ready_pct = 5`, kill ngay sau `DMAGO` | Như trên; phản hồi refill đến muộn bị bỏ |
| 3 | Kill khi chờ peripheral | `DMAFLUSHP P; DMAWFP P, B; DMAEND`, peripheral không gửi request | Như trên |
| 4 | Kill khi chờ event | `DMAWFE E15; DMAEND` | Như trên |
| 5 | Kill kênh đang dừng | | `CSR` vẫn Stopped, `irq_abort = 0` |
| 6 | Dùng lại | 3 job M2M | Scoreboard |

---

### TC-13 `dma_stress_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Mọi loại job trên mọi kênh, back-pressure nặng ở AXI và peripheral |
| Cấu hình | AXI `set_slow()` (READY 30 %, latency 2–30, R gap 40 %); `daready_pct = 30` ở mọi peripheral |
| Sequence | `dma_traffic_vseq`: 4 kênh × 10 job, `max_bytes = 4096`, `kinds` = mọi loại job (M2M có trọng số gấp đôi) |
| VP | AXI-01, DP-07, DP-08, PER-09, ISA-06 |

Kiểm tra: scoreboard; mọi SVA; không treo (watchdog). Đây là test chính cho MFIFO đầy, queue đầy, ack queue đầy và phân xử dưới tải nặng.

Watchdog của DUT được bật suốt test với `WD.timeout = 16` (4096 chu kỳ). Cuối test, `WDSTAT` phải bằng 0, tức không có báo nhầm dưới tải nặng (VP-WD-05).

---

### TC-14 `dma_isa_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Lệnh ít gặp |
| Sequence | `dma_traffic_vseq`: `kinds = {JOB_ISA_MIX, JOB_LOOP2D, JOB_M2M}`, 4 kênh × 6 job |
| VP | ISA-03, ISA-04, ISA-05 |

Chương trình `JOB_ISA_MIX` (copy các block theo thứ tự ngược):
```
DMANOP
DMAMOV SAR, src + (n-1)*bb ; DMAMOV DAR, dst ; DMAMOV CCR
DMALP LC0, n
  DMALD
  DMARMB                 ; chờ đọc xong trước khi store
  DMAST
  DMAADNH SAR, -2*bb     ; lùi 2 block (LD đã cộng 1 block)
DMALPEND LC0
DMAWMB ; DMASEV ; DMAKILL  ; DMAKILL kết thúc chương trình
```

Kiểm tra: thứ tự địa chỉ đọc giảm dần, ghi tăng dần (scoreboard); kênh về Stopped sau `DMAKILL` mà không báo lỗi.

---

### TC-15 `dma_periph_corner_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Các góc cạnh của giao thức peripheral; ngữ nghĩa `DMAWFP S/B`, lệnh `S` một beat, barrier của `DMAFLUSHP`, reset riêng domain peripheral |
| Sequence | `dma_periph_corner_vseq` |
| VP | PER-05, PER-06, PER-07, PER-08, PER-11, ISA-06, ISA-07, ISA-08, ISA-10 |

| # | Kịch bản | Trình tự | Kiểm tra |
|---|---|---|---|
| 1 | Flush ack không được yêu cầu (mọi peripheral) | Peripheral gửi `drtype = 10` khi DMA không flush, rồi chạy job M2P 3 request | DMA bỏ qua; job sau đó chạy đúng |
| 2 | Request dồn dập (mọi peripheral) | Kênh đã chờ ở WFP; peripheral tắt `wait_ack` và gửi 8 request burst liên tiếp | `drready = 0` khi latch đầy; đủ 8 burst và 8 ack đúng thứ tự |
| 4 | Request trong lúc flush | Peripheral 2 tắt `auto_flush_ack`; kênh 0 đã ở WFP. Gửi một request burst, rồi mới gửi flush ack | `SAR` của kênh 0 không đổi, tức request bị bỏ; sau đó 4 request thật chạy đúng |
| 3 | Hai kênh dùng chung peripheral 2 | Kênh 0 (3 request) và kênh 1 (4 request) cùng `FLUSHP`/`WFP`; peripheral gửi 7 burst | Ack: FLUSH, FLUSH, 7 × BURST; cả hai kênh hoàn tất, tổng 7 burst được chia đúng 3 + 4 |
| 5 | `DMAWFP B` bỏ request single | Chương trình tay (kênh 2): `FLUSHP; WFP B; LDB; STPB; WMB; SEV; END`, 4 × 8 B. Peripheral gửi single, chờ 300 clk, rồi gửi burst | Sau request single kênh vẫn chờ (`CSR` = Waiting for peripheral); ack FLUSH, BURST; `SAR` tăng 32 |
| 6 | `DMAWFP S` để lại request burst | `FLUSHP; WFP S; LDS; LDB; STPS; WFP P; LDB; STPB; …`. Peripheral gửi một burst | `WFP S` đi tiếp với `request_type = single` (LDS + STPS: 1 beat, ack SINGLE), request burst vẫn nằm trong latch nên `WFP P` đi tiếp ngay (ack BURST); `SAR` tăng 8 + 32 |
| 7 | `DMAFLUSHP` sau `DMASTPB` | `FLUSHP; WFP B; LD; STPB; FLUSHP; …` (kênh 3), một request burst | Ack đúng thứ tự FLUSH, BURST, FLUSH: flush thứ hai chờ B của `STPB` |
| 8 | `DMAWFP B` xóa `request_last` | `FLUSHP; loop { WFP B; LDB; STPB } DMALPFE`. Peripheral gửi một burst có `drlast = 1` | Vòng `DMALPFE` không thoát: sau 500 clk kênh lại chờ peripheral, `SAR` tăng đúng 32; `DMAKILL` |
| 9 | Reset riêng peripheral 1 | Job M2P 2 request (3 transfer mỗi chiều qua CDC, toggle ở 1), rồi `pulse_periph_reset(1)`; sau đó chương trình không `FLUSHP`: `WFP P; LDB; STPB; …` | Kênh vẫn chờ sau 500 clk (không có request ảo); không có ack ảo (SB-06); một request thật hoàn tất chương trình |

---

### TC-16 `dma_boot_err_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Manager boot từ địa chỉ trả lỗi AXI |
| Chuẩn bị | Vùng `0xE00F_0000..0FFF` trả SLVERR khi đọc; `boot_from_pc = 1`, `boot_addr = 0xE00F_0000` |
| Sequence | `dma_boot_err_vseq` |
| VP | MGR-05, FLT-12 |

Trình tự và kiểm tra:
1. Chờ `irq_abort`.
2. `DSR` = Faulting; `FTRD[16]` (`instr_fetch_err`); `DPC = boot_addr`.
3. Debug `DMAKILL` manager → `FSRD = 0`.
4. `INTEN`, chạy một job M2M trên kênh 0 → đúng dữ liệu (DMA dùng lại được bình thường).

---

### TC-17 `dma_reset_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Reset hệ thống giữa lúc truyền, trạng thái sau reset, chạy lại |
| Sequence | `dma_reset_vseq` |
| VP | RST-01..03 |

Trình tự và kiểm tra:
1. Cả 4 kênh bắt đầu job M2M 4096 B.
2. Sau 1000–2000 clk (ngẫu nhiên): đặt các kênh vào chế độ ignore, `pulse_reset(20)` (reset mọi domain), `rm.reset()`.
3. Kiểm tra `DSR` và mọi `CSR` = Stopped, `INTEN = 0`, `irq = 0`, `irq_abort = 0`.
4. Bật lại `INTEN`; mỗi kênh chạy 2 job M2M song song → scoreboard đúng.

---

### TC-18 `dma_endian_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Endian swap `CCR[30:28]` trên dữ liệu ghi |
| Sequence | `dma_traffic_vseq`: `endian_mode = 1`, `kinds = {JOB_M2M, JOB_M2M, JOB_FILL}`, 4 kênh × 8 job |
| Ràng buộc | M2M: `swap` ∈ {1, 2, 3} phân bố đều (giải trước `dst_size`); `DAR` và `nbytes` là bội của beat size phía đích và của nhóm swap; `swap ≤ dst_size`, hoặc (dst INCR) `dst_beats × 2^dst_size` là bội của nhóm: nhóm rộng hơn beat (TRM 2.11.2). Phía nguồn tùy ý (size, len, alignment). FILL: `swap` ∈ 1..7, kể cả giá trị không hợp lệ, không ràng buộc alignment: `DMASTZ` phải bỏ qua swap |
| VP | DP-10 |

Kiểm tra:
* Scoreboard đảo byte trong từng nhóm `2^swap` byte liên tiếp của burst kỳ vọng (theo stream, nên đúng cả khi nhóm trải trên nhiều beat) rồi so bit-exact; C model dự đoán độc lập (SB-09).
* Sequence in số job theo từng kích thước swap và số job có nhóm rộng hơn beat, và báo lỗi nếu không có job nào có swap.

---

### TC-19 `dma_watchdog_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Watchdog phát hiện kênh bị treo, hai chế độ báo, không báo nhầm |
| Sequence | `dma_watchdog_vseq`, kênh chọn ngẫu nhiên theo seed |
| Công cụ | AXI VIP `add_stall_region`: giữ mọi R của vùng nguồn của kênh (slave treo) |
| VP | WD-01..04, FLT-20 |

| Phần | Trình tự | Kiểm tra |
|---|---|---|
| A. Abort | `WD = 4 << 16` (1024 chu kỳ); job 2048 B với nguồn bị treo | `irq_abort`; `WDSTAT[ch]`; `FTR[31]`; `FSRC[ch]`; status = Fault completing (R vẫn bị giữ). Gỡ stall → Faulting; ghi W1C `WDSTAT`; `DMAKILL` → Stopped, `FTR = 0`, `irq_abort = 0` |
| B. Chỉ báo | `WD = (4 << 16) \| 1`; job tương tự | `WDSTAT[ch]`, `irq_abort`, `FSRC = 0`. Gỡ stall → job hoàn tất, scoreboard đúng; W1C → `irq_abort = 0` |
| C. Chờ hợp lệ | `WD = 2 << 16`; kênh `DMAWFE` 3000 chu kỳ; kênh M2P chờ peripheral 3000 chu kỳ | `WDSTAT = 0`, `irq_abort = 0`; sau đó hoàn tất bình thường |
| D. Tắt | `WD = 0`; nguồn bị treo 3000 chu kỳ | Không báo; gỡ stall → job hoàn tất |
| E. Mọi kênh | Chế độ chỉ báo; 4 kênh cùng treo | `WDSTAT` = mọi bit; giữ treo thêm 600 chu kỳ, xóa `WDSTAT` → không bị báo lại khi chưa có progress; gỡ stall → 4 job đúng dữ liệu |
| F. Đang kill | `WD = 0`; kênh treo, `DMAKILL` → Killing; bật `WD = 2 << 16` | `WDSTAT[ch]`, `irq_abort`; `FTR = 0` (kênh đang kill không bị fault); gỡ stall → Stopped |
| G. Đang lỗi | Kênh treo nhận lệnh debug không hợp lệ → Fault completing; bật watchdog | `WDSTAT[ch]`; `FTR` giữ lỗi debug, **không** có `lockup_err`; gỡ stall → Faulting → `DMAKILL` |

---

### TC-20 `dma_lowpower_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | AMBA Q-Channel: quiescence, tắt clock lõi, đánh thức |
| Sequence | `dma_lowpower_vseq` |
| Công cụ | `ctrl_if.q_request/q_release/gate_clock`; clock gate dạng latch trong `tb_top` trên clock lõi của DUT |
| VP | LP-01..05 |

| # | Trình tự | Kiểm tra |
|---|---|---|
| 1 | DMA rảnh: `qreqn = 0` → tắt clock 300 chu kỳ → đọc `DSR` qua APB | Accept; `qactive = 0` khi ngủ; truy cập APB làm `qactive = 1` và bị giữ cho tới khi controller bật clock và kéo `qreqn = 1`; giá trị đọc đúng |
| 2 | Job 4096 B đang chạy: `qreqn = 0` | Deny (`qdeny = 1`); job hoàn tất đúng |
| 3 | Kênh M2P đang `DMAWFP` | Deny; sau đó gửi request, job hoàn tất |
| 4 | Kênh lỗi (opcode `0xFF`) ở Faulting | Accept, ngủ/đánh thức như bước 1; sau đó `DMAKILL` |
| 5 | 5 lần: job M2M ngẫu nhiên rồi ngủ 10–300 chu kỳ, đánh thức bằng APB | Accept mỗi lần; mọi job đúng |

Trong toàn bộ test, `dma_lpi_sva` kiểm tra giao thức Q-Channel và việc lõi không phát AXI/ack khi `qacceptn = 0`.

---

### TC-21 `dma_rand_prog_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Kiểm DUT bằng **chương trình DMA-330 ngẫu nhiên cấp ISA**; hành vi kỳ vọng do **C model** (DPI-C) dự đoán, không phải generator |
| Sequence | `dma_traffic_vseq`: `kinds = {JOB_RAND}`, 4 kênh × 10 chương trình, song song |
| Generator | `dma_rand_prog` (xem [CMODEL.md](CMODEL.md) mục 6): 1–4 "segment" mỗi chương trình, chọn trong copy / zero-fill / copy ngược (`DMAADNH`) |
| Yêu cầu | C model (thư viện DPI). Không có thì test báo `CMODEL` fatal; `run_regression.py --no-cmodel` bỏ qua test này |
| VP | CM-01..05 |

Mỗi segment tự ngẫu nhiên hóa: kích thước beat và số beat mỗi phía (1–16), INCR hay FIXED, offset không align (kể cả cả hai phía), endian swap 16/32/64-bit khi hợp lệ, `AxPROT`/`AxCACHE` trong `CCR`, số lệnh `DMALD`/`DMAST` mỗi vòng (cân bằng dữ liệu theo bội chung), vòng lặp `DMALP` một hoặc hai cấp (LC0/LC1 chọn ngẫu nhiên), `DMAADDH` bước hàng có cả bước nhảy nhiều trang 4 KB (imm16 lên tới `0xF040`, bit 15 được dùng), `DMASTZ` kèm trường swap bất kỳ (phải bị bỏ qua), xen kẽ `DMANOP`/`DMARMB`/`DMAWMB`/`DMASEV` event dư, kết thúc `DMAEND` hoặc `DMAKILL`. Kênh 0 có thêm kernel nằm sát đỉnh không gian địa chỉ 32 bit (`0xFFFF_F000`) để `SAR`/`DAR` quay vòng về 0. Dữ liệu nguồn là **ngẫu nhiên** (`randomize_region`), không phải mẫu theo địa chỉ.

Kiểm tra:
* Chương trình chỉ được dùng khi C model chạy tới `DMAEND`/`DMAKILL` sạch (không fault, không lock-up MFIFO, đủ dữ liệu cho mọi `DMAST`, không burst nào vượt 4 KB); nếu không sinh lại (tối đa 60 lần).
* Scoreboard so từng burst AXI, từng beat (`WDATA`, `WSTRB`), thuộc tính, với dự đoán của C model (`from_model`).
* `ARCH`: `CPC`, `SAR`, `DAR`, `CCR`, `LC0`, `LC1` cuối chương trình bằng C model.
* Số chương trình được dự đoán chỉ bằng C model in trong báo cáo scoreboard (`jobs predicted by the model alone`).

---

### TC-22 `dma_cmodel_mix_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Trộn mọi loại job có sẵn và chương trình ngẫu nhiên trên cùng 4 kênh dưới back-pressure rất nặng |
| Sequence | `dma_traffic_vseq`: `kinds = {M2M, FILL, LOOP2D, M2P, P2M, PERIPH_MIXED, P2M_MIXED, COND_LOOP, ISA_MIX, RAND ×3}`, 4 kênh × 12 job |
| Cấu hình | `axi_cfg.set_choke()` (AWREADY/ARREADY 10 %, WREADY 25 %, latency B/R 5–40 chu kỳ: các hàng đợi outstanding đầy), `daready_pct = 40` cho mọi peripheral |
| VP | CM-01..05, AXI-01 |

Kiểm tra: như TC-21 cho job `JOB_RAND`; với các job có danh sách op là **đối chiếu hai bộ dự đoán** (generator và C model) trước khi chạy, cộng đối chiếu thanh ghi cuối job.

---

### TC-23 `dma_mfifo_share_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | MFIFO dùng chung, cấp phát động: một kênh dùng được gần hết pool; kênh không có chỗ thì chờ; load-lock; dead-lock giữa hai kênh được phát hiện chính xác (abort hoặc chỉ báo) |
| Sequence | `dma_mfifo_vseq` |
| Thiết lập | Kênh A, B chọn ngẫu nhiên (khác nhau). Burst 16 × 8 B = 128 B = 16 line; pool 1 KB = 8 burst. Chương trình viết tay, scoreboard bỏ qua hai kênh này; dữ liệu đích được so với nguồn trong memory model |
| VP | MF-01..03, MF-06, MF-07, DP-08, FLT-20 |

| # | Kịch bản | Kiểm tra |
|---|---|---|
| 1 | Kênh A: 7 `DMALD` (896 B = 112 line) rồi 7 `DMAST`; kênh B: tương tự với `SAR` +3, `DAR` +5 | Không lỗi, 896 / 891 byte đúng (phần chia tĩnh cũ chỉ cho 256 B/kênh) |
| 2 | A: 7 `DMALD`, `DMAWFE E12` (nhả load-lock), 7 `DMAST`. Khi A đang chờ event, B chạy `DMALP 2 { LD; LD; ST; ST }` | `DMALD` thứ hai của B không vừa: B ở Executing, `CPC` = `DMALD` đó, `FSRC = 0` sau 3000 chu kỳ. Debug `DMASEV E12` → A store, B chạy tiếp, cả hai copy đúng |
| 3 | A: 6 `DMALD` (96 line), `DMAWFE E12`, `DMALD`... B: 3 `DMALD` (B giữ 32 line và load-lock, `DMALD` thứ ba chờ chỗ). Kênh C (không giữ line): `DMALD; DMAST; DMAWMB; DMASEV; DMAEND`, `DMALD` chờ load-lock | Trước khi thả A: B và C chỉ chờ, không lỗi. Sau debug `DMASEV E12`: A kẹt ở `DMALD` (chờ load-lock), không kênh nào có store → phát hiện lock-up: A và B lỗi `lockup_err` (FTR = `0x8000_0000` đúng một bit), `CPC` tại `DMALD` kẹt, `FSRC` = đúng hai bit đó. C không giữ line nên không bị lỗi; khi line của A, B về pool và load-lock được nhả, C chạy xong và copy đúng. `DMAKILL` A, B, `irq_abort` = 0 |
| 3b | Như kịch bản 3 (không có C) nhưng `WD = 1` (`irq_only`) | Lock-up chỉ được báo: `WDSTAT` = đúng bit của A và B, `irq_abort = 1`, `FSRC = 0`, `CPC` của A tại `DMALD`. `DMAKILL` A, B, ghi 1 vào `WDSTAT`: `irq_abort = 0` |
| 3c | Load-lock: A, B, C mỗi kênh 5 `DMALD` (5/8 pool) rồi 5 `DMAST`, khởi động liền nhau | Không thể chạy song song (hai kênh đã vượt pool), nhưng thỏa quy tắc TRM 2.11.4 (yêu cầu tĩnh 0, động 5/8 pool): nhờ load-lock cả ba chạy xong, không lỗi, copy đúng |
| 4 | Mọi kênh chạy 2 job M2M song song, sau đó lặp lại kịch bản 1 (`SAR` +1, `DAR` +6) | Scoreboard; pool đã trống lại sau deadlock |

---

### TC-24 `dma_security_test`

| Mục | Nội dung |
|---|---|
| Mục tiêu | Security kiểu TrustZone: hai cổng APB, `CR3`/`CR4`, quyền của thread NS, cổng NS chỉ thấy tài nguyên NS |
| Sequence | `dma_security_vseq` |
| Thiết lập | Trước reset: `boot_irq_ns = 0x00FF` (event 0–7 NS, 8–15 secure), `boot_periph_ns = 0b0011` (peripheral 0, 1 NS), `boot_manager_ns = 0`. Kênh 0 secure, kênh 1 NS. Truy cập cổng NS bằng `apb_rd`/`apb_wr`/`dbg_exec_ns` (agent `apb_ns`) |
| VP | SEC-01..13 |

Giai đoạn 1 (manager secure):

| # | Kịch bản | Kiểm tra |
|---|---|---|
| 1 | Đọc `CR3`, `CR4`, `CR0`, `DSR` trên hai cổng | `CR3 = 0x00FF`, `CR4 = 0x3`, `CR0[2] = 0`; `DSR` trên cổng NS = 0 |
| 2 | Một job M2M secure trên kênh 0, một job NS trên kênh 1 (scoreboard kiểm `AxPROT[1]`) | Cổng NS: mọi thanh ghi của kênh 0 đọc 0, của kênh 1 bằng cổng S; `CSR.CNS` đúng |
| 3 | `INTEN`: S ghi 0, NS ghi `0xFFFF` → S đọc 0; S ghi `0xFFFF`, NS ghi 0 → S đọc `0xFFFF`, NS đọc 0 | Manager secure: cổng NS không thấy và không đổi được `INTEN` (TRM Table 3-1) |
| 4 | Debug `DMASEV E9`, `DMASEV E3`; NS ghi `INTCLR = 0xFFFF` | `INT_EVENT_RIS` S = `0x208`, NS = 0; `INTMIS` NS = 0; INTCLR của NS bị bỏ qua: `irq[3] = irq[9] = 1`; cổng S xóa cả hai |
| 5 | S ghi `WD = 0x0010_0001`; NS đọc, NS ghi 0 | NS đọc 0; `WD` không đổi |
| 6 | `DBGINST0/1` ghi khác nhau trên hai cổng | Mỗi cổng đọc lại giá trị của mình |
| 7 | Hai cổng đồng thời: mỗi cổng 64 lần ghi rồi đọc `DBGINST1` | Mọi lần đọc trả đúng giá trị của cổng đó (va chạm cùng chu kỳ được tuần tự hóa) |
| 7b | Cổng NS đọc địa chỉ không map, ghi vào `CR0` (read-only) | `PSLVERR_NS = APB_SLVERR` (1 ở cấu hình async); `CR0` không đổi |
| 8 | Cổng NS: `DMAGO` qua manager secure; `DMASEV` tới kênh secure; `DMAKILL` tới kênh secure đang chạy job 2 KB | Không có tác dụng: kênh không chạy, không event, job hoàn tất đúng; `DBGSTATUS = 0`, `FSRD = 0` |
| 9 | Kênh NS chạy: `DMASEV E9`, `DMAWFE E9`, `DMAWFP P2`, `DMAFLUSHP P2`, `DMALDPS P2`, `DMASTPS P2`, `DMALD` với `src_prot = 000`, `DMAST` với `dst_prot = 000` | Lần lượt `ch_evnt_err` ×2, `ch_periph_err` ×4, `ch_rdwr_err` ×2 (FTR đúng một bit, đọc từ cổng NS); `FSRC` thấy được từ cổng S, cổng NS đọc 0 (manager secure); `DMAKILL` qua cổng NS đưa kênh về Stopped, `FTR = 0` |
| 10 | Debug `DMASEV E9` qua cổng NS tới kênh NS đang dừng | FTR = `ch_evnt_err` + `dbg_instr` |
| 11 | Kênh NS: `DMAFLUSHP P1; DMASEV E3; DMAEND`; debug `DMASEV E3` qua cổng NS. Kênh secure: `DMAFLUSHP P2; DMASEV E9; DMASEV E3; DMAEND` | Không lỗi; ack flush đúng peripheral; các interrupt đúng (xóa qua cổng S) |
| 12 | Kênh secure lỗi (`DMASEV 20`); manager secure lỗi (`DMAGO C7`) | Cổng S thấy `FSRC`/`FSRD`; cổng NS đọc `FSRC`, `FTR0`, `FSRD`, `FTRD`, `DPC` = 0; `DMAKILL` qua cổng NS bị bỏ qua; `DMAKILL` qua cổng S phục hồi |
| 12b | Tag NS của I-cache: chương trình `DMAWFE E4; DMASEV E5; DMAEND` ở `0x00F0_0000`, vùng chỉ-secure (đọc NS trả 0). Kênh secure chạy và chờ E4; kênh NS khởi động cùng địa chỉ (fetch NS → byte 0 = `DMAEND`); manager secure gửi `DMASEV E4` | Kênh NS dừng tại `CPC = 0x00F0_0000`; kênh secure không dùng line NS mà fetch lại, chạy `DMASEV E5` (`irq[5]`), dừng tại `DMAEND` (`CPC = +4`), `FTR = 0` |

Giai đoạn 2: reset với `boot_manager_ns = 1`.

| # | Kịch bản | Kiểm tra |
|---|---|---|
| 13 | Đọc cấu hình | `CR0[2] = 1`, `DSR` trên cổng NS = `0x200` |
| 13b | Cổng NS với manager NS: ghi `INTEN = 0xFFFF`; debug `DMASEV E9`, `E3` (qua kênh secure, cổng S); NS ghi `INTCLR = 0xFFFF` | `INTEN` chỉ đổi bit NS (`0x00FF`); `INT_EVENT_RIS`/`INTMIS` NS = `0x8`; `irq[3] = 0`, `irq[9] = 1` |
| 14 | Job M2M NS chỉ qua cổng NS: `INTEN`, `DMAGO` (debug NS), chờ irq, `INTCLR`, `CSR` | Scoreboard (`AxPROT[1] = 1`), trạng thái kiến trúc cuối job |
| 15 | Qua cổng NS: `DMAGO` kênh secure; `DMASEV E9`. Qua cổng S: `DMAGO` kênh secure | `dmago_err`, `mgr_evnt_err`, `dmago_err`; mỗi lần cổng NS thấy `FSRD`/`FTRD` và `DMAKILL` qua cổng NS phục hồi manager |
| 16 | Qua cổng NS: manager `DMASEV E3` | `irq[3]`, không lỗi |

---

## 4. Thêm test mới

1. Tạo virtual sequence kế thừa `dma_base_vseq` trong `tb/seq/`, và include nó trong `dma_seq_pkg.sv`. Có thể dùng các API sẵn có: `run_job`, `make_job`, `load_job`, `start_channel`, `kill_channel`, `dbg_exec`, `wait_irq`, `wait_abort`, `wait_ch_status`, `reg_rd`/`reg_wr`, và assembler `dma330_asm`.
2. Tạo class test trong `tb/tests/dma_test_pkg.sv`, override `create_vseq()`. Nếu cần, override thêm `configure()` hoặc `end_of_elaboration_phase()`.
3. Thêm tên test vào danh sách `TESTS` trong `sim/run_regression.py` (test bắt buộc có C model thì thêm vào cả `CMODEL_TESTS`). `make regress`/`make cov` gọi script này nên tự có test mới.
4. Cập nhật bảng VP trong `VERIFICATION_PLAN.md` và mục tương ứng trong tài liệu này.
