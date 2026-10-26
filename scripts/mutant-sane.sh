#!/usr/bin/env bash
# T5: refuses a mutant that could go red for a reason other than the deleted or replaced line. decision: mutant-sane-before-red
#   scripts/mutant-sane.sh <original> <mutant> [<from>[-<to>]]                deletion
#   scripts/mutant-sane.sh <original> <mutant> <line> --replaced-with <text>  replacement
#   silent exit 0, or one REFUSED line and exit 1 (usage: 2)
# Blind to a deleted `exit` that still prints the grepped message: that is a weak assertion, not a broken
# mutant, so a suite asserts the rc as well as the text.
set -uo pipefail

usage() { printf 'usage: mutant-sane.sh <original> <mutant> [<from-line>[-<to-line>] | <line> --replaced-with <text>]\n' >&2; exit 2; }
refuse() { printf 'mutant-sane: REFUSED %s\n' "$*" >&2; exit 1; }

saved_on_disk() {
    case "$1" in /dev/* | /proc/*) return 1 ;; esac
    [ -f "$1" ]
}
is_shell_script() { head -n 1 -- "$1" | grep -qE '^#!.*[/[:space:]](ba)?sh([[:space:]]|$)'; }
with_line_replaced() {
    head -n "$(($1 - 1))" -- "${ORIGINAL}"
    printf '%s' "${REPLACEMENT}"
    sed -n -e "$1{s/.*//;p}" -- "${ORIGINAL}"
    tail -n "+$(($1 + 1))" -- "${ORIGINAL}"
}

[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || { [ "$#" -eq 5 ] && [ "$4" = --replaced-with ]; } || usage
ORIGINAL=$1
MUTANT=$2
RANGE=${3-}
REPLACEMENT=${5-}
[[ -z ${RANGE} || ${RANGE} =~ ^[1-9][0-9]*(-[1-9][0-9]*)?$ ]] || usage
[ "$#" -ne 5 ] || [[ ${RANGE} =~ ^[1-9][0-9]*$ && -n ${REPLACEMENT} ]] || usage
saved_on_disk "${ORIGINAL}" || usage

saved_on_disk "${MUTANT}" || refuse "the mutant is not a regular file saved on disk: ${MUTANT}"
! cmp -s -- "${ORIGINAL}" "${MUTANT}" || refuse "the mutant is byte-identical to the original"
original_mode=$(stat -L -c %a -- "${ORIGINAL}")
mutant_mode=$(stat -L -c %a -- "${MUTANT}")
[ "${mutant_mode}" = "${original_mode}" ] || refuse "the mutant's mode ${mutant_mode} differs from the original's ${original_mode}"
! is_shell_script "${ORIGINAL}" || bash -n -- "${MUTANT}" 2>/dev/null || refuse "the mutant of a shell script does not parse (bash -n)"

if [ -n "${REPLACEMENT}" ]; then
    total=$(awk 'END { print NR }' <"${ORIGINAL}")
    ((RANGE <= total)) || refuse "the line ${RANGE} is not inside the original's ${total} lines"
    with_line_replaced "${RANGE}" | cmp -s - "${MUTANT}" || refuse "the mutant is not the original with exactly line ${RANGE} replaced by the given text"
elif [ -n "${RANGE}" ]; then
    from=${RANGE%-*}
    to=${RANGE#*-}
    lines=$(wc -l <"${ORIGINAL}")
    ((from <= to && to <= lines)) || refuse "the range ${RANGE} is not inside the original's ${lines} lines"
    sed -e "${from},${to}d" -- "${ORIGINAL}" | cmp -s - "${MUTANT}" || refuse "the mutant is not the original with exactly line(s) ${RANGE} removed"
else
    changes=$(diff --unchanged-line-format= --old-line-format=- --new-line-format=+ -- "${ORIGINAL}" "${MUTANT}")
    [ "${changes}" = - ] || refuse "the mutant is not the original with exactly one line removed and nothing added or changed"
fi
exit 0
