#!/usr/bin/env bash
# Fixtures only: throwaway git repos in a temp dir drive the real
# scripts/decisions-rollup.sh and, after it, the real decisions-check.sh.
# DECISIONS_ROLLUP_SH points at a scratch copy for the red proofs.
#
#   scripts/decisions-rollup-test.sh
#   DECISIONS_ROLLUP_SH=/path/mutant.sh scripts/decisions-rollup-test.sh   the red proofs
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROLLUP="${DECISIONS_ROLLUP_SH:-${SCRIPT_DIR}/decisions-rollup.sh}"
export DECISIONS_CHECK_SH="${SCRIPT_DIR}/decisions-check.sh"
HEADER='> Newer decisions are one file each in docs/decisions/, until the change that adds the 10th folds them in at the bottom of this file (W7).'

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
matches() { if printf '%s' "$2" | grep -qE "$3"; then pass "$1"; else fail "$1 — [$2] does not match /$3/"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
n=0

# A fresh repo: DECISIONS.md with the header, $1 decision files (default 2),
# committed, with origin/main at HEAD.
fresh() {
    n=$((n + 1)); R="${WORK}/r${n}"
    git init -q -b main "${R}"
    git -C "${R}" config user.email 'fixture@example.invalid'
    git -C "${R}" config user.name 'Standards fixture'
    mkdir -p "${R}/docs/decisions"
    printf '# Decisions\n\n%s\n\n## An old entry\n\nOld prose.\n' "${HEADER}" >"${R}/docs/DECISIONS.md"
    local i
    for ((i = 1; i <= ${1:-2}; i++)); do add_decision "2026-02-0${i}-0900-file-${i}" "File ${i}"; done
    commit 'Added the decisions fixture'
    git -C "${R}" update-ref refs/remotes/origin/main HEAD
}
add_decision() { printf '# %s\n\nWhy it is so.\n\nA second paragraph.\n' "$2" >"${R}/docs/decisions/$1.md"; }
commit() { git -C "${R}" add -- docs && git -C "${R}" commit -q -m "$1"; }
run() { OUT="$(bash "${ROLLUP}" "${R}" 2>&1)"; RC=$?; }
snap() { SNAP="$(cat "${R}/docs/DECISIONS.md" 2>&1; ls "${R}/docs/decisions" 2>&1; git -C "${R}" status --porcelain)"; }
unchanged() { local before="${SNAP}"; snap; equals "$1: nothing was written" "$([ "${before}" = "${SNAP}" ] && echo same || echo changed)" same; }

# --- 1. two files fold in, in filename order, in the rolled-up form ---------------
fresh; old_log="$(cat "${R}/docs/DECISIONS.md")"; run
matches 'case 1: rolled' "${OUT}" 'decisions-rollup: rolled 2 decision\(s\) into docs/DECISIONS\.md'
matches 'case 1: then the check passes' "${OUT}" 'decisions-check: ok \(0 unrolled, 2 rolled up\)'
equals  'case 1: exit code' "${RC}" 0
expected="${old_log}
$(printf '\n### file-1\n\n*2026-02-01 — File 1*\n\nWhy it is so.\n\nA second paragraph.\n\n### file-2\n\n*2026-02-02 — File 2*\n\nWhy it is so.\n\nA second paragraph.')"
equals  'case 1: the log is the old log plus both entries' "$([ "$(cat "${R}/docs/DECISIONS.md")" = "${expected}" ] && echo same || echo differs)" same
equals  'case 1: both files are git-rm-ed and the log staged' "$(git -C "${R}" status --porcelain | tr '\n' ' ')" 'M  docs/DECISIONS.md D  docs/decisions/2026-02-01-0900-file-1.md D  docs/decisions/2026-02-02-0900-file-2.md '

# --- 2. a second run is a no-op ----------------------------------------------------
snap; run
matches 'case 2: nothing to roll up' "${OUT}" 'holds no decisions; nothing to roll up'
equals  'case 2: exit code' "${RC}" 0
unchanged 'case 2'

# --- 3. uncommitted changes refuse --------------------------------------------------
fresh; printf 'edit\n' >>"${R}/docs/DECISIONS.md"; snap; run
matches 'case 3a: a dirty log refuses' "${OUT}" 'uncommitted changes: +M docs/DECISIONS\.md'
equals  'case 3a: exit code' "${RC}" 1; unchanged 'case 3a'
fresh; printf 'edit\n' >>"${R}/docs/decisions/2026-02-01-0900-file-1.md"; snap; run
matches 'case 3b: a dirty decision refuses' "${OUT}" 'uncommitted changes: +M docs/decisions/2026-02-01-0900-file-1\.md'
equals  'case 3b: exit code' "${RC}" 1; unchanged 'case 3b'
fresh; add_decision 2026-02-09-0900-file-new 'New'; snap; run
matches 'case 3c: an untracked decision refuses' "${OUT}" 'uncommitted changes: \?\? docs/decisions/2026-02-09-0900-file-new\.md'
equals  'case 3c: exit code' "${RC}" 1; unchanged 'case 3c'

# --- 4. a file changed on main since the branch point refuses ------------------------
fresh; base=$(git -C "${R}" rev-parse HEAD)
printf 'main edit\n' >>"${R}/docs/decisions/2026-02-01-0900-file-1.md"; commit 'Edited on main'
git -C "${R}" update-ref refs/remotes/origin/main HEAD
git -C "${R}" checkout -q -b feature "${base}"; snap; run
matches 'case 4: changed on main refuses' "${OUT}" 'docs/decisions/2026-02-01-0900-file-1\.md changed on main since this branch began'
equals  'case 4: exit code' "${RC}" 1; unchanged 'case 4'

# --- 5. slug collisions refuse --------------------------------------------------------
fresh; printf '\n### file-2\n\n*2026-01-01 — Old*\n\nOld.\n' >>"${R}/docs/DECISIONS.md"; commit 'Rolled file-2 by hand'; snap; run
matches 'case 5a: a slug already rolled refuses' "${OUT}" 'slug file-2 is already rolled up in docs/DECISIONS\.md'
equals  'case 5a: exit code' "${RC}" 1; unchanged 'case 5a'
fresh; add_decision 2026-02-03-0900-file-1 'Again'; commit 'Added a twin'; snap; run
matches 'case 5b: two files with one slug refuse' "${OUT}" 'slug file-1 is used by docs/decisions/2026-02-01-0900-file-1\.md and docs/decisions/2026-02-03-0900-file-1\.md'
equals  'case 5b: exit code' "${RC}" 1; unchanged 'case 5b'

# --- 6. names, form, a missing log, a missing main --------------------------------------
fresh; printf 'x\n' >"${R}/docs/decisions/notes.md"; commit 'Added a stray'; snap; run
matches 'case 6a: a bad name refuses' "${OUT}" 'docs/decisions/notes\.md is not a decision file name'
equals  'case 6a: exit code' "${RC}" 1; unchanged 'case 6a'
fresh; printf 'No title\n\nx\n' >"${R}/docs/decisions/2026-02-01-0900-file-1.md"; commit 'Broke a title'; snap; run
matches 'case 6b: a bad title refuses' "${OUT}" "file-1\\.md: line 1 is not '# <Title>'"
equals  'case 6b: exit code' "${RC}" 1; unchanged 'case 6b'
fresh; git -C "${R}" rm -q docs/DECISIONS.md; git -C "${R}" commit -q -m 'Dropped the log'; snap; run
matches 'case 6c: a missing log refuses' "${OUT}" 'docs/DECISIONS\.md does not exist'
equals  'case 6c: exit code' "${RC}" 1; unchanged 'case 6c'
fresh; git -C "${R}" update-ref -d refs/remotes/origin/main; snap; run
matches 'case 6d: a missing main refuses' "${OUT}" 'origin/main is not in this clone'
equals  'case 6d: exit code' "${RC}" 1; unchanged 'case 6d'

# --- 7. two branches each add the 10th file and roll up: main into b conflicts, ------
#        and a resolve that keeps both sides whole rolls nine slugs up twice
fresh 9; base=$(git -C "${R}" rev-parse HEAD)
git -C "${R}" checkout -q -b a; add_decision 2026-03-01-0900-tenth-a 'Tenth A'; commit 'Added tenth A'; run
equals  'case 7: branch a rolls up' "${RC}" 0
git -C "${R}" commit -q -m 'Rolled up 10 decisions (a)'
git -C "${R}" checkout -q -b b "${base}"; add_decision 2026-01-15-0900-tenth-b 'Tenth B'; commit 'Added tenth B'; run
equals  'case 7: branch b rolls up' "${RC}" 0
git -C "${R}" commit -q -m 'Rolled up 10 decisions (b)'
git -C "${R}" checkout -q main; git -C "${R}" merge -q --ff-only a; git -C "${R}" update-ref refs/remotes/origin/main HEAD
git -C "${R}" checkout -q b
git -C "${R}" merge -q origin/main >/dev/null 2>&1; merge_rc=$?
equals  'case 7: merging main into b conflicts' "$([ "${merge_rc}" -ne 0 ] && echo conflict || echo clean)" conflict
{ git -C "${R}" show :2:docs/DECISIONS.md; git -C "${R}" show :3:docs/DECISIONS.md | tail -n +8; } >"${WORK}/both"
cp -- "${WORK}/both" "${R}/docs/DECISIONS.md"
git -C "${R}" add -- docs/DECISIONS.md; git -C "${R}" commit -q --no-edit
OUT="$(bash "${DECISIONS_CHECK_SH}" "${R}" 2>&1)"; RC=$?
matches 'case 7: keeping both sides says rebase' "${OUT}" '### file-1 is rolled up twice \(line [0-9]+\): rebase onto main and re-run decisions-rollup\.sh'
equals  'case 7: exit code' "${RC}" 1

# --- 8. the rewritten log keeps its owner and mode ----------------------------------
fresh; chown nobody: "${R}/docs/DECISIONS.md"; chmod 640 "${R}/docs/DECISIONS.md"; run
equals  'case 8: exit code' "${RC}" 0
equals  'case 8: owner and mode' "$(stat -c '%U %a' "${R}/docs/DECISIONS.md")" 'nobody 640'

if [ "${fails}" -gt 0 ]; then printf '%s failure(s)\n' "${fails}" >&2; exit 1; fi
printf 'decisions-rollup-test: all cases passed\n'
