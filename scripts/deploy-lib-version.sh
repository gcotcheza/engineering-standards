#!/usr/bin/env bash
# Fails when a file under scripts/lib/deploy/ changed and the lib's VERSION did not rise, judged
# against the merge base with origin/main, so one version names one tree. decision: deploy-lib-version-names-one-tree
#
#   scripts/deploy-lib-version.sh [repo-root]
#
# DEPLOY_LIB_VERSION_GIT is the git seam; check.sh hands it the gate's own CHECK_GIT.
# Each guard below is one deletable line, so T5's mutant is a line deletion.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
cd -- "${ROOT}" || exit 2
GIT=${DEPLOY_LIB_VERSION_GIT:-git}
BASE_REF='origin/main'
LIB_DIR='scripts/lib/deploy'
VERSION_FILE="${LIB_DIR}/VERSION"

fail_base() {
    printf 'deploy-lib-version: %s is not in this clone, so the lib version cannot be judged — fetch it. A missing base is never a pass.\n' \
        "${BASE_REF}" >&2
    exit 1
}

unjudged() {
    printf 'deploy-lib-version: %s, so nothing was judged.\n' "$1" >&2
    exit 2
}

base="$("${GIT}" merge-base HEAD "${BASE_REF}" 2>/dev/null)"
[ -n "${base}" ] || fail_base

changed="$("${GIT}" diff --name-only "${base}" --)" || unjudged "the changed-file comparison against ${base} failed"

fail_lib() {
    printf 'deploy-lib-version: %s changed and %s did not, since %s — bump it, or one version names two trees.\n' \
        "$1" "${VERSION_FILE}" "${base}" >&2
    exit 1
}

fail_rise() {
    printf 'deploy-lib-version: %s went from %s to %s since %s — a bump must rise, or one version names two trees.\n' \
        "${VERSION_FILE}" "${old}" "${new}" "${base}" >&2
    exit 1
}

lib_moved="$(grep -E "^${LIB_DIR}/" <<<"${changed}" | grep -vxF -m1 -- "${VERSION_FILE}")"
version_moved=0
grep -qxF -- "${VERSION_FILE}" <<<"${changed}" && version_moved=1

[ -n "${lib_moved}" ] && [ "${version_moved}" = 0 ] && fail_lib "${lib_moved}"

if [ "${version_moved}" = 1 ]; then
    old="$("${GIT}" show "${base}:${VERSION_FILE}")" || unjudged "${VERSION_FILE} could not be read at ${base}"
    new="$(head -1 -- "${VERSION_FILE}")" || unjudged "${VERSION_FILE} could not be read in this tree"
    [ "${new}" != "${old}" ] || fail_rise
    [ "$(printf '%s\n%s\n' "${old}" "${new}" | sort -V | tail -1)" = "${new}" ] || fail_rise
fi

printf 'deploy-lib-version: ok (no file under %s changed without %s rising since %s)\n' "${LIB_DIR}" "${VERSION_FILE}" "${base}"
exit 0
