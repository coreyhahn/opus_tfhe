# Silicon gate: build 033 on the BCU-1525 (2026-11-07)

Set: PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128, p-fail 2^-129.58, tfhe-rs 1.8.2. Engine: P = 32,
batch 8, KSL = 184, 250 MHz. Bitstream: commit 55306ef (VERSION 55306ef1), sha256 daff5bbd... (bit_sha256.txt).
Build 033 checks that the DDR4 pin constraints and part CSV generated from AMD's Apache-2.0 VCU1525
board file (synth/scripts/gen_ddr4_constraints.py) work on the board. They replace the GPLv2 community files
that builds up to 029 used. The new files change the DQ bit and byte order within each channel and leave
the I/O standards to the DDR4 IP. rtl/ is unchanged from build 029. The build header's "DIRTY: 3 files"
were README.md, NOTICE and evidence/stage4/SUMMARY.md; rtl/, synth/, tb/ and ref/ are unchanged since 55306ef.

## Build [model]
| Build | Method | WNS (ns) | WHS (ns) | Notes |
|---|---|---|---|---|
| 033 | incremental from 029's routed dcp (TimingClosure), place SSI_SpreadLogic_high, route AggressiveExplore | +0.004 | +0.004 | 99.59% of nets reused; programmed |
| 032 | fresh, clean tree at 55306ef, SSI_SpreadLogic_high, route AggressiveExplore | +0.000 | +0.005 | met; not programmed |

033: 0 unrouted nets, DRC 0 errors (warnings only, drc.rpt), 0 unclocked pins, pblock non_engine=0 in all three
(build033.log). "All user specified timing constraints are met" (build033_timing_summary_head.rpt).

## DDR4 [silicon]
MAGIC 0f7fe001, VERSION 55306ef1, **CALIB = 0xF: all four channels calibrated with the generated constraints.**
`ddr_test.py --quick` (64 MiB per channel, 4 seeds x 2 runs x 4 channels): 32/32 PASS
(ddr_test_20261107_005825.json, ddr_test.out). An earlier full-size run passed 27/27 before my client-side
timeout cut its ssh (ddr_test_full_interrupted.out).

## Gate, 4 seeds x 2 runs x 12,500, one invocation, no reprogramming [silicon]
Evidence: ../pbs_run/pbs_run_20261107_005848_s1_2_3_4.{json,log}; console gate.out.

| Seed | Run | tfhe-rs failures | Mismatches vs model | PBS/s host wall | PBS/s BUSY_CYC |
|---|---|---|---|---|---|
| 1 | 0 | 0 | 0 | 3,471.4 | 3,511.1 |
| 1 | 1 | 0 | 0 | 3,602.6 | 3,618.1 |
| 2 | 0 | 0 | 0 | 3,495.7 | 3,527.0 |
| 2 | 1 | 0 | 0 | 3,562.0 | 3,597.4 |
| 3 | 0 | 0 | 0 | 3,516.6 | 3,540.5 |
| 3 | 1 | 0 | 0 | 3,607.8 | 3,622.5 |
| 4 | 0 | 0 | 0 | 3,503.6 | 3,538.2 |
| 4 | 1 | 0 | 0 | 3,582.4 | 3,600.0 |

100,000 bootstraps, 0 failures, 0 mismatches; output noise log2 std 49.02-49.04.
Median over the 8 runs: 3,539 PBS/s host wall, 3,569 PBS/s BUSY_CYC (build 029: 3,595 / 3,607).
Batch latency (start to done, batch 8): median 3.747 ms, worst 5.60 ms (build 029: 3.753 / 5.62 ms).
Same RTL, so the cycle difference comes from outside the engine. A guess, not analysed: the DDR4 path
(new byte order, new calibration). Run 0 of every seed is again slower than run 1.

## Ladder [silicon]
../../stage4/ladder/ladder_20261107_010017_s1_2_3_4.{json,log}: 179,000 bootstraps, all bit-exact,
tfhe-rs 0 failures (PASS). See ../../stage4/SUMMARY.md.

## Power [model]
Vivado estimate on build 033's routed dcp: ../power/vivado_033/ (99.7 W eng50, 90.3 W vectorless).
The board steps of the same `reproduce.sh power` call ran after another session had loaded its own
design onto the shared board, so they are not build 033 data: not_this_design/README.md. Die temperatures,
the soak and the 450,000-bootstrap thermal-load run stay those of build 029 (../silicon_029/, ../power/).
