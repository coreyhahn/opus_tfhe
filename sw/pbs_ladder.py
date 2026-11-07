#!/usr/bin/env python3
"""Stage 4 batch ladder on silicon: closed-loop requests of B ciphertexts, B in 1 2 4 8 12 16.

A request of B ciphertexts is handed to the engine, the host waits for all B outputs, and only then
issues the next request (one request in flight). Throughput at batch B = B / request latency;
this is how the HPU's "batch 2: 3,273 PBS/s at 611 us" reads (2 / 611 us). The engine always runs
8 slots per engine batch (CTRL has no slot count), so B <= 8 is one engine batch with the unused
slots padded, and B = 12 / 16 is two engine batches, both banks started at once. A "stream" row
(12,500 ciphertexts, both banks kept full, sw/pbs_run.py's loop) is the unlimited-batch rate.

Latency per request, two clocks:
  host   time from the first H2C to the last C2H (time.monotonic), includes DMA and polling
  device BUSY_CYC delta over the request at 250 MHz (engine busy cycles; for one engine batch it
         equals BATCH_CYC)
Every output is checked bit-exact against the engine model and decrypted by tfhe-rs.

  $PY sw/pbs_ladder.py --keys data/v25k/ks32_s1 [data/v25k/ks32_s2 ...] --expect-version 7994da9f
"""
import argparse
import json
import os
import socket
import statistics
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pbs_run as PR  # noqa: E402

LADDER = [1, 2, 4, 8, 12, 16]
STREAM = 12500


def pct(xs, q):
    s = sorted(xs)
    return s[min(len(s) - 1, int(q * (len(s) - 1) + 0.5))]


