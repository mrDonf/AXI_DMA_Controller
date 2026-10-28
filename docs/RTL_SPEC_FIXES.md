# Sửa RTL theo TRM DMA-330 r1p2

Ngày: 2026-10-28. Nguồn: Arm DDI 0424D trong `references`.
Tiếp nối [review](RTL_SPEC_REVIEW.md); các thay đổi chưa commit có sẵn trong
workspace được giữ lại. Không tạo commit trong đợt này.

## Thay đổi

| Phát hiện | Sửa trong implementation |
|---|---|
| F1: conditional store false nhả load-lock | Chỉ store có điều kiện đúng mới nhả lock. Cặp test hai kênh so sánh DMASTB false với DMANOP vẫn giữ lại |
| F2: discontinuity không barrier/discard | C_RECONFIG báo At barrier; source discontinuity drain read, destination discontinuity drain read/write rồi bỏ residual MFIFO. Commit MOV sau barrier. Đổi burst length hoặc INCR destination size giữ residual |
| F3: manager đang boot không nhận debug | Debug preempt tại FETCH, kể cả refill bị kẹt. DMAGO/DMASEV tiếp tục cùng program PC; kill dừng thread và bỏ late delivery |
| F4: quyền debug NS | DNS gate toàn giao diện debug NS. DBGINST0/1 chung, write-only; busy writes bị bỏ qua, pending instruction được chốt |
| F5: CCR security fault muộn | Kiểm tra cả hai PROT[1] của immediate ngay tại DMAMOV CCR. Precise CPC trỏ MOV, CCR cũ không bị ghi và các lệnh sau không tạo side effect |
| F6: CR1 encoding reserved | Chỉ chấp nhận line 4/8/16/32 byte, đủ một beat bus. Thêm assembly instruction qua ba line 4 byte, gồm retry/kill/invalidate/error |

Các sửa bổ sung để đồng nhất programmer's model:

- Quyền APB theo TRM Tables 3-1..3-5: control/fault/debug/config/WD theo DNS;
  channel status/AXI/loop theo CNS. FTRn theo manager; bỏ lọc thêm CR3/CNS ở
  control summary khi DNS=1. ID registers vẫn đọc được ở cả hai cổng.
- Lock-up theo 2.8.3: các queue/in-flight đã drain và mọi channel đang chạy
  đều bị chặn ở LD. Một thread chờ event/peripheral trì hoãn phát hiện.
- Endian swap 128 bit trên bus 32/64 bit bằng buffer nhóm 128 bit. Descriptor
  giữ nguyên, AW chỉ issue khi đủ dữ liệu của burst, WDATA giữ ổn định khi stall.
- AW tách khỏi sequencer W, có queue context và issued-byte reservation. Kill
  giữ dữ liệu cho mọi context đã commit, kể cả đang xếp sau channel khác.
  Watchdog theo dõi W bằng channel của W thực tế thay vì AWID đang chạy trước.
- I-cache phục vụ hit của thread khác trong lúc chờ AR/R của refill. Refill
  RLAST ưu tiên response port chung; không trộn thread/security tags.

C model, RAL, security tests và generator được cập nhật cùng semantics TRM.
Generator cũ của test FIXED nạp dữ liệu rồi mới đổi destination size, dẫn đến
discard đúng theo TRM và `st_data_unavailable`. Generator mới cấu hình cả hai
phía trước LD và chọn beat FIXED vừa alignment/độ dài, không đổi natural width
khi đang giữ residual. Các ca kiểm tra riêng vẫn kiểm tra việc discard khi đổi
field, nên không bỏ mất coverage của hành vi này.

## Validation

| Kiểm tra | Kết quả |
|---|---|
| C model known-answer tests | **190 checks, 0 failed** |
| UVM hiện có, 25 test × sync/async × seeds 1–3 | **150/150 PASS**, không UVM warning/error/fatal và không lỗi simulator/SVA |
| Unit matrix | **15/15 PASS**: cache/fetch/write/thread status; bus 32/64/128, cache line 4/8/16/32 B ở các module tương ứng |
| Mutation checks unit | **10/10 lỗi cấy thử bị phát hiện** bằng diagnostic mong đợi |
| TRM probes, full core 64-bit, line 32 B | **28/28 PASS** |
| TRM probes, full core 32-bit, line 4 B | **28/28 PASS** |
| TRM probes, full core 128-bit, line 32 B | **28/28 PASS** |
| Cache line 64 B không có encoding hợp lệ trong CR1 | **2/2 rejected đúng**, sync/async; fatal này là kết quả mong đợi |
| Write latency benchmark | **64 W beats / 64 cycles**, 100% trong cửa sổ W; trước sửa 64/91 cycles, 70,33% |
| Python compile và git diff --check | PASS |

