# Stage 3 power (2026-11-06): no measured card watts; Vivado model + SYSMON sanity data

User answer to NEXT_SESSION Requests §1: "b) c is a backup".

## (b) Board-controller UART, read-only, under the board lock: nothing readable
- Tool: `sw/bmc_probe.py`. Our card's FT4232H is serial 21440289J04F (the one `program.tcl` opens
  for JTAG); interfaces 1..3 are /dev/ttyUSB1..3 on snoke. The other FT4232H (21430289G0C0)
  belongs to another card and was not opened.
- Per UG1268 (VCU1525) the MSP432 board controller's UART is FT4232H channel C (ttyUSB2).
- All three ports: 0 bytes at 115200, 9600, 57600, 19200, 38400, 230400 and 921600 baud, listening
  passively (`bmc_probe_passive_*.log`, two rates) and after one CR per rate (`bmc_probe_cr_*.log`).
  CSR MAGIC/VERSION (0x0f7fe001 / 0x7994da9f) identical before and after both probes.
- The only public tool that reads BCU-1525 sensors (NextJTAG) does it by loading its own
  bitstream. Going further here means sending guessed binary commands, which is not read-only:
  stopped.
- (Before the probe, one `stty -F /dev/ttyUSB1 -a` opened that port briefly without the lock; the
  CSR read afterwards was unchanged.)

## (c) Vivado report_power on build 029 (routed, VERSION 7994da9f) [model]
`synth/scripts/power_est.tcl`, resets deasserted, vectorless, reports in `vivado_029/`.

| | t12p5: vectorless default | eng50: engine at 50% toggle |
|---|---|---|
| Total on-chip | 90.2 W | **99.6 W** |
| Dynamic | 84.1 W | 92.6 W |
| opus_0 (TFHE engine) | 68.9 W | 77.4 W |
| xdma_0 | 4.1 W | 4.0 W |
| ddr4_0..3 (MIG) | 6.9 W | 6.9 W |
| VCCINT current at 0.85 V | 95.5 A | 106.3 A |
| Junction (Vivado's thermal model) | 72.0 °C | 76.9 °C |
| Signals / CLB logic / URAM / DSP / BRAM / clocks | 27.1 / 27.4 / 2.4 / 9.1 / 5.3 / 5.6 W | 32.3 / 28.2 / 4.3 / 9.3 / 5.7 / 5.7 W |

- **eng50 is the headline model figure.** The engine operates on uniformly random ciphertext, key
  and twiddle-product data, so its datapath bits toggle about 50% per cycle (user, 2026-11-06).
  `set_switching_activity -type {register shift_register lut_ram dsp} -hier -toggle_rate 50
  -static_probability 0.5` on bd_i/opus_0; Vivado then reports internal-node activity "High" (more
  than 25% user-specified). Control logic toggles less than 50%, so this leans high for that part.
- t12p5 (resets deasserted; the build's own routed report without that gave 88.0 W) is the
  vectorless default: its 12.5% applies to undriven inputs only, and a first "25%" variant left the
  engine at exactly 68.928 W, so it was dropped.
- Vivado's overall confidence stays **Low** (no simulation activity file: I/O activity unspecified).
  A SAIF from simulation would be better; Verilator 5.020 cannot write one.
- Scope: FPGA die only. Not included: DDR4 DIMMs, regulator losses, the rest of the card.

**Derived:** 3,607 PBS/s [silicon, median BUSY_CYC, Stage 3 gate] / 99.6 W [model, eng50] = **36.2 PBS/W
[derived from model power: a guess, not a measurement]** (40.0 PBS/W at the 12.5% default), PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128, p-fail 2^-129.58,
batch 8, 250 MHz, FPGA die power only. Not a measurement.

## SYSMON over JTAG, idle vs loaded [silicon]
`synth/scripts/sysmon_log.tcl` (read-only hw_manager; never programs), board lock held.
- Idle (engine idle, bitstream 029 resident), 60 s: die temperature mean 68.65 °C (67.8–69.3),
  VCCINT 0.858 V (`sysmon_idle_*.csv`).
- Loaded (`thermal_load.sh`): sampler 300 s; 36 back-to-back runs of 12,500 on seed 2 = 450,000
  bootstraps, about 175 s of device work from ~t=20 s of the CSV (marker times are wall-clock; the
  CSV clock starts after Vivado opens the target). Temperature 69.3 → 71.8 °C, mean 71.83 °C over
  t ≥ 150 s, and it stayed at ~71.8 °C for the ~110 s after the load ended. VCCINT 0.858–0.861 V,
  no droop.
- Reading: no load step is resolvable (a ~2.5 °C drift that does not decay when the load stops).
  Consistent with most die power being load-independent (clock trees and logic run whether or not a
  batch is in flight; static), but the card's thermal resistance and fan control are unknown, so no
  watts are inferred from it.
- The load run itself: 36/36 runs PASS, 0 tfhe-rs failures, 0 bit-exact mismatches, 3,513–3,594
  PBS/s (`evidence/stage3/pbs_run/pbs_run_20261106_070343_s2.*`, `thermal_pbs_run.log`).

## Status
Stage 3 power is reported as a **model** figure with a derived PBS/W, as the user's fallback (c).
A measured PBS/W still needs option (a): a USB-PMBus/I2C adapter on header J1 (LTC3884 at 0x44,
docs/research/POWER.md).

## Build 033 (2026-11-07) [model]: the figures the README now uses
`power_est.tcl` on build 033's routed dcp (VERSION 55306ef1, generated DDR4 constraints, same RTL), `vivado_033/`:
90.3 W total at the vectorless default (engine 68.9 W), **99.7 W** with the engine at 50% toggle (engine 77.4 W).
**Derived:** 3,569 PBS/s [silicon, median BUSY_CYC, build 033 gate] / 99.7 W [model] = **35.8 PBS/W, a guess
[derived from model power, nothing measured]**, PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128, p-fail
2^-129.58, batch 8. The SYSMON steps of that run caught another project's design on the shared board and
are not used (../silicon_033/not_this_design/). The die temperatures above (build 029) stand.
