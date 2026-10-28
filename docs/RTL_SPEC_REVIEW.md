# Review RTL so với Arm DMA-330 r1p2

> Đây là báo cáo phát hiện trước khi sửa. Các lỗi F1..F6 đã được xử lý trong
> [RTL_SPEC_FIXES.md](RTL_SPEC_FIXES.md); dùng báo cáo đó để xem trạng thái và
> kết quả validation hiện tại. Phần dưới giữ lại bằng chứng trước sửa.

Ngày review: 2026-10-28. Đối tượng: trạng thái working tree hiện tại, bao gồm
các thay đổi chưa commit có sẵn khi bắt đầu review. Không sửa RTL trong lần
review này.

Nguồn chuẩn: [Arm DDI 0424D trong references](../references/DDI0424D_dma330_r1p2_trm.pdf).
Số trang TRM dưới đây là số trang in trong tài liệu, không phải index PDF.
Đặc tả nội bộ: [DESIGN_SPEC.md](DESIGN_SPEC.md), đặc biệt Mục 9.

## Kết luận

**Chưa thể coi RTL là tương thích đầy đủ với programmer's model của DMA-330.**
Regression sẵn có pass nhưng các phép kiểm tra trực tiếp yêu cầu TRM phát hiện
5 sai khác chức năng, đều tái hiện trên sync và async. Một sai khác cấu hình
khác được xác định bằng đối chiếu register encoding. Có hai điểm giảm khả năng
che latency cần cân nhắc khi đặt mục tiêu performance.

Mức ưu tiên:

- **P1:** cần sửa trước khi dùng IP như một DMA-330 tương thích trong các tình
  huống bị ảnh hưởng: sai dữ liệu, abort chương trình hợp lệ, sai quyền debug,
  hoặc không thực hiện được lệnh dừng manager.
- **P2:** sai programmer's model/khả năng nhận dạng cấu hình; nên sửa trước khi
  cam kết tương thích và phát hành driver chung.

## Phát hiện chức năng

### F1 — P1: lệnh store có điều kiện false vẫn nhả load-lock

