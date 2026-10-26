#!/usr/bin/env bash
# T5's guard-deletion sweep: each table row changes one exact line of the target in a copy on disk, and the
# row's case must pass on an unmutated copy and fail on the mutant. decision: one-guard-mutant-runner
#
#   scripts/guard-mutants.sh <target> <table>
#   a row is   id@@case@@exact line@@replacement   (an empty replacement deletes the line; blank and # lines skip)
#   a case is a bash command run in a fresh empty directory with MUTANT_TARGET set to the copy: exit 0 is
#   green, anything else is red, except a case over GUARD_MUTANTS_TIMEOUT seconds (default 120), a failure
#   every mutant is first checked by scripts/mutant-sane.sh (beside this script); one it refuses is never red
#   exit 0: every mutant went red; 1: a mutant survived, timed out, does not parse or was refused as insane; 2: usage, or a refused row or original
set -euo pipefail

usage() { printf 'usage: guard-mutants.sh <target> <table>\n' >&2; exit 2; }
refuse() { printf 'guard-mutants: REFUSED %s\n' "$*" >&2; exit 2; }

[ "$#" -eq 2 ] || usage
TARGET=$1
TABLE=$2
[ -f "${TARGET}" ] || refuse "the target is not a regular file: ${TARGET}"
[ -f "${TABLE}" ] || refuse "the table is not a regular file: ${TABLE}"
SANE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/mutant-sane.sh"
[ -f "${SANE}" ] || refuse "mutant-sane.sh is not beside this script: ${SANE}"
LIMIT=${GUARD_MUTANTS_TIMEOUT:-120}
[[ ${LIMIT} =~ ^(0\.[0-9]*[1-9][0-9]*|[1-9][0-9]*(\.[0-9]+)?)$ ]] || refuse "GUARD_MUTANTS_TIMEOUT is not a number of seconds above 0: ${LIMIT}"
NAME=${TARGET##*/}
SEP='@@'

ids=() cases=() olds=() news=() ats=()
declare -A seen=()
row_no=0
while IFS= read -r row || [ -n "${row}" ]; do
    row_no=$((row_no + 1))
    case "${row}" in '' | '#'*) continue ;; esac
    [[ ${row} == *"${SEP}"*"${SEP}"*"${SEP}"* ]] || refuse "table line ${row_no} is not id${SEP}case${SEP}exact line${SEP}replacement"
    id=${row%%"${SEP}"*}; rest=${row#*"${SEP}"}
    case_cmd=${rest%%"${SEP}"*}; rest=${rest#*"${SEP}"}
    old=${rest%%"${SEP}"*}; new=${rest#*"${SEP}"}
    [[ ${id} =~ ^[A-Za-z0-9._-]+$ ]] || refuse "table line ${row_no}: the id must be letters, digits, . _ or -: ${id}"
    [ -z "${seen[${id}]-}" ] || refuse "table line ${row_no}: the id ${id} is used twice"
    seen[${id}]=1
    [ -n "${old}" ] || refuse "mutant ${id}: no line to change is named"
    [ "${old}" != "${new}" ] || refuse "mutant ${id}: the replacement is the line itself, so nothing would change"
    hits=$(OLD=${old} awk '($0 "") == ENVIRON["OLD"] { n++ } END { print n + 0 }' "${TARGET}")
    [ "${hits}" -eq 1 ] || refuse "mutant ${id}: its line matches ${hits} lines of ${TARGET}, not exactly one: ${old}"
    at=$(OLD=${old} awk '($0 "") == ENVIRON["OLD"] { print NR; exit }' "${TARGET}")
    ids+=("${id}"); cases+=("${case_cmd}"); olds+=("${old}"); news+=("${new}"); ats+=("${at}")
done <"${TABLE}"
[ "${#ids[@]}" -gt 0 ] || refuse "the table names no mutant: ${TABLE}"

child=''
cleanup() {
    [ -z "${child}" ] || { kill -TERM "${child}" 2>/dev/null || true; wait "${child}" 2>/dev/null || true; }
    rm -rf -- "${WORK:?}"
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/guard-mutants.XXXXXX")
trap cleanup EXIT

# run_case <dir> <case>: sets rc; the case's cwd is a fresh <dir>/cwd, its output <dir>/case.log
run_case() {
    mkdir -- "$1/cwd"
    (
        cd -- "$1/cwd" || exit 125
        MUTANT_TARGET=$1/${NAME} exec timeout -k 5 "${LIMIT}" bash -c "$2"
    ) >"$1/case.log" 2>&1 &
    child=$!
    rc=0
    wait "${child}" || rc=$?
    child=''
}
timed_out() { [ "$1" -eq 124 ] || [ "$1" -eq 137 ]; }
last_line() { tail -n 1 -- "$1/case.log"; }

parse_check=1
bash -n -- "${TARGET}" 2>/dev/null || { parse_check=0; printf 'guard-mutants: the target is not bash, so mutants are not parse-checked\n'; }

declare -A original_green=()
for i in "${!ids[@]}"; do
    [ -z "${original_green[${cases[i]}]-}" ] || continue
    d=${WORK}/original-${ids[i]}
    mkdir -- "${d}"
    cp -p -- "${TARGET}" "${d}/${NAME}"
    run_case "${d}" "${cases[i]}"
    ! timed_out "${rc}" || refuse "mutant ${ids[i]}: its case timed out after ${LIMIT}s on the unmutated original"
    [ "${rc}" -eq 0 ] || refuse "mutant ${ids[i]}: its case is red (exit ${rc}) on the unmutated original, so a red mutant would prove nothing; last line: $(last_line "${d}")"
    original_green[${cases[i]}]=1
done

red=0 survived=0 unparsed=0 slow=0 insane=0
for i in "${!ids[@]}"; do
    d=${WORK}/m-${ids[i]}
    mkdir -- "${d}"
    cp -p -- "${TARGET}" "${d}/${NAME}"
    OLD=${olds[i]} NEW=${news[i]} awk '($0 "") == ENVIRON["OLD"] { if (ENVIRON["NEW"] != "") print ENVIRON["NEW"]; next } { print }' \
        "${TARGET}" >"${d}/mutant"
    cat -- "${d}/mutant" >"${d}/${NAME}"
    if [ "${parse_check}" -eq 1 ] && ! bash -n -- "${d}/${NAME}" 2>/dev/null; then
        unparsed=$((unparsed + 1)); printf 'MUTANT %s: REFUSED, does not parse: %s\n' "${ids[i]}" "${olds[i]}"; continue
    fi
    sane_args=("${TARGET}" "${d}/${NAME}" "${ats[i]}")
    [ -z "${news[i]}" ] || sane_args+=(--replaced-with "${news[i]}")
    if ! why=$(bash "${SANE}" "${sane_args[@]}" 2>&1); then
        insane=$((insane + 1)); printf 'MUTANT %s: REFUSED as insane (%s): %s\n' "${ids[i]}" "${why#mutant-sane: REFUSED }" "${olds[i]}"; continue
    fi
    run_case "${d}" "${cases[i]}"
    ! timed_out "${rc}" || { slow=$((slow + 1)); printf 'MUTANT %s: TIMED OUT after %ss, which is not red: %s\n' "${ids[i]}" "${LIMIT}" "${olds[i]}"; continue; }
    [ "${rc}" -ne 0 ] || { survived=$((survived + 1)); printf 'MUTANT %s: SURVIVED, its case stayed green with this line changed: %s\n' "${ids[i]}" "${olds[i]}"; continue; }
    red=$((red + 1))
    printf 'MUTANT %s: red (case exit %s): %s\n    last line: %s\n' "${ids[i]}" "${rc}" "${olds[i]}" "$(last_line "${d}")"
done

printf 'guard mutants: %s, %s red, %s survived, %s do not parse, %s timed out, %s refused as insane\n' "${#ids[@]}" "${red}" "${survived}" "${unparsed}" "${slow}" "${insane}"
[ "$((survived + unparsed + slow + insane))" -eq 0 ] || exit 1
