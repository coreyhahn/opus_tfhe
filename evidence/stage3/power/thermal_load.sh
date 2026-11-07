#!/bin/bash
# SYSMON sampler + continuous PBS load under one board-lock hold (run via board_lock.py --exec).
cd /home/cah/r2d2/code/fpga/opus_tfhe
source /home/cah/r2d2/sc2data/tools/Vivado/2024.2/settings64.sh >/dev/null
TS=$(date +%Y%m%d_%H%M%S)
vivado -mode batch -nojournal -nolog -source synth/scripts/sysmon_log.tcl \
  -tclargs 300 2 evidence/stage3/power/sysmon_load_$TS.csv > .scratch/sysmon_load.out 2>&1 &
SM=$!
sleep 30
echo "load_start $(date +%s.%N)" > evidence/stage3/power/sysmon_load_$TS.markers
/home/cah/r2d2/code/fpga/fable5_llm/sw/.venv/bin/python sw/pbs_run.py --keys data/v25k/ks32_s2 \
  --count 12500 --runs 36 --expect-version ${VERSION:-7994da9f} > .scratch/thermal_pbs.log 2>&1 &
PB=$!
# the device phase ends when the first "run N checks:" appears
until grep -q "checks:" .scratch/thermal_pbs.log 2>/dev/null || ! kill -0 $PB 2>/dev/null; do sleep 1; done
echo "load_end $(date +%s.%N)" >> evidence/stage3/power/sysmon_load_$TS.markers
wait $SM
wait $PB
echo "pbs_rc $?" >> evidence/stage3/power/sysmon_load_$TS.markers
