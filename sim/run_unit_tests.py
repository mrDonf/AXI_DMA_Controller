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
    parser.add_argument("--top", choices=["dma_icache_tb", "dma_fetch_unit_tb", "dma_wr_engine_tb", "dma_thread_status_tb"])
    parser.add_argument("--library", default="unit_work")
    parser.add_argument("--mutations", action="store_true", help="also confirm that the planted bugs fail")
    parser.add_argument("--cov", action="store_true",
                        help="code coverage of the RTL under test, merged into sim/cov/unit/merged.ucdb "
                             "(kept apart from the UVM UCDB: other parameter values make other code)")
    args = parser.parse_args(argv)
    lib = args.library
    logs = HERE / "logs" / "unit"
    if lib != "unit_work":
        logs = logs / lib
    logs.mkdir(parents=True, exist_ok=True)
    if not (HERE / lib).exists():
        run("vlib", lib, log=logs / "vlib.log")
    rtl = ["core/dma330_pkg.sv", "common/dma_sync_fifo.sv", "common/dma_rr_arbiter.sv",
           "core/dma_icache.sv", "core/dma_fetch_unit.sv", "core/dma_wr_engine.sv",
           "core/dma_channel.sv", "core/dma_manager.sv"]
    tops = ["dma_icache_tb", "dma_fetch_unit_tb", "dma_wr_engine_tb", "dma_thread_status_tb"]
    # Same coverage options as the UVM build (run_regression.py), RTL only
    rtl_cov = ["+cover=bcesf", "-coverexcludedefault", "-nofsmresettrans"] if args.cov else []
    run("vlog", "-sv", "-svinputport=var", "-quiet", "-work", lib, *rtl_cov,
        *[args.rtl_root / f for f in rtl], log=logs / "build.log")
    run("vlog", "-sv", "-svinputport=var", "-quiet", "-work", lib,
        *[ROOT / "tb" / "unit" / f"{top}.sv" for top in tops], log=logs / "build_tb.log")
    cov_dir = HERE / "cov" / "unit"
    if args.cov:
        cov_dir.mkdir(parents=True, exist_ok=True)
    cases = [("dma_icache_tb", {"DATA_W": w, "BEATS": b})
             for w, b in [(32, 1), (32, 2), (64, 1), (64, 4), (128, 1), (128, 2)]]
    cases += [("dma_fetch_unit_tb", {"LINE_BYTES": b}) for b in (4, 8, 16, 32)]
    cases += [("dma_wr_engine_tb", {"DATA_W": w}) for w in (32, 64, 128)]
    cases += [("dma_thread_status_tb", {"MANAGER": m}) for m in (0, 1)]
    if args.top:
        cases = [case for case in cases if case[0] == args.top]
    for top, params in cases:
        name = top + "_" + "_".join(f"{k}{v}" for k, v in params.items())
        run("vopt", f"{lib}.{top}", "-work", lib, "-o", name,
            *[f"-G{k}={v}" for k, v in params.items()], log=logs / f"{name}_opt.log")
        do = "run -all; quit -f"
        if args.cov:
            ucdb = (cov_dir / f"{name}.ucdb").as_posix()
            do = f"coverage save -onexit -testname unit_{name} {ucdb}; " + do
        out = run("vsim", "-c", *(["-coverage"] if args.cov else []), f"{lib}.{name}", "-do", do,
                  log=logs / f"{name}.log")
        if "UNIT TEST PASSED:" not in out:
            sys.exit(f"FAIL (no result): {name}")
        print(f"PASS {name}", flush=True)
    print(f"All {len(cases)} directed RTL cases passed.")
    if args.cov:
        ucdbs = sorted(str(p) for p in cov_dir.glob("*.ucdb") if p.name != "merged.ucdb")
        run("vcover", "merge", cov_dir / "merged.ucdb", *ucdbs, log=logs / "cov_merge.log")
        run("vcover", "report", "-totals", cov_dir / "merged.ucdb", log=HERE / "logs" / "cov_unit_summary.txt")
        run("vcover", "report", "-details", "-code", "bcesf", "-zeros", cov_dir / "merged.ucdb",
            log=HERE / "logs" / "cov_unit_zeros.txt")
        print("[cov] unit-test coverage: logs/cov_unit_summary.txt, logs/cov_unit_zeros.txt", flush=True)
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
        ("next_line_retry", "core/dma_fetch_unit.sv", "dma_fetch_unit_tb", "cancelled fetch delivered", [
            # second-line (F_NEXT) response: the one followed by "insn <="
            ("if (fetch_req && !aborted && !inv && !ic_resp_retry) begin\n              if (ic_resp_err) begin\n"
             "                fetch_err <= 1'b1;\n              end else if (int'(pc_off)",
             "if (fetch_req && !aborted && !inv) begin\n              if (ic_resp_err) begin\n"
             "                fetch_err <= 1'b1;\n              end else if (int'(pc_off)")]),
        ("write_bubble", "core/dma_wr_engine.sv", "dma_wr_engine_tb", "avoidable W bubble", [
            ("assign start     = (!act_valid || finish) && !ctx_empty;", "assign start     = !act_valid && !ctx_empty;")]),
        ("write_overclaim", "core/dma_wr_engine.sv", "dma_wr_engine_tb", "MFIFO underflow", [
            ("(int'(mf_count[ch]) - int'(issued_bytes[ch]))", "int'(mf_count[ch])")]),
        ("channel_update_hidden", "core/dma_channel.sv", "dma_thread_status_tb", "Updating PC count", [
            ("C_UPDATING_PC:      status = ST_UPDATING_PC;", "C_UPDATING_PC:      status = ST_EXECUTING;")]),
        ("manager_update_hidden", "core/dma_manager.sv", "dma_thread_status_tb", "Updating PC count", [
            ("M_UPDATING_PC: status = ST_UPDATING_PC;", "M_UPDATING_PC: status = ST_EXECUTING;")]),
        ("channel_false_miss", "core/dma_channel.sv", "dma_thread_status_tb", "false Cache miss", [
            ("C_FETCH:            status = ic_refill ?", "C_FETCH:            status = ic_req ?")]),
        ("manager_false_miss", "core/dma_manager.sv", "dma_thread_status_tb", "false Cache miss", [
            ("M_FETCH:    status = ic_refill ?", "M_FETCH:    status = ic_req ?")]),
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
