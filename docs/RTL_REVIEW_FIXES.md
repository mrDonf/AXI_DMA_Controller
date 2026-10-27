# RTL fixes on `Codex_rtl`

Date: 2026-10-27. Reference: Arm DMA-330 r1p2 TRM, DDI 0424D,
sections 4.3.3 (DMAEND), 4.3.6 (DMAKILL), 4.3.19 (DMAWFE).

## Changes

* Instruction-cache entries now carry thread ID and NS tags. Maintenance
  invalidates only the issuing thread and its local line buffer. DMAEND and
  DMAKILL invalidate after the channel's data transactions drain; the manager
  also invalidates on its END/KILL paths, including debug kill from Faulting.
* Starting a stopped channel invalidates only that target. DMAGO to a running
  channel has no cache or PC side effects.
* Invalidation cancels an in-progress lookup/refill. A pending AR remains
  asserted until accepted, and outstanding R beats still drain. The stale
  result cannot be allocated or executed: the cache responds with retry,
  and the fetch unit restarts. An invalidated cross-line instruction fetch
  starts again at its first line. Late results after kill/restart cannot
  repopulate the local buffer or fault the restarted program.
* The write engine can replace a completed burst on the same edge. Admission
  uses the MFIFO count after this cycle's pop, including a whole endian-swap
  group when appropriate. Pending AW/W remain stable under backpressure.
  With queued single-beat bursts, ready AXI, data available and B-tracker
  space, W can now transfer on consecutive cycles.
* Added a UVM program-replacement test, three directed RTL testbenches,
  END/KILL maintenance assertions, and a unit/mutation runner. Normal
  regression builds run the unit matrix automatically (`--skip-unit` opts out).
* Corrected the WDSTAT RAL map rights to RW while retaining its W1C field
  policy. Serialized RAL access across virtual-sequence threads so concurrent
  INTCLR writes cannot race UVM's desired-value/prediction state.

## Validation

| Check | Result |
|---|---|
| Questa RTL/TB compile, sync and async optimized snapshots | PASS |
| C reference-model unit test | 173 checks, 0 failures |
| Full UVM regression | **150/150 PASS**, 25 tests x sync/async x seeds 1–3; 246 s, 12 jobs |
| Directed RTL matrix | **9/9 PASS**; AXI data widths 32/64/128, cache refill lengths 1/2/4, fetch line sizes 8/32 |
| Five planted bugs in isolated RTL copies | **5/5 detected** by the expected functional/performance check |
| Python compilation and `git diff --check` | PASS |

Reproduction from `sim/`:

```sh
python run_regression.py --seeds 3 -j 12
python run_unit_tests.py --mutations
```

The full run used the DPI-C reference model. UVM logs are under
`sim/logs/sync` and `sim/logs/async`; the machine-readable scan of all 150
results is `sim/logs/review_validation.json`. Directed logs are under
`sim/logs/unit`, and intentional mutation failures are retained separately.

An initial full pass exposed existing RAL warnings about WDSTAT map rights
and concurrent INTCLR access. Both testbench causes were corrected before
the final full regression. The final 150 runs have zero UVM warnings,
UVM_ERROR/UVM_FATAL and simulator/SVA errors.

The full UVM configuration uses DATA_W=64; the 32/128-bit checks here are
directed module tests. Code/functional coverage, synthesis and STA were not
rerun, so historical coverage percentages and the target clock frequency are
not claims about this branch. These fixes address the cache and write-engine
review findings; the remaining interface/configuration and alignment
differences from Arm DMA-330 are still listed in DESIGN_SPEC section 9.
