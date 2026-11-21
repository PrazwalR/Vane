#!/usr/bin/env bash
# Calibrates the belief's decay rate (theta) and the horizon length (K) against the replay
# engine. Each parameter set gets its own dumped state, so the replays run in parallel.
#
# For every (theta, K) it replays a near-martingale price (momentum 0, where the gain should
# stay at zero and nothing should change) and two trending ones (momentum 0.9 and 0.95,
# where the gain switches on), over several seeds, and writes one JSON line per run.
#
#   ./sim/calibrate.sh                 # from the repository root
#   JOBS=8 SEEDS="1 2 3" ./sim/calibrate.sh
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=sim/results/calibration.jsonl
BLOCKS=${BLOCKS:-400}
SEEDS=${SEEDS:-"1 2"}
JOBS=${JOBS:-6}
MOMENTA=${MOMENTA:-"0.0 0.9 0.95"}
THETA_DIVS=${THETA_DIVS:-"100 50 20 10"}
HORIZONS=${HORIZONS:-"10 20 40"}

mkdir -p sim/results
: > "$OUT"

TWO_64=18446744073709551616
jobs_file=$(mktemp)

for div in $THETA_DIVS; do
  theta=$(python3 -c "print($TWO_64 // $div)")
  for k in $HORIZONS; do
    dir="sim/state/cal_${div}_${k}"
    mkdir -p "$dir"
    SIM_STATE_DIR="$dir" SIM_THETA_X64="$theta" SIM_HORIZON_K="$k" \
      forge test --match-path test/sim/SimStateDump.t.sol >/dev/null
    for m in $MOMENTA; do
      for seed in $SEEDS; do
        echo "$div $k $m $seed" >> "$jobs_file"
      done
    done
  done
done

# Each job replays one (theta, K, momentum, seed) and tags the JSON line with its inputs.
run_one() {
  local div=$1 k=$2 m=$3 seed=$4
  local line
  line=$(cd sim && ./target/release/vane-sim --state "state/cal_${div}_${k}" --blocks "$BLOCKS" \
    --momentum "$m" --seed "$seed" --json 2>/dev/null | tail -1)
  [ -n "$line" ] && echo "${line%\}},\"theta_div\":${div},\"horizon_k\":${k}}"
}
export -f run_one
export BLOCKS

xargs -P "$JOBS" -L 1 bash -c 'run_one "$@"' _ < "$jobs_file" >> "$OUT"
rm -f "$jobs_file"
echo "wrote $(wc -l < "$OUT") runs to $OUT"
