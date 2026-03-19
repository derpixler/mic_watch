#!/usr/bin/env bash
##
## test_integration.sh
##
## Smoke test: starts pi_simulator, sends requests via curl,
## verifies the /status endpoint reflects the correct lamp state.
##
## Usage:  bash test_integration.sh
##

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=0
PASS=0
FAIL=0

cleanup() {
  if [[ -n "${SIM_PID:-}" ]]; then
    kill "$SIM_PID" 2>/dev/null || true
    wait "$SIM_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- Helpers ----------------------------------------------------------------

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✅  $label"
    PASS=$((PASS + 1))
  else
    echo "  ❌  $label  (expected: $expected, got: $actual)"
    FAIL=$((FAIL + 1))
  fi
}

wait_for_server() {
  local url="$1"
  for i in $(seq 1 20); do
    if curl -sf "$url/status" > /dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  echo "❌  Server did not start in time"
  exit 1
}

# --- Start simulator on a random free port ----------------------------------

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
BASE="http://localhost:${PORT}"

echo "🚀  Starting pi_simulator on port ${PORT}..."
PI_PORT="$PORT" node "$SCRIPT_DIR/pi_simulator.mjs" > /dev/null 2>&1 &
SIM_PID=$!
wait_for_server "$BASE"
echo ""

# --- Tests ------------------------------------------------------------------

echo "── Initial state ──"
STATUS=$(curl -sf "$BASE/status")
LAMP=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin)['lamp'])")
assert_eq "Lamp starts OFF" "False" "$LAMP"
echo ""

echo "── Turn ON ──"
RESP=$(curl -sf "$BASE/on")
assert_eq "/on returns ON" "ON" "$RESP"
LAMP=$(curl -sf "$BASE/status" | python3 -c "import sys,json; print(json.load(sys.stdin)['lamp'])")
assert_eq "Status is now ON" "True" "$LAMP"
echo ""

echo "── Turn OFF ──"
RESP=$(curl -sf "$BASE/off")
assert_eq "/off returns OFF" "OFF" "$RESP"
LAMP=$(curl -sf "$BASE/status" | python3 -c "import sys,json; print(json.load(sys.stdin)['lamp'])")
assert_eq "Status is now OFF" "False" "$LAMP"
echo ""

echo "── Toggle sequence ──"
curl -sf "$BASE/on"  > /dev/null
curl -sf "$BASE/off" > /dev/null
curl -sf "$BASE/on"  > /dev/null
LAMP=$(curl -sf "$BASE/status" | python3 -c "import sys,json; print(json.load(sys.stdin)['lamp'])")
assert_eq "After ON→OFF→ON, lamp is ON" "True" "$LAMP"
echo ""

echo "── Unknown route ──"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/foobar")
assert_eq "/foobar returns 404" "404" "$HTTP_CODE"
echo ""

# --- Summary ----------------------------------------------------------------

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
