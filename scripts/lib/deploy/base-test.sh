#!/usr/bin/env bash
# Guards base.sh against fixture repos and a git that fails on cue. test.sh runs it; red proofs run
# DEPLOY_LIB_DIR=<copy> TMPDIR=<dir under /srv/worker-scratch> base-test.sh. Fixture commits run the fleet hook (S1).
# shellcheck disable=SC2016
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${DEPLOY_LIB_DIR:-${SCRIPT_DIR}}"
fails=0
pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 — no [$3] in:"$'\n'"$2" ;; esac; }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
WORK="$(mktemp -d -p "${TMPDIR:-/srv/worker-scratch}" base-test.XXXXXXXX)" || { printf 'cannot make a work directory\n' >&2; exit 1; }
trap 'rm -rf "${WORK}"' EXIT
R="${WORK}/repo"
FETCH='  git fetch origin — this gate never moves its own comparison point.'
HINT='  Name the commit this head was built on, or leave the base out and let origin/main answer.'

g() { git -C "$R" -c user.name=t -c user.email=t@example.invalid "$@"; }
commit() { printf '%s\n' "$1" >"$R/$1.txt" && g add "$1.txt" && g commit -q -m "$1" && g rev-parse HEAD; }
# main: m0 m1 M(m1, f2) m3; f1 f2 merged by M; x1 off m0, never merged; g1 off m3, not merged yet.
git init -q -b main "$R" || exit 1
M0=$(commit m0) M1=$(commit m1) || exit 1
g switch -q -c feat "$M0" && g merge -q --ff-only "$M1" || exit 1
F1=$(commit f1) F2=$(commit f2) || exit 1
g switch -q main && g merge -q --no-ff -m M feat || exit 1
MM=$(g rev-parse HEAD) M3=$(commit m3) || exit 1
g switch -q -c side "$M0" && X1=$(commit x1) || exit 1
g switch -q -c next "$M3" && G1=$(commit g1) || exit 1
g update-ref refs/remotes/origin/main "$M3" || exit 1
[ -n "$M0$M1$F1$F2$MM$M3$X1$G1" ] || exit 1

# A git that exits 128 on merge-base --is-ancestor when its two arguments are FAIL_A and FAIL_B.
FAKE="${WORK}/fake-git"
printf '%s\n' '#!/bin/bash' 'd=$2; shift 2' \
    'if [ "$1 $2" = "merge-base --is-ancestor" ] && [ "$3" = "${FAIL_A}" ] && [ "$4" = "${FAIL_B}" ]; then exit 128; fi' \
    'exec git -C "$d" "$@"' >"$FAKE"

# vet <head> <base> <ancestor hint> [fail a] [fail b]: OUT is stdout, ERR stderr, RC the exit.
vet() {
    g -c advice.detachedHead=false checkout -q "$1" || exit 1
    OUT=$(cd "$R" && FAIL_A=${4:-} FAIL_B=${5:-} bash -c '. "$1"; base_vet "$2" "$3" "$4" bash "$5" -C "$6"' \
        _ "${LIB_DIR}/base.sh" "$2" "$FETCH" "$3" "$FAKE" "$R" 2>"${WORK}/err")
    RC=$?
    ERR=$(cat "${WORK}/err")
}
armed() {
    OUT=$(FAIL_A=${4:-} FAIL_B=${5:-} bash -c '. "$1"; base_vet_armed "$2" "$3" "$4" bash "$5" -C "$6"' \
        _ "${LIB_DIR}/base.sh" "$1" "$2" "$3" "$FAKE" "$R" 2>"${WORK}/err")
    RC=$?
    ERR=$(cat "${WORK}/err")
}

vet "$G1" "$M3" ''
equals 'happy: a base at origin/main under an unmerged head prints its sha' "$RC:$OUT:$ERR" "0:$M3:"
vet "$G1" "${M3:0:9}" ''
equals 'happy: a short base resolves to the full sha' "$RC:$OUT" "0:$M3"
OUT=$(R_DIR=$R bash -c '. "$1"; gitfn() { git -C "$R_DIR" "$@"; }; base_vet "$2" "" "" gitfn' _ "${LIB_DIR}/base.sh" "$M3" 2>&1)
equals 'happy: the git can be a function name' "$OUT" "$M3"

vet "$G1" nosuchref ''
equals 'not a commit: refused with 2 and nothing on stdout' "$RC:$OUT" '2:'
equals 'not a commit: the sentence' "$ERR" 'the base nosuchref is not a commit in this clone.'

vet "$G1" "$X1" ''
equals 'not an ancestor: refused with 2' "$RC:$OUT" '2:'
equals 'not an ancestor: the sentence, and no hint line when none is given' "$ERR" "the base $X1 is not an ancestor of HEAD, so $X1..HEAD is not what this head is made of."
vet "$G1" "$X1" "$HINT"
equals 'not an ancestor: the caller'\''s hint is the second line' "$ERR" "the base $X1 is not an ancestor of HEAD, so $X1..HEAD is not what this head is made of."$'\n'"$HINT"

