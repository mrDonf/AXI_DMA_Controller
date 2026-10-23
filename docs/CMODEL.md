# C reference model qua DPI-C

| Mục | Giá trị |
|---|---|
| Mã nguồn C | `model/dma330_ref.{h,c}` (mô hình), `model/dma330_dpi.c` (lớp DPI), `model/dma330_ref_test.c` (test độc lập) |
| Phía SystemVerilog | `tb/dpi/dma330_dpi_pkg.sv` (import), `tb/env/dma_cmodel.sv` (wrapper), `tb/env/dma_rand_prog.sv` (generator chương trình ngẫu nhiên) |
| Test dùng | mọi test chạy job (đối chiếu), `dma_rand_prog_test`, `dma_cmodel_mix_test` (C model là bộ dự đoán duy nhất) |
| Tài liệu liên quan | [VERIFICATION_PLAN.md](VERIFICATION_PLAN.md), [TESTCASES.md](TESTCASES.md) (TC-21, TC-22), [DESIGN_SPEC.md](DESIGN_SPEC.md) mục 4.5, 4.7, 5.9, 7 |

---

## 1. Vì sao cần C model

Trước đây reference model nằm trong scoreboard và dự đoán từ `job.ops`: danh sách burst do chính `dma_prog_gen` sinh ra cùng lúc với chương trình. Cách này có hai điểm yếu:

1. **Không độc lập với stimulus.** Không có thành phần nào *giải mã byte code*. Nếu generator và bộ dự đoán cùng hiểu sai một ngữ nghĩa (ví dụ số byte của burst không align, điều kiện thoát vòng lặp), cả hai sai giống nhau.
2. **Chỉ có chín khuôn chương trình.** Dự đoán gắn với từng loại job, nên không kiểm được chương trình ngẫu nhiên tùy ý.

C model là một **bộ mô phỏng tập lệnh (ISS)** của một channel thread, viết từ đặc tả:

* đọc byte code thật trong bộ nhớ, giải mã và thực thi;
* trả về, theo đúng thứ tự chương trình, những gì phần cứng phải làm trên các giao diện: burst AXI (địa chỉ, hình dạng, dữ liệu từng beat, strobe), ack peripheral, event, kết thúc/lỗi;
* giữ trạng thái kiến trúc (`PC`, `SAR`, `DAR`, `CCR`, `LC0`, `LC1`) để so với thanh ghi của DUT.

Nó là mô hình kiến trúc, không có thời gian: không biết latency, thứ tự hoàn thành giữa các kênh hay back-pressure. Phần đó vẫn do scoreboard (theo ID) và SVA lo.

---

## 2. Kiến trúc

```
             +----------------------------- vsim (SystemVerilog) ----------------------------+
 program     |  dma_base_vseq.load_job ──► sb.model_job(job) ──► dma_cmodel.run(job, mem)     |
 in memory ──┼─►                                                      │ DPI-C import           |
 (axi_mem_   |                                                        ▼                        |
  model)     |                                       dma330_ref.dll (model/dma330_dpi.c)       |
             |                                       └─ dma330_ref.c  (ISS, không có bộ nhớ)   |
             |    dma_cmodel_result: rd[] wr[] acks[] sev[] + PC/SAR/DAR/CCR/LC0/LC1/FTR        |
             |        │                 │                         │                            |
             |        ▼                 ▼                         ▼                            |
             |   SB_XCHECK         add_job (JOB_RAND)       check_arch_state (ARCH)             |
             |   so với job.ops    kỳ vọng chỉ từ model      so với CPC/SAR/DAR/CCR/LC0/LC1     |
             +---------------------------------------------------------------------------------+
```

### 2.1 Vì sao dùng giao thức "sự kiện", không dùng callback

Questa 10.7c ở máy này không kèm gcc. DPI **export** (C gọi ngược SV để đọc bộ nhớ) cần biên dịch một wrapper trong lúc `vopt`, nên không dùng được. Giải pháp: C model **không có bộ nhớ** và không gọi ngược. Mỗi lần cần dữ liệu nó dừng lại và trả một sự kiện; SV trả lời bằng `dma330_dpi_supply()` rồi gọi bước kế tiếp.

