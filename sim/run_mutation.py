#!/usr/bin/env python3
"""
run_mutation.py - plant one RTL bug in a copy of the tree and see who notices.

For every mutant the script copies rtl/ sva/ tb/ model/ to a work directory
(the real tree is never touched), applies a text patch to one RTL file and runs
the regression in the sync configuration.

The v1.2 mutants (C model, M1..M4) run twice:
  old  : the 20 original tests with the C model switched off (+NO_CMODEL)
  new  : every test with the C model on (cross-check + register compare +
         random instruction streams)
A mutant that only the 'new' run catches is a gap the generator-based
environment had. The v1.3 mutants (shared MFIFO, security) only run 'new'.

The printed table lists the tests that failed in each run.

  python run_mutation.py                      # all mutants
  python run_mutation.py M2_lc1_readback      # one mutant
  python run_mutation.py --work D:/mut        # keep the copies elsewhere

Add a mutant to MUTANTS as (file, old text, new text, occurrences of old text).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

OLD_TESTS = [
    "dma_reg_test", "dma_m2m_aligned_test", "dma_m2m_unaligned_test", "dma_multi_ch_test",
    "dma_fixed_addr_test", "dma_fill_test", "dma_loop2d_test", "dma_periph_test",
    "dma_event_test", "dma_boot_test", "dma_fault_test", "dma_kill_test", "dma_stress_test",
    "dma_isa_test", "dma_periph_corner_test", "dma_boot_err_test", "dma_reset_test",
    "dma_endian_test", "dma_watchdog_test", "dma_lowpower_test",
]
NEW_TESTS = ["dma_rand_prog_test", "dma_cmodel_mix_test", "dma_mfifo_share_test", "dma_security_test"]
TWO_RUNS  = {"M1_addh_signext", "M2_lc1_readback", "M3_kill_moves_cpc", "M4_sar_carry31"}

# name: (rtl file, old text, new text, expected occurrences of old text)
MUTANTS = {
    # DMAADDH with bit 15 of the immediate set is sign-extended (only huge row steps see it)
    "M1_addh_signext": (
        "rtl/core/dma_channel.sv",
        "{(cls == I_ADNH) ? 16'hFFFF : 16'h0000, imm16}",
        "{(cls == I_ADNH || imm16[15]) ? 16'hFFFF : 16'h0000, imm16}", 2),
    # LC1 reads back as LC0 (no effect on the bus, only on the register file)
    "M2_lc1_readback": (
        "rtl/core/dma_channel.sv",
        "assign lc1_o    = {24'd0, lc1};",
        "assign lc1_o    = {24'd0, lc0};", 1),
    # DMAKILL inside a program moves CPC past the instruction
    "M3_kill_moves_cpc": (
        "rtl/core/dma_channel.sv",
        "              I_KILL: state <= C_KILLING;",
        "              I_KILL: begin pc <= pc_next; state <= C_KILLING; end", 1),
    # SAR adder with a 31-bit carry: wrong when the address wraps around 2**32
    "M4_sar_carry31": (
        "rtl/core/dma_channel.sv",
        "if (ccr.src_inc) sar <= sar + ADDR_W'(ld_xfer.bytes);",
        "if (ccr.src_inc) sar <= {sar[31], 31'(sar[30:0] + 31'(ld_xfer.bytes))};", 1),

    # ---- v1.3: shared MFIFO ----
    # A fully popped line never returns to the pool
    "M5_mfifo_no_free": (
        "rtl/core/dma_mfifo.sv",
        "      if (pop_frees) own[hd[pop_ch]] <= 1'b0;\n",
        "", 1),
    # The head does not move to the new line when the only line is freed and a
    # new one is taken in the same cycle
    "M6_mfifo_stale_head": (
        "rtl/core/dma_mfifo.sv",
        "if (al && (nlines[c] == '0 || (fr && nlines[c] == LCNT_W'(1))))",
        "if (al && nlines[c] == '0)", 1),
    # The reservation ignores the partly used line (under-reserves)
    "M7_need_no_offset": (
        "rtl/core/dma_datapath.sv",
        "(int'(res_off[ch]) + int'(ld_xfer[ch].bytes) + NB - 1)",
        "(int'(ld_xfer[ch].bytes) + NB - 1)", 1),
    # An idle channel keeps its last, partly used line
    "M8_no_release": (
        "rtl/core/dma_datapath.sv",
        "assign release_ch[ch] = (reserved[ch] == '0) && (held[ch] != '0);",
        "assign release_ch[ch] = 1'b0;", 1),
    # Deadlocks between channels are never reported
    "M9_no_deadlock": (
        "rtl/core/dma_datapath.sv",
        "assign deadlock = |(stuck & holder) && ((holder & ~stuck) == '0) && (release_ch == '0);",
        "assign deadlock = 1'b0;", 1),
    # ---- v1.3: security ----
    # The NS port sees the registers of secure channels
    "M10_ns_sees_secure_ch": (
        "rtl/core/dma_regs.sv",
        "assign ch_vis  = acc_n ? ch_ns  : '1;",
        "assign ch_vis  = '1;", 1),
    # An NS write to INTEN changes the secure bits too
    "M11_ns_inten_all": (
        "rtl/core/dma_regs.sv",
        "A_INTEN:    inten <= (inten & ~ev_vis) | (wdata[NUM_EVENTS-1:0] & ev_vis);",
        "A_INTEN:    inten <= wdata[NUM_EVENTS-1:0];", 1),
    # NS debug instructions reach secure channels
    "M12_ns_dbg_secure_ch": (
        "rtl/core/dma_regs.sv",
        "assign dbg_ch_ok  = (int'(dbg_ch) < NUM_CH) && (!acc_n || ch_ns[dbg_ch]);",
        "assign dbg_ch_ok  = (int'(dbg_ch) < NUM_CH);", 1),
    # A non-secure channel may use secure events
    "M13_ns_thread_secure_ev": (
        "rtl/core/dma_channel.sv",
        "assign ev_bad      = (int'(num5) >= NUM_EVENTS) || (ns && !irq_ns32[num5]);",
        "assign ev_bad      = (int'(num5) >= NUM_EVENTS);", 1),
    # One DBGINST0 for both ports
    "M14_shared_dbginst0": (
        "rtl/core/dma_regs.sv",
        "A_DBGINST0: if (acc_n) dbg_inst0_ns <= wdata & 32'hFFFF_0701;",
        "A_DBGINST0: if (acc_n) dbg_inst0    <= wdata & 32'hFFFF_0701;", 1),
    # The NS port does not wait when both ports access in the same cycle
    "M15_ns_no_wait": (
        "rtl/core/dma_regs.sv",
        "assign pready_ns  = !acc_s;",
        "assign pready_ns  = 1'b1;", 1),
    # The NS port sees a secure manager
    "M16_ns_sees_secure_mgr": (
        "rtl/core/dma_regs.sv",
        "assign mgr_vis = !acc_n || dsr[9];",
        "assign mgr_vis = 1'b1;", 1),
}


def sh(cmd, cwd, env):
    r = subprocess.run([str(c) for c in cmd], cwd=cwd, capture_output=True, text=True, env=env)
    return r.stdout + r.stderr


def failing(out):
    return sorted(set(re.findall(r"^\s+FAIL[^\n]*?(dma_\w+?)_(?:sync|async)_s\d+", out, re.M)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mutants", nargs="*", default=list(MUTANTS))
    ap.add_argument("--work", default=None, help="directory for the mutated copies")
    ap.add_argument("-j", "--jobs", type=int, default=4)
    ap.add_argument("--vopt-j", type=int, default=4)
    args = ap.parse_args()

    work = Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="dma_mut_"))
    work.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["PATH"] = "C:/msys64/ucrt64/bin" + os.pathsep + env["PATH"]     # gcc for the C model

    rows = []
    for name in args.mutants:
        rel, old, new, cnt = MUTANTS[name]
        d = work / name
        if d.exists():
            shutil.rmtree(d, ignore_errors=True)
        for sub in ("rtl", "sva", "tb", "model"):
            shutil.copytree(REPO / sub, d / sub)
        (d / "sim").mkdir()
        for f in ("rtl.f", "tb.f", "run_regression.py"):
            shutil.copy(REPO / "sim" / f, d / "sim" / f)
        p = d / rel
        txt = p.read_text(encoding="utf-8")
        if txt.count(old) != cnt:
            sys.exit(f"{name}: expected {cnt} occurrence(s) of the text to replace in {rel}, "
                     f"found {txt.count(old)} (RTL changed?)")
        p.write_text(txt.replace(old, new), encoding="utf-8")

        t0 = time.time()
        sim = d / "sim"
        common = [sys.executable, "run_regression.py", "-c", "sync", "-j", str(args.jobs)]
        if name in TWO_RUNS:
            out_old = sh([*common, "--vopt-j", str(args.vopt_j), "-t", *OLD_TESTS, "--plusargs", "+NO_CMODEL"],
                         sim, env)
            out_new = sh([*common, "--no-build", "-t", *OLD_TESTS, *NEW_TESTS], sim, env)
            old = failing(out_old)
        else:
            out_new = sh([*common, "--vopt-j", str(args.vopt_j), "-t", *OLD_TESTS, *NEW_TESTS], sim, env)
            old = None
        rows.append((name, old, failing(out_new), time.time() - t0))
        print(f"{name}: old {'-' if old is None else len(old)} failing, new {len(rows[-1][2])} failing",
              flush=True)

    print("\n" + "=" * 100)
    print(f"{'mutant':<24} {'old environment':<22} new environment")
    for name, o, n, _ in rows:
        old_txt = "(not run)" if o is None else ("MISSED" if not o else ", ".join(o))
        print(f"{name:<24} {old_txt:<22} {('MISSED' if not n else ', '.join(n))}")
    print("=" * 100)
    print(f"copies kept in {work}")


if __name__ == "__main__":
    main()
