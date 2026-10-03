#!/usr/bin/env bash
# Emits frontend/generated/status.json from the toolchain rather than from memory.
#
# Every figure the site published about its own rigour was hand-typed, and every one had
# drifted: the test count, the runtime size, the invariant count, and branch coverage,
# which was understated by ten points. A claims page about audit discipline is the worst
# place to carry stale self-reported numbers, so they are generated here and committed
# next to deployments.json, which exists for the same reason.
#
# Run from the repository root. Vercel has no Foundry, so the output is committed.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=frontend/generated/status.json
mkdir -p "$(dirname "$OUT")"

TEST_OUT=$(forge test 2>/dev/null | tail -3)
TESTS=$(printf '%s' "$TEST_OUT" | grep -oE '[0-9]+ tests passed' | tail -1 | grep -oE '^[0-9]+' || true)
SUITES=$(printf '%s' "$TEST_OUT" | grep -oE 'Ran [0-9]+ test suites' | tail -1 | grep -oE '[0-9]+' || true)
RUNTIME=$(forge build --sizes 2>/dev/null | awk -F'|' '/VaneHook  /{gsub(/[ ,]/,"",$3); print $3; exit}')
INVARIANTS=$(grep -h 'function invariant_' test/invariant/*.sol | wc -l | tr -d ' ')
RUST_TESTS=$(cd sim && cargo test --release 2>/dev/null | grep -oE '[0-9]+ passed' | head -1 | grep -oE '^[0-9]+' || true)
SLITHER=$(slither . --config-file slither.config.json 2>&1 | grep -oE '[0-9]+ result\(s\) found' | grep -oE '^[0-9]+' || true)

# Coverage is the slow one, so it is opt-in: pass --coverage to refresh it, otherwise the
# previous value is carried forward rather than silently zeroed.
BRANCH_COV=""
LINE_COV=""
if [ "${1:-}" = "--coverage" ]; then
  # Columns are: File | Lines | Statements | Branches | Funcs
  COV_ROW=$(VANE_SKIP_GAS_ASSERTIONS=true forge coverage --report summary --no-match-coverage "(test|script)" 2>/dev/null \
    | grep -E '^\| Total' | head -1)
  LINE_COV=$(printf '%s' "$COV_ROW" | awk -F'|' '{print $3}' | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
  BRANCH_COV=$(printf '%s' "$COV_ROW" | awk -F'|' '{print $5}' | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
elif [ -f "$OUT" ]; then
  BRANCH_COV=$(python3 -c "import json;print(json.load(open('$OUT')).get('branchCoveragePct',''))" 2>/dev/null || true)
  LINE_COV=$(python3 -c "import json;print(json.load(open('$OUT')).get('lineCoveragePct',''))" 2>/dev/null || true)
fi

# The hook's worst-case marginal cost, measured against an in-run plain-pool control so
# the figure does not depend on the machine that measured it.
GAS=$(forge test --match-test test_Gas_WorstCaseCheckpointWithActiveBelief -vvv 2>/dev/null \
  | grep -oE 'marginal hook cost: [0-9]+' | grep -oE '[0-9]+' | tail -1 || true)

python3 - "$OUT" "$TESTS" "$SUITES" "$RUNTIME" "$INVARIANTS" "$RUST_TESTS" "$SLITHER" "$BRANCH_COV" "$GAS" "$LINE_COV" <<'PY'
import json, sys, datetime
out, tests, suites, runtime, inv, rust, slither, cov, gas, linecov = sys.argv[1:11]
def num(x, cast=int):
    try:
        return cast(x)
    except Exception:
        return None
data = {
    "generatedAt": datetime.date.today().isoformat(),
    "tests": num(tests),
    "testSuites": num(suites),
    "rustTests": num(rust),
    "statefulInvariants": num(inv),
    "runtimeBytes": num(runtime),
    "slitherFindings": num(slither),
    "lineCoveragePct": num(linecov, float),
    "branchCoveragePct": num(cov, float),
    "worstCaseGasOverhead": num(gas),
    "gasBudget": 45000,
}
missing = [k for k, v in data.items() if v is None]
if missing:
    sys.exit("refusing to write a partial status file; could not collect: " + ", ".join(missing))
with open(out, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(json.dumps(data, indent=2))
PY
