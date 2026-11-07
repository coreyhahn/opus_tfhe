# Stage 4: the ladder, comparisons, README (2026-11-06)

Set: PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128, p-fail 2^-129.58, tfhe-rs 1.8.2; build 029
(VERSION 7994da9f), 250 MHz, 8 engine slots.

## Ladder [silicon] (`ladder/ladder_20261106_092227_s1_2_3_4.{json,log}`, tool `sw/pbs_ladder.py`)
Closed loop, one request of B ciphertexts in flight; throughput = B / request latency. 4 seeds x 750
requests per B, plus a 12,500-ciphertext stream row per seed. 179,000 bootstraps, all bit-exact vs the
model, tfhe-rs 0 failures (28/28 output sets PASS).

| B | device latency med | device PBS/s | host latency med | host PBS/s |
|--:|--:|--:|--:|--:|
| 1 | 3.753 ms | 266 | 4.26 ms | 235 |
| 2 | 3.753 ms | 533 | 4.32 ms | 463 |
| 4 | 3.753 ms | 1,066 | 4.41 ms | 906 |
| 8 | 3.753 ms | 2,132 | 4.58 ms | 1,747 |
| 12 | 5.905 ms | 2,032 | 6.54 ms | 1,835 |
| 16 | 5.905 ms | 2,710 | 6.74 ms | 2,375 |

Device = BUSY_CYC delta over the request; host = first H2C to last C2H. Medians across seeds (device
values agree to 0.1 us across seeds). snoke load average ~81 on 48 cores (other users' jobs) during the
run: host p99 latencies 7.9-15.6 ms, and the stream rows gave 3,271-3,332 PBS/s on busy cycles against
3,607 in the quieter Stage 3 gate, which the README uses as the stream figure.

## Comparisons, README, licence
README.md (figures recomputed by `sw/readme_numbers.py --check`: 53/53 found), LICENSE (Apache-2.0),
NOTICE (Zama patent caution; GPLv2 DIMM/part files), `reproduce.sh` (numbers / data / build / program /
gate / ladder / power). PBS/W: 36.2, a guess [derived from model power; no watts measured], evidence/stage3/power/SUMMARY.md.

Charter ladder: T0 met; T1 (5,000 PBS/s), T2, T3, latency (611 us / 973 us) and efficiency (171 PBS/W)
not met.

## Rerun on build 033 (2026-11-07) [silicon]: the figures the README now uses
Build 033 (VERSION 55306ef1, generated DDR4 constraints, same RTL), `ladder/ladder_20261107_010017_s1_2_3_4.{json,log}`,
same set and p-fail, same 4 seeds x 750 requests. 179,000 bootstraps, all bit-exact, tfhe-rs 0 failures (PASS).

| B | device latency med | device PBS/s | host latency med | host PBS/s |
|--:|--:|--:|--:|--:|
| 1 | 3.747 ms | 267 | 4.09 ms | 244 |
| 2 | 3.747 ms | 534 | 4.14 ms | 483 |
| 4 | 3.747 ms | 1,068 | 4.20 ms | 953 |
| 8 | 3.747 ms | 2,135 | 4.34 ms | 1,843 |
| 12 | 5.892 ms | 2,037 | 6.34 ms | 1,892 |
| 16 | 5.892 ms | 2,716 | 6.47 ms | 2,472 |

snoke load average ~15 at the start. Stream rows 3,531-3,625 PBS/s on busy cycles; the build 033 gate median
is 3,569 (../stage3/silicon_033/SUMMARY.md). PBS/W against build 033's Vivado estimate: 3,569 / 99.7 W = 35.8,
a guess [derived from model power].