vet "$G1" "$G1" ''
equals 'ahead of origin/main: refused with 2' "$RC:$OUT" '2:'
equals 'ahead of origin/main: the sentence' "$ERR" "the base $G1 is ahead of origin/main, so $G1..HEAD leaves out commits this branch added."

g update-ref -d refs/remotes/origin/main || exit 1
vet "$G1" "$M3" ''
equals 'no origin/main: refused with 2' "$RC:$OUT" '2:'
equals 'no origin/main: the sentence and the caller'\''s fetch hint' "$ERR" 'origin/main is not in this clone, so nothing here can say the base is behind it.'$'\n'"$FETCH"
g update-ref refs/remotes/origin/main "$M3" || exit 1

vet "$F2" "$M1" ''
equals 'merged head: a base at the floor (the first parent of the merge) is accepted' "$RC:$OUT:$ERR" "0:$M1:"
vet "$F2" "$M0" ''
equals 'merged head: a base below the floor is accepted' "$RC:$OUT" "0:$M0"
vet "$F2" "$F1" ''
equals 'merged head: a base inside the merge is refused with 2' "$RC:$OUT" '2:'
equals 'merged head: the inside sentence names the merge and the floor' "$ERR" "the base $F1 is inside what HEAD merged into origin/main (at ${MM:0:12}), so $F1..HEAD leaves some of it out: give $M1."

vet "$M0" "$M0" ''
equals 'merged head: a head that landed as the root commit has no floor, so its base is refused' "$RC:$OUT" '2:'
equals 'merged head: the no-floor sentence asks for its first parent' "$ERR" "the base $M0 is inside what HEAD merged into origin/main (at ${M0:0:12}), so $M0..HEAD leaves some of it out: give its first parent."

vet "$F2" "$F1" '' HEAD "$MM"
equals 'floor loop: merge-base exiting 128 refuses (fail closed), not a break that floors too late' "$RC:$OUT" '2:'
equals 'floor loop: the sentence names the commit and the exit' "$ERR" "git could not say whether HEAD is in $MM (merge-base exited 128), so no floor is known for the base $F1."
vet "$G1" "$M3" '' "$M3" HEAD
equals 'base in HEAD: merge-base exiting 128 refuses with 2' "$RC:$OUT" '2:'
equals 'base in HEAD: the sentence names the exit' "$ERR" "git could not say whether $M3 is in HEAD (merge-base exited 128), so the base $M3 cannot be vetted."
vet "$G1" "$M3" '' "$M3" origin/main
equals 'base in origin/main: merge-base exiting 128 refuses with 2' "$RC:$OUT" '2:'
contains 'base in origin/main: the sentence names the exit' "$ERR" "is in origin/main (merge-base exited 128)"
vet "$G1" "$M3" '' HEAD origin/main
equals 'head in origin/main: merge-base exiting 128 refuses with 2' "$RC:$OUT" '2:'
contains 'head in origin/main: the sentence names the exit' "$ERR" 'git could not say whether HEAD is in origin/main (merge-base exited 128)'
vet "$F2" "$M0" '' "$M0" "$M1"
equals 'base in the floor: merge-base exiting 128 refuses with 2' "$RC:$OUT" '2:'
contains 'base in the floor: the sentence names the exit' "$ERR" "git could not say whether $M0 is in $M1 (merge-base exited 128)"

OUT=$(bash -c '. "$1"; base_vet "" "" "" git' _ "${LIB_DIR}/base.sh" 2>&1)
RC=$?
equals 'usage: an empty base is refused with 2' "$RC" 2
contains 'usage: and names the call' "$OUT" 'base_vet: usage:'

armed "$M3" "$M3" "$G1"
equals 'armed: a recorded head that holds the base passes silently' "$RC:$OUT:$ERR" '0::'
armed "$M3" "$M3" "$X1"
equals 'armed: a recorded head without the base is refused with 2' "$RC" 2
equals 'armed: the sentence' "$ERR" "the base $M3 is not an ancestor of $X1, the commit this run records: HEAD moved after the base was vetted."$'\n''Run the gate again on the head you mean to record.'
armed "$M3" "$M3" ''
equals 'armed: no armed commit is refused with 2' "$RC" 2
equals 'armed: the no-commit sentence' "$ERR" "the gate armed no commit, so nothing says the base $M3 is in the head this run records."
armed "$M3" "$M3" "$G1" "$M3" "$G1"
equals 'armed: merge-base exiting 128 refuses with 2' "$RC" 2
contains 'armed: the sentence names the exit' "$ERR" "git could not say whether $M3 is in $G1 (merge-base exited 128)"
armed "$M3" '' "$G1"
equals 'armed usage: no vetted sha is refused with 2' "$RC" 2
equals 'armed usage: and names the call' "$ERR" 'base_vet_armed: usage: base_vet_armed <base> <vetted sha> <armed sha> <git command>...'

if [ "$fails" -eq 0 ]; then
    printf 'base-test: all checks passed\n'
    exit 0
fi
printf 'base-test: %s check(s) failed\n' "$fails" >&2
exit 1
