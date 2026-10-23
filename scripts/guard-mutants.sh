#!/usr/bin/env bash
# T5's guard-deletion sweep: each table row changes one exact line of the target in a copy on disk, and the
# row's case must pass on an unmutated copy and fail on the mutant. Why it is shaped this way: docs/DECISIONS.md.
#
#   scripts/guard-mutants.sh <target> <table>
#   a row is   id@@case@@exact line@@replacement   (an empty replacement deletes the line; blank and # lines skip)
#   a case is a bash command run with MUTANT_TARGET set to the copy: exit 0 is green, anything else is red
#   exit 0: every mutant went red; 1: a mutant survived; 2: usage, or a refused row or original
set -euo pipefail

usage() { printf 'usage: guard-mutants.sh <target> <table>\n' >&2; exit 2; }
refuse() { printf 'guard-mutants: REFUSED %s\n' "$*" >&2; exit 2; }

[ "$#" -eq 2 ] || usage
TARGET=$1
TABLE=$2
[ -f "${TARGET}" ] || refuse "the target is not a regular file: ${TARGET}"
[ -f "${TABLE}" ] || refuse "the table is not a regular file: ${TABLE}"
NAME=${TARGET##*/}
SEP='@@'

ids=() cases=() olds=() news=()
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
    ids+=("${id}"); cases+=("${case_cmd}"); olds+=("${old}"); news+=("${new}")
done <"${TABLE}"
[ "${#ids[@]}" -gt 0 ] || refuse "the table names no mutant: ${TABLE}"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/guard-mutants.XXXXXX")
trap 'rm -rf -- "${WORK:?}"' EXIT

declare -A original_green=()
for i in "${!ids[@]}"; do
    [ -z "${original_green[${cases[i]}]-}" ] || continue
    d=${WORK}/original-${ids[i]}
    mkdir -- "${d}"
    cp -p -- "${TARGET}" "${d}/${NAME}"
    rc=0
    MUTANT_TARGET=${d}/${NAME} bash -c "${cases[i]}" >"${d}/case.log" 2>&1 || rc=$?
    [ "${rc}" -eq 0 ] || refuse "mutant ${ids[i]}: its case is red (exit ${rc}) on the unmutated original, so a red mutant would prove nothing; last line: $(tail -n 1 -- "${d}/case.log")"
    original_green[${cases[i]}]=1
done

red=0 survived=0
for i in "${!ids[@]}"; do
    d=${WORK}/m-${ids[i]}
    mkdir -- "${d}"
    cp -p -- "${TARGET}" "${d}/${NAME}"
    OLD=${olds[i]} NEW=${news[i]} awk '($0 "") == ENVIRON["OLD"] { if (ENVIRON["NEW"] != "") print ENVIRON["NEW"]; next } { print }' \
        "${TARGET}" >"${d}/mutant"
    cat -- "${d}/mutant" >"${d}/${NAME}"
    rc=0
    MUTANT_TARGET=${d}/${NAME} bash -c "${cases[i]}" >"${d}/case.log" 2>&1 || rc=$?
    [ "${rc}" -ne 0 ] || { survived=$((survived + 1)); printf 'MUTANT %s: SURVIVED, its case stayed green with this line changed: %s\n' "${ids[i]}" "${olds[i]}"; continue; }
    red=$((red + 1))
    printf 'MUTANT %s: red (case exit %s): %s\n' "${ids[i]}" "${rc}" "${olds[i]}"
done

printf 'guard mutants: %s, %s red, %s survived\n' "${#ids[@]}" "${red}" "${survived}"
[ "${survived}" -eq 0 ] || exit 1
