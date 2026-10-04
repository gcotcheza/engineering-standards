#!/usr/bin/env bash
# One throwaway git repo drives the real scripts/version-text-pair.sh; every case
# after the fixture's single commit is a working-tree edit, so no network, no
# credentials and nothing outside the temp dir. VERSION_PAIR_SH points at a
# scratch copy for the red proofs.
#
#   scripts/version-text-pair-test.sh
#   VERSION_PAIR_SH=/tmp/mutant.sh scripts/version-text-pair-test.sh   the red proofs
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${VERSION_PAIR_SH:-${SCRIPT_DIR}/version-text-pair.sh}"

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
matches() { if printf '%s' "$2" | grep -qE "$3"; then pass "$1"; else fail "$1 — [$2] does not match /$3/"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="${WORK}/repo"

reset_tree() {
    printf '2026-01-01\n' >"${REPO}/VERSION"
    printf '# Standards\n\nR1. A rule.\n' >"${REPO}/ENGINEERING-STANDARDS.md"
    printf 'unrelated\n' >"${REPO}/README.md"
}

git init -q -b main "${REPO}"
git -C "${REPO}" config user.email 'fixture@example.invalid'
git -C "${REPO}" config user.name 'Standards fixture'
reset_tree
git -C "${REPO}" add VERSION ENGINEERING-STANDARDS.md README.md
git -C "${REPO}" commit -q -m 'Added the fixture base for version-text-pair-test'
git -C "${REPO}" update-ref refs/remotes/origin/main HEAD

run() {
    OUT="$("${CHECK}" "${REPO}" 2>&1)"
    RC=$?
}

# --- 1. both moved -> ok -------------------------------------------------------
reset_tree
printf '2026-02-02\n' >"${REPO}/VERSION"
printf '# Standards\n\nR1. A rule, reworded.\n' >"${REPO}/ENGINEERING-STANDARDS.md"
run
matches 'case 1: both moved is ok' "${OUT}" '^version-text-pair: ok \(VERSION and ENGINEERING-STANDARDS\.md moved together'
equals  'case 1: exit code' "${RC}" 0

# --- 2. neither moved (an empty diff, which is main itself) -> ok --------------
reset_tree
run
matches 'case 2: an empty diff is ok' "${OUT}" '^version-text-pair: ok \(VERSION and ENGINEERING-STANDARDS\.md moved together'
equals  'case 2: exit code' "${RC}" 0

# --- 2b. another file alone is not this guard's business -> ok -----------------
reset_tree
printf 'unrelated, edited\n' >"${REPO}/README.md"
run
matches 'case 2b: an unrelated file alone is ok' "${OUT}" '^version-text-pair: ok \('
equals  'case 2b: exit code' "${RC}" 0

# --- 3. only VERSION -> fails, naming VERSION ---------------------------------
reset_tree
printf '2026-02-02\n' >"${REPO}/VERSION"
run
matches 'case 3: only VERSION fails, naming VERSION' "${OUT}" '^version-text-pair: VERSION changed and ENGINEERING-STANDARDS\.md did not, since [0-9a-f]{40} — move both or neither\.$'
equals  'case 3: exit code' "${RC}" 1

# --- 4. only the text -> fails, naming the text -------------------------------
reset_tree
printf '# Standards\n\nR1. A rule, reworded.\n' >"${REPO}/ENGINEERING-STANDARDS.md"
run
matches 'case 4: only the text fails, naming the text' "${OUT}" '^version-text-pair: ENGINEERING-STANDARDS\.md changed and VERSION did not, since [0-9a-f]{40} — move both or neither\.$'
equals  'case 4: exit code' "${RC}" 1

# --- 4b. git diff itself fails -> exit 2, nothing judged, no ok line ----------
reset_tree
cat >"${WORK}/git-diff-fails" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = diff ] && exit 128
exec git "$@"
FAKE
chmod +x "${WORK}/git-diff-fails"
OUT="$(VERSION_PAIR_GIT="${WORK}/git-diff-fails" "${CHECK}" "${REPO}" 2>&1)"
RC=$?
matches 'case 4b: a failing comparison is named' "${OUT}" '^version-text-pair: the changed-file comparison against [0-9a-f]{40} failed, so nothing was judged\.$'
equals  'case 4b: exit code' "${RC}" 2
equals  'case 4b: no ok line is printed' "$(printf '%s' "${OUT}" | grep -c 'version-text-pair: ok')" 0

# --- 4c. only VERSION among a diff bigger than a pipe buffer -> still fails ---
reset_tree
cat >"${WORK}/git-big-diff" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = diff ] || exec git "$@"
printf 'VERSION\n'
for i in $(seq 1 900); do printf 'zz/a-path-long-enough-that-900-of-them-overflow-a-pipe-buffer-%s.txt\n' "$i"; done
FAKE
chmod +x "${WORK}/git-big-diff"
OUT="$(VERSION_PAIR_GIT="${WORK}/git-big-diff" "${CHECK}" "${REPO}" 2>&1)"
RC=$?
matches 'case 4c: only VERSION fails in a large diff' "${OUT}" '^version-text-pair: VERSION changed and ENGINEERING-STANDARDS\.md did not'
equals  'case 4c: exit code' "${RC}" 1

# --- 5. no origin/main -> loud failure, never a silent pass (C9) ---------------
reset_tree
git -C "${REPO}" update-ref -d refs/remotes/origin/main
run
matches 'case 5: a missing origin/main fails loudly' "${OUT}" '^version-text-pair: origin/main is not in this clone, so the pair cannot be judged'
equals  'case 5: exit code' "${RC}" 1
equals  'case 5: no ok line is printed' "$(printf '%s' "${OUT}" | grep -c 'version-text-pair: ok')" 0

if [ "${fails}" -eq 0 ]; then
    printf '\nversion-text-pair-test: all checks passed\n'
    exit 0
fi
printf '\nversion-text-pair-test: %s check(s) failed\n' "${fails}" >&2
exit 1
