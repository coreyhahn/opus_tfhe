# Stage 3 silicon gate: build 029 on the BCU-1525 (2026-11-05)

Set: PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128, p-fail 2^-129.58, tfhe-rs 1.8.2. Engine: P = 32,
batch 8, KSL = 184, 250 MHz. Bitstream: commit 7994da9 (VERSION 7994da9f), sha256 397733a9... (bit_sha256.txt).
The build header's "DIRTY: 8 files" were regression logs only; rtl/, synth/ and tb/ are unchanged since 7994da9.

## Build [model]
| Build | Method | WNS (ns) | WHS (ns) | Notes |
|---|---|---|---|---|
| 029 | incremental from 028's routed dcp (TimingClosure) | +0.006 | +0.010 | 99.78% of nets reused; programmed |
| 030 | fresh, SSI_SpreadLogic_high, route AggressiveExplore | +0.001 | +0.006 | not programmed |

029: 0 failed nets, DRC 0 errors, 0 unclocked pins, pblock non_engine=0 in all three.
A fresh placement also closed (030), so 028's closure was not a one-off of that placement.

## Gate, 4 seeds x 2 runs x 12,500, one invocation, no reprogramming [silicon]
Evidence: ../pbs_run/pbs_run_20261105_220958_s1_2_3_4.{json,log}. CSR/DDR4: ../full_hw/ddr_test_20261105_220950.json.

| Seed | Run | tfhe-rs failures | Mismatches vs model | PBS/s host wall | PBS/s BUSY_CYC |
|---|---|---|---|---|---|
| 1 | 0 | 0 | 0 | 3,556.8 | 3,572.6 |
| 1 | 1 | 0 | 0 | 3,659.0 | 3,661.2 |
| 2 | 0 | 0 | 0 | 1,184.4 | 3,494.4 |
| 2 | 1 | 0 | 0 | 3,659.3 | 3,660.9 |
| 3 | 0 | 0 | 0 | 2,182.8 | 3,532.5 |
| 3 | 1 | 0 | 0 | 3,660.8 | 3,666.7 |
| 4 | 0 | 0 | 0 | 2,620.5 | 3,525.5 |
| 4 | 1 | 0 | 0 | 3,633.6 | 3,640.6 |

100,000 bootstraps, 0 failures, 0 mismatches; output noise log2 std 49.02-49.04.
Median over the 8 runs: 3,595 PBS/s host wall, 3,607 PBS/s BUSY_CYC.
Batch latency (start to done, batch 8): median 3.753 ms, worst 5.62 ms. The tail is not analysed.
BATCH_CYC is measured with the other bank in flight.

Slow run 0s: the likely cause is cold NFS reads of lwe_in.u64 during the timed loop. Support: seed 2 run 0 went
from 1,184 to 3,571 PBS/s with the file cached (soak below). One comparison, no cold-cache control.

## Soak, seed 2, 12 runs back to back [silicon]
Evidence: ../pbs_run/pbs_run_20261105_221136_s2.{json,log}. 150,000 bootstraps, 0 failures, 0 mismatches,
42.4 s of runs (more than two 17.18 s wrap periods of the old counter), worst batch 5.61 ms: no 2^32 stall.
3,393-3,602 PBS/s host wall, 3,451-3,606 BUSY_CYC. Rates vary with host promptness on the shared snoke.

## Against simulation [derived]
Best run 3,667 PBS/s = 545.5k cycles per batch; tb_top's DDR model gave 512,168 cycles (3,905 PBS/s).

## Not done
Power: no card-sensor path yet (NEXT_SESSION Requests 1), so no PBS/W. Stage 3 stays open on this one item.

## Bugs found on first silicon
1. Host, 5150bc1: H2C from unaligned buffers misplaced io-window words. 14/16 wrong on the first run.
2. RTL, 7994da9: br_core's free-running 32-bit cyc stalled a batch 2^32 cycles. brwrap 57/64 unfixed, 64/64 fixed.
3. Host, 7994da9: pbs_run judged STATUS.done_bank against a DONE_CNT read before STATUS. Inferred from the code;
   the one abort it explains (seed 4 batch 1488, build 028) was not reproduced.
