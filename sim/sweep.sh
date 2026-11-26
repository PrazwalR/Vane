#!/usr/bin/env bash
# Scans depth against noise volume to locate any regime where the open-loop gain is
# non-zero. Liquidity changes the dumped pool, so it costs a forge run; noise is a
# command-line argument, so it does not.
set -u
cd "$(dirname "$0")/.."
OUT=sim/results/sweep.jsonl
mkdir -p sim/results
: > "$OUT"

for LIQ_E in 1e3 1e4 1e5 1e6 1e7 1e8; do
  LIQ=$(python3 -c "print(int(float('$LIQ_E')*10**18))")
  for FEE in 500 3000; do
    SPACING=10; [ "$FEE" = "3000" ] && SPACING=60
    SIM_LIQUIDITY="$LIQ" SIM_FEE="$FEE" SIM_SPACING="$SPACING" \
      forge test --match-path test/sim/SimStateDump.t.sol >/dev/null 2>&1 || continue
    for NS in 1e18 1e19 1e20 1e21 1e22; do
      (cd sim && ./target/release/vane-sim --blocks 250 --json --noise-size "$NS" \
        --noise-rate 20 --sigma 0.0004) >> "$OUT" 2>/dev/null
      echo -n "."
    done
  done
done
echo
echo "wrote $OUT"
