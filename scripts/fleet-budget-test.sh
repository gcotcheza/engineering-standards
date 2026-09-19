#!/usr/bin/env bash
# Fakes only: a fake meter JSON and fake /proc files drive the real
# scripts/fleet-budget.sh through its own seams. No network, no credentials,
# no cache outside the temp dir. FLEET_BUDGET_SH points at a scratch copy for
# the red proofs.
#
#   scripts/fleet-budget-test.sh
#   FLEET_BUDGET_SH=/tmp/mutant.sh scripts/fleet-budget-test.sh   the red proofs
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${FLEET_BUDGET_SH:-${SCRIPT_DIR}/fleet-budget.sh}"

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
matches() { if printf '%s' "$2" | grep -qE "$3"; then pass "$1"; else fail "$1 — [$2] does not match /$3/"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '0.10 0.20 0.30 1/200 99\n' >"${WORK}/loadavg"
printf 'MemTotal:  7931000 kB\nMemAvailable:  4200000 kB\n' >"${WORK}/meminfo"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.13 total=1\n' >"${WORK}/pressure"
: >"${WORK}/conf"

# $1 five-hour %, $2 seven-day %, $3 Fable weekly % ('none' leaves it out)
meter() {
    { printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":%s},"limits":[' "$1" "$2"
      printf '{"kind":"session","group":"session","percent":%s,"scope":null}' "$1"
      [ "$3" != none ] && printf ',{"kind":"weekly_fable","group":"weekly","percent":%s,"scope":{"model":{"display_name":"Fable"}}}' "$3"
      printf ']}\n'
    } >"${WORK}/meter.json"
}

run() {
    OUT="$(FLEET_BUDGET_CONF="${WORK}/conf" \
        FLEET_BUDGET_METER_FILE="${1-${WORK}/meter.json}" \
        FLEET_BUDGET_CREDS="${WORK}/no-credentials.json" \
        FLEET_BUDGET_CACHE="${WORK}/cache.json" \
        FLEET_BUDGET_ENDPOINT='http://127.0.0.1:1/never' \
        FLEET_BUDGET_LOADAVG="${WORK}/loadavg" \
        FLEET_BUDGET_MEMINFO="${WORK}/meminfo" \
        FLEET_BUDGET_PRESSURE="${WORK}/pressure" \
        FLEET_BUDGET_CORES=4 \
        "${CHECK}" 2>&1)"
    RC=$?
}

# --- 1. every meter one below its cap -> ok ------------------------------------
meter 49 59 59; run
matches 'case 1: one below every cap reports ok' "${OUT}" '^ok 5h 49%/50 week-all 59%/60 week-fable 59%/60$'
equals  'case 1: exit code' "${RC}" 0

# --- 2. week-all exactly at its cap -> hold ------------------------------------
meter 10 60 10; run
matches 'case 2: week-all at its cap holds' "${OUT}" '^hold week-all meter 60% is at or above its cap 60'
equals  'case 2: exit code' "${RC}" 1

# --- 3. the 5-hour meter exactly at its cap -> hold ----------------------------
meter 50 10 10; run
matches 'case 3: 5h at its cap holds' "${OUT}" '^hold 5h meter 50% is at or above its cap 50'
equals  'case 3: exit code' "${RC}" 1

# --- 4. the weekly Fable meter exactly at its cap -> hold ----------------------
meter 10 10 60; run
matches 'case 4: week-fable at its cap holds' "${OUT}" '^hold week-fable meter 60% is at or above its cap 60'
equals  'case 4: exit code' "${RC}" 1

# --- 5. the conf raises a cap ---------------------------------------------------
printf 'WEEK_ALL_MAX=90\n' >"${WORK}/conf"
meter 10 67 10; run
matches 'case 5: a conf cap of 90 makes 67% ok' "${OUT}" '^ok 5h 10%/50 week-all 67%/90 week-fable 10%/60$'
equals  'case 5: exit code' "${RC}" 0

# --- 5b. a value written with spaces is read, not silently dropped -------------
printf 'WEEK_ALL_MAX = 90\n' >"${WORK}/conf"
meter 10 67 10; run
matches 'case 5b: WEEK_ALL_MAX = 90 (spaces) is read' "${OUT}" '^ok 5h 10%/50 week-all 67%/90 week-fable 10%/60$'
equals  'case 5b: exit code' "${RC}" 0

# --- 5c. a value that is not a number -> hold, never the looser default --------
printf 'WEEK_ALL_MAX=sixty\n' >"${WORK}/conf"
meter 10 67 10; run
equals  'case 5c: an unparseable conf value holds' "${OUT}" 'hold conf unreadable: WEEK_ALL_MAX'
equals  'case 5c: exit code' "${RC}" 1

# --- 5d. a value outside 0-100 -> hold -----------------------------------------
printf 'FIVE_HOUR_MAX=1000\n' >"${WORK}/conf"
meter 10 10 10; run
equals  'case 5d: a conf value over 100 holds' "${OUT}" 'hold conf unreadable: FIVE_HOUR_MAX'
equals  'case 5d: exit code' "${RC}" 1
: >"${WORK}/conf"

# --- 6. no Fable meter in the response -> unreadable, hold ---------------------
meter 10 10 none; run
matches 'case 6: a missing Fable meter is unreadable, not zero' "${OUT}" '^hold meter unreadable \(no utilization numbers'
equals  'case 6: exit code' "${RC}" 1

# --- 7. no token and no cache -> hold, fail closed ------------------------------
run ''
matches 'case 7: a missing token holds' "${OUT}" '^hold meter unreadable \(token missing\)'
equals  'case 7: exit code' "${RC}" 1

# --- 8. a fresh cache is used without any credentials ---------------------------
meter 10 11 12; cp "${WORK}/meter.json" "${WORK}/cache.json"; run ''
matches 'case 8: a fresh cache is read without credentials' "${OUT}" '^ok 5h 10%/50 week-all 11%/60 week-fable 12%/60$'
rm -f "${WORK}/cache.json"

# --- 9. load15 over the core count -> hold --------------------------------------
printf '0.10 0.20 4.01 1/200 99\n' >"${WORK}/loadavg"
meter 10 10 10; run
matches 'case 9: load15 over the cores holds' "${OUT}" '^hold capacity: load15 4.01 over 4 cores'
equals  'case 9: exit code' "${RC}" 1
printf '0.10 0.20 0.30 1/200 99\n' >"${WORK}/loadavg"

# --- 10. available memory under the floor -> hold -------------------------------
printf 'MemAvailable:  1400000 kB\n' >"${WORK}/meminfo"
run
matches 'case 10: under 1500MB available holds' "${OUT}" '^hold capacity: 1367MB available, under 1500MB'
printf 'MemTotal:  7931000 kB\nMemAvailable:  4200000 kB\n' >"${WORK}/meminfo"

# --- 11. memory pressure over the ceiling -> hold -------------------------------
printf 'some avg10=0 avg60=0 avg300=0 total=1\nfull avg10=0 avg60=0 avg300=10.4 total=1\n' >"${WORK}/pressure"
run
matches 'case 11: memory pressure over 10 holds' "${OUT}" '^hold capacity: memory pressure full avg300 10.4 over 10'

# --- 12. an unreadable pressure reading is a hold, never a zero -----------------
printf 'full avg10=x avg60=x avg300=nonsense total=1\n' >"${WORK}/pressure"
run
matches 'case 12: unreadable pressure holds' "${OUT}" '^hold capacity unreadable: .*pressure'
equals  'case 12: exit code' "${RC}" 1

# --- 13. fetch_meter against a local http.server: the 200 path -----------------
# A dummy token in a fake credentials file. It must never reach the output or
# the cache, and the assertions below fail if it does.
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.13 total=1\n' >"${WORK}/pressure"
DUMMY_TOKEN='sk-ant-oat01-DUMMY-FOR-TESTS-never-real-0000'
printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":%s000}}\n' "${DUMMY_TOKEN}" "$(( $(date +%s) + 3600 ))" >"${WORK}/fake-creds.json"

cat >"${WORK}/meter-server.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
BODY = open(sys.argv[1], 'rb').read()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body, code = (BODY, 200) if self.path == '/meter' else (b'', 401)
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


s = HTTPServer(('127.0.0.1', 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY

meter 10 11 12
python3 "${WORK}/meter-server.py" "${WORK}/meter.json" >"${WORK}/port" 2>"${WORK}/server.log" &
SERVER_PID=$!
trap 'kill "${SERVER_PID}" 2>/dev/null; rm -rf "$WORK"' EXIT
PORT=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
    PORT="$(cat "${WORK}/port" 2>/dev/null)"
    [ -n "${PORT}" ] && break
    sleep 0.3
done

fetch() {
    OUT="$(FLEET_BUDGET_CONF="${WORK}/conf" \
        FLEET_BUDGET_METER_FILE='' \
        FLEET_BUDGET_CREDS="${WORK}/fake-creds.json" \
        FLEET_BUDGET_CACHE="${WORK}/cache.json" \
        FLEET_BUDGET_ENDPOINT="http://127.0.0.1:${PORT}$1" \
        FLEET_BUDGET_LOADAVG="${WORK}/loadavg" \
        FLEET_BUDGET_MEMINFO="${WORK}/meminfo" \
        FLEET_BUDGET_PRESSURE="${WORK}/pressure" \
        FLEET_BUDGET_CORES=4 \
        "${CHECK}" 2>&1)"
    RC=$?
}

rm -f "${WORK}/cache.json"
fetch /meter
matches 'case 13: a 200 is computed into one ok line' "${OUT}" '^ok 5h 10%/50 week-all 11%/60 week-fable 12%/60$'
equals  'case 13: exit code' "${RC}" 0
equals  'case 13: the cache is mode 600' "$(stat -c %a "${WORK}/cache.json" 2>/dev/null)" 600
equals  'case 13: the token is not in the output' "$(printf '%s' "${OUT}" | grep -cF "${DUMMY_TOKEN}")" 0
equals  'case 13: the token is not in the cache' "$(grep -cF "${DUMMY_TOKEN}" "${WORK}/cache.json" 2>/dev/null)" 0

# --- 14. the 401 path: hold, exit 1, stale cache untouched ---------------------
printf 'SENTINEL-not-json\n' >"${WORK}/cache.json"
touch -d '-2 hours' "${WORK}/cache.json"
fetch /denied
equals 'case 14: stdout is exactly the hold line' "${OUT}" 'hold meter unreadable (HTTP 401)'
equals 'case 14: exit code' "${RC}" 1
equals 'case 14: the stale cache is untouched' "$(cat "${WORK}/cache.json")" 'SENTINEL-not-json'
equals 'case 14: the token is not in the output' "$(printf '%s' "${OUT}" | grep -cF "${DUMMY_TOKEN}")" 0
kill "${SERVER_PID}" 2>/dev/null

if [ "${fails}" -eq 0 ]; then
    printf '\nfleet-budget-test: all checks passed\n'
    exit 0
fi
printf '\nfleet-budget-test: %s check(s) failed\n' "${fails}" >&2
exit 1
