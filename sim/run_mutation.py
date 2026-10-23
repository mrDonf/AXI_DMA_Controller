#!/usr/bin/env python3
"""
run_mutation.py - plant one RTL bug in a copy of the tree and see who notices.

For every mutant the script copies rtl/ sva/ tb/ model/ to a work directory
(the real tree is never touched), applies a text patch to one RTL file and runs
the regression twice, in the sync configuration:

  old  : the 20 original tests with the C model switched off (+NO_CMODEL)
  new  : every test with the C model on (cross-check + register compare +
         random instruction streams)

The printed table lists the tests that failed in each run. A mutant that only
the 'new' run catches is a gap the generator-based environment had.

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
NEW_TESTS = ["dma_rand_prog_test", "dma_cmodel_mix_test"]

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
    ap.add_argument("-j", "--jobs", type=int, default=14)
    ap.add_argument("--vopt-j", type=int, default=12)
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
        out_old = sh([*common, "--vopt-j", str(args.vopt_j), "-t", *OLD_TESTS, "--plusargs", "+NO_CMODEL"],
                     sim, env)
        out_new = sh([*common, "--no-build", "-t", *OLD_TESTS, *NEW_TESTS], sim, env)
        rows.append((name, failing(out_old), failing(out_new), time.time() - t0))
        print(f"{name}: old {len(rows[-1][1])} failing, new {len(rows[-1][2])} failing", flush=True)

    print("\n" + "=" * 100)
    print(f"{'mutant':<22} {'old environment':<22} new environment")
    for name, o, n, _ in rows:
        print(f"{name:<22} {('MISSED' if not o else ', '.join(o)):<22} "
              f"{('MISSED' if not n else ', '.join(n))}")
    print("=" * 100)
    print(f"copies kept in {work}")


if __name__ == "__main__":
    main()
