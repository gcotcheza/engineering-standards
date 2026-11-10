#!/usr/bin/env bash
# Fixtures only: throwaway Dockerfiles in a temp dir drive the real scripts/dockerfile-unzip-check.sh, every case
# under bash and again under busybox sh with only busybox applets on PATH, as an Alpine image runs it (dash for case 9c).
#
#   scripts/dockerfile-unzip-check-test.sh
#   DOCKERFILE_UNZIP_CHECK_SH=/path/mutant.sh scripts/dockerfile-unzip-check-test.sh   the red proofs
#   DU_TEST=$PWD/scripts/dockerfile-unzip-check-test.sh scripts/guard-mutants.sh scripts/dockerfile-unzip-check.sh scripts/dockerfile-unzip-check-mutants.txt
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${DOCKERFILE_UNZIP_CHECK_SH:-${SCRIPT_DIR}/dockerfile-unzip-check.sh}"

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
# decision: grep-q-reads-a-here-string-not-a-pipe
contains() { if grep -qF -- "$3" <<<"$2"; then pass "$1"; else fail "$1 — [$2] does not contain [$3]"; fi; }
lacks()    { if grep -qF -- "$3" <<<"$2"; then fail "$1 — [$2] must not contain [$3]"; else pass "$1"; fi; }

