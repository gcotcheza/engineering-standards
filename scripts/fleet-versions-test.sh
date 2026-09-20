#!/usr/bin/env bash
# Fakes only: builds a temp canonical + temp project roots, drives the real
# scripts/fleet-versions.sh through its own seams (STANDARDS_CANONICAL,
# STANDARDS_ROOT, STANDARDS_PROJECTS). It never reads a real checkout, runs no
# docker, no gh. FLEET_VERSIONS_SH points it at a scratch copy for the red
# proofs; FLEET_VERSIONS_CANON_LIB overrides the seed for the canonical fake
# (default: this repo's own scripts/lib/deploy — read-only, never written).
#
#   scripts/fleet-versions-test.sh
#   FLEET_VERSIONS_SH=/tmp/mutant.sh scripts/fleet-versions-test.sh   the red proofs
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${FLEET_VERSIONS_SH:-${SCRIPT_DIR}/fleet-versions.sh}"
CANON_SRC="${FLEET_VERSIONS_CANON_LIB:-${SCRIPT_DIR}/lib/deploy}"

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
matches() { if printf '%s' "$2" | grep -qE "$3"; then pass "$1"; else fail "$1 — [$2] does not match /$3/"; fi; }
unmatches() { if printf '%s' "$2" | grep -qE "$3"; then fail "$1 — [$2] matches /$3/"; else pass "$1"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CANON="${WORK}/canon"
ROOT="${WORK}/projects"
mkdir -p "${CANON}/scripts/lib/deploy" "${ROOT}"

# --- 0. the canonical fake: a copy of the clone's scripts/lib/deploy -----------
cp "${CANON_SRC}"/*.sh "${CANON_SRC}/VERSION" "${CANON}/scripts/lib/deploy/"
LIB_VERSION="$(head -1 "${CANON_SRC}/VERSION")"
printf 'fake canonical standards\n' >"${CANON}/ENGINEERING-STANDARDS.md"
printf '2026-09-18\n' >"${CANON}/VERSION"
STANDARDS_HASH="$(sha256sum "${CANON}/ENGINEERING-STANDARDS.md" | cut -d' ' -f1)"

# Every fixture gets a canonical-matching docs/STANDARDS.md + symlink, so the
# EXISTING (docs) check reports ok for it too — only the new deploy-lib line
# is under test, and case 7 proves the existing line survives alongside it.
add_docs_ok() {
    local proj=$1
    mkdir -p "${proj}/docs" "${proj}/.claude/rules"
    printf '<!-- standards-version: 2026-09-18 · sha256: %s -->\n' "${STANDARDS_HASH}" >"${proj}/docs/STANDARDS.md"
    cat "${CANON}/ENGINEERING-STANDARDS.md" >>"${proj}/docs/STANDARDS.md"
    ln -s '../../docs/STANDARDS.md' "${proj}/.claude/rules/standards.md"
}

run() {
    OUT="$(STANDARDS_CANONICAL="${CANON}" STANDARDS_ROOT="${ROOT}" STANDARDS_PROJECTS="$1" "${CHECK}" 2>&1)"
    RC=$?
}

# --- 1. byte-identical copy -> ok ----------------------------------------------
mkdir -p "${ROOT}/p1/scripts/lib/deploy"
cp "${CANON}/scripts/lib/deploy/"* "${ROOT}/p1/scripts/lib/deploy/"
: >"${ROOT}/p1/scripts/deploy.sh"
add_docs_ok "${ROOT}/p1"
run p1
matches 'case 1: byte-identical copy reports ok' "${OUT}" "ok +p1 +\(deploy-lib ${LIB_VERSION}\)"
equals  'case 1: exit code' "${RC}" 0

# --- 2. one body byte changed, header NOT re-stamped -> DRIFTED ----------------
mkdir -p "${ROOT}/p2/scripts/lib/deploy"
cp "${CANON}/scripts/lib/deploy/"* "${ROOT}/p2/scripts/lib/deploy/"
printf '# one extra body byte\n' >>"${ROOT}/p2/scripts/lib/deploy/ledger.sh"
: >"${ROOT}/p2/scripts/deploy.sh"
add_docs_ok "${ROOT}/p2"
run p2
matches 'case 2: a changed body byte reports DRIFTED' "${OUT}" 'DRIFTED +p2 +\(ledger\.sh differs from canonical'
equals  'case 2: exit code' "${RC}" 1

# --- 3. body changed AND header re-stamped correctly -> DIVERGED --------------
# The case a project's own drift test cannot see: header is self-consistent and
# claims the current version, only the comparison against canonical catches it.
mkdir -p "${ROOT}/p3/scripts/lib/deploy"
cp "${CANON}/scripts/lib/deploy/"* "${ROOT}/p3/scripts/lib/deploy/"
f="${ROOT}/p3/scripts/lib/deploy/resolve.sh"
tail -n +2 "${f}" >"${f}.body"
printf '# one extra body byte\n' >>"${f}.body"
newhash="$(sha256sum "${f}.body" | cut -d' ' -f1)"
{ printf '# fleet-deploy-lib %s sha256:%s\n' "${LIB_VERSION}" "${newhash}"; cat "${f}.body"; } >"${f}"
rm -f "${f}.body"
: >"${ROOT}/p3/scripts/deploy.sh"
add_docs_ok "${ROOT}/p3"
run p3
matches 'case 3: a re-stamped header reports DIVERGED' "${OUT}" "DIVERGED +p3 +\(claims ${LIB_VERSION} but resolve\.sh differs from canonical"
equals  'case 3: exit code' "${RC}" 1

# --- 4. VERSION changed alone -> STALE -----------------------------------------
mkdir -p "${ROOT}/p4/scripts/lib/deploy"
cp "${CANON}/scripts/lib/deploy/"* "${ROOT}/p4/scripts/lib/deploy/"
printf '2020-01-01\n' >"${ROOT}/p4/scripts/lib/deploy/VERSION"
: >"${ROOT}/p4/scripts/deploy.sh"
add_docs_ok "${ROOT}/p4"
run p4
matches "case 4: a changed VERSION file reports STALE" "${OUT}" "STALE +p4 +\\(VERSION is '2020-01-01', canonical is '${LIB_VERSION}'\\)"
equals  'case 4: exit code' "${RC}" 1

# --- 5. deploy.sh present, no lib dir -> MISSING (failure) --------------------
mkdir -p "${ROOT}/p5/scripts"
: >"${ROOT}/p5/scripts/deploy.sh"
add_docs_ok "${ROOT}/p5"
run p5
matches 'case 5: deploy.sh with no lib dir reports MISSING' "${OUT}" 'MISSING +p5 +\(scripts/deploy\.sh present but no scripts/lib/deploy\)'
equals  'case 5: exit code' "${RC}" 1

# --- 6. no deploy.sh -> none, exit unaffected ----------------------------------
mkdir -p "${ROOT}/p6/scripts"
add_docs_ok "${ROOT}/p6"
run p6
matches 'case 6: no deploy.sh reports none' "${OUT}" 'none +p6 +\(no scripts/deploy\.sh'
equals  'case 6: none is not a failure — exit code' "${RC}" 0

# --- 7. the existing docs/STANDARDS.md line still prints alongside ours -------
mkdir -p "${ROOT}/p7/scripts/lib/deploy"
cp "${CANON}/scripts/lib/deploy/"* "${ROOT}/p7/scripts/lib/deploy/"
: >"${ROOT}/p7/scripts/deploy.sh"
add_docs_ok "${ROOT}/p7"
run p7
matches 'case 7: the existing (docs) line still prints' "${OUT}" 'ok +p7 +\(2026-09-18\)'
matches 'case 7: and the new deploy-lib line prints alongside it' "${OUT}" "ok +p7 +\(deploy-lib ${LIB_VERSION}\)"
equals  'case 7: exit code' "${RC}" 0

# --- 8. a canonical VERSION carrying a serial is accepted, not a fatal ---------
# The date-only validator made a second change in one day unreportable: every
# project vanished behind "canonical VERSION is not a date" (exit 2).
mkdir -p "${ROOT}/p8/scripts/lib/deploy"
cp "${CANON}/scripts/lib/deploy/"* "${ROOT}/p8/scripts/lib/deploy/"
: >"${ROOT}/p8/scripts/deploy.sh"
add_docs_ok "${ROOT}/p8"
printf '2026-09-18.2\n' >"${CANON}/VERSION"
printf '<!-- standards-version: 2026-09-18.2 · sha256: %s -->\n' "${STANDARDS_HASH}" >"${ROOT}/p8/docs/STANDARDS.md"
cat "${CANON}/ENGINEERING-STANDARDS.md" >>"${ROOT}/p8/docs/STANDARDS.md"
run p8
matches 'case 8: a serial canonical version reports ok' "${OUT}" 'ok +p8 +\(2026-09-18\.2\)'
equals  'case 8: exit code' "${RC}" 0

# --- 9. a canonical VERSION that is neither still refuses to report ------------
printf 'tuesday\n' >"${CANON}/VERSION"
run p8
matches 'case 9: a malformed canonical version is fatal' "${OUT}" "canonical VERSION is not a date: 'tuesday'"
equals  'case 9: exit code' "${RC}" 2
printf '2026-09-18\n' >"${CANON}/VERSION"

# --- 10. the canonical deploy-lib moved on -> STALE, not a local edit ---------
# Every vendored copy on the box read DRIFTED "(local edit ... or missing)" the
# day the canonical VERSION moved; a stale copy is self-consistent, just behind.
OLD_LIB_VERSION='2026-09-19'
mkdir -p "${ROOT}/p10/scripts/lib/deploy"
cp "${CANON}/scripts/lib/deploy/"* "${ROOT}/p10/scripts/lib/deploy/"
for lf in ledger resolve preflight summary; do
    f="${ROOT}/p10/scripts/lib/deploy/${lf}.sh"
    tail -n +2 "${f}" >"${f}.body"
    oldhash="$(sha256sum "${f}.body" | cut -d' ' -f1)"
    { printf '# fleet-deploy-lib %s sha256:%s\n' "${OLD_LIB_VERSION}" "${oldhash}"; cat "${f}.body"; } >"${f}"
    rm -f "${f}.body"
done
printf '%s\n' "${OLD_LIB_VERSION}" >"${ROOT}/p10/scripts/lib/deploy/VERSION"
: >"${ROOT}/p10/scripts/deploy.sh"
add_docs_ok "${ROOT}/p10"
run p10
matches 'case 10: a canonical that moved on reports STALE' "${OUT}" "STALE +p10 +\(deploy-lib ${OLD_LIB_VERSION}, canonical ${LIB_VERSION}\)"
equals  'case 10: exit code' "${RC}" 1

# --- 11. two failing rows on one project count once ---------------------------
mkdir -p "${ROOT}/p11/scripts/lib/deploy" "${ROOT}/p11/docs" "${ROOT}/p11/.claude/rules"
cp "${CANON}/scripts/lib/deploy/"* "${ROOT}/p11/scripts/lib/deploy/"
printf '# one extra body byte\n' >>"${ROOT}/p11/scripts/lib/deploy/ledger.sh"
: >"${ROOT}/p11/scripts/deploy.sh"
printf 'older canonical standards\n' >"${WORK}/p11-body"
OLD_STANDARDS_HASH="$(sha256sum "${WORK}/p11-body" | cut -d' ' -f1)"
printf '<!-- standards-version: 2026-09-01 · sha256: %s -->\n' "${OLD_STANDARDS_HASH}" >"${ROOT}/p11/docs/STANDARDS.md"
cat "${WORK}/p11-body" >>"${ROOT}/p11/docs/STANDARDS.md"
ln -s '../../docs/STANDARDS.md' "${ROOT}/p11/.claude/rules/standards.md"
run p11
matches 'case 11: the stale content row prints' "${OUT}" 'STALE +p11 +\(declared 2026-09-01, canonical 2026-09-18\)'
matches 'case 11: the drifted deploy-lib row prints too' "${OUT}" 'DRIFTED +p11 +\(ledger\.sh differs from canonical'
matches 'case 11: but the project is counted once' "${OUT}" 'fleet: 1 of 1 project\(s\) need attention'
equals  'case 11: exit code' "${RC}" 1

# --- 12. a repository under the root that is not on the list is named ---------
mkdir -p "${ROOT}/newbie/.git" "${ROOT}/x-staging/.git" "${ROOT}/y-worktrees/.git"
run p1
matches   'case 12: an unlisted repository is named' "${OUT}" 'unlisted: newbie'
unmatches 'case 12: a -staging directory is not' "${OUT}" 'x-staging'
unmatches 'case 12: nor is a -worktrees directory' "${OUT}" 'y-worktrees'
equals    'case 12: unlisted is attention — exit code' "${RC}" 1

if [ "${fails}" -eq 0 ]; then
    printf '\nfleet-versions-test: all checks passed\n'
    exit 0
fi
printf '\nfleet-versions-test: %s check(s) failed\n' "${fails}" >&2
exit 1
