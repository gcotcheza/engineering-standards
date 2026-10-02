#!/usr/bin/env bash
# Fails when VERSION and ENGINEERING-STANDARDS.md do not move together, judged
# against the merge base with origin/main. Why, and why loudly, in docs/DECISIONS.md.
#
#   scripts/version-text-pair.sh [repo-root]
#
# VERSION_PAIR_GIT is the git seam; check.sh hands it the gate's own CHECK_GIT.
# Each guard below is one deletable line, so T5's mutant is a line deletion.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
cd -- "${ROOT}" || exit 2
GIT=${VERSION_PAIR_GIT:-git}
BASE_REF='origin/main'
VERSION_FILE='VERSION'
TEXT_FILE='ENGINEERING-STANDARDS.md'

fail_base() {
    printf 'version-text-pair: %s is not in this clone, so the pair cannot be judged — fetch it. A missing base is never a pass.\n' \
        "${BASE_REF}" >&2
    exit 1
}

fail_pair() {
    printf 'version-text-pair: %s changed and %s did not, since %s — move both or neither.\n' "$1" "$2" "${base}" >&2
    exit 1
}

base="$("${GIT}" merge-base HEAD "${BASE_REF}" 2>/dev/null)"
[ -n "${base}" ] || fail_base

if ! changed="$("${GIT}" diff --name-only "${base}" --)"; then
    printf 'version-text-pair: git diff against %s failed, so nothing was judged.\n' "${base}" >&2
    exit 2
fi

moved() { grep -qxF -- "$1" <<<"${changed}"; }

version_moved=0
text_moved=0
moved "${VERSION_FILE}" && version_moved=1
moved "${TEXT_FILE}" && text_moved=1

[ "${version_moved}" = 1 ] && [ "${text_moved}" = 0 ] && fail_pair "${VERSION_FILE}" "${TEXT_FILE}"
[ "${text_moved}" = 1 ] && [ "${version_moved}" = 0 ] && fail_pair "${TEXT_FILE}" "${VERSION_FILE}"

printf 'version-text-pair: ok (%s and %s moved together or not at all since %s)\n' \
    "${VERSION_FILE}" "${TEXT_FILE}" "${base}"
exit 0
