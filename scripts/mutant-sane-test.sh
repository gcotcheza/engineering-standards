#!/usr/bin/env bash
# Drives the real scripts/mutant-sane.sh over fixture files in a temp dir: no network, no git.
#   scripts/mutant-sane-test.sh
#   MUTANT_SANE_SH=/path/to/mutant.sh scripts/mutant-sane-test.sh   the red proofs
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${MUTANT_SANE_SH:-${SCRIPT_DIR}/mutant-sane.sh}"

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
# decision: grep-q-reads-a-here-string-not-a-pipe
matches() { if grep -qE -- "$3" <<<"$2"; then pass "$1"; else fail "$1 — [$2] does not match /$3/"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
ORIG=${WORK}/greet.sh
printf '%s\n' '#!/usr/bin/env bash' 'set -u' 'if [ -z "${1:-}" ]; then' '    echo "STOP: no name" >&2' \
    '    echo "usage: greet.sh <name>" >&2' '    exit 1' 'fi' 'echo "hello $1"' >"${ORIG}"
chmod 755 -- "${ORIG}"
TEXT=${WORK}/notes.txt
printf '%s\n' 'first' 'if [ x ]; then' 'fi' 'last' >"${TEXT}"
chmod 644 -- "${TEXT}"

# A FIFO with no writer blocks a reader forever; a checker that opens one is cut off, not waited on.
run() { OUT="$(timeout 10 bash "${CHECKER}" "$@" 2>&1)"; RC=$?; }
# mutate <original> <name> <sed script>: a copy saved on disk with the original's mode
mutate() {
    M=${WORK}/$2
    sed -e "$3" -- "$1" >"${M}"
    chmod --reference="$1" -- "${M}"
}
is_sane() { equals "$1: exit code" "${RC}" 0; equals "$1: output" "${OUT}" ''; }
is_refused() {
    equals "$1: exit code" "${RC}" "${3:-1}"
    equals "$1: output lines" "$(printf '%s\n' "${OUT}" | wc -l)" 1
    matches "$1: names the refusal" "${OUT}" "$2"
}
NOT_ON_DISK='^mutant-sane: REFUSED the mutant is not a regular file saved on disk: '

# --- 0. sane mutants pass in silence ---
mutate "${ORIG}" one-line.sh 8d; run "${ORIG}" "${M}"
is_sane 'case 0a: one line deleted'
mutate "${ORIG}" range.sh 4,5d; run "${ORIG}" "${M}" 4-5
is_sane 'case 0b: lines 4-5 deleted, range given'
mutate "${ORIG}" single.sh 8d; run "${ORIG}" "${M}" 8
is_sane 'case 0c: line 8 deleted, one-line range given'
mutate "${TEXT}" notes-m.txt 3d; run "${TEXT}" "${M}"
is_sane 'case 0d: a file with no shell shebang is not parse-checked'

# --- 1. the mutant is not a regular file saved on disk ---
run "${ORIG}" "${WORK}/missing.sh"
is_refused 'case 1a: missing path' "${NOT_ON_DISK}"
mkfifo -- "${WORK}/fifo"
run "${ORIG}" "${WORK}/fifo"
is_refused 'case 1b: FIFO' "${NOT_ON_DISK}"
run "${ORIG}" <(sed -e 8d -- "${ORIG}")
is_refused 'case 1c: <(...) process substitution' "${NOT_ON_DISK}/dev/fd/"
ln -s -- "${WORK}/fifo" "${WORK}/fifo-link"
run "${ORIG}" "${WORK}/fifo-link"
is_refused 'case 1d: symlink to a FIFO' "${NOT_ON_DISK}"
mutate "${ORIG}" fd.sh 8d
exec 3<"${M}"
run "${ORIG}" /dev/fd/3
exec 3<&-
is_refused 'case 1e: /dev/fd/3 open on a regular file' "${NOT_ON_DISK}/dev/fd/3$"

# --- 2. byte-identical ---
cp -p -- "${ORIG}" "${WORK}/same.sh"; run "${ORIG}" "${WORK}/same.sh"
is_refused 'case 2: identical copy' '^mutant-sane: REFUSED the mutant is byte-identical to the original$'

# --- 3. mode differs ---
mutate "${ORIG}" no-exec.sh 8d; chmod 644 -- "${M}"; run "${ORIG}" "${M}"
is_refused 'case 3: copied without the exec bit' "^mutant-sane: REFUSED the mutant's mode 644 differs from the original's 755$"

# --- 4. a shell script's mutant does not parse ---
mutate "${ORIG}" no-fi.sh 7d; run "${ORIG}" "${M}"
is_refused 'case 4: deleted fi' '^mutant-sane: REFUSED the mutant of a shell script does not parse \(bash -n\)$'

# --- 5. not exactly the intended deletion ---
ONE_LINE='^mutant-sane: REFUSED the mutant is not the original with exactly one line removed and nothing added or changed$'
mutate "${ORIG}" two-lines.sh 4,5d; run "${ORIG}" "${M}"
is_refused 'case 5a: two lines removed, no range' "${ONE_LINE}"
mutate "${ORIG}" changed.sh 's/hello/bye/'; run "${ORIG}" "${M}"
is_refused 'case 5b: one line changed, no range' "${ONE_LINE}"
mutate "${ORIG}" del-and-add.sh '8d;2a echo extra'; run "${ORIG}" "${M}"
is_refused 'case 5c: one line removed and one added, no range' "${ONE_LINE}"
mutate "${ORIG}" stale.sh 4,5d; run "${ORIG}" "${M}" 4
is_refused 'case 5d: a stale range removed more than line 4' '^mutant-sane: REFUSED the mutant is not the original with exactly line\(s\) 4 removed$'
mutate "${ORIG}" wide.sh 8d; run "${ORIG}" "${M}" 8-9
is_refused 'case 5e: a range past the last line' "^mutant-sane: REFUSED the range 8-9 is not inside the original's 8 lines$"
run "${ORIG}" "${WORK}/one-line.sh" 5-4
is_refused 'case 5f: a range that runs backwards' "^mutant-sane: REFUSED the range 5-4 is not inside the original's 8 lines$"

# --- 6. usage ---
run "${ORIG}"
is_refused 'case 6a: one argument' '^usage: mutant-sane.sh ' 2
run "${ORIG}" "${WORK}/one-line.sh" 4-
is_refused 'case 6b: a malformed range' '^usage: mutant-sane.sh ' 2
run "${WORK}/missing.sh" "${WORK}/one-line.sh"
is_refused 'case 6c: the original is not on disk' '^usage: mutant-sane.sh ' 2
run "${ORIG}" "${WORK}/one-line.sh" 8 --with 'echo "bye $1"'
is_refused 'case 6d: a fourth argument that is not --replaced-with' '^usage: mutant-sane.sh ' 2
run "${ORIG}" "${WORK}/one-line.sh" 4-5 --replaced-with 'echo x'
is_refused 'case 6e: a range with --replaced-with' '^usage: mutant-sane.sh ' 2
run "${ORIG}" "${WORK}/one-line.sh" 8 --replaced-with ''
is_refused 'case 6f: an empty replacement' '^usage: mutant-sane.sh ' 2

# --- 7. a replacement: exactly line N swapped for exactly the given text ---
BYE='echo "bye $1"'
REPLACED='^mutant-sane: REFUSED the mutant is not the original with exactly line 8 replaced by the given text$'
mutate "${ORIG}" bye.sh "8s/.*/${BYE}/"; run "${ORIG}" "${M}" 8 --replaced-with "${BYE}"
is_sane 'case 7a: line 8 replaced'
mutate "${ORIG}" wrong-line.sh "4s/.*/${BYE}/"; run "${ORIG}" "${M}" 8 --replaced-with "${BYE}"
is_refused 'case 7b: another line replaced' "${REPLACED}"
mutate "${ORIG}" bye-extra.sh "8s/.*/${BYE}/;2a echo extra"; run "${ORIG}" "${M}" 8 --replaced-with "${BYE}"
is_refused 'case 7c: the replacement plus an extra line' "${REPLACED}"
mutate "${ORIG}" bye-other.sh "8s/.*/${BYE}/"; run "${ORIG}" "${M}" 8 --replaced-with 'echo "bye"'
is_refused 'case 7d: the text does not match the replacement' "${REPLACED}"
NOTRAIL=${WORK}/no-newline.txt
printf 'first\nlast' >"${NOTRAIL}"
printf 'first\nLAST' >"${WORK}/no-newline-m.txt"
run "${NOTRAIL}" "${WORK}/no-newline-m.txt" 2 --replaced-with LAST
is_sane 'case 7e: a last line with no newline stays without one'
run "${ORIG}" "${WORK}/bye.sh" 9 --replaced-with "${BYE}"
is_refused 'case 7f: a line past the end' "^mutant-sane: REFUSED the line 9 is not inside the original's 8 lines$"

if [ "${fails}" -eq 0 ]; then
    printf 'mutant-sane-test: all cases passed\n'
    exit 0
fi
printf 'mutant-sane-test: %s check(s) failed\n' "${fails}" >&2
exit 1