**Mã:** [dma_channel.sv:374](../rtl/core/dma_channel.sv#L374),
[dma_datapath.sv:286](../rtl/core/dma_datapath.sv#L286).
**Chuẩn:** TRM 2.6.4, trang 2-17; 2.11.4, trang 2-37–2-38.

`ll_release` chỉ xét instruction class và `in_exec_ok`, không xét `cond_ok`.
Vì vậy `DMASTB` khi `request_type=Single`, hoặc `DMASTS` khi
`request_type=Burst`, vẫn làm mất quyền sở hữu load-lock, mặc dù TRM yêu cầu
thực hiện như `DMANOP` khi điều kiện không khớp. Vấn đề cũng áp dụng cho
`DMASTP` có điều kiện không khớp.

Ca tái hiện dùng MFIFO mặc định 128 line. Hai chương trình có static requirement
0 và dynamic requirement 128 line mỗi chương trình: tổng static + dynamic lớn
nhất bằng 128, đúng ngân sách TRM. Kênh 0 load 64 line, gặp `DMASTB` false,
chạy một đoạn NOP rồi load thêm 64 line. Kênh 1 tranh load-lock và cũng cần
128 line trước khi store. RTL nhả lock sai ở kênh 0, cho kênh 1 chiếm phần pool
còn lại; sau đó cả hai cùng bị abort:

```text
FTR0=80000000 FTR1=80000000 CSR0=0000008f CSR1=0000009f
```

Đây là lỗi chức năng của load-lock, không phải chương trình vượt ngân sách.
Ca đối chứng thay riêng `DMASTB` false bằng `DMANOP` phải hoàn thành trên cả
hai cấu hình; xem kết quả validation.

**Hướng sửa:** store chỉ nhả lock khi điều kiện thực thi đúng; giữ nguyên các
đường nhả lock hợp lệ khác. Giữ ca hai kênh và ca đối chứng trong regression.

### F2 — P1: thay đổi destination discontinuity không drain/discard MFIFO

**Mã:** [dma_channel.sv:519](../rtl/core/dma_channel.sv#L519),
[dma_datapath.sv:237](../rtl/core/dma_datapath.sv#L237).
**Chuẩn:** TRM 2.11.3, trang 2-36–2-37.

`DMAMOV` cập nhật SAR/DAR/CCR ngay rồi chuyển sang cập nhật PC. Không có logic
phát hiện discontinuity, drain bus và bỏ residual MFIFO theo yêu cầu TRM.
Đây là sai khác được thừa nhận ở Mục 9, nhưng tác động lớn hơn khác biệt trạng
thái quan sát được: cùng bytecode có thể ghi ra các byte khác nhau.

Ca tái hiện:

1. Cấu hình nguồn mỗi load 8 byte, đích mỗi store 4 byte; DAR ban đầu aligned.
2. `DMALD` đưa `10 11 12 13 14 15 16 17` vào MFIFO.
3. `DMAMOV DAR` đổi byte-lane alignment từ 0 sang 4.
4. `DMALD` tiếp theo đọc `20 21 22 23 24 25 26 27`.
5. `DMAST` ghi 4 byte.

TRM yêu cầu bước 3 đợi read/write hoàn tất và bỏ residual của lần load đầu.
Đích phải nhận `20 21 22 23`; RTL thực tế ghi **`10 11 12 13`** và vẫn kết thúc
không lỗi. Trường hợp source discontinuity cũng thiếu read barrier, dù TRM
không yêu cầu bỏ dữ liệu ở phía source.

**Ảnh hưởng software:** chương trình tái cấu hình descriptor, đổi alignment,
đổi endian/destination increment/fixed burst size giữa chừng có thể khác kết
quả Arm. `DMARMB; DMAWMB` đơn thuần không thay thế được thao tác discard.

**Hướng sửa:** phân biệt source và destination discontinuity đúng các field
TRM liệt kê; source drain read, destination drain cả hai hướng và flush residual
MFIFO. Không áp dụng flush cho mọi lần đổi burst length/địa chỉ nếu TRM không
yêu cầu, vì sẽ phá các chương trình packing hợp lệ.

### F3 — P1: debug manager không được phục vụ khi chương trình boot đang chạy

**Mã:** [dma_manager.sv:229](../rtl/core/dma_manager.sv#L229),
[dma_manager.sv:237](../rtl/core/dma_manager.sv#L237),
[dma_regs.sv:322](../rtl/core/dma_regs.sv#L322).
**Chuẩn:** TRM 2.5.1, trang 2-13.

Manager nhận debug ở `M_STOPPED`, `M_WFE` và đường kill từ `M_FAULTING`.
`M_FETCH`, `M_EXEC`, `M_UPDATING_PC` không tiếp nhận debug. Một debug command
được đưa vào pending khi manager đang chạy chỉ hoàn thành khi chương trình tự
đi đến trạng thái nhận debug.

Ca tái hiện boot bằng hàng nghìn `DMANOP`, phát debug `DMAKILL`, đợi 256 clock:

```text
sync : DBGSTATUS=1 DSR=1 DPC=00008002 -> 00008059
async: DBGSTATUS=1 DSR=1 DPC=00008006 -> 00008077
```

Con số 256 clock là cửa sổ kiểm tra, không phải timeout kiến trúc do TRM quy
định. Bằng chứng quan trọng là manager đã xử lý nhiều instruction boundary
nhưng không phục vụ debug. Với chương trình dài, độ trễ phụ thuộc chiều dài
chương trình; với fetch bị kẹt, có thể không bao giờ phục vụ.

Trong thời gian đó `dbg_mgr_busy` còn chặn cả debug command mới tới channel.
Software có thể mất đường hủy DMA và phải reset hệ thống/IP.

**Hướng sửa:** chèn debug tại instruction boundary an toàn trong lúc manager
chạy; bảo toàn PC/program context cho `DMAGO`/`DMASEV`, xử lý kill/invalidate
đúng với fetch đang pending.

### F4 — P1: quyền debug cổng NS khác TRM khi manager Secure

**Mã:** [dma_regs.sv:330](../rtl/core/dma_regs.sv#L330),
[dma_regs.sv:418](../rtl/core/dma_regs.sv#L418).
**Chuẩn:** TRM 2.5.1, trang 2-13; Table 3-4, trang 3-9.

TRM dùng security của **manager** để quyết định quyền truy cập NS đối với debug
registers. Khi DNS=0, cổng NS phải RAZ/không thực thi command. RTL kiểm tra DNS
cho command tới manager, nhưng command tới channel chỉ kiểm tra CNS của channel.

Ca tái hiện: manager Secure khởi động channel NS đang `DMAWFE`; cổng NS phát
`DMAKILL` tới channel đó. RTL đưa channel về Stopped (`CSR=00200000`), trong khi
theo quyền debug của TRM channel phải tiếp tục chờ.

Ngoài ra `DBGSTATUS` NS trả busy thật khi DNS=0; DBGINST0/1 có bank NS đọc/ghi
riêng. TRM mô tả DBGINST0/1 là write-only và debug NS chịu quyền của manager.
Các khác biệt này rộng hơn hàng lọc interrupt trong Mục 9.

Đây là thay đổi quyền sở hữu/điều khiển DMA giữa hai world. Ca tái hiện chứng
minh NS có thể hủy kênh NS do Secure manager quản lý; không chứng minh NS thực
hiện được secure AXI access hoặc điều khiển được channel Secure.

**Hướng sửa:** nếu mục tiêu là tương thích Arm, áp quyền DNS cho cả giao diện
debug NS theo Table 3-4. Nếu chủ đích là chính sách khác, phải công bố rõ như
một thay đổi security architecture, dùng driver/integration contract tương ứng.

### F5 — P2: lỗi CCR security không phải precise abort tại DMAMOV

**Mã:** [dma_channel.sv:301](../rtl/core/dma_channel.sv#L301),
[dma_channel.sv:321](../rtl/core/dma_channel.sv#L321),
[dma_channel.sv:522](../rtl/core/dma_channel.sv#L522).
**Chuẩn:** TRM 2.8.2, trang 2-25; Table 3-21, trang 3-26–3-27.

Kênh NS không được lập trình CCR để tạo secure read/write. RTL chỉ kiểm tra
`src_prot[1]` tại load và `dst_prot[1]` tại store. Tại `DMAMOV CCR`, RTL chỉ
kiểm tra số register rồi chấp nhận immediate.

Ca tái hiện channel NS:

```text
DMAMOV CCR, 0
DMASEV 0
DMAEND
```

TRM cần abort tại MOV với `ch_rdwr_err`, không thực hiện các lệnh sau.
RTL thực tế: `FTR=0`, `CPC=00010008`, `RIS[0]=1`. Nếu sau đó có LD/ST, lỗi
cũng bị dời sang instruction khác, làm sai precise fault PC và thứ tự side
effect. Kiểm tra hiện có vẫn chặn secure data transaction tại LD/ST; lỗi này
không đồng nghĩa đã chứng minh được rò quyền truy cập AXI Secure.

**Hướng sửa:** kiểm tra cả hai security field của immediate CCR trước khi
commit MOV, giữ CCR cũ khi fault. Sửa oracle C và các test security đang kỳ
vọng lỗi ở LD/ST.

### F6 — P2: cấu hình cache được chấp nhận nhưng CR1 dùng encoding reserved

**Mã:** [dma330_core.sv:717](../rtl/core/dma330_core.sv#L717),
[dma_regs.sv:392](../rtl/core/dma_regs.sv#L392).
**Chuẩn:** TRM Table 3-30, trang 3-36.

RTL cho phép line cache là lũy thừa 2 bất kỳ, chỉ yêu cầu ít nhất 8 byte.
CR1[2:0] lại chứa 3 bit của `log2(LINE_BYTES)`. TRM chỉ định nghĩa line
4/8/16/32 byte; encoding 6 và 7 là reserved.

Ví dụ `DATA_W=128, IC_BEATS=4` được phép elaboration nhưng tạo line 64 byte và
CR1[2:0]=6. Cấu hình mặc định 64-bit/4 beat, line 32 byte không gặp lỗi này.
Đây là kết luận từ logic tham số và bảng encoding, chưa bổ sung simulation
full-core cho cấu hình 128-bit trong review này.

**Hướng sửa:** với profile tương thích DMA-330, giới hạn line ở các giá trị
TRM biểu diễn được và front-end hỗ trợ. Nếu giữ line lớn, cần capability
extension và driver riêng; không mô tả CR1 là hoàn toàn tương thích Arm.

## Performance

### P-A: AW không chạy trước W của burst hiện tại

**Mã:** [dma_wr_engine.sv:208](../rtl/core/dma_wr_engine.sv#L208),
[dma_wr_engine.sv:237](../rtl/core/dma_wr_engine.sv#L237).

`start` burst sau phụ thuộc `finish`, mà `finish` đợi cả AW và WLAST của burst
hiện tại. Có thể có nhiều B outstanding, nhưng chỉ có một context đang phát
AW/W. Tăng `WR_OUT` không làm AW của burst kế tiếp được issue sớm khi W hiện
tại còn chạy.

Probe standalone xếp sẵn 4 burst, mỗi burst 16 beat, dùng DMASTZ để loại bỏ
thiếu dữ liệu MFIFO; slave nhận AW ngay và bắt đầu nhận W sau 8 chu kỳ latency:

```text
AWs=4 beats=64 W_window=91 cycles utilization=70.33%
```

Mẫu slave này cho thấy latency lặp lại giữa các burst, dù data/queue/tracker
đủ. Đây là giới hạn che latency, không phải vi phạm AXI hoặc bằng chứng rằng
thiết kế luôn chỉ đạt 70,33%. Unit test sẵn có với AWREADY/WREADY luôn sẵn sàng
vẫn chứng minh được W liên tiếp.

**Tối ưu đề xuất:** tách queue/context AW khỏi sequencer W, cho phép AW của
burst kế tiếp được issue trước khi W của burst hiện tại kết thúc, với điều kiện
dữ liệu của burst kế tiếp đã đầy đủ. Giữ thứ tự W của AXI4 và tracking kill/error.
Điều kiện phải có đủ dữ liệu trước AW vốn đúng TRM 2.10.7 và phải tiếp tục giữ.

### P-B: một cache miss chặn phục vụ request của các thread khác

**Mã:** [dma_icache.sv:107](../rtl/core/dma_icache.sv#L107),
[dma_icache.sv:208](../rtl/core/dma_icache.sv#L208).

Cache chỉ nhận request trong IC_IDLE; khi IC_AR/IC_R, lookup của thread khác
phải đợi, kể cả lookup có thể hit. Local line buffer cho phép thread tiếp tục
nếu instruction còn trong line cục bộ, nên ảnh hưởng phụ thuộc program footprint
và latency instruction memory. Khi nhiều kênh đổi line đồng thời hoặc loop
không vừa local buffer, latency fetch bị cộng dồn. Chưa benchmark mức suy giảm
toàn hệ thống trong review này.

Có thể cho hit đi qua miss, tăng số refill context hoặc prefetch. Đây là lựa
chọn kiến trúc/performance, không nên báo như lỗi tính đúng của AXI.

## Đánh giá từng nhóm của Mục 9

| Nội dung | Tác động tới software / hệ thống | Đánh giá |
|---|---|---|
| Alignment/discontinuity | Cùng chương trình hợp lệ có thể ghi dữ liệu khác; barrier/discard và ordering khác | **Lớn**, F2; cần sửa nếu yêu cầu tương thích bytecode |
| FIXED không aligned | TRM không hỗ trợ kiểu lập trình này | Thấp với chương trình đúng chuẩn; không dựa vào phần mở rộng khi chạy lại trên Arm |
| Burst size lớn hơn bus | Có precise abort nhưng dùng `ch_rdwr_err` cho lỗi ngoài security | Ảnh hưởng chẩn đoán; không ảnh hưởng transfer hợp lệ; nên ghi rõ overload fault bit |
| Lọc INTEN/RIS/INTMIS/INTCLR/FSRC khi manager NS | Thay đổi giá trị đọc, quyền write và khả năng xử lý shared events/faults | Trung bình đến lớn tùy cách chia tài nguyên S/NS; không chỉ là thay đổi performance |
| Quyền NS của FTRn | RTL dùng CNS để lọc, trong khi Table 3-1 đặt FTRn theo security của manager | Cần bổ sung vào danh sách; ảnh hưởng quan sát/định tuyến lỗi và chẩn đoán |
| Quyền debug NS và DBGINST | Cho NS điều khiển channel NS khi manager Secure; register readback/banking cũng khác | **Lớn**, F4; Mục 9 hiện thiếu |
| Lock-up/watchdog | Thời điểm phát hiện, tập kênh bị abort và sticky WDSTAT khác Arm | Có ảnh hưởng error recovery; mô tả đủ điều kiện load/store queue của TRM 2.8.3. Tách khỏi lỗi nhả lock F1 |
| Chờ đủ dữ liệu trước AW | Arm cũng yêu cầu như vậy ở 2.10.7 | **Không phải khác biệt**; chuyển sang phần hành vi tuân thủ. P-A là vấn đề pipeline AW/W riêng |
| DMAGO vào kênh chạy nhận NOP | Arm cũng quy định ở 4.3.5 | **Không phải khác biệt**. Invalidate thêm khi start một kênh Stopped nhìn chung không làm thay đổi kết quả đúng |
| “DMALPFE có điều kiện chỉ LC1” | TRM 4.3.10 không cho suffix S/B khi loop bắt đầu bằng DMALPFE; lc=1 cho forever loop | **Cần sửa mô tả**; không tính đây là thiếu tính năng chuẩn. Dùng encoding chuẩn thay vì quảng bá các alias 0x28/0x2A |
| AXI4 thay AXI3 | Không đổi bytecode, nhưng khác giao diện WID/LOCK/LEN, bridge và kiểm tra bus | Lớn ở tích hợp phần cứng; chấp nhận được nếu hệ thống dùng AXI4 và tài liệu công bố rõ |
| ID instruction fetch dùng all-ones | Thay routing/monitoring/QoS hoặc chính sách hệ thống nếu có phân biệt theo ID | Chủ yếu integration; không tự động đổi software ISA. Security attribute trên PROT vẫn cần được tôn trọng |
| APB async thay pclken | Thay latency, clock/reset và cách kết nối bus | Thấp với driver tuân thủ PREADY; cần contract clock/reset rõ. Tên APB4 cần khớp tập port thực tế |
| Peripheral request latch sâu 1 | Backpressure sớm, có bubble khi consume/refill; async còn có một entry trong CDC | Không tự làm mất request nếu peripheral tuân handshake; có thể giảm tốc độ phục vụ peripheral |
| FARn/WDSTAT/WD timeout/Q-Channel/PSLVERR | Thêm register/behavior ngoài vùng chuẩn | Phải để driver opt-in, phân biệt extension. WD bit 0 bản thân đã là thanh ghi chuẩn của Arm |
| irq ở aclk | Phụ thuộc clock của interrupt controller phía nhận | Điều kiện tích hợp/CDC; cột Arm đang bỏ trống không đủ để kết luận đây là sai khác kiến trúc |
| MFIFO tối thiểu 32 line | Hạn chế cấu hình phần cứng, thông số có thể đọc từ CRD | Nhìn chung ít ảnh hưởng phần mềm nếu đọc capability; dense byte-stream packing cũng khác mức dùng line trong Appendix B |
| I-cache line >=8, không giới hạn trên | Có cấu hình tạo encoding reserved của CR1 | **Cần sửa**, F6; Mục 9 cần phân biệt profile tương thích và extension |
| Endian swap không rộng hơn bus | Cắt bớt các lựa chọn swap mà Table 3-22 mô tả, không có trường capability riêng cho giới hạn này | Có ảnh hưởng chương trình dùng nhóm swap lớn hơn bus; dùng DATA_W=128 hoặc driver có quy tắc giới hạn riêng |
| PERIPH_ID mặc định bằng Arm r1p2 | Có thể khiến software nhận dạng như Arm trong khi semantics/capability khác | Không dùng ID trùng làm bằng chứng tương thích; cân nhắc nhận dạng/binding riêng nếu giữ các thay đổi chức năng |

Mục 9 nên tách thành: yêu cầu TRM chưa đáp ứng, khác biệt giao diện tích hợp,
extension được công bố, và giới hạn performance. Cần bổ sung F1/F3/F4/F5/F6;
bỏ các hàng đang mô tả hành vi vốn phù hợp TRM như một khác biệt. Đặc biệt,
khẳng định “CCR NS đã sửa” ở mở đầu Mục 9 chưa đầy đủ vì F5.

## Phạm vi kiểm tra và bằng chứng

| Kiểm tra thực hiện trên working tree | Kết quả |
|---|---|
| C reference-model unit test | 173 checks, 0 failed |
| Unit RTL hiện có | 11/11 PASS; cache/fetch/write/thread status, gồm các cấu hình 32/64/128-bit ở cấp module |
| UVM hiện có, 25 test × sync/async × seed 1 | **50/50 PASS**, 4 simulation song song |
| Probe TRM F1–F5, mỗi probe sync/async | **10/10 tái hiện sai khác**, expected NONCONFORMANT trên RTL hiện tại |
| Đối chứng F1, thay conditional store false bằng DMANOP | **2/2 PASS**, sync và async; không UVM warning/error/fatal |
| Write-engine latency probe | 64 W beats / 91 cycles trong cửa sổ đo, 70,33% |
| F6 | Static review register encoding và parameter guards; chưa simulation full-core 128-bit |
| Synthesis, STA, formal, sign-off CDC/RDC | Không thực hiện trong review này |

Các probe dùng AXI/APB VIP và DUT hiện có nhưng tắt scoreboard/reference-model
cho các ca tranh luận, rồi kiểm tra trực tiếp kết quả theo TRM: memory,
CSR/FTR/CPC/RIS và debug status. Không ép FSM hoặc force tín hiệu bên trong RTL.
SVA từ baseline vẫn được bind trong top UVM. Lỗi UVM ở các probe là kết quả
đối chiếu mong muốn, không phải lỗi compile hay thiếu kích thích.

Pass regression hiện có chưa chứng minh conformance: C model cũng cập nhật
CCR trực tiếp và kiểm tra NS ở load/store (`model/dma330_ref.c`, các nhánh
I_MOV/data transfer), và dùng stream semantics cho dữ liệu. Một oracle độc lập
về ngôn ngữ/cấu trúc vẫn có thể cùng giả định kiến trúc với DUT.

Mã tái hiện:

- [tb/review/dma_spec_review_pkg.sv](../tb/review/dma_spec_review_pkg.sv)
- [tb/review/dma_write_perf_tb.sv](../tb/review/dma_write_perf_tb.sv)
- [sim/run_spec_review.py](../sim/run_spec_review.py)

Chạy từ root repository:

```powershell
python sim/run_regression.py -j 4 --vopt-j 4
python sim/run_spec_review.py
```

Lệnh thứ hai trả exit code 1 khi còn bất kỳ probe NONCONFORMANT. Ca control
phải PASS; runner không chuyển lỗi conformance thành PASS. Log, JSON kết quả
và hash SHA-256 của RTL nằm ở `sim/logs/spec_review/`. Library review nằm trong
thư mục log riêng, không ghi đè thư viện regression.

## Thứ tự xử lý đề xuất

1. Sửa F1 và giữ cặp test semantic-equivalence false-store/NOP.
2. Implement discontinuity F2 và bổ sung các test đổi từng field CCR/SAR/DAR,
   cả khi có outstanding read/write, cùng các ca packing hợp lệ không được flush.
3. Sửa phục vụ debug manager F3 và quyền cổng NS F4 theo contract đã chọn.
4. Sửa fault-at-MOV F5 cùng C model và expectations về precise CPC.
5. Ràng buộc cache profile/register capability F6, cập nhật lại Mục 9 và nhận dạng IP.
6. Tối ưu AW pipeline và cache concurrency theo latency/bandwidth mục tiêu,
   sau khi có benchmark và kiểm tra kill/error/ordering tương ứng.

Nếu chỉ dùng chương trình copy thông thường, không đổi discontinuity khi còn
residual, không phụ thuộc conditional store để giữ lock, và software luôn
quản lý qua secure manager đã dừng, một số lỗi sẽ không được kích hoạt. Điều
đó giải thích regression pass; không đủ để cam kết tương thích chung với
mọi chương trình DMA-330 hợp lệ.
