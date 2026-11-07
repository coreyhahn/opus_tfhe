# Not build 033: captures taken on another project's design

`./reproduce.sh power` on 2026-11-07 ran the Vivado estimate first (01:04-01:41, kept as
`../../power/vivado_033/`). By the time its board steps ran (01:41), another session on the shared
board had loaded its own design: pbs_run read MAGIC 0x52100002 VERSION 232d16f4 and stopped before
any DMA (thermal_pbs log, pbs_rc 3). The SYSMON idle and load CSVs here (32.4-32.9 °C, no load)
are therefore of that design and are not used anywhere. The board was not reprogrammed back.

Build 033's own gate (00:58) and ladder (01:00) ran before the swap: both check VERSION 55306ef1 at
start and every output is bit-exact against the model.
