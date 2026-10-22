#!/usr/bin/env bash
# Holds W4's closing line and its word-count sed together: the sed, read out of
# the standard, must strip exactly that line and count only the prose.
# W4_TEXT points at a scratch copy of the standard for the red proofs.
#
#   scripts/w4-closing-line-test.sh
#   W4_TEXT=/path/mutant.md scripts/w4-closing-line-test.sh   the red proofs
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEXT="${W4_TEXT:-${SCRIPT_DIR}/../ENGINEERING-STANDARDS.md}"
CLOSING='Technical detail: commits and docs/decisions/.'

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

stated=$(grep -oE 'one closing line: \*[^*]+\*' "${TEXT}" | sed -E 's/^one closing line: \*(.*)\*$/\1/')
equals 'the closing line W4 states' "${stated}" "${CLOSING}"

sed_cmd=$(grep -oE "\`sed -e '[^\`]+' <body-file> \| wc -w\`" "${TEXT}" | head -n 1)
mapfile -t exprs < <(grep -oE -- "-e '[^']+'" <<<"${sed_cmd}" | sed -E "s/^-e '(.*)'\$/\\1/")
equals 'the sed W4 states has three expressions' "${#exprs[@]}" 3

printf '## What changed\nOne two three.\n## Why\nFour five.\n%s\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\nfooter words here\n' \
    "${CLOSING}" >"${WORK}/body.md"
args=()
for e in "${exprs[@]}"; do args+=(-e "$e"); done
equals 'the sed counts the prose only' "$(sed "${args[@]}" "${WORK}/body.md" | wc -w)" 5
equals 'the sed leaves no closing line' "$(sed "${args[@]}" "${WORK}/body.md" | grep -cxF -- "${CLOSING}")" 0
printf 'Prose that mentions %s in passing.\n' "${CLOSING}" >"${WORK}/prose.md"
equals 'the sed keeps prose that only mentions it' "$(sed "${args[@]}" "${WORK}/prose.md" | wc -w)" 10

if [ "${fails}" -gt 0 ]; then printf '%s failure(s)\n' "${fails}" >&2; exit 1; fi
printf 'w4-closing-line-test: all cases passed\n'
