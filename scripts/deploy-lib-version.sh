#!/usr/bin/env bash
# Fails when a file under scripts/lib/deploy/ changed in HEAD and the lib's VERSION did not rise above
# both the merge base's and origin/main's, so one version names one tree. decision: deploy-lib-version-names-one-tree
#
#   scripts/deploy-lib-version.sh [repo-root]
#
# Exit 0 ok, 1 a finding, 2 nothing could be judged (no origin/main, no merge base, a git call failed).
# DEPLOY_LIB_VERSION_GIT is the git seam; check.sh hands it the gate's own CHECK_GIT.
# Each guard below is one deletable line, so T5's mutant is a line deletion.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
GIT=${DEPLOY_LIB_VERSION_GIT:-git}
BASE_REF='origin/main'
LIB_DIR='scripts/lib/deploy'
VERSION_FILE="${LIB_DIR}/VERSION"
VERSION_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}(\.[0-9]+)?$'

unjudged() {
    printf 'deploy-lib-version: %s, so nothing was judged.\n' "$1" >&2
    exit 2
}

finding() {
    printf 'deploy-lib-version: %s — one version must name one tree.\n' "$1" >&2
    exit 1
}

cd -- "${ROOT}" 2>/dev/null || unjudged "${ROOT} could not be entered"
"${GIT}" rev-parse -q --verify "${BASE_REF}^{commit}" >/dev/null || unjudged "${BASE_REF} is not in this clone (fetch it)"
base="$("${GIT}" merge-base HEAD "${BASE_REF}" 2>/dev/null)" || unjudged "HEAD and ${BASE_REF} have no merge base (a shallow clone?)"

changed="$("${GIT}" diff --no-renames --name-only "${base}" HEAD --)" || unjudged "the changed-file comparison against ${base} failed"

lib_moved="$(grep -E "^${LIB_DIR}/" <<<"${changed}" | grep -vxF -m1 -- "${VERSION_FILE}")"
version_moved=0
grep -qxF -- "${VERSION_FILE}" <<<"${changed}" && version_moved=1

[ -n "${lib_moved}" ] && [ "${version_moved}" = 0 ] && finding "${lib_moved} changed and ${VERSION_FILE} did not, since ${base}"

if [ "${version_moved}" = 1 ]; then
    new="$("${GIT}" show "HEAD:${VERSION_FILE}")" || unjudged "${VERSION_FILE} could not be read at HEAD"
    old="$("${GIT}" show "${base}:${VERSION_FILE}")" || unjudged "${VERSION_FILE} could not be read at ${base}"
    tip="$("${GIT}" show "${BASE_REF}:${VERSION_FILE}")" || unjudged "${VERSION_FILE} could not be read at ${BASE_REF}"
    [[ ${new} =~ ${VERSION_RE} ]] || finding "${VERSION_FILE} reads [${new//$'\n'/\\n}], not one YYYY-MM-DD or YYYY-MM-DD.N line"
    [ "${new}" != "${old}" ] || finding "${VERSION_FILE} still reads ${old}, as at ${base}"
    [ "${new}" != "${tip}" ] || finding "${VERSION_FILE} reads ${tip}, which ${BASE_REF} already names"
    [ "$(printf '%s\n%s\n%s\n' "${old}" "${tip}" "${new}" | sort -V | tail -1)" = "${new}" ] || finding "${VERSION_FILE} went to ${new}, not above ${old} (merge base) and ${tip} (${BASE_REF})"
fi

printf 'deploy-lib-version: ok (no file under %s changed without %s rising since %s)\n' "${LIB_DIR}" "${VERSION_FILE}" "${base}"
exit 0
