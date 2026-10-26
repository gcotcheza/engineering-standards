#!/usr/bin/env bash
# W7's check: decisions are one file each in docs/decisions/, rolled into
# docs/DECISIONS.md by the change that adds the 10th. Read-only. decision: decisions-are-one-file-each
#
#   scripts/decisions-check.sh <repo-root>
#
# Findings: a pointer that resolves nowhere (every slug of a comma list), a line-number pointer,
# a duplicate slug, a bad file name, a symlink or directory, CRLF endings, a malformed file
# (# <Title>, blank line, prose), a missing opening line, 10 unrolled files, a roll-up that
# collided with another branch's. Pointers are judged in every tracked file, fenced blocks too.
# A project whose tracked .fleet/decisions-mode reads no-rollup skips only the fold and the opening
# line; any other value, a symlink, an untracked file or a NUL byte there judges nothing (2).
# Exit 0 clean, 1 with one line per finding, 2 when nothing could be judged.
# DECISIONS_GIT is the git seam (it may be several words: git-as <app> -C <tree>),
# DECISIONS_BASE_REF the main it compares against.
# Each guard below is one deletable line, so T5's mutant is a line deletion.
set -uo pipefail

[ -n "${1:-}" ] || { printf 'usage: decisions-check.sh <repo-root>\n' >&2; exit 2; }
ROOT=$1
cd -- "${ROOT}" || exit 2
read -ra GIT <<<"${DECISIONS_GIT:-git}"
BASE_REF=${DECISIONS_BASE_REF:-origin/main}
LOG='docs/DECISIONS.md'
DIR='docs/decisions'
LIMIT=10
HEADER='> Newer decisions are one file each in docs/decisions/, until the change that adds the 10th folds them in at the bottom of this file (W7).'
SLUG='[a-z0-9]+(-[a-z0-9]+)+'
NAME_RE="^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-(${SLUG})\\.md\$"
ITEM='`?'"${SLUG}"'`?'
LIST="${ITEM}((, and |, or |, | and | or )${ITEM})*,?"
POINTER='([Dd]ecisions?|DECISIONS(\.md)?)`?: '"${LIST}"
NUMBERED='(DECISIONS\.md|decisions/[A-Za-z0-9._-]+\.md)(:L?[0-9]+|#L[0-9]+)'
REBASE='rebase onto main and re-run decisions-rollup.sh'
MODE='.fleet/decisions-mode'

findings=0
finding() { printf 'decisions-check: %s\n' "$*" >&2; findings=$((findings + 1)); }

top=$("${GIT[@]}" rev-parse --show-toplevel 2>&1) || { printf 'decisions-check: %s is not a git work tree, so nothing was judged: %s\n' "${ROOT}" "${top}" >&2; exit 2; }
[ "${top}" = "$(pwd -P)" ] || { printf 'decisions-check: %s is not the top of its work tree (%s), so nothing was judged.\n' "${ROOT}" "${top}" >&2; exit 2; }

rollup=yes
if [ -e "${MODE}" ] || [ -L "${MODE}" ]; then
    [ ! -L "${MODE}" ] || { printf 'decisions-check: %s is a symlink, so nothing was judged\n' "${MODE}" >&2; exit 2; }
    "${GIT[@]}" ls-files --error-unmatch -- "${MODE}" >/dev/null 2>&1 || { printf 'decisions-check: %s is not tracked by git, so nothing was judged\n' "${MODE}" >&2; exit 2; }
    mode=$(cat -- "${MODE}" 2>&1) || { printf 'decisions-check: %s could not be read, so nothing was judged: %s\n' "${MODE}" "${mode}" >&2; exit 2; }
    [ "$(tr -d '\000' <"${MODE}" | wc -c)" -eq "$(wc -c <"${MODE}")" ] || { printf 'decisions-check: %s holds a NUL byte, so nothing was judged\n' "${MODE}" >&2; exit 2; }
    [ "${mode}" = 'no-rollup' ] || { printf 'decisions-check: %s must read exactly no-rollup (or not exist), so nothing was judged\n' "${MODE}" >&2; exit 2; }
    rollup=no
    printf 'decisions-check: %s is no-rollup: the project never folds, so the 10-file fold and the opening line are not checked; every other check runs\n' "${MODE}"
fi