Các probe kiểm tra trực tiếp memory và APB status/fault/PC, không dùng C model
hoặc generator hiện tại làm oracle cho các yêu cầu TRM đang sửa. SVA vẫn được
bind. Suite bao gồm từng field discontinuity, giữ residual khi không phải
discontinuity, read/write outstanding tại barrier, false-store/NOP equivalence,
debug GO/SEV tiếp tục boot PC, kill khi fetch bị kẹt, late refill sau kill,
swap 128 bit qua biên 4 KB và điều kiện lock-up khi có thread chờ event.

Probe có stall data sử dụng AXI reorder/interleave giữa các RID, để fetch của
instruction barrier trên RID riêng không bị chính VIP chặn sau data RID đang
stall. Điều này đặc biệt cần cho line cache 4 byte. Lần đầu test này bị kẹt ở
Cache miss do cấu hình slave nối thứ tự toàn bộ RID; đã sửa kích thích để kiểm
tra đúng barrier, không thay RTL để né điều kiện test.

Benchmark xếp sẵn bốn burst 16 beat, dữ liệu sẵn, AWREADY=1; mỗi AW có deadline
nhận W sau 8 clock, lưu riêng trong FIFO của slave để hỗ trợ nhiều AW. Số
100% chỉ áp dụng cửa sổ đo này, không phải cam kết mọi workload đạt full bus
bandwidth. Unit test hit-under-miss kiểm tra hit khi cả AR và R của refill bị
stall, đồng thời kiểm tra tranh response port tại RLAST.

Reproduce từ root:

```powershell
python sim/run_regression.py --seeds 3 -j 3 --vopt-j 4
python sim/run_unit_tests.py --mutations
python sim/run_spec_review.py
python sim/run_spec_review.py --data-width 32 --cache-beats 1
python sim/run_spec_review.py --data-width 128
python sim/run_spec_review.py --data-width 64 --cache-beats 8 --expect-config-error
```

Tổng số simulator chạy đồng thời trong validation không quá 4. Các lệnh trên
có thể chạy tuần tự. `run_spec_review.py` trả exit code khác 0 nếu probe fail,
thiếu marker hoàn tất hoặc có lỗi simulator/SVA. Chế độ `--expect-config-error`
chỉ pass khi có đúng fatal về cache-line profile. `--no-build` kiểm tra source
hash trước khi dùng lại snapshot.

Log/JSON ở `sim/logs/spec_review/` và các thư mục `dw32_ic1`, `dw128_ic2`,
`dw64_ic8`; regression audit ở `sim/logs/spec_fix/regression_results.json`;
unit/mutation ở `sim/logs/unit/`. Kết quả 144/150 của lần chạy với generator
FIXED cũ không phải kết quả cuối; log lỗi ban đầu được giữ riêng dưới
`sim/logs/spec_fix/pre_generator_correction/`.

## Phạm vi cam kết

Các lỗi F1..F6 và các ca kiểm tra chức năng bổ sung đều đã được xử lý.
[DESIGN_SPEC Mục 9](DESIGN_SPEC.md#9-phạm-vi-tương-thích-và-giao-diện-tích-hợp)
được viết lại để phân biệt programmer's model với contract tích hợp.
Giao diện vẫn là AXI4, instruction-fetch ID all-ones, APB/CDC wrapper riêng,
peripheral request latch một entry và các extension đã công bố. MFIFO nội bộ
đóng gói byte-stream có thể khác mức dùng line của macro Arm trong Appendix B.
Không gọi đây là bản sao pin/cycle/resource-identical của macro Arm AXI3.

Không phát hiện lỗi chức năng còn lại trong các bộ test nêu trên. Review này
không thực hiện formal proof, synthesis/STA hoặc sign-off CDC/RDC; simulation
pass không phải chứng minh tuyệt đối thiết kế không còn mọi loại bug.
