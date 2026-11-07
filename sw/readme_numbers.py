#!/usr/bin/env python3
"""Recompute every figure quoted in README.md from the committed evidence files.

  python3 sw/readme_numbers.py            print the figures, each with its label and source
  python3 sw/readme_numbers.py --check    also fail (exit 1) if a figure's README text is missing

No board, no Vivado: it reads evidence/ only. reproduce.sh regenerates that evidence on the board.
"""
import argparse
import glob
import json
import os
import re
import statistics
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EV = os.path.join(REPO, "evidence")
GATE = "stage3/pbs_run/pbs_run_20261107_005848_s1_2_3_4.json"
SOAK = "stage3/pbs_run/pbs_run_20261105_221136_s2.json"
LOAD = "stage3/pbs_run/pbs_run_20261106_070343_s2.json"
LADDER = "stage4/ladder/ladder_20261107_010017_s1_2_3_4.json"
BUILD = "stage3/silicon_033/build033_summary.txt"
P12 = "stage3/power/vivado_033/power_t12p5.rpt"
P50 = "stage3/power/vivado_033/power_eng50.rpt"
SYS_IDLE = "stage3/power/sysmon_idle_20261106_070101.csv"
SYS_LOAD = "stage3/power/sysmon_load_20261106_070313.csv"


def j(p):
    return json.load(open(os.path.join(EV, p)))


def c(x, nd=0):
    return f"{x:,.{nd}f}"


def runs(d):
    return [r for s in d["seeds"] for r in s["runs"]]


def rpt_total(p):
    t = open(os.path.join(EV, p)).read()
    tot = float(re.search(r"Total On-Chip Power \(W\)\s*\|\s*([\d.]+)", t).group(1))
    eng = float(re.search(r"^\|\s+opus_0\s+\|\s+([\d.]+)", t, re.M).group(1))
    return tot, eng


def csv_temps(pat, tmin=0.0):
    f = sorted(glob.glob(os.path.join(EV, pat)))[-1]
    rows = [ln.split(",") for ln in open(f).read().split("\n")[1:] if ln]
    return [float(r[2]) for r in rows if float(r[0]) >= tmin]


def figures():
    F = []

    def add(key, text, label, src):
        F.append((key, text, label, src))

    g = j(GATE)
    gr = runs(g)
    n = sum(s["count"] * len(s["runs"]) for s in g["seeds"])
    add("gate_n", c(n), "silicon", GATE)
    add("gate_fail", str(sum(r["failures"] for r in gr)), "silicon", GATE)
    add("gate_busy_med", c(statistics.median(r["pbs_per_s_busy_cyc"] for r in gr)), "silicon", GATE)
    add("gate_wall_med", c(statistics.median(r["pbs_per_s_host_wall"] for r in gr)), "silicon", GATE)
    add("gate_busy_best", c(max(r["pbs_per_s_busy_cyc"] for r in gr)), "silicon", GATE)
    stds = [r["decrypt"]["log2_std"] for r in gr]
    add("gate_log2std", f"{min(stds):.2f}", "silicon", GATE)
    add("gate_log2std_hi", f"{max(stds):.2f}", "silicon", GATE)
    lat = [r["latency_first_batch_us"] for r in gr]
    add("lat8_ms", f"{statistics.median(lat) / 1000:.3f}", "silicon", GATE)
    s, ld = j(SOAK), j(LOAD)
    add("soak_n", c(sum(x["count"] * len(x["runs"]) for x in s["seeds"])), "silicon", SOAK)
    add("load_n", c(sum(x["count"] * len(x["runs"]) for x in ld["seeds"])), "silicon", LOAD)
    add("soak_load_fail", str(sum(r["failures"] for r in runs(s) + runs(ld))), "silicon", SOAK + " " + LOAD)

    L = j(LADDER)
    lad_n = 0
    lad_fail = 0
    for b in [1, 2, 4, 8, 12, 16]:
        rows = [r for sd in L["seeds"] for r in sd["rows"] if r["batch"] == b]
        lad_n += sum(r["requests"] * b for r in rows)
        lad_fail += sum(r["failures"] + r["mismatched_ct"] for r in rows)
        dl = statistics.median(r["device_latency_us_med_p99_max"][0] for r in rows)
        hl = statistics.median(r["host_latency_us_med_p99_max"][0] for r in rows)
        add(f"b{b}_dev_lat_ms", f"{dl / 1000:.3f}", "silicon", LADDER)
        add(f"b{b}_dev_pbs", c(b / (dl / 1e6)), "derived", LADDER)
        add(f"b{b}_host_lat_ms", f"{hl / 1000:.2f}", "silicon", LADDER)
        add(f"b{b}_host_pbs", c(b / (hl / 1e6)), "derived", LADDER)
    st = [r for sd in L["seeds"] for r in sd["rows"] if r["batch"] == "stream"]
    lad_n += sum(r["count"] for r in st)
    lad_fail += sum(r["failures"] + r["mismatched_ct"] for r in st)
    add("ladder_n", c(lad_n), "silicon", LADDER)
    add("ladder_fail", str(lad_fail), "silicon", LADDER)
    add("ladder_stream_dev_lo", c(min(r["pbs_per_s_device"] for r in st)), "silicon", LADDER)
    add("ladder_stream_dev_hi", c(max(r["pbs_per_s_device"] for r in st)), "silicon", LADDER)
    add("ladder_load", f"{L['loadavg_start'][0]:.0f}", "silicon", LADDER)

    t = open(os.path.join(EV, BUILD)).read()
    add("wns", re.search(r"WNS / TNS\s*:\s*([\d.-]+)", t).group(1), "model", BUILD)
    add("whs", re.search(r"WHS / THS\s*:\s*([\d.-]+)", t).group(1), "model", BUILD)
    lut, ff = re.search(r"LUT / FF\s*:\s*(\d+) / (\d+)", t).groups()
    add("lut", c(int(lut)), "model", BUILD)
    add("ff", c(int(ff)), "model", BUILD)
    bram, uram = re.search(r"BRAM36 / URAM\s*:\s*([\d.]+) / (\d+)", t).groups()
    add("bram", bram, "model", BUILD)
    add("uram", uram, "model", BUILD)
    add("dsp", c(int(re.search(r"DSP\s*:\s*(\d+)", t).group(1))), "model", BUILD)

    p12, e12 = rpt_total(P12)
    p50, e50 = rpt_total(P50)
    add("pw12", f"{p12:.1f}", "model", P12)
    add("pw50", f"{p50:.1f}", "model", P50)
    add("pw50_eng", f"{e50:.1f}", "model", P50)
    best = statistics.median(r["pbs_per_s_busy_cyc"] for r in gr)
    add("pbs_per_w", f"{best / p50:.1f}", "derived", GATE + " / " + P50)
    ti, tl = csv_temps(SYS_IDLE), csv_temps(SYS_LOAD, 150.0)
    add("t_idle", f"{statistics.mean(ti):.1f}", "silicon", SYS_IDLE)
    add("t_load", f"{statistics.mean(tl):.1f}", "silicon", SYS_LOAD)
    return F


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    F = figures()
    readme = open(os.path.join(REPO, "README.md")).read() if args.check else ""
    missing = 0
    for key, text, label, src in F:
        flag = ""
        if args.check and text not in readme:
            flag, missing = "  MISSING FROM README", missing + 1
        print(f"{key:22s} {text:>10s}  [{label}]  {src}{flag}")
    if args.check:
        print(f"{len(F) - missing}/{len(F)} figures found in README.md")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
