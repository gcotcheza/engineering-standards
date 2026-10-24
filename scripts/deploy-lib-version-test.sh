#!/usr/bin/env bash
# One throwaway git repo drives the real scripts/deploy-lib-version.sh; a case edits the working
# tree, or commits on top of the fixture's main and is reset after, so no network, no credentials
# and nothing outside the temp dir. DEPLOY_LIB_VERSION_SH points at a scratch copy for the red proofs.
#
#   scripts/deploy-lib-version-test.sh
#   DEPLOY_LIB_VERSION_SH=/tmp/mutant.sh scripts/deploy-lib-version-test.sh   the red proofs
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${DEPLOY_LIB_VERSION_SH:-${SCRIPT_DIR}/deploy-lib-version.sh}"

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
matches() { if printf '%s' "$2" | grep -qE "$3"; then pass "$1"; else fail "$1 — [$2] does not match /$3/"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="${WORK}/repo"
LIB="${REPO}/scripts/lib/deploy"

g() { git -C "${REPO}" "$@"; }

git init -q -b main "${REPO}"
g config user.email 'fixture@example.invalid'
g config user.name 'Standards fixture'
mkdir -p "${LIB}"
printf '2026-01-01\n' >"${LIB}/VERSION"
printf 'summary\n' >"${LIB}/summary.sh"
printf 'suite\n' >"${LIB}/test.sh"
printf 'unrelated\n' >"${REPO}/README.md"
g add -A
g commit -q -m 'Added the fixture base for deploy-lib-version-test'
g update-ref refs/remotes/origin/main HEAD
MAIN="$(g rev-parse HEAD)"

reset_tree() {
    g update-ref refs/remotes/origin/main "${MAIN}"
    g reset -q --hard "${MAIN}"
    g clean -qfd
}

run() {
    OUT="$("${CHECK}" "${REPO}" 2>&1)"
    RC=$?
}

OK_RE='^deploy-lib-version: ok \(no file under scripts/lib/deploy changed without scripts/lib/deploy/VERSION rising since [0-9a-f]{40}\)$'

# --- 1. a lib file and a risen VERSION -> ok ------------------------------------
reset_tree
printf 'summary, edited\n' >"${LIB}/summary.sh"
printf '2026-02-02\n' >"${LIB}/VERSION"
run
matches 'case 1: a lib change with a risen VERSION is ok' "${OUT}" "${OK_RE}"
equals  'case 1: exit code' "${RC}" 0

# --- 2. an empty diff (main itself), and an unrelated file alone -> ok ---------
reset_tree
run
matches 'case 2: an empty diff is ok' "${OUT}" "${OK_RE}"
equals  'case 2: exit code' "${RC}" 0
printf 'unrelated, edited\n' >"${REPO}/README.md"
run
matches 'case 2b: an unrelated file alone is ok' "${OUT}" "${OK_RE}"
equals  'case 2b: exit code' "${RC}" 0

# --- 3. a risen VERSION alone -> ok ----------------------------------------------
reset_tree
printf '2026-01-01.1\n' >"${LIB}/VERSION"
run
matches 'case 3: a same-day serial alone is ok' "${OUT}" "${OK_RE}"
equals  'case 3: exit code' "${RC}" 0

# --- 4. a lib file without VERSION -> fails, naming the file --------------------
reset_tree
printf 'summary, edited\n' >"${LIB}/summary.sh"
run
matches 'case 4: a lib file alone fails, naming it' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/summary\.sh changed and scripts/lib/deploy/VERSION did not, since [0-9a-f]{40} — bump it, or one version names two trees\.$'
equals  'case 4: exit code' "${RC}" 1

# --- 4b. the lib's own test script counts as a lib file (card 547's change) ------
reset_tree
printf 'suite, edited\n' >"${LIB}/test.sh"
run
matches 'case 4b: the lib test script alone fails' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/test\.sh changed and scripts/lib/deploy/VERSION did not'
equals  'case 4b: exit code' "${RC}" 1

# --- 4c. a new lib file committed on the branch -> fails ------------------------
reset_tree
printf 'new\n' >"${LIB}/new.sh"
g add scripts/lib/deploy/new.sh
g commit -q -m 'Added a lib file without a bump'
run
matches 'case 4c: a committed new lib file fails' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/new\.sh changed and scripts/lib/deploy/VERSION did not'
equals  'case 4c: exit code' "${RC}" 1

# --- 4d. a lib file among a diff bigger than a pipe buffer -> still fails -------
reset_tree
cat >"${WORK}/git-big-diff" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = diff ] || exec git "$@"
for i in $(seq 1 900); do printf 'aa/a-path-long-enough-that-900-of-them-overflow-a-pipe-buffer-%s.txt\n' "$i"; done
printf 'scripts/lib/deploy/ledger.sh\n'
FAKE
chmod +x "${WORK}/git-big-diff"
OUT="$(DEPLOY_LIB_VERSION_GIT="${WORK}/git-big-diff" "${CHECK}" "${REPO}" 2>&1)"
RC=$?
matches 'case 4d: a lib file fails in a large diff' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/ledger\.sh changed and scripts/lib/deploy/VERSION did not'
equals  'case 4d: exit code' "${RC}" 1

