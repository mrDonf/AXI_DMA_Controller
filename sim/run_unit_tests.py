#!/usr/bin/env python3
"""Directed RTL tests for cache cancellation, fetch coherency and W throughput.

Run independently with `python run_unit_tests.py`. Uses a separate Questa
library so it does not disturb the UVM regression snapshots.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
BIN = Path(os.environ.get("QUESTA_HOME", "C:/questasim64_10.7c")) / "win64"


def run(tool, *args, log):
    result = subprocess.run([str(BIN / tool), *map(str, args)], cwd=HERE,
                            capture_output=True, text=True)
    out = result.stdout + result.stderr
    log.write_text(out, encoding="utf-8")
    if result.returncode or re.search(r"\*\* (?:Error|Fatal)", out):
        sys.exit(f"FAIL: {log}\n{out[-4000:]}")
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl-root", type=Path, default=ROOT / "rtl")
    parser.add_argument("--top", choices=["dma_icache_tb", "dma_fetch_unit_tb", "dma_wr_engine_tb"])
    parser.add_argument("--library", default="unit_work")
    parser.add_argument("--mutations", action="store_true", help="also confirm that five planted bugs fail")
    args = parser.parse_args(argv)
    lib = args.library
    logs = HERE / "logs" / "unit"
    if lib != "unit_work":
        logs = logs / lib
    logs.mkdir(parents=True, exist_ok=True)
    if not (HERE / lib).exists():
        run("vlib", lib, log=logs / "vlib.log")
    rtl = ["core/dma330_pkg.sv", "common/dma_sync_fifo.sv", "common/dma_rr_arbiter.sv",
           "core/dma_icache.sv", "core/dma_fetch_unit.sv", "core/dma_wr_engine.sv"]
    tops = ["dma_icache_tb", "dma_fetch_unit_tb", "dma_wr_engine_tb"]
    run("vlog", "-sv", "-svinputport=var", "-quiet", "-work", lib,
        *[args.rtl_root / f for f in rtl],
        *[ROOT / "tb" / "unit" / f"{top}.sv" for top in tops], log=logs / "build.log")
    cases = [("dma_icache_tb", {"DATA_W": w, "BEATS": b})
             for w, b in [(32, 2), (64, 1), (64, 4), (128, 4)]]
    cases += [("dma_fetch_unit_tb", {"LINE_BYTES": b}) for b in (8, 32)]
    cases += [("dma_wr_engine_tb", {"DATA_W": w}) for w in (32, 64, 128)]
    if args.top:
        cases = [case for case in cases if case[0] == args.top]
    for top, params in cases:
        name = top + "_" + "_".join(f"{k}{v}" for k, v in params.items())
        run("vopt", f"{lib}.{top}", "-work", lib, "-o", name,
            *[f"-G{k}={v}" for k, v in params.items()], log=logs / f"{name}_opt.log")
        out = run("vsim", "-c", f"{lib}.{name}", "-do", "run -all; quit -f",
                  log=logs / f"{name}.log")
        if "UNIT TEST PASSED:" not in out:
            sys.exit(f"FAIL (no result): {name}")
        print(f"PASS {name}", flush=True)
    print(f"All {len(cases)} directed RTL cases passed.")
    if args.mutations:
        check_mutations(rtl, logs)


def check_mutations(rtl, logs):
    # Copies under ignored logs; the working RTL and UVM library are untouched.
    mutants = [
        ("shared_thread", "core/dma_icache.sv", "dma_icache_tb", "missing/incorrect refill AR", [
            ("line_tid[w] == cur_tid && line_ns[w] == cur_ns", "line_ns[w] == cur_ns")]),
        ("late_refill", "core/dma_icache.sv", "dma_icache_tb", "response t0", [
            ("assign cancelled = cur_invalid || inv[cur_tid];", "assign cancelled = inv[cur_tid];")]),
        ("fetch_on_invalidate", "core/dma_fetch_unit.sv", "dma_fetch_unit_tb", "cancelled fetch delivered", [
            ("&& !fetch_err && !inv)", "&& !fetch_err)"),
            ("        insn_valid <= 1'b0;\n        fetch_err  <= 1'b0;", "")]),
        ("write_bubble", "core/dma_wr_engine.sv", "dma_wr_engine_tb", "avoidable W bubble", [
            ("assign start     = (!act_valid || finish) && sel_valid;", "assign start     = !act_valid && sel_valid;")]),
        ("write_overclaim", "core/dma_wr_engine.sv", "dma_wr_engine_tb", "MFIFO underflow", [
            ("(int'(mf_count[ch]) - (mf_pop[ch] ? int'(mf_pop_n) : 0))", "int'(mf_count[ch])")]),
    ]
    for name, target, top, diagnostic, patches in mutants:
        dest = logs / "mutations" / name
        for source in rtl:
            path = dest / source
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / "rtl" / source, path)
        path = dest / target
        text = path.read_text(encoding="utf-8")
        for old, new in patches:
            if text.count(old) != 1:
                sys.exit(f"Invalid mutation patch: {name}")
            text = text.replace(old, new)
        path.write_text(text, encoding="utf-8")
        proc = subprocess.run([sys.executable, __file__, "--rtl-root", str(dest),
                               "--top", top, "--library", "unit_mutant"],
                              cwd=HERE, capture_output=True, text=True)
        out = proc.stdout + proc.stderr
        (dest / "result.log").write_text(out, encoding="utf-8")
        if proc.returncode == 0 or diagnostic not in out:
            sys.exit(f"Mutation {name} was not detected by the expected check:\n{out[-3000:]}")
        print(f"DETECTED {name}: {diagnostic}", flush=True)
    print(f"All {len(mutants)} planted bugs detected.")


if __name__ == "__main__":
    main()
