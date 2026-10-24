#!/usr/bin/env bash
# One throwaway git repo drives the real scripts/deploy-lib-version.sh. A case edits the tree and run()
# commits it on top of the fixture's main, since the check judges HEAD; reset_tree undoes it. No network,
# no credentials, nothing outside the temp dir. DEPLOY_LIB_VERSION_SH points at a scratch copy for the red proofs.
#
#   scripts/deploy-lib-version-test.sh
#   DEPLOY_LIB_VERSION_SH=/tmp/mutant.sh scripts/deploy-lib-version-test.sh   the red proofs
# shellcheck disable=SC2016  # the fake gits' tests are written for the fake, not expanded here
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${DEPLOY_LIB_VERSION_SH:-${SCRIPT_DIR}/deploy-lib-version.sh}"

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
matches() { if printf '%s' "$2" | grep -qE "$3"; then pass "$1"; else fail "$1 — [$2] does not match /$3/"; fi; }
no_ok() { equals "$1: no ok line is printed" "$(printf '%s' "${OUT}" | grep -c 'deploy-lib-version: ok')" 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="${WORK}/repo"
LIB="${REPO}/scripts/lib/deploy"

g() { git -C "${REPO}" "$@"; }
commit() { g add -A && g commit -q --allow-empty -m "$1"; }

git init -q -b main "${REPO}"
g config user.email 'fixture@example.invalid'
g config user.name 'Standards fixture'
mkdir -p "${LIB}"
printf '2026-01-01\n' >"${LIB}/VERSION"
printf 'summary\n' >"${LIB}/summary.sh"
printf 'suite\n' >"${LIB}/test.sh"
printf 'unrelated\n' >"${REPO}/README.md"
commit 'Added the fixture base for deploy-lib-version-test'
MAIN="$(g rev-parse HEAD)"

reset_tree() {
    g checkout -q main
    g reset -q --hard "${MAIN}"
    g clean -qfd
    g update-ref refs/remotes/origin/main "${MAIN}"
}

# run [git seam]: commit the case's edits, then judge HEAD.
run() {
    commit 'The case under test'
    OUT="$(DEPLOY_LIB_VERSION_GIT="${1:-git}" "${CHECK}" "${REPO}" 2>&1)"
    RC=$?
}

OK_RE='^deploy-lib-version: ok \(no file under scripts/lib/deploy changed without scripts/lib/deploy/VERSION rising since [0-9a-f]{40}\)$'
FINDING='^deploy-lib-version: .* — one version must name one tree\.$'

# --- 1. a lib file and a risen VERSION -> ok ------------------------------------
reset_tree
printf 'summary, edited\n' >"${LIB}/summary.sh"
printf '2026-02-02\n' >"${LIB}/VERSION"
run
matches 'case 1: a lib change with a risen VERSION is ok' "${OUT}" "${OK_RE}"
equals  'case 1: exit code' "${RC}" 0

# --- 2. an empty diff, and an unrelated file alone -> ok -----------------------
reset_tree
run
matches 'case 2: an empty diff is ok' "${OUT}" "${OK_RE}"
equals  'case 2: exit code' "${RC}" 0
reset_tree
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
matches 'case 4: a lib file alone fails, naming it' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/summary\.sh changed and scripts/lib/deploy/VERSION did not, since [0-9a-f]{40} — one version must name one tree\.$'
equals  'case 4: exit code' "${RC}" 1

# --- 4b. the lib's own test script counts as a lib file (card 547's change) ------
reset_tree
printf 'suite, edited\n' >"${LIB}/test.sh"
run
matches 'case 4b: the lib test script alone fails' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/test\.sh changed and scripts/lib/deploy/VERSION did not'
equals  'case 4b: exit code' "${RC}" 1

# --- 4c. a new lib file -> fails -------------------------------------------------
reset_tree
printf 'new\n' >"${LIB}/new.sh"
run
matches 'case 4c: a new lib file fails' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/new\.sh changed and scripts/lib/deploy/VERSION did not'
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
run "${WORK}/git-big-diff"
matches 'case 4d: a lib file fails in a large diff' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/ledger\.sh changed and scripts/lib/deploy/VERSION did not'
equals  'case 4d: exit code' "${RC}" 1

# --- 4e. a file renamed out of the lib still counts (rename detection is off) ---
reset_tree
g mv -- scripts/lib/deploy/summary.sh scripts/summary.sh
run
matches 'case 4e: a rename out of the lib fails, naming the old path' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/summary\.sh changed and scripts/lib/deploy/VERSION did not'
equals  'case 4e: exit code' "${RC}" 1

# --- 4f. the check judges HEAD: a committed lib change reverted on disk fails ----
reset_tree
printf 'summary, edited\n' >"${LIB}/summary.sh"
run
g checkout -q "${MAIN}" -- scripts/lib/deploy/summary.sh
OUT="$("${CHECK}" "${REPO}" 2>&1)"
RC=$?
matches 'case 4f: a committed change reverted on disk still fails' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/summary\.sh changed'
equals  'case 4f: exit code' "${RC}" 1

# --- 5. a VERSION that moved without rising -> fails ---------------------------
reset_tree
printf 'summary, edited\n' >"${LIB}/summary.sh"
printf '2025-12-31\n' >"${LIB}/VERSION"
run
matches 'case 5: a lower VERSION fails, naming both' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/VERSION went to 2025-12-31, not above 2026-01-01 \(merge base\) and 2026-01-01 \(origin/main\) — one version must name one tree\.$'
equals  'case 5: exit code' "${RC}" 1
reset_tree
printf '2026-01-01\n\n' >"${LIB}/VERSION"
run
matches 'case 5b: a VERSION edited to the same value fails' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/VERSION still reads 2026-01-01, as at [0-9a-f]{40}'
equals  'case 5b: exit code' "${RC}" 1

# --- 5c. serials compare as numbers: .9 -> .10 rises, .9 -> .8 does not ---------
reset_tree
printf '2026-01-01.9\n' >"${LIB}/VERSION"
commit 'Moved the fixture main to serial 9'
g update-ref refs/remotes/origin/main HEAD
printf '2026-01-01.10\n' >"${LIB}/VERSION"
run
matches 'case 5c: serial 9 to 10 is a rise' "${OUT}" "${OK_RE}"
equals  'case 5c: exit code' "${RC}" 0
g reset -q --hard HEAD~1
printf '2026-01-01.8\n' >"${LIB}/VERSION"
run
matches 'case 5d: serial 9 to 8 is not' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/VERSION went to 2026-01-01\.8, not above 2026-01-01\.9'
equals  'case 5d: exit code' "${RC}" 1

# --- 5e. not one dated line -> fails ---------------------------------------------
for bad in 'garbage' '2026-02-02 extra' $'2026-02-02\n2026-02-03'; do
    reset_tree
    printf '%s\n' "${bad}" >"${LIB}/VERSION"
    run
    matches "case 5e: a VERSION of [${bad}] fails" "${OUT}" "${FINDING}"
    matches "case 5e: and says why" "${OUT}" 'not one YYYY-MM-DD or YYYY-MM-DD\.N line'
    equals  "case 5e: exit code" "${RC}" 1
done

# --- 5f. two branches from one base bump to the same value: the later one fails ---
reset_tree
g checkout -q -b branch-b
printf 'summary, edited by B\n' >"${LIB}/summary.sh"
printf '2026-02-02\n' >"${LIB}/VERSION"
commit 'Branch B: a lib edit and a bump'
g checkout -q main
printf 'summary, edited by A\n' >"${LIB}/summary.sh"
printf '2026-02-02\n' >"${LIB}/VERSION"
commit 'Branch A: another lib edit, the same bump'
g update-ref refs/remotes/origin/main HEAD
g checkout -q branch-b
OUT="$("${CHECK}" "${REPO}" 2>&1)"
RC=$?
matches 'case 5f: B re-gated after A merged fails on main'"'"'s VERSION' "${OUT}" '^deploy-lib-version: scripts/lib/deploy/VERSION reads 2026-02-02, which origin/main already names — one version must name one tree\.$'
equals  'case 5f: exit code' "${RC}" 1
g checkout -q main; g branch -q -D branch-b

# --- 6. a git call that fails -> exit 2, nothing judged, no ok line -------------
# fake <name> <shell test on "$@">: a git that exits 128 when the test holds.
fake() {
    printf '#!/usr/bin/env bash\n%s && exit 128\nexec git "$@"\n' "$2" >"${WORK}/$1"
    chmod +x "${WORK}/$1"
}
fake diff-fails '[ "$1" = diff ]'
fake show-head-fails '[ "$1" = show ] && [[ $2 == HEAD:* ]]'
fake show-base-fails '[ "$1" = show ] && [[ $2 == [0-9a-f]*:* ]]'
fake show-main-fails '[ "$1" = show ] && [[ $2 == origin/main:* ]]'
fake merge-base-fails '[ "$1" = merge-base ]'
for f in diff-fails:'comparison against [0-9a-f]{40} failed' show-head-fails:'could not be read at HEAD' \
    show-base-fails:'could not be read at [0-9a-f]{40}' show-main-fails:'could not be read at origin/main' \
    merge-base-fails:'no merge base'; do
    reset_tree
    printf 'summary, edited\n' >"${LIB}/summary.sh"
    printf '2026-02-02\n' >"${LIB}/VERSION"
    run "${WORK}/${f%%:*}"
    matches "case 6 (${f%%:*}): the failure is named" "${OUT}" "^deploy-lib-version: .*${f#*:}.*, so nothing was judged\.\$"
    equals  "case 6 (${f%%:*}): exit code" "${RC}" 2
    no_ok   "case 6 (${f%%:*})"
done

# --- 7. no origin/main, a root that does not exist -> exit 2, never a pass ------
reset_tree
g update-ref -d refs/remotes/origin/main
run
matches 'case 7: a missing origin/main is named' "${OUT}" '^deploy-lib-version: origin/main is not in this clone \(fetch it\), so nothing was judged\.$'
equals  'case 7: exit code' "${RC}" 2
no_ok   'case 7'
OUT="$(cd -- "${REPO}" && "${CHECK}" "${WORK}/no-such-root" 2>&1)"
RC=$?
matches 'case 7b: a root that cannot be entered is named, never judged from the caller'"'"'s directory' "${OUT}" '^deploy-lib-version: .*/no-such-root could not be entered, so nothing was judged\.$'
equals  'case 7b: exit code' "${RC}" 2

if [ "${fails}" -eq 0 ]; then
    printf '\ndeploy-lib-version-test: all checks passed\n'
    exit 0
fi
printf '\ndeploy-lib-version-test: %s check(s) failed\n' "${fails}" >&2
exit 1
