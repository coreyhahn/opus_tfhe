#!/bin/bash
# launch_build_full.sh — create + build the opus_tfhe FULL bitstream (shell + engine) in a NEW,
# isolated out dir, detached with nohup. Run on a host with a VU9P synthesis licence:
#   synth/scripts/launch_build_full.sh [<tag>]      (from the repo root; VIVADO_SETTINGS=<settings64.sh>)
# Output: synth/out_build_<NNN>_full[_<tag>]/ with NNN = next free number (never reused/overwritten).
#   launch.out (driver log), create.log, build_run.log, build.log (headline), reports/,
#   opus_full.bit, opus_full_routed.dcp, opus_full.ltx (if debug cores), summary.txt
#
# PROVENANCE (this file): copied from synth/scripts/launch_build.sh. Changes: create_full.tcl /
#   build_full.tcl, out dir suffix _full, optional tag, headline greps for the engine checks
#   (SYNTH_OPTS, ENGINE_SYNTH_OPTS_OK, PBLOCK). Expect many hours: the engine alone took hours OOC.
#
# PROVENANCE: adapted from fable5_llm (the user's own project), commit 35d95a5,
#   synth/scripts/launch_build.sh. Changes: auto-numbered out_build_<NNN>_<tag> dir, self-detaching
#   (nohup) instead of a manual nohup wrapper, create_shell.tcl/build_shell.tcl, git dirty flag
#   recorded, a DONE/FAILED marker file for pollers.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

if [ "${1:-}" != "__run" ]; then
    TAG=full${1:+_$1}
    [[ "$TAG" =~ ^[A-Za-z0-9_]+$ ]] || { echo "FATAL: tag must be [A-Za-z0-9_]+" >&2; exit 1; }
    last=$(ls -d "$REPO_ROOT"/synth/out_build_[0-9][0-9][0-9]_* 2>/dev/null \
           | sed -E 's|.*/out_build_([0-9]{3})_.*|\1|' | sort -n | tail -1 || true)
    NNN=$(printf "%03d" $((10#${last:-0} + 1)))
    OUT_DIR="$REPO_ROOT/synth/out_build_${NNN}_${TAG}"
    # plain mkdir (no -p): fails if the dir exists, so a build is never overwritten
    mkdir "$OUT_DIR" || { echo "FATAL: $OUT_DIR exists — builds are never overwritten" >&2; exit 1; }
    nohup "$0" __run "$OUT_DIR" > "$OUT_DIR/launch.out" 2>&1 < /dev/null &
    echo "launched $OUT_DIR (pid $!) on $(hostname)"
    exit 0
fi

OUT_DIR=$2
cd "$REPO_ROOT"
VERSION=$(git rev-parse --short=8 HEAD)
DIRTY=$(git status --porcelain --untracked-files=no | wc -l)
GIT_DESC="$(git rev-parse HEAD) ($( [ "$DIRTY" = 0 ] && echo clean || echo "DIRTY: $DIRTY tracked files modified"))"
trap 'rc=$?; [ $rc -ne 0 ] && echo "rc=$rc $(date)" > "$OUT_DIR/FAILED"; exit $rc' EXIT

# Xilinx settings64.sh references unset vars; relax -u while sourcing
set +u
source "${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2024.2/settings64.sh}"
set -u

cd "$OUT_DIR"
echo "=== $(date) host $(hostname) git $GIT_DESC" | tee build.log
echo "=== create_full (VERSION 0x$VERSION) ===" | tee -a build.log
vivado -mode batch -nojournal -log create.log \
    -source "$SCRIPT_DIR/create_full.tcl" -tclargs "$OUT_DIR" "$VERSION" \
    > create.out 2>&1 || true
grep -q CREATE_PROJECT_OK create.log || { echo "FATAL: create_full failed (see $OUT_DIR/create.log)" | tee -a build.log; exit 1; }
grep -E "^CSR_VERSION|^ROMDIR|^ADDRESS MAP|^  /xdma_0|^  /opus_0|^SYNTH_OPTS" create.log | tee -a build.log

echo "=== build $(date) ===" | tee -a build.log
vivado -mode batch -nojournal -log build_run.log \
    -source "$SCRIPT_DIR/build_full.tcl" -tclargs "$OUT_DIR" "$VERSION" "$GIT_DESC" \
    > build_run.out 2>&1 || true
grep -E "^(IMPL_CFG|SYNTH_OPTS|ENGINE_SYNTH_OPTS_OK|PBLOCK|CLOCK_GATE_OK|WARNING: [0-9]+ register|TIMING:|UTIL:|PCIE_LOC|EXC_MATCHED|BITSTREAM|FATAL)" build_run.log | tee -a build.log || true
grep -q BUILD_OK build_run.log || { echo "FATAL: build failed (see $OUT_DIR/build_run.log)" | tee -a build.log; exit 1; }

ls -la --time-style=full-iso "$OUT_DIR"/opus_full.* | tee -a build.log
echo "=== DONE $(date): $OUT_DIR ===" | tee -a build.log
date > "$OUT_DIR/DONE"
