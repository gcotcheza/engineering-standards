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

if [ "${fails}" -eq 0 ]; then
    printf '\nfleet-budget-test: all checks passed\n'
    exit 0
fi
printf '\nfleet-budget-test: %s check(s) failed\n' "${fails}" >&2
exit 1