declare -A owner=()
files=()
if [ -d "${DIR}" ]; then
    for f in "${DIR}"/* "${DIR}"/.[!.]*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        base=${f#"${DIR}/"}
        [ "${base}" != '.gitkeep' ] || continue
        [[ ${base} =~ ${NAME_RE} ]] || { finding "${f}: not a decision file name (YYYY-MM-DD-HHMM-<slug>.md)"; continue; }
        if [ ! -f "$f" ] || [ -L "$f" ]; then finding "${f}: not a plain file"; continue; fi
        slug=${BASH_REMATCH[1]}
        files+=("${f}")
        [ -z "${owner[${slug}]:-}" ] || finding "slug ${slug} is used twice: ${owner[${slug}]} and ${f}"
        owner[${slug}]=${f}
        ! grep -q $'\r' -- "$f" || { finding "${f}: CRLF line endings; save it with LF endings"; continue; }
        head -n 1 -- "$f" | grep -qE '^# [^[:space:]]' || finding "${f}:1: line 1 is not '# <Title>'"
        [ -z "$(sed -n 2p -- "$f")" ] || finding "${f}:2: line 2 is not blank"
        [ -n "$(sed -n 3p -- "$f")" ] || finding "${f}:3: no prose after the title"
    done
fi
[ "${rollup}" = no ] || [ "${#files[@]}" -lt "${LIMIT}" ] || finding "${#files[@]} unrolled decisions: run decisions-rollup.sh in this change"

declare -A rolled=()
if [ -f "${LOG}" ]; then
    while IFS=: read -r n slug; do
        slug=${slug#'### '}
        [ -z "${rolled[${slug}]:-}" ] || finding "${LOG}:${n}: ### ${slug} is rolled up twice (line ${rolled[${slug}]}): ${REBASE}"
        [ -z "${owner[${slug}]:-}" ] || finding "${LOG}:${n}: ### ${slug} is rolled up and ${owner[${slug}]} still exists: ${REBASE}"
        rolled[${slug}]=${n}
    done < <(grep -nE "^### ${SLUG}\$" -- "${LOG}")
fi

# decision: grep-q-reads-a-here-string-not-a-pipe
[ "${rollup}" = no ] || [ "${#files[@]}" -eq 0 ] || grep -qxF -- "${HEADER}" <<<"$(head -n 10 -- "${LOG}" 2>/dev/null)" || finding "${LOG}: ${DIR}/ holds decisions, so its first 10 lines must carry: ${HEADER}"

if [ "${#rolled[@]}" -gt 0 ]; then
    if ! base=$("${GIT[@]}" merge-base HEAD "${BASE_REF}" 2>/dev/null); then
        [ "${findings}" -eq 0 ] || { printf 'decisions-check: %s is not in this clone, so the roll-up and pointers were not judged — fetch it\ndecisions-check: %s finding(s)\n' "${BASE_REF}" "${findings}" >&2; exit 1; }
        printf 'decisions-check: %s is not in this clone, so nothing was judged: a roll-up cannot be compared with main — fetch it. A missing base is never a pass.\n' "${BASE_REF}" >&2
        exit 2
    fi
    while IFS= read -r p; do
        base_name=${p#"${DIR}/"}
        [[ ${base_name} =~ ${NAME_RE} ]] || continue
        slug=${BASH_REMATCH[1]}
        [ -n "${rolled[${slug}]:-}" ] || continue
        [ "$("${GIT[@]}" rev-parse -q --verify "${BASE_REF}:${p}")" = "$("${GIT[@]}" rev-parse -q --verify "${base}:${p}")" ] || finding "${LOG}:${rolled[${slug}]}: ### ${slug} is rolled up here and ${p} changed on main since this branch began: ${REBASE}"
    done < <("${GIT[@]}" ls-tree --name-only "${BASE_REF}" -- "${DIR}/")
fi

resolves() { [ -n "${owner[$1]:-}" ] || [ -n "${rolled[$1]:-}" ]; }
judge() {
    local slug
    while IFS= read -r slug; do
        resolves "${slug}" || finding "${1}: pointer to ${slug} ('${2}') resolves to no ${DIR}/*-${slug}.md and no ### ${slug} in ${LOG}"
    done < <(grep -oE "${SLUG}" <<<"${3}")
}

if ! hits=$("${GIT[@]}" grep -nIE -e "${POINTER}" -e "${NUMBERED}" 2>&1); then
    [ -z "${hits}" ] || { printf 'decisions-check: git grep failed, so no pointer was judged: %s\n' "${hits}" >&2; exit 2; }
fi
while IFS= read -r hit; do
    [ -n "${hit}" ] || continue
    path=${hit%%:*}; rest=${hit#*:}; ln=${rest%%:*}; text=${rest#*:}
    while IFS= read -r ptr; do
        [ -n "${ptr}" ] || continue
        judge "${path}:${ln}" "${ptr}" "${ptr#*: }"
        next=${ln}; after=${text#*"${ptr}"}; cont=${ptr}
        while [[ ${cont} == *, && -z ${after//[[:space:]]/} ]]; do
            next=$((next + 1)); line=$(sed -n "${next}p" -- "${path}")
            cont=$(grep -oE "^[[:space:]]*${LIST}" <<<"${line}") || break
            judge "${path}:${next}" "${cont#"${cont%%[![:space:]]*}"}" "${cont}"
            after=${line#"${cont}"}
        done
    done < <(grep -oE "${POINTER}" <<<"${text}")
    while IFS= read -r ptr; do
        [ -z "${ptr}" ] || finding "${path}:${ln}: line-number pointer '${ptr}': point at a slug (decision: <slug>) instead"
    done < <(grep -oE "${NUMBERED}" <<<"${text}")
done <<<"${hits}"

[ "${findings}" -eq 0 ] || { printf 'decisions-check: %s finding(s)\n' "${findings}" >&2; exit 1; }
printf 'decisions-check: ok (%s unrolled, %s rolled up)\n' "${#files[@]}" "${#rolled[@]}"
exit 0
