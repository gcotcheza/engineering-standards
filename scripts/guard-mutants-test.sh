#!/usr/bin/env bash
# Drives the real scripts/guard-mutants.sh over a fixture guard script in a temp dir: no network, no git.
# GUARD_MUTANTS_SH points at a scratch copy for the red proofs.
#
#   scripts/guard-mutants-test.sh
#   GUARD_MUTANTS_SH=/path/to/mutant.sh scripts/guard-mutants-test.sh   the red proofs
# Fixture lines and cases stay single-quoted on purpose: they are the target's and the case's text.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${GUARD_MUTANTS_SH:-${SCRIPT_DIR}/guard-mutants.sh}"

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
matches() { if printf '%s' "$2" | grep -qE -- "$3"; then pass "$1"; else fail "$1 — [$2] does not match /$3/"; fi; }
lacks() { if printf '%s' "$2" | grep -qE -- "$3"; then fail "$1 — [$2] matches /$3/"; else pass "$1"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
TARGET=${WORK}/greet.sh
TABLE=${WORK}/mutants.table

GUARD='[ -n "${1:-}" ] || { echo "STOP: no name given" >&2; exit 1; }'
GREET='echo "hello ${1:-nobody}"'
DUP="printf 'done\\n'"
printf '%s\n' '#!/usr/bin/env bash' 'set -u' "${GUARD}" "${GREET}" "${DUP}" "${DUP}" >"${TARGET}"
cp -p -- "${TARGET}" "${WORK}/greet.sh.before"
REFUSES='! bash "$MUTANT_TARGET"'
GREETS='bash "$MUTANT_TARGET" Ann'
CALLER=${WORK}/caller
mkdir -- "${CALLER}"

run() {
    printf '%s\n' "$@" >"${TABLE}"
    OUT="$(cd -- "${CALLER}" && bash "${RUNNER}" "${TARGET}" "${TABLE}" 2>&1)"
    RC=$?
}

# --- 1. a real guard, deleted and rewritten: both mutants go red -> exit 0 ------
run "G1@@${REFUSES}@@${GUARD}@@" "G2@@${REFUSES}@@${GUARD}@@true"
matches 'case 1: the deleted guard is red' "${OUT}" '^MUTANT G1: red \(case exit 1\)'
matches 'case 1: the rewritten guard is red' "${OUT}" '^MUTANT G2: red \(case exit 1\)'
matches 'case 1: a red mutant shows its case last line' "${OUT}" '^    last line: done$'
matches 'case 1: the summary counts both red' "${OUT}" '^guard mutants: 2, 2 red, 0 survived, 0 do not parse, 0 timed out$'
equals  'case 1: exit code' "${RC}" 0

# --- 2. a mutant whose case stays green -> the runner fails, naming it ----------
run "G1@@${REFUSES}@@${GUARD}@@" "S1@@${REFUSES}@@${GREET}@@echo \"hi \${1:-nobody}\""
matches 'case 2: the green mutant is named' "${OUT}" '^MUTANT S1: SURVIVED, its case stayed green'
matches 'case 2: the red one still counts' "${OUT}" '^MUTANT G1: red'
matches 'case 2: the summary counts the survivor' "${OUT}" '^guard mutants: 2, 1 red, 1 survived, 0 do not parse, 0 timed out$'
equals  'case 2: exit code' "${RC}" 1

# --- 3. a line that matches nothing -> refused before any case runs -------------
run "G1@@${REFUSES}@@${GUARD}@@" "N1@@${REFUSES}@@echo \"goodbye \$1\"@@"
matches 'case 3: the non-matching row is refused' "${OUT}" '^guard-mutants: REFUSED mutant N1: its line matches 0 lines'
lacks   'case 3: no mutant ran' "${OUT}" '^MUTANT '
equals  'case 3: exit code' "${RC}" 2

# --- 4. a line that matches twice -> refused ------------------------------------
run "D1@@${REFUSES}@@${DUP}@@"
matches 'case 4: the twice-matching row is refused' "${OUT}" '^guard-mutants: REFUSED mutant D1: its line matches 2 lines'
lacks   'case 4: no mutant ran' "${OUT}" '^MUTANT '
equals  'case 4: exit code' "${RC}" 2

# --- 5. a case that is red on the unmutated original -> refused -----------------
run "G1@@${REFUSES}@@${GUARD}@@" "R1@@bash \"\$MUTANT_TARGET\"@@${GUARD}@@"
matches 'case 5: the red original is refused' "${OUT}" '^guard-mutants: REFUSED mutant R1: its case is red \(exit 1\) on the unmutated original'
lacks   'case 5: no mutant ran' "${OUT}" '^MUTANT '
equals  'case 5: exit code' "${RC}" 2

# --- 6. a row that is not four fields, and a replacement that changes nothing ---
run "B1@@${REFUSES}@@${GUARD}"
matches 'case 6: a three-field row is refused' "${OUT}" '^guard-mutants: REFUSED table line 1 is not id@@case@@exact line@@replacement'
equals  'case 6: exit code' "${RC}" 2
run "B2@@${REFUSES}@@${GUARD}@@${GUARD}"
matches 'case 6: a no-op replacement is refused' "${OUT}" '^guard-mutants: REFUSED mutant B2: the replacement is the line itself'
equals  'case 6: exit code, no-op' "${RC}" 2

# --- 7. ids, an empty line to change, an empty table, and the arguments ---------
run "a/b@@${REFUSES}@@${GUARD}@@"
matches 'case 7: an id that is not a plain name is refused' "${OUT}" '^guard-mutants: REFUSED table line 1: the id must be'
equals  'case 7: exit code, id' "${RC}" 2
run "G1@@${REFUSES}@@${GUARD}@@" "G1@@${REFUSES}@@${GREET}@@"
matches 'case 7: an id used twice is refused' "${OUT}" '^guard-mutants: REFUSED table line 2: the id G1 is used twice'
equals  'case 7: exit code, twice' "${RC}" 2
run "E1@@${REFUSES}@@@@x"
matches 'case 7: an empty line to change is refused' "${OUT}" '^guard-mutants: REFUSED mutant E1: no line to change is named'
equals  'case 7: exit code, empty line' "${RC}" 2
run '' '# only a comment'
matches 'case 7: an empty table is refused' "${OUT}" '^guard-mutants: REFUSED the table names no mutant'
equals  'case 7: exit code, empty table' "${RC}" 2
OUT="$(bash "${RUNNER}" "${WORK}/absent.sh" "${TABLE}" 2>&1)"; RC=$?
matches 'case 7: a missing target is refused' "${OUT}" '^guard-mutants: REFUSED the target is not a regular file'
equals  'case 7: exit code, target' "${RC}" 2
OUT="$(bash "${RUNNER}" "${TARGET}" "${WORK}/absent.table" 2>&1)"; RC=$?
matches 'case 7: a missing table is refused' "${OUT}" '^guard-mutants: REFUSED the table is not a regular file'
equals  'case 7: exit code, table' "${RC}" 2
OUT="$(bash "${RUNNER}" "${TARGET}" 2>&1)"; RC=$?
matches 'case 7: one argument is a usage error' "${OUT}" '^usage: guard-mutants.sh <target> <table>'
equals  'case 7: exit code, usage' "${RC}" 2

# --- 8. the target itself was never written ---------------------------------------
if cmp -s -- "${WORK}/greet.sh.before" "${TARGET}"; then pass 'case 8: the target is unchanged'; else fail 'case 8: the runner wrote the target'; fi

# --- 9. a mutant that does not parse is refused, not counted red -------------------
run "P1@@${GREETS}@@${GREET}@@echo \"hello \${1"
matches 'case 9: the unparsable mutant is refused' "${OUT}" '^MUTANT P1: REFUSED, does not parse'
lacks   'case 9: it is not counted red' "${OUT}" '^MUTANT P1: red'
matches 'case 9: the summary counts it' "${OUT}" '^guard mutants: 1, 0 red, 0 survived, 1 do not parse, 0 timed out$'
equals  'case 9: exit code' "${RC}" 1

# --- 10. each case runs in its own fresh directory, never the caller's ------------
STATEFUL='[ ! -e state ] && : >state && bash "$MUTANT_TARGET" Ann'
run "F1@@${STATEFUL}@@${GREET}@@echo \"hi \${1:-nobody}\""
matches 'case 10: state left by the original cannot fake red' "${OUT}" '^MUTANT F1: SURVIVED'
equals  'case 10: exit code' "${RC}" 1
if [ -e "${CALLER}/state" ]; then fail 'case 10: a case wrote into the caller cwd'; else pass 'case 10: the caller cwd is untouched'; fi

# --- 11. a case over its time limit is a failure, not red ---------------------------
GUARD_MUTANTS_TIMEOUT=0.2 run "T1@@${GREETS}@@${GREET}@@sleep 4"
matches 'case 11: the slow mutant is named' "${OUT}" '^MUTANT T1: TIMED OUT after 0.2s'
matches 'case 11: the summary counts it' "${OUT}" '^guard mutants: 1, 0 red, 0 survived, 0 do not parse, 1 timed out$'
equals  'case 11: exit code' "${RC}" 1
GUARD_MUTANTS_TIMEOUT=0.2 run "O1@@sleep 4@@${GUARD}@@"
matches 'case 11: a case slow on the original is refused' "${OUT}" '^guard-mutants: REFUSED mutant O1: its case timed out after 0.2s on the unmutated original'
equals  'case 11: exit code, slow original' "${RC}" 2
GUARD_MUTANTS_TIMEOUT=0 run "G1@@${REFUSES}@@${GUARD}@@"
matches 'case 11: a time limit of 0 is refused' "${OUT}" '^guard-mutants: REFUSED GUARD_MUTANTS_TIMEOUT'
equals  'case 11: exit code, limit' "${RC}" 2

# --- 12. TERM and HUP stop the running case and remove the runner's temp dir --------
mkdir -- "${WORK}/tmp"
PIDFILE=${WORK}/case.pid
printf '%s\n' "Z1@@${GREETS}@@${GREET}@@echo \$\$ >${PIDFILE}; sleep 20" >"${TABLE}"
for sig in TERM HUP; do
    rm -f -- "${PIDFILE:?}"
    TMPDIR=${WORK}/tmp bash "${RUNNER}" "${TARGET}" "${TABLE}" >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 50); do [ -s "${PIDFILE}" ] && break; sleep 0.1; done
    kill -"${sig}" "${pid}"
    { wait "${pid}"; } 2>/dev/null
    left=$(find "${WORK}/tmp" -mindepth 1 | wc -l)
    equals "case 12: temp paths left after ${sig}" "${left}" 0
    case_pid=$(cat -- "${PIDFILE}" 2>/dev/null)
    for _ in $(seq 20); do kill -0 "${case_pid:-0}" 2>/dev/null || break; sleep 0.1; done
    if [ -n "${case_pid}" ] && ! kill -0 "${case_pid}" 2>/dev/null; then pass "case 12: the case is stopped after ${sig}"; else fail "case 12: the case [${case_pid}] still runs after ${sig}"; fi
done

if [ "${fails}" -eq 0 ]; then
    printf 'guard-mutants-test: all cases passed\n'
    exit 0
fi
printf 'guard-mutants-test: %s check(s) failed\n' "${fails}" >&2
exit 1