```
dma330_dpi_go(h, pc, ns);  (+ dma330_dpi_periph_req cho từng request peripheral)
loop:
  k = dma330_dpi_step(h)
    NEED_CODE : đọc supply_bytes (32) byte tại supply_addr từ axi_mem_model, supply
    LD        : tạo burst đọc kỳ vọng; đọc supply_bytes byte từ supply_addr, supply
    ST / STZ  : tạo burst ghi kỳ vọng; lấy từng beat bằng dma330_dpi_beat (data 128 bit + strobe)
    ACK       : ack peripheral (single / burst / flush)
    SEV, WFE  : ghi lại
    END / KILL / FAULT / STARVED / UNKNOWN / RUNAWAY : kết thúc
```

Hệ quả tốt: thư viện chỉ dùng kiểu scalar và `bit [127:0]` (không cần `svdpi` runtime, không cần link `mtipli`), nên biên dịch bằng bất kỳ gcc nào thành DLL/`.so` rồi nạp bằng `vsim -sv_lib`.

### 2.2 Dữ liệu LD, FIXED và INCR

* INCR: các byte của burst là một đoạn liên tiếp từ địa chỉ đầu (beat đầu có thể ngắn nếu không align); SV cấp `bytes` byte.
* FIXED: mọi beat đọc cùng địa chỉ, nên SV chỉ cấp `size_bytes − offset` byte và model nhân lên cho từng beat.

Dữ liệu được lấy từ `axi_mem_model` **tại thời điểm model chạy** (lúc `load_job`), giống thời điểm snapshot của scoreboard. Vì vậy mọi vùng nguồn không được ghi lại giữa lúc nạp chương trình và lúc kênh chạy.

---

## 3. Giao diện C

Chi tiết trong `model/dma330_ref.h`. Cấu hình phải bằng tham số DUT: `bus_bytes = DATA_W/8`, `num_events`, `num_periph`, `mfifo_bytes` (dung lượng MFIFO của một kênh).

| Hàm | Vai trò |
|---|---|
| `dma330_new / free` | Tạo / hủy một ngữ cảnh model |
| `dma330_go(pc, ns)` | Như `DMAGO`: đặt PC, NS; mọi thanh ghi trở thành "chưa biết" |
| `dma330_periph_req(p, burst, last)` | Xếp một request peripheral; `DMAWFP` lấy theo thứ tự |
| `dma330_step()` | Chạy tới sự kiện kế tiếp |
| `dma330_supply(bytes, n)` | Cấp byte cho `NEED_CODE` / `LD` (nhiều đoạn được) |
| `dma330_beat(i, data, strb)` | Beat thứ i của burst ghi hiện tại: lane dữ liệu và strobe |
| `dma330_reg(r)`, `dma330_reg_valid(r)` | Giá trị thanh ghi cuối và việc chương trình có ghi nó không |

Sự kiện `DM_EV_*`:

| Sự kiện | Ý nghĩa |
|---|---|
| `NEED_CODE`, `LD` | Cần byte từ `supply_addr` (`supply_bytes` byte) |
| `LD`, `ST`, `STZ` | Một burst AXI: `addr`, `len`, `size`, `inc`, `cache`, `prot` (đã trộn NS), `bytes`, số beat |
| `ACK` | Ack peripheral (`periph`, loại single/burst/flush), sau `LD` của `DMALDP`, sau `ST` của `DMASTP`, hoặc `DMAFLUSHP` |
| `SEV`, `WFE` | Event được báo; `DMAWFE` luôn coi là đã thỏa |
| `END`, `KILL` | Kết thúc bình thường (CPC đứng tại lệnh này) |
| `FAULT` | Lỗi kênh: `ftr` (bit chắc chắn) và `ftr_maybe` (bit phụ thuộc thời gian) |
| `STARVED` | `DMAWFP` mà chưa có request nào được xếp |
| `UNKNOWN` | Chương trình dùng thanh ghi chưa ghi (SAR/DAR/CCR/LC) |
| `RUNAWAY` | Quá ngân sách lệnh (mặc định 100 000) |

---

## 4. Ngữ nghĩa đã mô hình hóa

Tất cả theo `DESIGN_SPEC.md` (mục 4.5, 4.7, 5.9, 7). Đối chiếu với `rtl/core/dma_channel.sv` và `dma_datapath.sv` chỉ để loại điểm mơ hồ.

