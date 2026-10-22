#!/usr/bin/env bash
# Folds every docs/decisions/ file into the bottom of docs/DECISIONS.md, in filename
# order, git-rms each by name, stages the log, then runs decisions-check.sh (W7).
# decision: decisions-are-one-file-each
#
#   scripts/decisions-rollup.sh <repo-root>
#
# Refuses, writing nothing, on uncommitted decision files, a file changed on main
# since the branch point, or a slug collision; a second run is a no-op.
# DECISIONS_GIT, DECISIONS_BASE_REF and DECISIONS_CHECK_SH are the seams.
# Each guard below is one deletable line, so T5's mutant is a line deletion.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:?usage: decisions-rollup.sh <repo-root>}"
cd -- "${ROOT}" || exit 2
GIT=${DECISIONS_GIT:-git}
BASE_REF=${DECISIONS_BASE_REF:-origin/main}
CHECK=${DECISIONS_CHECK_SH:-${SCRIPT_DIR}/decisions-check.sh}
LOG='docs/DECISIONS.md'
DIR='docs/decisions'
NAME_RE='^([0-9]{4}-[0-9]{2}-[0-9]{2})-[0-9]{4}-([a-z0-9]+(-[a-z0-9]+)+)\.md$'

refuse() { printf 'decisions-rollup: %s — nothing was written.\n' "$*" >&2; exit 1; }

export LC_ALL=C
files=()
[ -d "${DIR}" ] && for f in "${DIR}"/*; do [ -e "$f" ] && files+=("$f"); done
[ "${#files[@]}" -gt 0 ] || { printf 'decisions-rollup: %s/ holds no decisions; nothing to roll up.\n' "${DIR}"; exit 0; }

[ -f "${LOG}" ] || refuse "${LOG} does not exist"
dirty=$("${GIT}" status --porcelain -- "${LOG}" "${DIR}") || refuse "git status failed"
[ -z "${dirty}" ] || refuse "uncommitted changes: $(tr '\n' ' ' <<<"${dirty}")"
base=$("${GIT}" merge-base HEAD "${BASE_REF}" 2>/dev/null) || refuse "${BASE_REF} is not in this clone, so changes on main cannot be judged"
on_main=$("${GIT}" diff --no-ext-diff --name-only "${base}" "${BASE_REF}" -- "${DIR}") || refuse "git diff against ${BASE_REF} failed"

declare -A seen=()
dates=(); slugs=()
for f in "${files[@]}"; do
    [[ ${f#"${DIR}/"} =~ ${NAME_RE} ]] || refuse "${f} is not a decision file name (YYYY-MM-DD-HHMM-<slug>.md)"
    dates+=("${BASH_REMATCH[1]}"); slug=${BASH_REMATCH[2]}; slugs+=("${slug}")
    ! grep -qxF -- "${f}" <<<"${on_main}" || refuse "${f} changed on main since this branch began; rebase onto main first"
    [ -z "${seen[${slug}]:-}" ] || refuse "slug ${slug} is used by ${seen[${slug}]} and ${f}"
    ! grep -qxF -- "### ${slug}" "${LOG}" || refuse "slug ${slug} is already rolled up in ${LOG}"
    head -n 1 -- "$f" | grep -qE '^# [^[:space:]]' || refuse "${f}: line 1 is not '# <Title>'"
    seen[${slug}]=${f}
done

tmp=$(mktemp -p docs .DECISIONS.rollup.XXXXXX) || refuse "no temp file in docs/"
trap 'rm -f -- "${tmp}"' EXIT
{
    cat -- "${LOG}"
    [ -z "$(tail -c 1 -- "${LOG}")" ] || printf '\n'
    for i in "${!files[@]}"; do
        printf '\n### %s\n\n*%s — %s*\n\n' "${slugs[i]}" "${dates[i]}" "$(head -n 1 -- "${files[i]}" | sed 's/^# //')"
        tail -n +3 -- "${files[i]}"
    done
} >"${tmp}" || refuse "could not build the rolled-up ${LOG}"
chmod --reference="${LOG}" -- "${tmp}" || refuse "could not copy ${LOG}'s mode"
chown --reference="${LOG}" -- "${tmp}" || refuse "could not copy ${LOG}'s owner"
mv -- "${tmp}" "${LOG}" || refuse "could not replace ${LOG}"

for f in "${files[@]}"; do
    "${GIT}" rm -q -- "${f}" || { printf 'decisions-rollup: git rm %s failed after %s was written.\n' "${f}" "${LOG}" >&2; exit 1; }
done
"${GIT}" add -- "${LOG}" || { printf 'decisions-rollup: git add %s failed.\n' "${LOG}" >&2; exit 1; }
printf 'decisions-rollup: rolled %s decision(s) into %s\n' "${#files[@]}" "${LOG}"
bash "${CHECK}" "${PWD}"