# --- 5. a VERSION that moved without rising -> fails ---------------------------
reset_tree
printf 'summary, edited\n' >"${LIB}/summary.sh"
printf '2025-12-31\n' >"${LIB}/VERSION"
run
matches 'case 5: a lower VERSION fails, naming both' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/VERSION went from 2026-01-01 to 2025-12-31 since [0-9a-f]{40} — a bump must rise, or one version names two trees\.$'
equals  'case 5: exit code' "${RC}" 1
printf '2026-01-01\n\n' >"${LIB}/VERSION"
run
matches 'case 5b: a VERSION edited to the same value fails' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/VERSION went from 2026-01-01 to 2026-01-01 since'
equals  'case 5b: exit code' "${RC}" 1

# --- 5c. serials compare as numbers: .9 -> .10 rises, .9 -> .8 does not ---------
reset_tree
printf '2026-01-01.9\n' >"${LIB}/VERSION"
g commit -q -am 'Moved the fixture main to serial 9'
g update-ref refs/remotes/origin/main HEAD
printf '2026-01-01.10\n' >"${LIB}/VERSION"
run
matches 'case 5c: serial 9 to 10 is a rise' "${OUT}" "${OK_RE}"
equals  'case 5c: exit code' "${RC}" 0
printf '2026-01-01.8\n' >"${LIB}/VERSION"
run
matches 'case 5d: serial 9 to 8 is not' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/VERSION went from 2026-01-01\.9 to 2026-01-01\.8 since'
equals  'case 5d: exit code' "${RC}" 1

# --- 6. git diff or git show fails -> exit 2, nothing judged, no ok line --------
for verb in diff show; do
    reset_tree
    printf '2026-02-02\n' >"${LIB}/VERSION"
    cat >"${WORK}/git-${verb}-fails" <<FAKE
#!/usr/bin/env bash
[ "\$1" = ${verb} ] && exit 128
exec git "\$@"
FAKE
    chmod +x "${WORK}/git-${verb}-fails"
    OUT="$(DEPLOY_LIB_VERSION_GIT="${WORK}/git-${verb}-fails" "${CHECK}" "${REPO}" 2>&1)"
    RC=$?
    matches "case 6 (${verb}): the failure is named" "${OUT}" '^deploy-lib-version: .* (comparison against [0-9a-f]{40} failed|could not be read at [0-9a-f]{40}), so nothing was judged\.$'
    equals  "case 6 (${verb}): exit code" "${RC}" 2
    equals  "case 6 (${verb}): no ok line is printed" "$(printf '%s' "${OUT}" | grep -c 'deploy-lib-version: ok')" 0
done

# --- 7. no origin/main -> loud failure, never a silent pass (C9) ---------------
reset_tree
g update-ref -d refs/remotes/origin/main
run
matches 'case 7: a missing origin/main fails loudly' "${OUT}" '^deploy-lib-version: origin/main is not in this clone, so the lib version cannot be judged'
equals  'case 7: exit code' "${RC}" 1
equals  'case 7: no ok line is printed' "$(printf '%s' "${OUT}" | grep -c 'deploy-lib-version: ok')" 0

if [ "${fails}" -eq 0 ]; then
    printf '\ndeploy-lib-version-test: all checks passed\n'
    exit 0
fi
printf '\ndeploy-lib-version-test: %s check(s) failed\n' "${fails}" >&2
exit 1
