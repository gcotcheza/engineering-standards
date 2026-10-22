#!/usr/bin/env bash
# W7's check: decisions are one file each in docs/decisions/, rolled into
# docs/DECISIONS.md by the change that adds the 10th. Read-only. decision: decisions-are-one-file-each
#
#   scripts/decisions-check.sh <repo-root>
#
# Exit 0 clean, 1 with one line per finding, 2 when nothing could be judged.
# DECISIONS_GIT is the git seam, DECISIONS_BASE_REF the main it compares against.
# Each guard below is one deletable line, so T5's mutant is a line deletion.
set -uo pipefail

ROOT="${1:?usage: decisions-check.sh <repo-root>}"
cd -- "${ROOT}" || exit 2
GIT=${DECISIONS_GIT:-git}
BASE_REF=${DECISIONS_BASE_REF:-origin/main}
LOG='docs/DECISIONS.md'
DIR='docs/decisions'
LIMIT=10
HEADER='> Newer decisions are one file each in docs/decisions/, until the change that adds the 10th folds them in at the bottom of this file (W7).'
SLUG='[a-z0-9]+(-[a-z0-9]+)+'
NAME_RE="^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-(${SLUG})\\.md\$"
REBASE='rebase onto main and re-run decisions-rollup.sh'

findings=0
finding() { printf 'decisions-check: %s\n' "$*" >&2; findings=$((findings + 1)); }

"${GIT}" rev-parse --git-dir >/dev/null 2>&1 || { printf 'decisions-check: %s is not a git work tree, so nothing was judged.\n' "${ROOT}" >&2; exit 2; }

declare -A owner=()
files=()
if [ -d "${DIR}" ]; then
    for f in "${DIR}"/* "${DIR}"/.[!.]*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        base=${f#"${DIR}/"}
        [[ ${base} =~ ${NAME_RE} ]] || { finding "${f}: not a decision file name (YYYY-MM-DD-HHMM-<slug>.md)"; continue; }
        if [ ! -f "$f" ] || [ -L "$f" ]; then finding "${f}: not a plain file"; continue; fi
        slug=${BASH_REMATCH[1]}
        files+=("${f}")
        head -n 1 -- "$f" | grep -qE '^# [^[:space:]]' || finding "${f}:1: line 1 is not '# <Title>'"
        [ -z "$(sed -n 2p -- "$f")" ] || finding "${f}:2: line 2 is not blank"
        [ -n "$(sed -n 3p -- "$f")" ] || finding "${f}:3: no prose after the title"
        [ -z "${owner[${slug}]:-}" ] || finding "slug ${slug} is used twice: ${owner[${slug}]} and ${f}"
        owner[${slug}]=${f}
    done
fi
[ "${#files[@]}" -lt "${LIMIT}" ] || finding "${#files[@]} unrolled decisions: run decisions-rollup.sh in this change"

declare -A rolled=()
if [ -f "${LOG}" ]; then
    while IFS=: read -r n slug; do
        slug=${slug#'### '}
        [ -z "${rolled[${slug}]:-}" ] || finding "${LOG}:${n}: ### ${slug} is rolled up twice (line ${rolled[${slug}]}): ${REBASE}"
        [ -z "${owner[${slug}]:-}" ] || finding "${LOG}:${n}: ### ${slug} is rolled up and ${owner[${slug}]} still exists: ${REBASE}"
        rolled[${slug}]=${n}
    done < <(grep -nE "^### ${SLUG}\$" -- "${LOG}")
fi

[ "${#files[@]}" -eq 0 ] || head -n 10 -- "${LOG}" 2>/dev/null | grep -qxF -- "${HEADER}" || finding "${LOG}: ${DIR}/ holds decisions, so its first 10 lines must carry: ${HEADER}"

if [ "${#rolled[@]}" -gt 0 ]; then
    if ! base=$("${GIT}" merge-base HEAD "${BASE_REF}" 2>/dev/null); then
        printf 'decisions-check: %s is not in this clone, so a roll-up cannot be compared with main — fetch it. A missing base is never a pass.\n' "${BASE_REF}" >&2
        exit 1
    fi
    while IFS= read -r p; do
        base_name=${p#"${DIR}/"}
        [[ ${base_name} =~ ${NAME_RE} ]] || continue
        slug=${BASH_REMATCH[1]}
        [ -n "${rolled[${slug}]:-}" ] || continue
        [ "$("${GIT}" rev-parse -q --verify "${BASE_REF}:${p}")" = "$("${GIT}" rev-parse -q --verify "${base}:${p}")" ] || finding "${LOG}:${rolled[${slug}]}: ### ${slug} is rolled up here and ${p} changed on main since this branch began: ${REBASE}"
    done < <("${GIT}" ls-tree --name-only "${BASE_REF}" -- "${DIR}/")
fi

resolves() { [ -n "${owner[$1]:-}" ] || [ -n "${rolled[$1]:-}" ]; }

if ! hits=$("${GIT}" grep -nIE -e "decision: \`?${SLUG}" -e "DECISIONS\\.md: \`?${SLUG}" -e '(DECISIONS\.md|decisions/[A-Za-z0-9._-]+\.md)(:L?[0-9]+|#L[0-9]+)' 2>&1); then
    [ -z "${hits}" ] || { printf 'decisions-check: git grep failed, so no pointer was judged: %s\n' "${hits}" >&2; exit 2; }
fi
while IFS= read -r hit; do
    [ -n "${hit}" ] || continue
    where=${hit%%:*}; rest=${hit#*:}; where="${where}:${rest%%:*}"; text=${rest#*:}
    while IFS= read -r ptr; do
        [ -n "${ptr}" ] || continue
        slug=${ptr##*: }; slug=${slug#\`}
        resolves "${slug}" || finding "${where}: pointer '${ptr}' resolves to no ${DIR}/*-${slug}.md and no ### ${slug} in ${LOG}"
    done < <(grep -oE "(decision|DECISIONS\\.md): \`?${SLUG}" <<<"${text}")
    while IFS= read -r ptr; do
        [ -z "${ptr}" ] || finding "${where}: line-number pointer '${ptr}': point at a slug (decision: <slug>) instead"
    done < <(grep -oE '(DECISIONS\.md|decisions/[A-Za-z0-9._-]+\.md)(:L?[0-9]+|#L[0-9]+)' <<<"${text}")
done <<<"${hits}"

[ "${findings}" -eq 0 ] || { printf 'decisions-check: %s finding(s)\n' "${findings}" >&2; exit 1; }
printf 'decisions-check: ok (%s unrolled, %s rolled up)\n' "${#files[@]}" "${#rolled[@]}"
exit 0
