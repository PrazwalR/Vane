#!/usr/bin/env bash
# Tests the scale-invariance claim: if arbitrage flow grows with depth, then D and D* grow
# together and no amount of liquidity switches the mechanism on. flowUnit is scaled with
# the pool so the estimator never saturates and cannot confound the answer.
set -u
cd "$(dirname "$0")/.."
OUT=sim/results/depth_scan.jsonl
mkdir -p sim/results
: > "$OUT"
for LIQ_E in 1e5 1e6 1e7 1e8 1e9; do
  LIQ=$(python3 -c "print(int(float('$LIQ_E')*10**18))")
  FU=$(python3 -c "print(max(10**9, min(10**18, int(float('$LIQ_E')*10**18/10**9))))")
  SIM_LIQUIDITY="$LIQ" SIM_FEE=500 SIM_SPACING=10 SIM_FLOW_UNIT="$FU" \
    forge test --match-path test/sim/SimStateDump.t.sol >/dev/null 2>&1 || continue
  for SIG in 0.0002 0.0004 0.0010; do
    (cd sim && ./target/release/vane-sim --blocks 250 --json --noise-size 5e18 \
      --noise-rate 20 --sigma "$SIG") | python3 -c "
import sys,json
r=json.load(sys.stdin); r['flow_unit']='$FU'; r['sigma_in']='$SIG'
print(json.dumps(r))" >> "$OUT"
    echo -n "."
  done
done
echo; echo "wrote $OUT"
