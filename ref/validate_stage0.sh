#!/usr/bin/env bash
# Stage 0 gate: the reference model (ref/tfhe_model) validated by tfhe-rs decryption.
#
# For each seed: tfhe-rs generates keys and 1000 encryptions (ref/tfhe_oracle gen); the model runs
# KS -> MS -> PBS in both arithmetics (exact64, and the engine's RNS); tfhe-rs decrypts the model's
# outputs (`decrypt` exits non-zero on any failure). Then the worst-case chain of the parameter set:
# model PBS outputs (LUT x mod 4) scaled by 5 (2-norm = max_noise_level) are bootstrapped again by
# the model and decrypted by tfhe-rs, beside tfhe-rs's own chain on the same keys.
#
# usage: ref/validate_stage0.sh [seeds...]      (default 1 2 3 4; logs to evidence/stage0/)
# Run it from the repo root (many cores help): ref/validate_stage0.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=$HOME/.cargo/bin:$PATH
# Needs cargo (Rust 1.92) for ref/tfhe_model and ref/tfhe_oracle.
if command -v cargo > /dev/null; then
    (cd ref/tfhe_oracle && cargo build --release -q)
    (cd ref/tfhe_model && cargo build --release -q)
fi
O=ref/tfhe_oracle/target/release/tfhe_oracle
M=ref/tfhe_model/target/release/tfhe_model
RNS=rns:249857,188417,163841:28
SEEDS=${*:-1 2 3 4}
C=${COUNT:-1000}
EV=${EVID:-evidence/stage0}      # evidence dir (logs, SUMMARY.md)
V=${VDATA:-data/v}             # bulk data dir
mkdir -p $EV

run() { # run LOG cmd...: append command, host, date, git to LOG, then its output
    local log=$1; shift
    { echo "\$ $*"; echo "# host $(hostname)  date $(date -Iseconds)  git $(git rev-parse --short HEAD)"; } >> "$log"
    "$@" 2>&1 | tee -a "$log"
}

for VAR in ks32 classic; do
  for S in $SEEDS; do
    [ "$VAR" = classic ] && [ "$S" != 1 ] && continue   # classic sibling: one seed
    D=$V/${VAR}_s$S; L=$EV/validate_${VAR}_s$S.log
    mkdir -p $D; : > $L
    run $L $O gen --variant $VAR --seed $S --count $C --lut sq3 --out $D > /dev/null
    for A in exact64 $RNS; do
      T=$D/model_${A%%:*}
      run $L $M run --keys $D --arith $A --lut sq3 --out $T > /dev/null
      run $L $O decrypt --keys $D --input $T.pbs.u64 --kind pbs --json $T.dec.json > /dev/null
    done
    run $L $O decrypt --keys $D --input $D/ref_pbs_out.u64 --kind pbs --json $D/tfhe.dec.json > /dev/null
    [ "$VAR" = classic ] && continue
    # worst-case chain, keys of a mod4 generation with the same seed
    DC=$V/chain_${VAR}_s$S; LC=$EV/validate_chain_${VAR}_s$S.log
    mkdir -p $DC; : > $LC
    run $LC $O gen --variant $VAR --seed $S --count $C --lut mod4 --out $DC > /dev/null
    run $LC $O expect --keys $DC --lut mod4 --w 5 --out $DC/exp_x5.u8 > /dev/null
    for A in exact64 $RNS; do
      T=$DC/model_${A%%:*}
      run $LC $M run --keys $DC --arith $A --lut mod4 --out $T.first > /dev/null
      run $LC $O decrypt --keys $DC --input $T.first.pbs.u64 --kind pbs --json $T.first.dec.json > /dev/null
      run $LC $M run --keys $DC --arith $A --lut id --input $T.first.pbs.u64 --scale 5 --in-msgs $DC/exp_x5.u8 --out $T.chain > /dev/null
      run $LC $O decrypt --keys $DC --input $T.chain.pbs.u64 --kind pbs --expect $DC/exp_x5.u8 --json $T.chain.dec.json > /dev/null
      run $LC $O ms-stats --keys $DC --input $T.chain.ms.u32 --expect $DC/exp_x5.u8 --json $T.chain.ms.json > /dev/null
    done
    run $LC $O scale --input $DC/ref_pbs_out.u64 --w 5 --out $DC/tfhe_x5.u64 > /dev/null
    run $LC $O pbs --keys $DC --input $DC/tfhe_x5.u64 --lut id --out $DC/tfhe_chain > /dev/null
    run $LC $O decrypt --keys $DC --input $DC/tfhe_chain.pbs.u64 --kind pbs --expect $DC/exp_x5.u8 --json $DC/tfhe_chain.dec.json > /dev/null
    run $LC $O ms-stats --keys $DC --input $DC/tfhe_chain.ms.u32 --expect $DC/exp_x5.u8 --json $DC/tfhe_chain.ms.json > /dev/null
  done
done
python3 ref/summarize_stage0.py "$V" "$EV" | tee $EV/SUMMARY.md
