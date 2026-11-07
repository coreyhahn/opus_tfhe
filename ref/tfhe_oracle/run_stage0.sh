#!/usr/bin/env bash
# Reproduce the Stage-0 oracle evidence logs (evidence/stage0/oracle_*.log).
# Usage: ref/tfhe_oracle/run_stage0.sh   (from anywhere; needs cargo)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
export PATH=$HOME/.cargo/bin:$PATH
(cd ref/tfhe_oracle && cargo build --release)
B=ref/tfhe_oracle/target/release/tfhe_oracle
EV=evidence/stage0
D=data/oracle
mkdir -p "$EV" "$D"

# run LOG cmd...: tee the command line, the host/date and the timed output into LOG
run() {
  local log=$1; shift
  { echo "\$ $*"; echo "# host $(hostname)  date $(date -Is)  git $(git rev-parse --short HEAD 2>/dev/null || echo none)"; } >> "$log"
  /usr/bin/time -f "# wall %e s  maxrss %M KB" "$@" 2>&1 | tee -a "$log"
}

for V in ks32 classic; do
  L=$EV/oracle_${V}.log; : > "$L"
  run "$L" $B gen --variant $V --seed 1 --count 1000 --lut sq3 --out $D/${V}_s1
  (cd $D/${V}_s1 && ls -l && sha256sum *) | tee -a "$L"
  run "$L" $B verify-format --dir $D/${V}_s1 --exact-pbs 32
  run "$L" $B decrypt --keys $D/${V}_s1 --input $D/${V}_s1/ref_pbs_out.u64 --kind pbs --json $D/${V}_s1/dec_pbs.json
  KS=$D/${V}_s1/ref_ks_out.u32; [ $V = classic ] && KS=$D/${V}_s1/ref_ks_out.u64
  run "$L" $B decrypt --keys $D/${V}_s1 --input $KS --kind ks --json $D/${V}_s1/dec_ks.json
  run "$L" $B ms-stats --keys $D/${V}_s1 --input $D/${V}_s1/ref_ms.u32
  run "$L" $B tfhe_noise --variant $V
done

# determinism: two independent gen runs, same args, byte-identical files
L=$EV/oracle_determinism.log; : > "$L"
for R in a b; do
  run "$L" $B gen --variant ks32 --seed 3 --count 64 --lut sq3 --out $D/det_$R
done
(cd $D/det_a && sha256sum * | sort -k2) > $D/det_a.sha
(cd $D/det_b && sha256sum * | sort -k2) > $D/det_b.sha
cat $D/det_a.sha | tee -a "$L"
if diff $D/det_a.sha $D/det_b.sha >> "$L"; then echo "DETERMINISM: all files byte-identical across two runs" | tee -a "$L";
else echo "DETERMINISM: FAIL" | tee -a "$L"; exit 1; fi

# worst-case-noise chain (lead request): PBS(mod4) -> x5 -> PBS(id)
L=$EV/oracle_chain_ks32.log; : > "$L"
C=$D/chain_ks32_s1
run "$L" $B gen --variant ks32 --seed 1 --count 1000 --lut mod4 --out $C
run "$L" $B decrypt --keys $C --input $C/ref_pbs_out.u64 --kind pbs
run "$L" $B scale --input $C/ref_pbs_out.u64 --w 5 --out $C/x5.u64
run "$L" $B expect --keys $C --lut mod4 --w 5 --out $C/exp_x5.u8
run "$L" $B decrypt --keys $C --input $C/x5.u64 --kind pbs --expect $C/exp_x5.u8
run "$L" $B pbs --keys $C --input $C/x5.u64 --lut id --out $C/chain
run "$L" $B decrypt --keys $C --input $C/chain.ks.u32 --kind ks --expect $C/exp_x5.u8
run "$L" $B ms-stats --keys $C --input $C/chain.ms.u32 --expect $C/exp_x5.u8 --json $C/chain_ms_stats.json
run "$L" $B decrypt --keys $C --input $C/chain.pbs.u64 --kind pbs --expect $C/exp_x5.u8 --json $C/chain_dec.json
echo "# for comparison: fresh-input MS-domain stats of the same keys (gen ref_ms, ideal 128*m)" | tee -a "$L"
run "$L" $B ms-stats --keys $C --input $C/ref_ms.u32