| Phần | Hành vi |
|---|---|
| Giải mã | Bảng opcode và độ dài lệnh của `dma330_pkg::decode_op/insn_len`, gồm các mã `DMALPEND`/`DMALPFE` (`0x38–0x3F`, `0x2C–0x2F`, `0x28`, `0x2A`) và quy tắc `0x29/0x2B` luôn là `DMASTP` |
| Số byte burst | `INCR: (len+1)·2^size − off`; `FIXED: (len+1)·(2^size − off)` |
| `DMALD`/`DMAST` | `SAR`/`DAR += bytes` nếu INCR; địa chỉ beat, lane và strobe theo quy tắc AXI beat hẹp / không align |
| Dòng dữ liệu | Byte của `LD` nối vào một stream; `ST` lấy từ đầu stream; `STZ` không lấy |
| Endian swap | Chỉ với `ST`/`STP` (không với `STZ`): đảo byte trong từng nhóm `2^swap` đã align của beat |
| Điều kiện `S`/`B` | So bit 1 của opcode với `request_type`; sai thì như `DMANOP` |
| `DMAWFP` | Lấy request kế của peripheral; `request_type` = loại request nếu `P`, ngược lại theo hậu tố `S`/`B`; ghi `request_last` |
| `DMAFLUSHP` | Ack `FLUSH`, xóa `request_type` và `request_last` |
| Vòng lặp | `DMALP` nạp `LCx = n−1`; `DMALPEND`: nếu `LCx ≠ 0` giảm và lùi `jump`, ngược lại đi tiếp; `DMALPFE` lùi tới khi `request_last`; điều kiện sai thì đi tiếp |
| `DMAADDH/ADNH` | Cộng `{0000, imm16}` hoặc `{FFFF, imm16}` theo modulo 2³² |
| Quay vòng | Mọi phép cộng địa chỉ modulo 2³² |

### 4.1 Lỗi

Model tính đúng các điều kiện của bảng 5.9 (`undef_instr`, `operand_invalid`, `ch_evnt_err`, `ch_periph_err`, `ch_rdwr_err`, `mfifo_err`, `st_data_unavailable`) tại đúng lệnh gây lỗi; CPC là địa chỉ lệnh đó.

* `mfifo_err` xảy ra khi `unclaimed + bytes > mfifo_bytes`. Khi đó dù mọi store đang chờ có xả hết, chỗ trống vẫn không đủ, nên DUT chắc chắn báo lỗi. Điều kiện này không phụ thuộc thời gian.
* Nếu cùng một lệnh còn gây lỗi khác (ví dụ `ch_rdwr_err`), việc bit 12 có mặt hay không phụ thuộc vào store có còn đang xả lúc lệnh được thực thi lần đầu. Model đưa bit này vào `ftr_maybe` thay vì `ftr`.
* Lỗi bus (`RRESP`/`BRESP`/fetch) và watchdog là bất đồng bộ, **không** thuộc phạm vi model.
* Sau lỗi, traffic của các burst đã issue trước đó là không xác định (hàng đợi bị flush), nên chỉ kiểm `FTR`/`CPC`, không kiểm traffic.

### 4.2 Giả định và giới hạn

* Một channel thread; không mô hình manager (`DMAGO` trong chương trình kênh là lỗi `undef_instr`, đúng RTL).
* `DMAWFE` luôn được coi là thỏa. Test dùng event vẫn tự điều khiển thời gian.
* Thứ tự ack là thứ tự chương trình. Đúng khi một kênh dùng peripheral (ack đọc sinh lúc RLAST, ack ghi lúc B, mà store luôn sau load của nó). Hai kênh chung một peripheral phải tự khai báo thứ tự (xem `dma_periph_corner_test`).
* Dữ liệu nguồn không được thay đổi giữa lúc model chạy và lúc kênh đọc.

---

## 5. Cách dùng trong môi trường

| Chế độ | Khi nào | Kiểm tra |
|---|---|---|
| **Đối chiếu** (`SB_XCHECK`) | Mọi job có danh sách op, ngay khi nạp (`load_job`, và `dma_boot_test`) | Số burst đọc / ghi, thuộc tính, dữ liệu và strobe từng beat, chuỗi ack, kết thúc sạch: generator và C model phải trùng nhau |
| **Trạng thái kiến trúc** (`ARCH`) | Sau mỗi `run_job` khi kênh về Stopped | `CPC` bằng địa chỉ `DMAEND`/`DMAKILL`; `SAR`/`DAR`/`CCR`/`LC0`/`LC1` mà chương trình đã ghi |
| **Bộ dự đoán duy nhất** | Job `JOB_RAND` | Mọi burst, beat, ack mà scoreboard so với bus lấy từ C model |

Tắt bằng `+NO_CMODEL` (runtime) hoặc `--no-cmodel` / `+define+DMA_NO_CMODEL` (build không có thư viện: `dma330_dpi_pkg` biên dịch các hàm rỗng, `run_regression.py` bỏ qua hai test cần model).

