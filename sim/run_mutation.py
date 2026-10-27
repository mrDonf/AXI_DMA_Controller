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
environment had. The v1.3 mutants (shared MFIFO, security) and the v1.4
mutants (DMA-330 conformance fixes, M17..M39: each restores one behaviour the
TRM review reported) only run 'new'. M37 and M39 need the async configuration
(the clock-domain crossings): run them with --configs async.

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
NEW_TESTS = ["dma_rand_prog_test", "dma_cmodel_mix_test", "dma_mfifo_share_test", "dma_security_test", "dma_cache_test"]
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
        "assign ev_sec_bad   = !ev_range_bad && ns && !irq_ns32[num5];",
        "assign ev_sec_bad   = 1'b0;", 1),
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

    # ---- v1.4: DMA-330 conformance fixes (each mutant restores one old behaviour) ----
    # DMALDS / DMASTS / DMALDPS / DMASTPS move a whole CCR burst
    "M17_single_full_burst": (
        "rtl/core/dma_channel.sv",
        "assign xfer_single = (op[1:0] == 2'b01);",
        "assign xfer_single = 1'b0;", 1),
    # The peripheral controller treats every DMAWFP like DMAWFP periph
    "M18_wfp_kind_ignored": (
        "rtl/core/dma_channel.sv",
        "assign wfp_kind     = {wfp_is_burst, wfp_is_periph};",
        "assign wfp_kind     = 2'b01;", 1),
    # DMAWFP single / burst copy drlast into request_last
    "M19_wfp_sb_keeps_last": (
        "rtl/core/dma_channel.sv",
        "req_last  <= wfp_is_periph && wfp_last;",
        "req_last  <= wfp_last;", 1),
    # A burst that crosses 4 KB is not split
    "M20_no_4k_split": (
        "rtl/core/dma330_pkg.sv",
        "    if (crosses_4k(x.addr, x.size, x.len, x.inc)) begin",
        "    if (1'b0) begin", 1),
    # No load-lock: every channel loads whenever its load fits
    "M21_no_load_lock": (
        "rtl/core/dma_datapath.sv",
        "assign may_load[ch]   = !lock_valid || (lock_owner == CH_W'(ch));",
        "assign may_load[ch]   = 1'b1;", 1),
    # An MFIFO dead-lock is reported as mfifo_err and ignores WD.irq_only
    "M22_dlock_as_mfifo_err": (
        "rtl/core/dma_channel.sv",
        "    exec_fault[FTC_LOCKUP_ERR] = ld_req && ld_dlock;",
        "    exec_fault[FTC_MFIFO_ERR]  = ld_req && (ld_lockup || ld_dlock);", 1),
    # DMAFLUSHP does not wait for the channel's transfers (and acknowledges)
    "M23_flushp_no_barrier": (
        "rtl/core/dma_channel.sv",
        "assign flush_valid  = (state == C_BARRIER) && barrier_fl && dp_idle;",
        "assign flush_valid  = (state == C_BARRIER) && barrier_fl;", 1),
    # A non-secure thread may ask for a secure read
    "M24_ns_secure_read": (
        "rtl/core/dma_channel.sv",
        "(ns && !ccr.src_prot[1])",
        "1'b0", 1),
    # Instruction-cache lines are not tagged with the security state
    "M25_icache_no_ns_tag": (
        "rtl/core/dma_icache.sv",
        "line_tid[w] == cur_tid && line_ns[w] == cur_ns",
        "line_tid[w] == cur_tid", 1),
    # FTRD dmago_err / mgr_evnt_err bit positions swapped
    "M26_ftrd_bits_swapped": (
        "rtl/core/dma330_pkg.sv",
        "  localparam int FTD_DMAGO_ERR       = 4;\n  localparam int FTD_MGR_EVNT_ERR    = 5;",
        "  localparam int FTD_DMAGO_ERR       = 5;\n  localparam int FTD_MGR_EVNT_ERR    = 4;", 1),
    # AWCACHE = {0, dst_cache} instead of {dst_cache[2], 0, dst_cache[1:0]}
    "M27_awcache_old_map": (
        "rtl/core/dma_channel.sv",
        "st_xfer.cache      = {ccr.dst_cache[2], 1'b0, ccr.dst_cache[1:0]};",
        "st_xfer.cache      = {1'b0, ccr.dst_cache};", 1),
    # Instruction fetches are unprivileged
    "M28_ifetch_unprivileged": (
        "rtl/core/dma_icache.sv",
        "assign ar_prot  = {1'b1, cur_ns, 1'b1};",
        "assign ar_prot  = {1'b1, cur_ns, 1'b0};", 1),
    # Old peripheral ID
    "M29_periph_id_old": (
        "rtl/top/axi_dma330.sv",
        "parameter logic [31:0] PERIPH_ID    = 32'h0034_1330,",
        "parameter logic [31:0] PERIPH_ID    = 32'h0000_0330,", 1),
    # CCR resets to 0
    "M30_ccr_reset_zero": (
        "rtl/core/dma_channel.sv",
        "ccr           <= ccr_t'(32'h0080_0200);",
        "ccr           <= '0;", 1),
    # EXOKAY on R is not an error
    "M31_rd_exokay_ok": (
        "rtl/core/dma_rd_engine.sv",
        "rd_err[r_ch]  = (m_rresp != 2'b00);",
        "rd_err[r_ch]  = m_rresp[1];", 1),
    # An endian swap wider than the beat is refused (old rule)
    "M32_wide_swap_refused": (
        "rtl/core/dma_channel.sv",
        "(ccr.dst_inc ? ((st_xfer.bytes[3:0] & swap_mask) != 4'd0)",
        "(ccr.dst_inc ? (ccr.endian_swap > ccr.dst_burst_size)", 1),
    # A wide swap group is popped beat by beat (wrong data)
    "M33_wide_swap_pop_each_beat": (
        "rtl/core/dma_wr_engine.sv",
        "mf_pop[act_ch] = w_fire && !act_x.zero && (!grp_mode || grp_last);",
        "mf_pop[act_ch] = w_fire && !act_x.zero;", 1),
    # A missing event number is reported as ch_evnt_err
    "M34_event_range_as_security": (
        "rtl/core/dma_channel.sv",
        "assign ev_sec_bad   = !ev_range_bad && ns && !irq_ns32[num5];",
        "assign ev_sec_bad   = ev_range_bad || (ns && !irq_ns32[num5]);", 1),
    # Debug instructions are not taken while the manager waits for an event
    "M35_no_debug_in_wfe": (
        "rtl/core/dma_manager.sv",
        "end else if (dbg_valid) begin           // debug instruction while waiting",
        "end else if (1'b0) begin", 1),
    # The NS port sees the NS events although the manager is secure
    "M36_ns_events_secure_mgr": (
        "rtl/core/dma_regs.sv",
        "assign ev_vis  = acc_n ? (dsr[9] ? irq_ns : '0) : '1;",
        "assign ev_vis  = acc_n ? irq_ns : '1;", 1),
    # The core side of a peripheral synchronizer is reset by aresetn only (the
    # pre-v1.4 wiring): a peripheral-only reset leaves its toggles out of phase
    "M37_cdc_periph_core_side": (
        "rtl/top/axi_dma330.sv",
        ".rst_n        (p_core_rst_n),",
        ".rst_n        (core_rst_n),", 1),
    # Same for the APB bridges: a pclk-only reset leaves the core side alone
    "M39_cdc_apb_core_side": (
        "rtl/top/axi_dma330.sv",
        ".rst_n     (apb_core_rst_n),",
        ".rst_n     (core_rst_n),", 1),
    # EXOKAY on B is not an error
    "M38_wr_exokay_ok": (
        "rtl/core/dma_wr_engine.sv",
        "wr_err[b_ch]   = (m_bresp != 2'b00);",
        "wr_err[b_ch]   = m_bresp[1];", 1),
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
    ap.add_argument("--configs", nargs="+", default=["sync"], choices=["sync", "async"])
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
        # This historical comparison measures UVM detection. Directed RTL
        # mutation checks run separately via run_unit_tests.py --mutations.
        common = [sys.executable, "run_regression.py", "--skip-unit", "-c", *args.configs, "-j", str(args.jobs)]
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