BUSYBOX=$(command -v busybox) || { printf 'busybox is not on PATH, so the Alpine half of this test cannot run (C9).\n' >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "${WORK}/bb" "${WORK}/fake"
ln -s "${BUSYBOX}" "${WORK}/bb/awk"
# An awk that exits 0 and prints nothing, so a missing verdict is never read as a pass.
printf '#!/bin/sh\nexit 0\n' >"${WORK}/fake/awk"
chmod 755 "${WORK}/fake/awk"
RM='RUN rm -f /usr/bin/unzip && ! command -v unzip'
n=0

# run [--fake-awk] <args...>: OUT/RC from bash, then busybox sh (dash with the fake awk) must print and exit the same.
run() {
    local second=("${BUSYBOX}" sh) second_path=${WORK}/bb path=${PATH}
    [ "${1-}" != --fake-awk ] || { shift; second=(dash); path=${WORK}/fake:${PATH}; second_path=${path}; }
    OUT="$(env PATH="${path}" bash "${CHECK}" "$@" 2>&1)"; RC=$?
    SECOND_OUT="$(env PATH="${second_path}" "${second[@]}" "${CHECK}" "$@" 2>&1)"; SECOND_RC=$?
    equals "case ${n}: ${second[*]##*/} exit code" "${SECOND_RC}" "${RC}"
    equals "case ${n}: ${second[*]##*/} output" "${SECOND_OUT}" "${OUT}"
}
# df <lines...>: a fresh Dockerfile F, one argument per line.
df() { n=$((n + 1)); F="${WORK}/Dockerfile.${n}"; printf '%s\n' "$@" >"${F}"; }
LEAVES='stage leaves /usr/bin/unzip after its last apk change: '

# --- 1. unzip removed after the last change of every stage, and a stage with no apk -------------
df 'ARG BASE=php' 'FROM php AS app' 'RUN apk add --no-cache git' "${RM}" 'FROM app AS gate' \
   'RUN apk upgrade && apk fix && rm -f /usr/bin/unzip' 'from gate as e2e' 'USER app'; run "${F}"
equals   'case 1: the verdict' "${OUT}" 'stages that change apk packages: 2, leaving unzip: 0'
equals   'case 1: exit code' "${RC}" 0

# --- 2. apk --no-cache add after the rm ------------------------------------------------------------
df 'FROM app AS gate' "${RM}" 'RUN apk --no-cache add git'; run "${F}"
contains 'case 2: the stage is named' "${OUT}" "${LEAVES}FROM app AS gate"
equals   'case 2: exit code' "${RC}" 1

# --- 3. apk del after the rm -------------------------------------------------------------------------
df 'FROM app AS gate' 'RUN apk add git' "${RM}" 'RUN apk del git'; run "${F}"
contains 'case 3: the stage is named' "${OUT}" "${LEAVES}FROM app AS gate"
equals   'case 3: exit code' "${RC}" 1

# --- 4. a child stage is its own stage ------------------------------------------------------------------
df 'FROM app AS gate' 'RUN apk add git' "${RM}" 'FROM gate AS e2e' 'RUN apk add chromium'; run "${F}"
contains 'case 4: the child is named' "${OUT}" "${LEAVES}FROM gate AS e2e"
lacks    'case 4: its parent is not' "${OUT}" "${LEAVES}FROM app AS gate"
contains 'case 4: both are counted' "${OUT}" 'stages that change apk packages: 2, leaving unzip: 1'
equals   'case 4: exit code' "${RC}" 1

# --- 5. a commented rm only -----------------------------------------------------------------------------
df 'FROM app AS gate' 'RUN apk add git' "  # ${RM}"; run "${F}"
contains 'case 5: a comment removes nothing' "${OUT}" "${LEAVES}FROM app AS gate"
equals   'case 5: exit code' "${RC}" 1

# --- 6. an earlier stage that leaves unzip, before one that does not --------------------------------------
df 'FROM php AS app' 'RUN apk add git' 'FROM app AS gate' 'RUN apk add curl' "${RM}"; run "${F}"
contains 'case 6: the earlier stage is named' "${OUT}" "${LEAVES}FROM php AS app"
lacks    'case 6: the later one is not' "${OUT}" "${LEAVES}FROM app AS gate"
equals   'case 6: exit code' "${RC}" 1

# --- 7. on one line: an apk change after the rm, and an rm between two changes ------------------------------
df 'FROM app AS gate' 'RUN rm -f /usr/bin/unzip && apk add git'; run "${F}"
equals   'case 7a: exit code' "${RC}" 1
df 'FROM app AS gate' 'RUN apk add git && rm -f /usr/bin/unzip && apk del git'; run "${F}"
contains 'case 7b: the last change on the line decides' "${OUT}" "${LEAVES}FROM app AS gate"
equals   'case 7b: exit code' "${RC}" 1

# --- 8. upgrade and fix are changes too; a word ending in apk is not apk -----------------------------------
df 'FROM app AS gate' "${RM}" 'RUN apk -U upgrade'; run "${F}"
equals   'case 8a: upgrade after the rm, exit code' "${RC}" 1
df 'FROM app AS gate' "${RM}" 'RUN apk fix'; run "${F}"
equals   'case 8b: fix after the rm, exit code' "${RC}" 1
df 'FROM app AS gate' 'RUN echo myapk add x'; run "${F}"
equals   'case 8c: myapk is no change' "${OUT}" 'stages that change apk packages: 0, leaving unzip: 0'
df 'FROM app AS gate' 'RUN apk add git && rm -f /usr/bin/unzip.bak'; run "${F}"
equals   'case 8d: removing unzip.bak removes no unzip, exit code' "${RC}" 1

# --- 9. refusals: no FROM, no file, no verdict, usage -------------------------------------------------------
df 'RUN apk add git'; run "${F}"
contains 'case 9a: no FROM is refused' "${OUT}" "${F} has no FROM line, so nothing was judged."
equals   'case 9a: exit code' "${RC}" 1
run "${WORK}/no-such-Dockerfile"
contains 'case 9b: a missing file is refused' "${OUT}" "${WORK}/no-such-Dockerfile is not a file, so nothing was judged."
equals   'case 9b: exit code' "${RC}" 1
df 'FROM app AS gate' 'RUN apk add git' "${RM}"; run --fake-awk "${F}"
contains 'case 9c: an awk with no verdict is refused' "${OUT}" "awk exited 0 without a verdict on ${F}."
equals   'case 9c: exit code' "${RC}" 1
run
contains 'case 9d: no argument is usage' "${OUT}" 'usage: dockerfile-unzip-check.sh <Dockerfile>'
equals   'case 9d: exit code' "${RC}" 2
run ''
equals   'case 9e: an empty argument, exit code' "${RC}" 2
run "${F}" "${F}"
equals   'case 9f: two arguments, exit code' "${RC}" 2

if [ "${fails}" -gt 0 ]; then printf '%s failure(s)\n' "${fails}" >&2; exit 1; fi
printf 'dockerfile-unzip-check-test: all cases passed\n'
