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

Chi tiết trong `model/dma330_ref.h`. Cấu hình phải bằng tham số DUT: `bus_bytes = DATA_W/8`, `num_events`, `num_periph`, `mfifo_bytes` (dung lượng của toàn bộ MFIFO dùng chung = `MFIFO_LINES × DATA_W/8`). Security của event/peripheral (`CR3`/`CR4`) đặt bằng `dma330_security(m, irq_ns, periph_ns)`; mặc định mọi event/peripheral là non-secure (trùng chân boot mặc định của TB).

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
| `FAULT` | Lỗi kênh: `ftr` (bit chắc chắn); `ftr_maybe` luôn bằng 0 từ v1.3 |
| `UNSURE` | `DMALD` mà việc có lock-up MFIFO hay không phụ thuộc thời gian (offset line, xem 4.1); model dừng ở lệnh đó |
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
| `DMALD`/`DMAST` | `SAR`/`DAR += bytes` nếu INCR; địa chỉ beat, lane và strobe theo quy tắc AXI beat hẹp / không align. Dạng `S` (`op[1:0] = 01`: `DMALDS`, `DMASTS`, `DMALDPS`, `DMASTPS`) là một beat (`len = 0`). Model báo burst của lệnh; việc tách burst vượt 4 KB thành hai burst AXI do scoreboard làm (`split_4k`) |
| Thuộc tính AXI | `prot` = `CCR.x_prot`; `cache`: đọc `{0, src_cache}`, ghi `{dst_cache[2], 0, dst_cache[1:0]}` (`AWCACHE[3,1,0]`) |
| Dòng dữ liệu | Byte của `LD` nối vào một stream; `ST` lấy từ đầu stream; `STZ` không lấy |
| Endian swap | Chỉ với `ST`/`STP` (không với `STZ`): đảo byte trong từng nhóm `2^swap` byte liên tiếp của burst (nhóm có thể trải trên nhiều beat hẹp) |
| Điều kiện `S`/`B` | So bit 1 của opcode với `request_type`; sai thì như `DMANOP` |
| `DMAWFP` | `P`: lấy request kế, `request_type`/`request_last` theo request. `S`: đi tiếp với request bất kỳ, chỉ lấy request single (request burst ở lại), `request_type = single`, `request_last = 0`. `B`: bỏ các request single, lấy request burst, `request_type = burst`, `request_last = 0` |
| `DMAFLUSHP` | Ack `FLUSH`, xóa `request_type` và `request_last` |
| Vòng lặp | `DMALP` nạp `LCx = n−1`; `DMALPEND`: nếu `LCx ≠ 0` giảm và lùi `jump`, ngược lại đi tiếp; `DMALPFE` lùi tới khi `request_last`; điều kiện sai thì đi tiếp |
| `DMAADDH/ADNH` | Cộng `{0000, imm16}` hoặc `{FFFF, imm16}` theo modulo 2³² |
| Quay vòng | Mọi phép cộng địa chỉ modulo 2³² |

### 4.1 Lỗi

Model tính đúng các điều kiện của bảng 5.9 (`undef_instr`, `operand_invalid`, `ch_evnt_err`, `ch_periph_err`, `ch_rdwr_err`, `mfifo_err`, `st_data_unavailable`) tại đúng lệnh gây lỗi; CPC là địa chỉ lệnh đó.

* Số event/peripheral ≥ `num_events`/`num_periph` → `operand_invalid`.
* Thread non-secure (`dma330_go(..., ns = 1)`): event secure trong `DMASEV`/`DMAWFE` → `ch_evnt_err`; peripheral secure trong `DMAWFP`/`DMAFLUSHP`/`DMALDP`/`DMASTP` → `ch_periph_err`; `DMALD`/`DMAST`/`DMASTZ` khi `CCR` yêu cầu truy cập secure (`x_prot[1] = 0`) → `ch_rdwr_err` (đặc tả 4.5).
* `ch_rdwr_err` khác: burst size > bus; endian swap không thực hiện được (nhóm > bus, `DAR` không align, INCR không chứa trọn nhóm, FIXED beat hẹp hơn nhóm). Burst vượt 4 KB không phải lỗi.
* `mfifo_err` (self lock-up, kênh chạy một mình trong pool dùng chung). Sau khi các store đã issue xả hết, kênh giữ các line chứa byte chưa store; với lệnh load này nó cần `ceil((off + unclaimed + bytes) / NB)` line, trong đó `off` là offset trong line của byte cũ nhất. Stream rỗng không giữ line nào (một load luôn vừa) và có thể bắt đầu lại ở offset 0, tùy thời điểm store xả xong. Model giữ tập các offset có thể có (`off_mask`: xoay theo số byte mỗi store, thêm 0 mỗi khi stream rỗng):
  * mọi offset đều vượt `mfifo_bytes / NB` line → `mfifo_err` chắc chắn;
  * chỉ một số offset vượt → kết quả phụ thuộc thời gian, model báo `UNSURE` (bộ sinh chương trình ngẫu nhiên loại bỏ chương trình đó);
  * với chương trình mà mọi store có số byte là bội của `NB` (thường gặp) tập này chỉ có offset 0, nên không bao giờ `UNSURE`.
* Lock-up chỉ được báo khi lệnh load không có lỗi khác (như datapath: `ld_req` chỉ bật khi lệnh không có lỗi khác). Vì vậy không còn trường hợp "bit 12 có thể có" (`ftr_maybe = 0`).
* Model không mô hình các kênh khác: load-lock, chờ chỗ trống và dead-lock giữa nhiều kênh (`lockup_err`, `dma_mfifo_share_test`) nằm ngoài model. Bộ sinh chương trình ngẫu nhiên giữ mỗi kênh dưới `MFIFO_LINES/NUM_CH` line dữ liệu chưa store, nên không có dead-lock giữa các kênh (load-lock chỉ làm thay đổi thời điểm).
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

`dma330_ref_test` có 173 kiểm tra known-answer, mọi giá trị kỳ vọng tính tay từ đặc tả (copy align và không align, FIXED, vòng lặp lồng, endian swap, `S`/`B`, `DMALPFE`, ack, fault, quay vòng 32 bit, giao thức `NEED_CODE`/`STARVED`/`RUNAWAY`, lock-up MFIFO theo line và `UNSURE`, security event/peripheral/`CCR` của thread NS; lệnh `S` một beat, `DMAWFP S/B/P`, burst vượt 4 KB hợp lệ, swap rộng hơn beat, `AWCACHE`, `operand_invalid` cho số event/peripheral sai).

---

## 7. Mở rộng

* Thêm lệnh mới: cập nhật `decode_op`/`insn_len` và `case` trong `dma330_step`, thêm known-answer vào `dma330_ref_test.c`, rồi cập nhật bảng mục 4.
* Cấu hình DUT khác (`DATA_W`, `MFIFO_LINES`): `dma_cmodel.build_model` đọc `dma_tb_params_pkg`, model hỗ trợ bus 1–16 byte; chưa chạy regression với cấu hình khác mặc định.
* Hướng tiếp theo: dự đoán `FTR`/`CPC` cho chương trình cố ý sai bằng `ftr` (model đã có sẵn); mô hình manager (`DMAGO`, boot); truyền `CR3`/`CR4` thật của test vào model (`dma_cmodel` hiện dùng mặc định toàn NS).
