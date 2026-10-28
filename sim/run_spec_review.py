"""Run independent TRM conformance probes against the current RTL.

First build the C model using run_regression.py. A nonzero exit means a tool
failure, incomplete probe, SVA error, or TRM conformance violation.
The regular scoreboard is disabled: each probe checks its TRM-specific result.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import run_regression as reg

HERE = Path(__file__).resolve().parent
OUT = HERE / "logs" / "spec_review"
LIB = "spec_review_work"
LIB_DIR = OUT / "library"
CASES = ("alignment", "ccr_security", "ns_debug", "manager_debug", "false_store_lock",
         "false_store_lock_control", "wide_swap", "reconfig_fields", "source_barrier",
         "destination_barrier", "manager_resume", "manager_stalled", "cache_crossline", "lockup_wait")


def command(args, name, allow_fatal=False):
    p = subprocess.run([str(a) for a in args], cwd=HERE, capture_output=True,
                       text=True, errors="replace", timeout=180)
    out = p.stdout + p.stderr
    (OUT / name).write_text(out, encoding="utf-8")
    if (p.returncode or "** Error" in out or "** Fatal" in out) and not allow_fatal:
        sys.exit(f"Tool failure: {name}\n{out[-4000:]}")
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--data-width",type=int,choices=(32,64,128),default=64)
    parser.add_argument("--cache-beats",type=int)
    parser.add_argument("--build-only",action="store_true")
    parser.add_argument("--no-build",action="store_true")
    parser.add_argument("--expect-config-error",action="store_true")
    parser.add_argument("--configs", nargs="+", choices=("sync", "async"), default=["sync", "async"])
    args = parser.parse_args()
    global OUT, LIB, LIB_DIR
    if args.data_width!=64 or args.cache_beats is not None:
        tag=f"dw{args.data_width}_ic{args.cache_beats or 32//(args.data_width//8)}"
        OUT=OUT/tag
        LIB=f"spec_review_{tag}"
        LIB_DIR=OUT/"library"
    OUT.mkdir(parents=True, exist_ok=True)
    if not LIB_DIR.exists() and not args.no_build:
        command([reg.BIN / "vlib", LIB_DIR], "vlib.log")
    hashes={
        p.relative_to(HERE.parent).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
        for base in ("rtl","tb","sva") for p in sorted((HERE.parent / base).rglob("*.sv"))
    }
    hash_file=OUT/"rtl_hashes.json"
    same_sources=hash_file.exists() and json.loads(hash_file.read_text(encoding="utf-8"))==hashes
    if args.no_build:
        if not same_sources:
            sys.exit("Source changed since probe build; rebuild required")
    else:
        command([reg.BIN / "vmap", LIB, LIB_DIR], "vmap.log")
        hash_file.write_text(json.dumps(hashes,indent=2),encoding="utf-8")
    common = [reg.BIN / "vlog", "-sv", "-svinputport=var", "-timescale", "1ns/1ps",
              "-work", LIB, "-L", reg.UVM_LIB, f"+incdir+{reg.UVM_SRC}",
              f"+define+AXI_DATA_W={args.data_width}"]
    if args.cache_beats is not None:
        common.append(f"+define+DMA_TEST_IC_BEATS={args.cache_beats}")
    if not args.no_build:
        command([*common, "-f", "rtl.f"], "compile_rtl.log")
        command([*common, "-f", "tb.f", HERE.parent / "tb/review/dma_spec_review_pkg.sv",
                 HERE.parent / "tb/review/dma_write_perf_tb.sv"], "compile.log")
    results = []
    for cfg in args.configs:
        snapshot = f"probe_{cfg}"
        if not args.no_build:
            command([reg.BIN / "vopt", f"{LIB}.dma_spec_review_top", "-work", LIB,
                     "-L", reg.UVM_LIB, "-o", snapshot,
                     f"-GASYNC={int(cfg == 'async')}", *reg.SUPPRESS], f"opt_{cfg}.log")
        if args.build_only: continue
        if args.expect_config_error:
            out=command([reg.BIN/"vsim","-c",f"{LIB}.{snapshot}","-L",reg.UVM_LIB,
                         "-sv_lib",reg.UVM_DPI,"-sv_lib",reg.MODEL_LIB.with_suffix(""),
                         *reg.SUPPRESS,"+UVM_TESTNAME=dma_spec_review_test",
                         "+SPEC_CASE=cache_crossline","-do","run -all; quit -f"],
                        f"config_guard_{cfg}.log",allow_fatal=True)
            rejected="** Fatal:" in out and "cache line must be 4/8/16/32 bytes" in out
            results.append({"case":"invalid_cache_config","config":cfg,"conformant":rejected})
            print(f"{'PASS' if rejected else 'FAIL'} invalid_cache_config/{cfg}",flush=True)
            continue
        for case in ([args.case] if args.case else CASES):
            out = command([reg.BIN / "vsim", "-c", f"{LIB}.{snapshot}",
                           "-L", reg.UVM_LIB, "-sv_lib", reg.UVM_DPI,
                           "-sv_lib", reg.MODEL_LIB.with_suffix(""), *reg.SUPPRESS,
                           "+UVM_TESTNAME=dma_spec_review_test", f"+SPEC_CASE={case}",
                           "-sv_seed", "1", "-do", "run -all; quit -f"], f"{case}_{cfg}.log")
            if "[SPEC_PROBE_DONE]" not in out:
                sys.exit(f"Incomplete probe: {case}/{cfg}")
            passed = "*** TEST PASSED ***" in out
            results.append({"case": case, "config": cfg, "conformant": passed})
            print(f"{'PASS' if passed else 'NONCONFORMANT'} {case}/{cfg}", flush=True)
    if args.build_only: return
    if not args.case and args.data_width==64 and not args.expect_config_error:
        command([reg.BIN / "vopt", f"{LIB}.dma_write_perf_tb", "-work", LIB,
                 "-o", "write_perf"], "opt_write_perf.log")
        out = command([reg.BIN / "vsim", "-c", f"{LIB}.write_perf",
                       "-do", "run -all; quit -f"], "write_perf.log")
        if "PERF_PROBE_DONE" not in out:
            sys.exit("Incomplete performance probe")
        print(next(line for line in out.splitlines() if "PERF_OBSERVATION" in line), flush=True)
    result_file = OUT / "results.json"
    all_conformant = all(r["conformant"] for r in results)
    if args.case and result_file.exists() and same_sources:
        previous = json.loads(result_file.read_text(encoding="utf-8"))
        updated = {(r["case"], r["config"]) for r in results}
        results = [r for r in previous if (r["case"], r["config"]) not in updated] + results
    result_file.write_text(json.dumps(results, indent=2), encoding="utf-8")
    sys.exit(0 if all_conformant else 1)


if __name__ == "__main__":
    main()
