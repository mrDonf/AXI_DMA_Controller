#!/usr/bin/env python3
"""
run_regression.py - QuestaSim build + parallel regression for the AXI DMA.

Speed-ups used:
  * vlog compiles everything once into one library
  * vopt builds the two snapshots (sync / async CDC configuration) one
    after the other, each using parallel code generation (vopt -j N)
  * every (test, config, seed) simulation runs as its own vsim process,
    N at a time (multi-core regression), all reading the same snapshots

Examples:
  python run_regression.py                        # all tests, both configs, 1 seed
  python run_regression.py -t dma_fault_test -c async --seeds 3
  python run_regression.py --cov -j 12            # with code + functional coverage
  python run_regression.py --no-build -t dma_reg_test
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODEL = HERE.parent / "model"                       # C reference model (DPI-C)
MODEL_LIB = HERE / ("dma330_ref.dll" if os.name == "nt" else "dma330_ref.so")
QUESTA = Path(os.environ.get("QUESTA_HOME", "C:/questasim64_10.7c"))
BIN = QUESTA / "win64"
UVM_LIB = QUESTA / "uvm-1.2"
UVM_SRC = QUESTA / "verilog_src" / "uvm-1.2" / "src"
UVM_DPI = UVM_LIB / "win64" / "uvm_dpi"

TESTS = [
    "dma_reg_test",
    "dma_m2m_aligned_test",
    "dma_m2m_unaligned_test",
    "dma_multi_ch_test",
    "dma_fixed_addr_test",
    "dma_fill_test",
    "dma_loop2d_test",
    "dma_periph_test",
    "dma_event_test",
    "dma_boot_test",
    "dma_fault_test",
    "dma_kill_test",
    "dma_stress_test",
    "dma_isa_test",
    "dma_periph_corner_test",
    "dma_boot_err_test",
    "dma_reset_test",
    "dma_endian_test",
    "dma_watchdog_test",
    "dma_lowpower_test",
    "dma_rand_prog_test",
    "dma_cmodel_mix_test",
    "dma_mfifo_share_test",
    "dma_security_test",
]
CMODEL_TESTS = {"dma_rand_prog_test", "dma_cmodel_mix_test"}    # need the C model as only predictor
CONFIGS = {"sync": 0, "async": 1}
SUPPRESS = ["-suppress", "12036"]       # bind targets absent in the sync config


def run(cmd, log=None, cwd=HERE):
    """Run a command, optionally teeing output into a log file."""
    res = subprocess.run([str(c) for c in cmd], cwd=cwd, capture_output=True, text=True)
    out = res.stdout + res.stderr
    if log:
        Path(log).write_text(out)
    return res.returncode, out


def find_cc():
    """C compiler for the reference model: $CC, gcc on PATH, or MSYS2 ucrt64."""
    for cand in (os.environ.get("CC"), shutil.which("gcc"), "C:/msys64/ucrt64/bin/gcc.exe"):
        if cand and (shutil.which(cand) or Path(cand).exists()):
            return cand
    return None


def build_model():
    """Unit-test the C model, then build the DPI shared library. True when usable."""
    cc = find_cc()
    if not cc:
        print("[model] no C compiler found (set CC): building without the C reference model")
        return False
    exe = HERE / "logs" / ("dma330_ref_test" + (".exe" if os.name == "nt" else ""))
    srcs = [MODEL / "dma330_ref.c"]
    cflags = ["-O2", "-Wall", "-Wextra"]

    print(f"[model] unit test ({Path(cc).name}) ...", flush=True)
    rc, out = run([cc, *cflags, "-o", exe, MODEL / "dma330_ref_test.c", *srcs],
                  log=HERE / "logs" / "model_build.log")
    if rc:
        sys.exit(f"C model unit test does not compile, see logs/model_build.log\n{out[-2000:]}")
    rc, out = run([exe], log=HERE / "logs" / "model_test.log")
    if rc or "MODEL TEST PASSED" not in out:
        sys.exit(f"C model unit test failed, see logs/model_test.log\n{out[-2000:]}")

    print("[model] DPI library ...", flush=True)
    flags = ["-shared", "-static-libgcc"] if os.name == "nt" else ["-shared", "-fPIC"]
    rc, out = run([cc, *cflags, *flags, "-o", MODEL_LIB, *srcs, MODEL / "dma330_dpi.c"],
                  log=HERE / "logs" / "model_dpi_build.log")
    if rc:
        sys.exit(f"DPI library build failed, see logs/model_dpi_build.log\n{out[-2000:]}")
    return True


def build(args):
    work = HERE / "work"
    if not work.exists():
        run([BIN / "vlib", "work"])
    common = ["-sv", "-svinputport=var", "-timescale", "1ns/1ps", "-L", UVM_LIB,
              f"+incdir+{UVM_SRC}", "-quiet"]
    if not args.cmodel:
        common.append("+define+DMA_NO_CMODEL")
    # Code coverage only on the RTL. Unreachable case defaults and implicit
    # asynchronous-reset FSM transitions are excluded (reset behaviour is
    # verified by dma_reset_test instead).
    rtl_cov = ["+cover=bcesf", "-coverexcludedefault", "-nofsmresettrans"] if args.cov else []

    print("[build] vlog RTL ...", flush=True)
    rc, out = run([BIN / "vlog", *common, *rtl_cov, "-f", "rtl.f"], log=HERE / "logs" / "vlog_rtl.log")
    if rc or "Error" in out:
        sys.exit(f"vlog RTL failed, see logs/vlog_rtl.log\n{out[-2000:]}")
    print("[build] vlog TB ...", flush=True)
    rc, out = run([BIN / "vlog", *common, "-f", "tb.f"], log=HERE / "logs" / "vlog_tb.log")
    if rc or re.search(r"\*\* Error", out):
        sys.exit(f"vlog TB failed, see logs/vlog_tb.log\n{out[-2000:]}")

    # One snapshot per CDC configuration. Snapshots share the 'work' library,
    # so they are built one after the other (concurrent vopt runs corrupt the
    # library index); each vopt uses parallel code generation (-j).
    acc = ["+acc=npr"] if not args.fast else []
    for cfg in args.configs:
        print(f"[build] vopt tb_{cfg} (-j {args.vopt_j}) ...", flush=True)
        rc, out = run([BIN / "vopt", "tb_top", "-L", UVM_LIB, "-o", f"tb_{cfg}",
                       f"-GASYNC={CONFIGS[cfg]}", "-j", args.vopt_j, *acc, *SUPPRESS],
                      HERE / "logs" / f"vopt_{cfg}.log")
        if rc or re.search(r"\*\* Error", out):
            sys.exit(f"vopt {cfg} failed:\n{out[-2000:]}")


def simulate(test, cfg, seed, args):
    name = f"{test}_{cfg}_s{seed}"
    log = HERE / "logs" / cfg / f"{name}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    do = ""
    if args.cov:
        # UVM ends with $finish, so the database is written on exit
        ucdb = (HERE / "cov" / f"{name}.ucdb").as_posix()
        do += f"coverage save -onexit -testname {name} {ucdb}; "
    do += "run -all; quit -f"
    lib = ["-sv_lib", MODEL_LIB.with_suffix("")] if args.cmodel else []
    cmd = [BIN / "vsim", "-c", f"tb_{cfg}", "-L", UVM_LIB, "-sv_lib", UVM_DPI, *lib, *SUPPRESS,
           f"+UVM_TESTNAME={test}", "-sv_seed", seed, "-l", log, "+UVM_VERBOSITY=" + args.verbosity,
           *(["-coverage"] if args.cov else []), *args.plusargs, "-do", do]
    t0 = time.time()
    run(cmd)
    return name, check_log(log), time.time() - t0, log


def check_log(log):
    """PASS only if UVM passed AND no simulator/SVA error was printed."""
    try:
        txt = Path(log).read_text(errors="ignore")
    except FileNotFoundError:
        return "NO LOG"
    if "*** TEST PASSED ***" not in txt:
        m = re.search(r"\*\*\* TEST FAILED \*\*\* \((\d+) errors\)", txt)
        return f"FAIL ({m.group(1)} UVM errors)" if m else "FAIL (no result)"
    sva = len(re.findall(r"^# \*\* Error: .*Assertion|^# \*\* Error \(suppressible\)|^# \*\* Error:", txt, re.M))
    if sva:
        return f"FAIL ({sva} simulator/SVA errors)"
    return "PASS"


def print_cov_totals(report):
    """Echo the per-metric totals of 'vcover report -totals'."""
    try:
        for line in Path(report).read_text(errors="ignore").splitlines():
            if re.search(r"(Branches|Conditions|Expressions|FSM|Statements|Toggles|Covergroups|"
                         r"Assertions|Directives|Total Coverage)", line):
                print("      " + line.strip())
    except FileNotFoundError:
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-t", "--tests", nargs="+", default=TESTS)
    ap.add_argument("-c", "--configs", nargs="+", default=list(CONFIGS), choices=list(CONFIGS))
    ap.add_argument("--seeds", type=int, default=1, help="seeds per test/config")
    ap.add_argument("--seed-base", type=int, default=1)
    ap.add_argument("-j", "--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2),
                    help="parallel simulations")
    ap.add_argument("--vopt-j", type=int, default=8, help="vopt parallel code generation")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--no-cmodel", action="store_true",
                    help="build without the DPI-C reference model (its tests are skipped)")
    ap.add_argument("--cov", action="store_true", help="code + functional coverage, merged UCDB")
    ap.add_argument("--fast", action="store_true", help="no +acc (fastest, no waveform visibility)")
    ap.add_argument("--verbosity", default="UVM_LOW")
    ap.add_argument("--plusargs", nargs="*", default=[])
    args = ap.parse_args()

    (HERE / "logs").mkdir(exist_ok=True)
    if args.cov:
        (HERE / "cov").mkdir(exist_ok=True)
    t0 = time.time()
    if args.no_build:
        args.cmodel = not args.no_cmodel and MODEL_LIB.exists()
    else:
        args.cmodel = not args.no_cmodel and build_model()
        build(args)
    if not args.cmodel:
        skipped = [t for t in args.tests if t in CMODEL_TESTS]
        if skipped:
            print(f"[sim] without the C model, skipping: {' '.join(skipped)}")
        args.tests = [t for t in args.tests if t not in CMODEL_TESTS]

    runs =[(t, c, s) for c in args.configs for t in args.tests
            for s in range(args.seed_base, args.seed_base + args.seeds)]
    print(f"[sim] {len(runs)} simulations, {args.jobs} in parallel", flush=True)
    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futs = [pool.submit(simulate, t, c, s, args) for t, c, s in runs]
        for f in as_completed(futs):
            name, status, dt, log = f.result()
            results.append((name, status, dt))
            print(f"  {status:<32} {name:<44} {dt:6.1f}s", flush=True)

    if args.cov:
        ucdbs = sorted(str(p) for p in (HERE / "cov").glob("*.ucdb") if p.name != "merged.ucdb")
        merged = HERE / "cov" / "merged.ucdb"
        run([BIN / "vcover", "merge", merged, *ucdbs], HERE / "logs" / "vcover_merge.log")
        run([BIN / "vcover", "report", "-totals", merged], HERE / "logs" / "cov_summary.txt")
        run([BIN / "vcover", "report", "-bydu", "-code", "bcesf", merged], HERE / "logs" / "cov_code_bydu.txt")
        run([BIN / "vcover", "report", "-details", "-cvg", merged], HERE / "logs" / "cov_functional.txt")
        run([BIN / "vcover", "report", "-html", "-htmldir", HERE / "cov" / "html", "-code", "bcesf",
             "-cvg", "-assert", "-directive", merged], HERE / "logs" / "vcover_html.log")
        print(f"[cov] merged coverage: {merged}")
        print(f"      totals logs/cov_summary.txt, html cov/html/index.html")
        print_cov_totals(HERE / "logs" / "cov_summary.txt")

    failed = [r for r in results if r[1] != "PASS"]
    print("\n" + "=" * 80)
    print(f" REGRESSION: {len(results) - len(failed)}/{len(results)} passed   "
          f"wall time {time.time() - t0:.0f}s")
    for name, status, _ in sorted(failed):
        print(f"   {status:<32} {name}")
    print("=" * 80)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