Thanh ghi "chưa biết": `dma330_go` xóa trạng thái "đã ghi", nên chỉ thanh ghi chương trình thực sự ghi (`DMAMOV`, `DMALP`) mới được so. Cách này an toàn khi kênh vừa chạy chương trình khác (ví dụ chương trình lỗi) mà model không thấy.

---

## 6. Generator chương trình ngẫu nhiên (`dma_rand_prog`)

Chương trình = 1–4 segment + `DMAWMB`, `DMASEV` ngắt, `DMAEND`/`DMAKILL`. Mỗi segment độc lập:

| Segment | Nội dung |
|---|---|
| Copy | `MOV SAR/DAR/CCR`; vòng lặp `DMALP` 0–2 cấp; thân vòng có `kl` lệnh `DMALD` và `ks` lệnh `DMAST` sao cho `kl·B_src = ks·B_dst` (cân bằng dữ liệu theo bội chung); xen kẽ `LD ST LD ST` hoặc `LD…LD ST…ST`; `DMARMB` tùy chọn; bước hàng `DMAADDH` gồm bước nhảy nhiều trang |
| Reverse | `LD; (RMB); ST; DMAADNH SAR,−2·burst` đọc nguồn từ cuối về đầu |
| Fill | `DMASTZ` trong vòng lặp, trường swap của `CCR` ngẫu nhiên kể cả giá trị không hợp lệ |

Mỗi segment ngẫu nhiên hóa kích thước/độ dài beat hai phía, INCR/FIXED từng phía, offset không align (INCR hai phía: offset nguồn ≤ offset đích để dòng dữ liệu luôn đủ), endian swap hợp lệ, `AxPROT`/`AxCACHE`. Mọi vùng INCR nằm trong một trang 4 KB. Kênh 0 có kernel kết thúc đúng cuối `0xFFFF_F000` để `SAR` quay về 0.

**Cân bằng dữ liệu được dựng sẵn trong kernel, còn "đúng hay không" do C model quyết định:** chương trình hoàn chỉnh được nạp vào bộ nhớ, C model chạy nó, và chỉ chương trình kết thúc sạch (không fault, không lock-up, không runaway, có burst) mới được dùng; ngược lại sinh lại. Nhờ đó ràng buộc phức tạp (offset không align, MFIFO) không phải tính lại trong generator.

Dữ liệu nguồn của mọi trang chương trình đọc được điền ngẫu nhiên.

---

## 6b. Biên dịch và chạy

`sim/run_regression.py` làm các bước sau (bỏ qua với `--no-cmodel`):

1. tìm compiler: `$CC`, `gcc` trong `PATH`, hoặc `C:/msys64/ucrt64/bin/gcc.exe`;
2. biên dịch `model/dma330_ref_test.c` + `dma330_ref.c` với `-Wall -Wextra`, chạy; **dừng nếu test độc lập fail**;
3. biên dịch `dma330_ref.c` + `dma330_dpi.c` thành `sim/dma330_ref.dll` (`-shared -static-libgcc`);
4. `vsim ... -sv_lib sim/dma330_ref`.

Chạy riêng test độc lập (không cần simulator):

```sh
gcc -O2 -Wall -Wextra -o dma330_ref_test model/dma330_ref_test.c model/dma330_ref.c && ./dma330_ref_test
```

`dma330_ref_test` có 133 kiểm tra known-answer, mọi giá trị kỳ vọng tính tay từ đặc tả (copy align và không align, FIXED, vòng lặp lồng, endian swap, `S`/`B`, `DMALPFE`, ack, fault, quay vòng 32 bit, giao thức `NEED_CODE`/`STARVED`/`RUNAWAY`).

---

## 7. Mở rộng

* Thêm lệnh mới: cập nhật `decode_op`/`insn_len` và `case` trong `dma330_step`, thêm known-answer vào `dma330_ref_test.c`, rồi cập nhật bảng mục 4.
* Cấu hình DUT khác (`DATA_W`, `MFIFO_LINES`): `dma_cmodel.build_model` đọc `dma_tb_params_pkg`, model hỗ trợ bus 1–16 byte; chưa chạy regression với cấu hình khác mặc định.
* Hướng tiếp theo: dự đoán `FTR`/`CPC` cho chương trình cố ý sai bằng `ftr`/`ftr_maybe` (model đã có sẵn); mô hình manager (`DMAGO`, boot).
