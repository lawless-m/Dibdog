#!/usr/bin/env bash
# Smoke test for the engine harness. Assumes the binary is built and
# DIBDOG_EM_HOST/USER/PASS are set in the environment.
#
# Launches the harness on a fixed port, runs a verdict matrix, kills
# the harness, prints the results to stdout. Diff against
# smoke.expected.txt to detect regressions.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/target/release/dibdog-engine-harness"
PORT=38121

if [[ ! -x "$BIN" ]]; then
  echo "smoke: $BIN not found; run cargo build --release first" >&2
  exit 2
fi
if [[ -z "${DIBDOG_EM_HOST:-}" || -z "${DIBDOG_EM_USER:-}" || -z "${DIBDOG_EM_PASS:-}" ]]; then
  echo "smoke: DIBDOG_EM_HOST/USER/PASS must be set" >&2
  exit 2
fi

DIBDOG_HARNESS_BIND="127.0.0.1:$PORT" "$BIN" >/dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; wait 2>/dev/null' EXIT
sleep 1

probe() {
  local sql="$1"
  printf '%-55s => ' "$(echo "$sql" | cut -c1-55)"
  curl -sS -X POST -H "Content-Type: application/json" \
    --data "$(jq -n --arg s "$sql" '{sql:$s}')" \
    "http://127.0.0.1:$PORT/verdict"
  echo
}

echo "health:"
curl -sS "http://127.0.0.1:$PORT/health"; echo
echo
echo "verdicts:"
probe "select count(*) from product"
probe "select CODE from CUSTOMER"
probe "select count(*) from analysis"
probe "select * from no_such_table"
probe "this is not valid sql at all"
probe "select from where"
probe "selectt CODE from CUSTOMER"
probe ""