def nolog(*_a, **_k):
    pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keys", nargs="+", required=True)
    ap.add_argument("--requests", type=int, default=750, help="requests per batch size")
    ap.add_argument("--batches", type=int, nargs="*", default=LADDER)
    ap.add_argument("--stream", type=int, default=STREAM, help="stream-row ciphertexts (0: skip)")
    ap.add_argument("--dev", default="/dev/xdma0")
    ap.add_argument("--expect-version", type=PR.hexint, default=None)
    ap.add_argument("--aclk-mhz", type=float, default=250.0)
    ap.add_argument("--ksk-timeout", type=float, default=5.0)
    ap.add_argument("--batch-timeout", type=float, default=5.0)
    ap.add_argument("--evidence", default=os.path.join(PR.REPO, "evidence/stage4/ladder"))
    PR.BL.add_lock_args(ap)
    args = ap.parse_args()
    args.verify_keys, args.dry_batch_images = True, -1
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    log = PR.Log()
    de, oracle = PR.tool_paths(argparse.Namespace(dump_engine=None, oracle=None))
    f = args.aclk_mhz * 1e6
    CB = PR.CT_BYTES
    keys_l = [os.path.abspath(k) for k in args.keys]
    metas = [json.load(open(os.path.join(k, "meta.json"))) for k in keys_l]
    os.makedirs(args.evidence, exist_ok=True)
    stem = os.path.join(args.evidence, f"ladder_{ts}_s" + "_".join(str(m["seed"]) for m in metas))
    ev = {"tool": "sw/pbs_ladder.py", "label": "silicon", "utc": datetime.now(timezone.utc).isoformat(),
          "host": socket.gethostname(), "git": PR.git_desc(), "argv": sys.argv,
          "param_set": PR.PARAM_SET, "p_fail": PR.P_FAIL, "engine_slots": PR.BS, "aclk_mhz": args.aclk_mhz,
          "definition": "closed loop, one request of B ciphertexts in flight; throughput = B / latency",
          "loadavg_start": os.getloadavg(), "seeds": [], "pass": True}
    log(f"# pbs_ladder silicon host {ev['host']} git {ev['git']} date {ev['utc']}")
    log("$ " + " ".join(sys.argv))
    for b in args.batches:
        if args.requests * b > min(int(m["count"]) for m in metas):
            raise SystemExit(f"--requests {args.requests} x batch {b} exceeds the key dirs' ciphertexts")

    lock = PR.BL.from_args(args, tool="pbs_ladder.py").acquire()
    dev, rc = None, 0
    pending = []
    try:
        stamps = [PR.prepare(k, os.path.join(k, f"pbs_prep_P{PR.PLOG}_L{PR.KSL}"), de, log) for k in keys_l]
        dev = PR.HwDev(args.dev)
        ev["version"] = f"{PR.check_device(dev, args, log):08x}"
        for k, st, meta in zip(keys_l, stamps, metas):
            seed = meta["seed"]
            prep = os.path.join(k, f"pbs_prep_P{PR.PLOG}_L{PR.KSL}")
            # whole input file in memory before any timing (cold NFS reads slowed pbs_run's run 0)
            lwe = open(os.path.join(k, "lwe_in.u64"), "rb").read()
            sev = {"seed": seed, "keys": k, "rows": []}
            ev["seeds"].append(sev)
            log(f"== seed {seed}: {k}")
            sev.update(PR.load_keys(dev, prep, st, PR.DEF_BSK_BASES, PR.DEF_KSK_BASE, args, log))
            outdir = os.path.join(k, "pbs_ladder", ts)
            os.makedirs(outdir, exist_ok=True)
            for b in args.batches:
                out = bytearray(args.requests * b * CB)
                host, devc = [], []
                t0 = time.monotonic()
                for r in range(args.requests):
                    o, s = PR.run_batches(dev, lwe[r * b * CB:(r + 1) * b * CB], b, r, args, nolog)
                    out[r * b * CB:(r + 1) * b * CB] = o
                    host.append(s["host_wall_s"])
                    devc.append(s["busy_cyc"])
                total = time.monotonic() - t0
                hm, dm = statistics.median(host), statistics.median(devc)
                row = {"batch": b, "requests": args.requests, "engine_batches_per_request": (b + PR.BS - 1) // PR.BS,
                       "host_latency_us_med_p99_max": [round(x * 1e6, 1) for x in (hm, pct(host, .99), max(host))],
                       "device_latency_us_med_p99_max": [round(x / f * 1e6, 1) for x in (dm, pct(devc, .99), max(devc))],
                       "pbs_per_s_host": round(b / hm, 1), "pbs_per_s_device": round(b / (dm / f), 1),
                       "pbs_per_s_loop_total": round(args.requests * b / total, 1)}
                log(f"  batch {b:2d}: latency host med {row['host_latency_us_med_p99_max'][0]} us "
                    f"(p99 {row['host_latency_us_med_p99_max'][1]}, max {row['host_latency_us_med_p99_max'][2]}), "
                    f"device med {row['device_latency_us_med_p99_max'][0]} us; PBS/s host {row['pbs_per_s_host']}, "
                    f"device {row['pbs_per_s_device']}, loop {row['pbs_per_s_loop_total']}  [silicon]")
                out_f = os.path.join(outdir, f"ladder_s{seed}_b{b}.u64")
                with open(out_f, "wb") as fo:
                    fo.write(out)
                sev["rows"].append(row)
                pending.append((k, row, out_f, args.requests * b))
            if args.stream:
                o, s = PR.run_batches(dev, lwe, args.stream, 0, args, nolog)
                row = {"batch": "stream", "count": args.stream, "pbs_per_s_host": s["pbs_per_s_host_wall"],
                       "pbs_per_s_device": s["pbs_per_s_busy_cyc"],
                       "engine_batch_latency_us_min_med_max": s["latency_batch_us_min_med_max"]}
                log(f"  stream {args.stream}: PBS/s host {row['pbs_per_s_host']}, device {row['pbs_per_s_device']}, "
                    f"engine-batch latency min/med/max {row['engine_batch_latency_us_min_med_max']} us  [silicon]")
                out_f = os.path.join(outdir, f"ladder_s{seed}_stream.u64")
                with open(out_f, "wb") as fo:
                    fo.write(o)
                sev["rows"].append(row)
                pending.append((k, row, out_f, args.stream))
        ev["loadavg_end_device"] = os.getloadavg()
    except PR.Fail as e:
        log(f"FATAL: {e}")
        ev["pass"], ev["fatal"] = False, str(e)
        rc = 3
    finally:
        if dev is not None:
            dev.close()
        lock.release()
    # checks are offline, after all device work
    for k, row, out_f, n in pending:
        log(f"check seed dir {os.path.basename(k)} batch {row['batch']}:")
        out = open(out_f, "rb").read()
        res = PR.check_outputs(k, out_f, out, n, oracle, os.path.join(k, "model_rns.pbs.u64"), log)
        bx = res["bitexact_vs_model"]
        row["failures"] = res["failures"]
        row["mismatched_ct"] = None if bx is None else bx["mismatched_ct"]
        row["log2_std"] = (res.get("decrypt") or {}).get("log2_std")
        ok = res["failures"] == 0 and bx is not None and bx["mismatched_ct"] == 0
        row["pass"] = ok
        ev["pass"] &= ok
    log("PASS" if ev["pass"] else "FAIL")
    with open(stem + ".json", "w") as fo:
        json.dump(ev, fo, indent=1)
    log(f"evidence: {stem}.json {stem}.log")
    log.save(stem + ".log")
    return rc or (0 if ev["pass"] else 1)


if __name__ == "__main__":
    sys.exit(main())
