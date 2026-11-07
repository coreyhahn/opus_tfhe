#!/usr/bin/env bash
# reproduce.sh — regenerate every figure in README.md.
#
#   ./reproduce.sh numbers        recompute every README figure from committed evidence (no board)
#   ./reproduce.sh data           tfhe-rs keys + 25,000 encryptions + model outputs per seed 1..4
#   ./reproduce.sh build [tag]    full Vivado build (needs a VU9P licence; many hours)
#   ./reproduce.sh program <bit>  volatile JTAG programming, PCIe remove/rescan, under the board lock
#   ./reproduce.sh gate           Stage 3 gate: 4 seeds x 2 runs x 12,500 on the board
#   ./reproduce.sh ladder         Stage 4 ladder: batch 1 2 4 8 12 16 + stream, 4 seeds
#   ./reproduce.sh power [dcp]    Vivado power estimate + SYSMON idle/load temperatures
#
# Board steps run on the host that holds the card and take the shared board lock. New evidence
# lands under evidence/ with new timestamps; point sw/readme_numbers.py's file names at it to re-derive.
# Labels: gate/ladder/SYSMON are silicon; build and power reports are model.
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(pwd)
mkdir -p .scratch
PY=${PY:-python3}
VIVADO_SETTINGS=${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2024.2/settings64.sh}
# board lock + safe JTAG/PCIe reprogramming script from the author's fable5_llm project
FABLE5_SW=${FABLE5_SW:-$REPO/../fable5_llm/sw}
LOCK=${LOCK:-$FABLE5_SW/board_lock.py}
PROGRAM=${PROGRAM:-$FABLE5_SW/program_fpga.sh}
SEEDS="1 2 3 4"
KEYS=""; for s in $SEEDS; do KEYS="$KEYS data/v25k/ks32_s$s"; done
# CSR VERSION of the resident bitstream = git short hash of the commit it was built from
VERSION=${VERSION:-55306ef1}

case "${1:-numbers}" in
numbers)
    python3 sw/readme_numbers.py --check ;;
data)
    export PATH=$HOME/.cargo/bin:$PATH
    COUNT=25000 VDATA=data/v25k EVID=evidence/stage2/validate_25k ref/validate_stage0.sh $SEEDS
    for k in $KEYS; do $PY sw/pbs_run.py --keys $k --prep-only; done ;;
build)
    synth/scripts/launch_build_full.sh ${2:-} ;;
program)
    bit=${2:?usage: reproduce.sh program <bitfile>}
    $PROGRAM --expect-sha256 "$(sha256sum "$bit" | cut -d' ' -f1)" "$bit" ;;
gate)
    $PY sw/pbs_run.py --keys $KEYS --count 12500 --runs 2 --expect-version $VERSION ;;
ladder)
    $PY sw/pbs_ladder.py --keys $KEYS --requests 750 --expect-version $VERSION ;;
power)
    dcp=${2:-synth/out_build_033_full_genddr_incr029/opus_full_routed.dcp}
    set +u; source "$VIVADO_SETTINGS" > /dev/null; set -u
    vivado -mode batch -nojournal -nolog -source synth/scripts/power_est.tcl \
        -tclargs "$dcp" evidence/stage3/power/vivado_$(date +%Y%m%d_%H%M%S)
    python3 "$LOCK" --tool reproduce_sysmon --exec -- vivado -mode batch -nojournal -nolog \
        -source synth/scripts/sysmon_log.tcl -tclargs 60 2 evidence/stage3/power/sysmon_idle_$(date +%Y%m%d_%H%M%S).csv
    VERSION=$VERSION python3 "$LOCK" --tool thermal_load --exec -- evidence/stage3/power/thermal_load.sh ;;
*)
    sed -n 2,15p "$0"; exit 2 ;;
esac
