# Thread status correction

Date: 2026-10-28. Reference: Arm DMA-330 r1p2 TRM DDI 0424D,
sections 2.3.3 (Cache miss), 2.3.4 (Updating PC), DSR and CSRn.

## Implemented behaviour

Both channel and manager now expose architectural status 3 during an
explicit PC-update phase. Sequential PC calculation and channel loop-branch
calculation commit at the end of this phase. Event/peripheral/barrier
wakeups also pass through it. Debug instructions do not advance the manager's
program PC; END and KILL retain the terminating PC.

The next fetch starts during PC calculation, using its target address, so
the new phase does not impose an extra idle cycle on the instruction pipeline.
Instruction side effects and transfer requests are issued only in EXEC.

| Internal phase | Software-visible DSR/CSR status |
|---|---|
| `C_UPDATING_PC` / `M_UPDATING_PC` | 3, Updating PC |
| FETCH with an AXI refill pending for this thread | 2, Cache miss |
| FETCH waiting for arbitration, local-buffer/shared-cache hit or assembly | 1, Executing |
| EXEC | 1, Executing |

The shared cache supplies a per-thread `refill_pending` vector. A bit is
active from the miss decision entering the AR phase through RLAST, including
AR/R stalls; an invalidated refill is drained without reporting it as an
active thread's miss. The front-end's `miss` output continues to describe
local-buffer work, and no longer controls DSR/CSR status.

Internal FSM enum encodings are separate from architectural status encodings.
For example, channel enum 10 is C_UPDATING_PC and reports CSR code 3; channel
enum 3 remains C_WFE and reports CSR code 4. Existing internal enum values
were preserved by appending the new phase.

## Verification

| Check | Result |
|---|---|
| Questa RTL/TB build and sync/async optimized snapshots | PASS |
| Full UVM regression, 25 tests x 2 configs x seeds 1-3 | 150/150 PASS, with coverage, 4 jobs, 303 s |
| C reference-model checks | 173/173 PASS |
| Directed RTL parameter matrix | 11/11 PASS, with coverage collected separately |
| Planted bugs in isolated source copies | 10/10 detected, including four status regressions |
| Assertions in full UVM | 179, zero failures; 174 exercised, 5 existing vacuous assertions |
| New Updating PC cover points | Covered on all four channels and the manager |
| Full-UVM statement / branch coverage, by file | 99.90% / 99.41% |
| Full-UVM FSM states / transitions, by file | 100% / 100% |
| Full-UVM functional bins / cover directives | 188/188 and 60/60 |

The new `dma_thread_status_tb` connects real channel/manager executors to
the shared cache and checks their CSR/DSR and PC outputs. It checks the exact
PC sequence through sequential instructions, a taken loop and loop exit,
wakeups, END, true refills with AR/R stalls, and a deliberately cold local
buffer hitting the warm shared cache. The latter must neither issue AR nor
report Cache miss. It also checks final SAR/LC0 and refill counts.

The four added mutations hide Updating PC or incorrectly report front-end
waiting as Cache miss, separately for channel and manager. Each is rejected
by the directed test's expected diagnostic.

Reproduce from `sim/`:

```sh
python run_regression.py --seeds 3 -j 4 --vopt-j 4 --cov
python run_unit_tests.py --cov --mutations
```

Logs and UCDBs: `sim/logs/{sync,async}`, `sim/cov/merged.ucdb`,
`sim/logs/unit`, and `sim/cov/unit/merged.ucdb`. New-state cover hits are in
`sim/logs/cov_status_directives.txt`; the machine-readable audit is
`sim/logs/thread_status_validation.json`. Unit UCDBs remain separate because
their parameter values differ from the full UVM configuration.

FEC condition coverage in full UVM is 89.36% (168/188); overall instance
coverage is lower than the by-file totals. These numbers are not a claim of
complete coverage. Synthesis/STA and regeneration of the existing waveform
figures were not part of this change. Other documented DMA-330 interface
and alignment differences remain outside this status correction.
