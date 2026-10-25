#!/usr/bin/env bash
# Fixtures only: throwaway git repos in a temp dir drive the real
# scripts/decisions-check.sh. No network, nothing outside the temp dir.
# Pointers are spelled through ${KW} and ${D} so this file is not itself one.
# DECISIONS_CHECK_SH points at a scratch copy for the red proofs.
#
#   scripts/decisions-check-test.sh
#   DECISIONS_CHECK_SH=/path/mutant.sh scripts/decisions-check-test.sh   the red proofs
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${DECISIONS_CHECK_SH:-${SCRIPT_DIR}/decisions-check.sh}"
KW='decision'
D='DECISIONS.md'
MD='.md'
HEADER='> Newer decisions are one file each in docs/decisions/, until the change that adds the 10th folds them in at the bottom of this file (W7).'

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
# decision: grep-q-reads-a-here-string-not-a-pipe
matches() { if grep -qE "$3" <<<"$2"; then pass "$1"; else fail "$1 — [$2] does not match /$3/"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
n=0

# A fresh repo: DECISIONS.md with the header and one rolled entry, two decision
# files, one source file pointing at each; committed, with origin/main at HEAD.
fresh() {
    n=$((n + 1)); R="${WORK}/r${n}"
    git init -q -b main "${R}"
    git -C "${R}" config user.email 'fixture@example.invalid'
    git -C "${R}" config user.name 'Standards fixture'
    mkdir -p "${R}/docs/decisions" "${R}/src"
    printf '# Decisions\n\n%s\n\n## An old entry\n\nOld prose.\n\n### rolled-one\n\n*2026-01-01 — Rolled one*\n\nBody.\n' "${HEADER}" >"${R}/docs/DECISIONS.md"
    add_decision 2026-02-01-0900-first-one 'First one'
    add_decision 2026-02-02-0900-second-one 'Second one'
    printf '# %s: first-one\n# %s: rolled-one\n# docs/%s: second-one\n' "${KW}" "${KW}" "${D}" >"${R}/src/app.sh"
    commit 'Added the decisions fixture'
    git -C "${R}" update-ref refs/remotes/origin/main HEAD
}
add_decision() { printf '# %s\n\nWhy it is so.\n' "$2" >"${R}/docs/decisions/$1.md"; }
commit() { git -C "${R}" add -- docs src && git -C "${R}" commit -q -m "$1"; }
run() { OUT="$(bash "${CHECK}" "${R}" 2>&1)"; RC=$?; }

# --- 1. a clean fixture passes --------------------------------------------------
fresh; run
matches 'case 1: clean is ok' "${OUT}" '^decisions-check: ok \(2 unrolled, 1 rolled up\)$'
equals  'case 1: exit code' "${RC}" 0

# --- 2. a pointer that resolves nowhere --------------------------------------------
fresh; printf 'x # %s: no-such-one\n' "${KW}" >>"${R}/src/app.sh"; run
matches 'case 2: dangling pointer is named with its line' "${OUT}" "src/app.sh:4: pointer to no-such-one \\('${KW}: no-such-one'\\) resolves to no"
equals  'case 2: exit code' "${RC}" 1

# --- 3. a legacy pointer that resolves nowhere -------------------------------------
fresh; printf "see docs/%s: \`gone-away\`\n" "${D}" >"${R}/src/b.md"; git -C "${R}" add -- src; run
matches 'case 3: dangling legacy pointer' "${OUT}" "src/b.md:1: pointer to gone-away \\('DECISIONS.md: .gone-away.'\\) resolves to no"
equals  'case 3: exit code' "${RC}" 1

# --- 4. line-number pointers ---------------------------------------------------------
fresh; printf 'a docs/%s:12\nb docs/%s#L40\nc docs/decisions/2026-02-01-0900-first-one.md#%s\n' "${D}" "${D}" L3 >"${R}/src/c.md"; git -C "${R}" add -- src; run
matches 'case 4: DECISIONS.md:N is flagged' "${OUT}" "src/c.md:1: line-number pointer '${D}:12'"
matches 'case 4: DECISIONS.md#LN is flagged' "${OUT}" "src/c.md:2: line-number pointer '${D}#L40'"
matches 'case 4: a decision file #LN is flagged' "${OUT}" "src/c.md:3: line-number pointer 'decisions/2026-02-01-0900-first-one${MD}#L3'"
equals  'case 4: exit code' "${RC}" 1

# --- 5. one slug, two files -------------------------------------------------------------
fresh; add_decision 2026-03-01-0900-first-one 'Again'; run
matches 'case 5: a slug used twice' "${OUT}" 'slug first-one is used twice: docs/decisions/2026-02-01-0900-first-one.md and docs/decisions/2026-03-01-0900-first-one.md'
equals  'case 5: exit code' "${RC}" 1

# --- 6. names and form -------------------------------------------------------------------
fresh; printf 'x\n' >"${R}/docs/decisions/notes.md"; run
matches 'case 6a: a bad name' "${OUT}" 'docs/decisions/notes.md: not a decision file name'
fresh; printf 'Title\n\nBody\n' >"${R}/docs/decisions/2026-02-01-0900-first-one.md"; run
matches 'case 6b: line 1 is not a title' "${OUT}" "2026-02-01-0900-first-one.md:1: line 1 is not '# <Title>'"
fresh; printf '# T\nBody\n' >"${R}/docs/decisions/2026-02-01-0900-first-one.md"; run
matches 'case 6c: line 2 is not blank' "${OUT}" '2026-02-01-0900-first-one.md:2: line 2 is not blank'
fresh; printf '# T\n\n' >"${R}/docs/decisions/2026-02-01-0900-first-one.md"; run
matches 'case 6d: no prose' "${OUT}" '2026-02-01-0900-first-one.md:3: no prose after the title'
fresh; mkdir "${R}/docs/decisions/2026-02-03-0900-a-dir.md"; run
matches 'case 6e: a directory is not a decision' "${OUT}" '2026-02-03-0900-a-dir.md: not a plain file'
equals  'case 6: exit code' "${RC}" 1

# --- 7. files without the header pointer ---------------------------------------------------
fresh; sed -i 3d "${R}/docs/DECISIONS.md"; run
matches 'case 7: the header is required' "${OUT}" 'docs/DECISIONS.md: docs/decisions/ holds decisions, so its first 10 lines must carry'
equals  'case 7: exit code' "${RC}" 1

# --- 8. nine files pass, ten fail -----------------------------------------------------------
fresh; for i in 3 4 5 6 7 8 9; do add_decision "2026-02-0${i}-0900-file-${i}" "File ${i}"; done; run
equals  'case 8a: nine files exit code' "${RC}" 0
add_decision 2026-02-10-0900-file-ten 'File ten'; run
matches 'case 8b: ten files fail' "${OUT}" '^decisions-check: 10 unrolled decisions: run decisions-rollup\.sh in this change$'
equals  'case 8b: exit code' "${RC}" 1

# --- 9. one slug rolled up twice --------------------------------------------------------------
fresh; printf '\n### rolled-one\n\n*2026-01-01 — Rolled one*\n\nBody.\n' >>"${R}/docs/DECISIONS.md"; run
matches 'case 9: a rolled slug twice says rebase' "${OUT}" '### rolled-one is rolled up twice \(line 9\): rebase onto main and re-run decisions-rollup\.sh'
equals  'case 9: exit code' "${RC}" 1

# --- 10. rolled up here and still a file ---------------------------------------------------------
fresh; add_decision 2026-01-01-0900-rolled-one 'Rolled one'; run
matches 'case 10: rolled and still a file says rebase' "${OUT}" '### rolled-one is rolled up and docs/decisions/2026-01-01-0900-rolled-one.md still exists: rebase onto main'
equals  'case 10: exit code' "${RC}" 1

# --- 11. rolled up here, and its file changed on main since the branch began ------------------------
fresh; base=$(git -C "${R}" rev-parse HEAD)
git -C "${R}" checkout -q -b side
printf '\n### first-one\n\n*2026-02-01 — First one*\n\nWhy it is so.\n' >>"${R}/docs/DECISIONS.md"
git -C "${R}" rm -q docs/decisions/2026-02-01-0900-first-one.md; commit 'Rolled first-one'
git -C "${R}" checkout -q -b main2 "${base}"
printf 'Changed on main.\n' >>"${R}/docs/decisions/2026-02-01-0900-first-one.md"; commit 'Edited first-one on main'
git -C "${R}" update-ref refs/remotes/origin/main HEAD
git -C "${R}" checkout -q side; run
matches 'case 11: a file changed on main says rebase' "${OUT}" '### first-one is rolled up here and docs/decisions/2026-02-01-0900-first-one\.md changed on main since this branch began: rebase onto main'
equals  'case 11: exit code' "${RC}" 1

# --- 12. a rolled-up log with no main to compare with ------------------------------------------------
fresh; git -C "${R}" update-ref -d refs/remotes/origin/main; run
matches 'case 12: a missing base is never a pass' "${OUT}" 'origin/main is not in this clone, so nothing was judged'
equals  'case 12: exit code (2: nothing judged, not a finding)' "${RC}" 2

# --- 13. not a git tree -------------------------------------------------------------------------------
mkdir -p "${WORK}/plain"; R="${WORK}/plain"; run
matches 'case 13: not a work tree' "${OUT}" 'is not a git work tree, so nothing was judged'
equals  'case 13: exit code' "${RC}" 2

# --- 14. a git grep that fails is not a clean tree ------------------------------------------------------
fresh; mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/git-grep-fails" <<'FAKE'
#!/bin/sh
[ "$1" = grep ] && { echo boom >&2; exit 128; }
exec git "$@"
FAKE
chmod +x "${WORK}/bin/git-grep-fails"
OUT="$(DECISIONS_GIT="${WORK}/bin/git-grep-fails" bash "${CHECK}" "${R}" 2>&1)"; RC=$?
matches 'case 14: a failing git grep judges nothing' "${OUT}" 'git grep failed, so no pointer was judged'
equals  'case 14: exit code' "${RC}" 2

# --- 15. every slug of a comma list, across a wrapped line, in each spelling --------------------------
fresh; printf "a docs/%s: \`first-one\`, \`list-gone\`, and \`second-one\`,\n\`wrap-gone\`.\nb %s: \`variant-gone\`\nc %s: first-one, rolled-one\n" "${D}" "${D%.md}" "${KW}" >"${R}/src/d.md"; git -C "${R}" add -- src; run
matches 'case 15a: the second slug of a list' "${OUT}" 'src/d.md:1: pointer to list-gone '
matches 'case 15b: a slug on the wrapped line' "${OUT}" 'src/d.md:2: pointer to wrap-gone '
matches 'case 15c: the DECISIONS: spelling' "${OUT}" 'src/d.md:3: pointer to variant-gone '
equals  'case 15: only those three' "$(grep -c 'pointer to' <<<"${OUT}")" 3
equals  'case 15: exit code' "${RC}" 1

# --- 16. a subdirectory or a mistyped root judges nothing ---------------------------------------------
fresh; R="${R}/src"; run
matches 'case 16: a subdirectory is refused' "${OUT}" 'is not the top of its work tree'
equals  'case 16: exit code' "${RC}" 2

# --- 17. a several-word git seam, and git's own words when it fails -------------------------------------
fresh; OUT="$(DECISIONS_GIT="git -C ${R}" bash "${CHECK}" "${R}" 2>&1)"; RC=$?
matches 'case 17a: git -C <tree> as the seam' "${OUT}" '^decisions-check: ok \(2 unrolled, 1 rolled up\)$'
OUT="$(DECISIONS_GIT="git -C ${WORK}/no-such-tree" bash "${CHECK}" "${R}" 2>&1)"; RC=$?
matches 'case 17b: git stderr is kept' "${OUT}" "is not a git work tree, so nothing was judged: fatal: cannot change to"
equals  'case 17b: exit code' "${RC}" 2

# --- 18. .gitkeep is allowed ----------------------------------------------------------------------------
fresh; : >"${R}/docs/decisions/.gitkeep"; run
equals  'case 18: .gitkeep exit code' "${RC}" 0

# --- 19. CRLF says so -----------------------------------------------------------------------------------
fresh; printf '# T\r\n\r\nBody\r\n' >"${R}/docs/decisions/2026-02-01-0900-first-one.md"; run
matches 'case 19: CRLF is named' "${OUT}" '2026-02-01-0900-first-one.md: CRLF line endings; save it with LF endings$'
equals  'case 19: no form finding on top' "$(grep -c 'line 2 is not blank' <<<"${OUT}")" 0
equals  'case 19: exit code' "${RC}" 1

# --- 20. a finding and no main: the finding wins (1), the base is still named --------------------------
fresh; printf 'x\n' >"${R}/docs/decisions/notes.md"; git -C "${R}" update-ref -d refs/remotes/origin/main; run
matches 'case 20: the finding is printed' "${OUT}" 'docs/decisions/notes.md: not a decision file name'
matches 'case 20: the missing base is named' "${OUT}" 'origin/main is not in this clone, so the roll-up and pointers were not judged'
equals  'case 20: exit code (1: a finding, not "nothing judged")' "${RC}" 1

# --- 21. no argument is a usage error (2) --------------------------------------------------------------
OUT="$(bash "${CHECK}" 2>&1)"; RC=$?
matches 'case 21: usage is printed' "${OUT}" '^usage: decisions-check\.sh <repo-root>$'
equals  'case 21: exit code' "${RC}" 2
fresh; OUT="$(cd "${R}" && bash "${CHECK}" '' 2>&1)"; RC=$?
matches 'case 21: an empty argument is usage too' "${OUT}" '^usage: decisions-check\.sh <repo-root>$'
equals  'case 21: empty argument exit code' "${RC}" 2

# --- 22. .fleet/decisions-mode no-rollup skips the fold and the opening line, nothing else -------------
SKIPPED='^decisions-check: \.fleet/decisions-mode is no-rollup: .* the 10-file fold and the opening line are not checked; every other check runs$'
no_rollup() { mkdir -p "${R}/.fleet"; printf '%s\n' "$1" >"${R}/.fleet/decisions-mode"; git -C "${R}" add -- .fleet; }
ten_without_header() { sed -i 3d "${R}/docs/DECISIONS.md"; for i in 3 4 5 6 7 8 9; do add_decision "2026-02-0${i}-0900-file-${i}" "File ${i}"; done; add_decision 2026-02-10-0900-file-ten 'File ten'; }
fresh; ten_without_header; no_rollup no-rollup; run
matches 'case 22a: the skip is said in one line' "${OUT}" "${SKIPPED}"
equals  'case 22a: ten files and no opening line pass' "${RC}" 0
matches 'case 22a: still ok, with the count' "${OUT}" '^decisions-check: ok \(10 unrolled, 1 rolled up\)$'
fresh; ten_without_header; no_rollup no-rollup; add_decision 2026-02-11-0900-Bad_Slug 'Bad'; printf 'x # %s: no-such-one\n' "${KW}" >>"${R}/src/app.sh"; run
matches 'case 22b: a bad slug still fails' "${OUT}" '2026-02-11-0900-Bad_Slug.md: not a decision file name'
matches 'case 22b: a dangling pointer still fails' "${OUT}" 'pointer to no-such-one '
equals  'case 22b: neither skipped check speaks' "$(grep -cE 'unrolled decisions|first 10 lines must carry' <<<"${OUT}")" 0
equals  'case 22b: exit code' "${RC}" 1

# --- 23. any other mode value judges nothing ------------------------------------------------------------
fresh; no_rollup 'no-rollup please'; run
matches 'case 23: an unknown mode is refused' "${OUT}" '^decisions-check: \.fleet/decisions-mode must read exactly no-rollup \(or not exist\), so nothing was judged$'
equals  'case 23: exit code' "${RC}" 2

# --- 24. no mode file: the fold and the opening line are judged as before ---------------------------------
fresh; ten_without_header; run
matches 'case 24: the fold is judged' "${OUT}" 'decisions-check: 10 unrolled decisions: run decisions-rollup\.sh in this change'
matches 'case 24: the opening line is judged' "${OUT}" 'its first 10 lines must carry'
equals  'case 24: no skip line' "$(grep -c 'is no-rollup' <<<"${OUT}")" 0
equals  'case 24: exit code' "${RC}" 1

# --- 25. a mode file the checker cannot trust judges nothing ----------------------------------------------
NOTHING=', so nothing was judged$'
fresh; ten_without_header; printf 'no-rollup\n' >"${WORK}/mode${n}"; mkdir -p "${R}/.fleet"; ln -s "${WORK}/mode${n}" "${R}/.fleet/decisions-mode"; git -C "${R}" add -- .fleet; run
matches 'case 25a: a symlinked mode is refused' "${OUT}" "^decisions-check: \\.fleet/decisions-mode is a symlink${NOTHING}"
equals  'case 25a: exit code' "${RC}" 2
fresh; ten_without_header; mkdir -p "${R}/.fleet"; printf 'no-rollup\n' >"${R}/.fleet/decisions-mode"; run
matches 'case 25b: an untracked mode is refused' "${OUT}" "^decisions-check: \\.fleet/decisions-mode is not tracked by git${NOTHING}"
equals  'case 25b: exit code' "${RC}" 2
fresh; mkdir -p "${R}/.fleet/decisions-mode"; : >"${R}/.fleet/decisions-mode/x"; git -C "${R}" add -- .fleet; run
matches 'case 25c: an unreadable mode is refused' "${OUT}" '^decisions-check: \.fleet/decisions-mode could not be read, so nothing was judged: '
equals  'case 25c: exit code' "${RC}" 2
fresh; ten_without_header; mkdir -p "${R}/.fleet"; printf 'no-rollup\000\n' >"${R}/.fleet/decisions-mode"; git -C "${R}" add -- .fleet; run
matches 'case 25d: a NUL byte is refused' "${OUT}" "^decisions-check: \\.fleet/decisions-mode holds a NUL byte${NOTHING}"
equals  'case 25d: exit code' "${RC}" 2

# --- 27. the header on line 1 of a DECISIONS.md whose next 9 lines are long ------
# 540 KB in lines 2-10: piped into grep -q, head would take SIGPIPE after the match.
fresh
{ printf '%s\n' "${HEADER}"; for _ in 1 2 3 4 5 6 7 8 9; do printf '%060000d\n' 0; done
  printf '\n### rolled-one\n\n*2026-01-01 — Rolled one*\n\nBody.\n'; } >"${R}/docs/DECISIONS.md"
commit 'Long lines under the header'; run
matches 'case 27: a header followed by long lines is found' "${OUT}" '^decisions-check: ok \(2 unrolled, 1 rolled up\)$'
equals  'case 27: exit code' "${RC}" 0

# --- 26. the helpers read a big output whose first line matches (card 704) ---
# Line 1 matches, then ~1.4 MB more: a piped grep -q would quit early and SIGPIPE
# the writer. Each helper runs in a subshell; only its verdict word is counted.
BIG="needle$(printf '\nfiller%.0s' {1..200000})"
equals 'case 26: matches sees the match' "$( (matches x "${BIG}" 'needle') 2>/dev/null | grep -c '^ok ')" 1

if [ "${fails}" -gt 0 ]; then printf '%s failure(s)\n' "${fails}" >&2; exit 1; fi
printf 'decisions-check-test: all cases passed\n'
