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
# replace_literally <original> <name> <line> <text>: line swapped for the text with no escape or & read, as a sweep does
replace_literally() {
    M=${WORK}/$2
    N=$3 T=$4 awk 'NR == ENVIRON["N"] { print ENVIRON["T"]; next } { print }' "$1" >"${M}"
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
GOOD=${M}
UP=$(printf '../%.0s' {1..40})
ln -s -- /dev/fd/3 "${WORK}/fd-link"
ln -s -- /dev/fd "${WORK}/fd-dir"
exec 3<"${GOOD}"
run "${ORIG}" /dev/fd/3
is_refused 'case 1e: /dev/fd/3 open on a regular file' "${NOT_ON_DISK}/dev/fd/3$"
run "${ORIG}" //dev/fd/3
is_refused 'case 1f: //dev/fd/3 open on a regular file' "${NOT_ON_DISK}//dev/fd/3$"
run "${ORIG}" "${WORK}/${UP}dev/fd/3"
is_refused 'case 1g: a .. route to /dev/fd/3' "${NOT_ON_DISK}/.*/\\.\\./dev/fd/3$"
run "${ORIG}" "${WORK}/fd-link"
is_refused 'case 1h: a symlink to /dev/fd/3' "${NOT_ON_DISK}/.*/fd-link$"
run "${ORIG}" "${WORK}/fd-dir/3"
is_refused 'case 1i: a symlinked directory to /dev/fd' "${NOT_ON_DISK}/.*/fd-dir/3$"
exec 3<&-
ln -s -- "${GOOD}" "${WORK}/good-link"
run "${ORIG}" "${WORK}/good-link"
is_refused 'case 1j: a symlink to a sane regular file is refused, not followed' "${NOT_ON_DISK}/.*/good-link$"
ln -s -- "${ORIG}" "${WORK}/orig-link"
run "${WORK}/orig-link" "${GOOD}"
is_refused 'case 1k: the original given as a symlink' '^usage: mutant-sane.sh ' 2
ln -- "${GOOD}" "${WORK}/hard.sh"
run "${ORIG}" "${WORK}/hard.sh"
is_sane 'case 1l: a hardlink to a sane mutant is judged by its bytes'

# --- 2. byte-identical ---
cp -p -- "${ORIG}" "${WORK}/same.sh"; run "${ORIG}" "${WORK}/same.sh"
IDENTICAL='^mutant-sane: REFUSED the mutant is byte-identical to the original$'
is_refused 'case 2a: identical copy' "${IDENTICAL}"
ln -- "${ORIG}" "${WORK}/orig-hard.sh"; run "${ORIG}" "${WORK}/orig-hard.sh"
is_refused 'case 2b: a hardlink to the original' "${IDENTICAL}"

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
printf 'first\nlast' >"${WORK}/end-open.txt"
printf 'first\n' >"${WORK}/end-open-m.txt"
chmod 644 -- "${WORK}/end-open.txt" "${WORK}/end-open-m.txt"
run "${WORK}/end-open.txt" "${WORK}/end-open-m.txt" 2
is_sane 'case 5g: the last line, with no newline, deleted, range given'
run "${WORK}/end-open.txt" "${WORK}/end-open-m.txt"
is_sane 'case 5h: the last line, with no newline, deleted, no range'

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
{ head -n 7 -- "${ORIG}"; printf 'echo a\necho b\n'; } >"${WORK}/two-for-one.sh"
chmod 755 -- "${WORK}/two-for-one.sh"
run "${ORIG}" "${WORK}/two-for-one.sh" 8 --replaced-with $'echo a\necho b'
is_refused 'case 6g: a replacement text with a newline' '^usage: mutant-sane.sh ' 2

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
{ cat -- "${ORIG}"; printf 'echo extra'; } >"${WORK}/appended.sh"
chmod 755 -- "${WORK}/appended.sh"
run "${ORIG}" "${WORK}/appended.sh" 9 --replaced-with 'echo extra'
is_refused 'case 7g: line 9 of 8 "replaced" by text appended at the end' "^mutant-sane: REFUSED the line 9 is not inside the original's 8 lines$"
cp -p -- "${ORIG}" "${WORK}/same-text.sh"
run "${ORIG}" "${WORK}/same-text.sh" 8 --replaced-with 'echo "hello $1"'
is_refused 'case 7h: line 8 replaced by its own text' "${IDENTICAL}"

# --- 8. near misses that must not pass for the intended mutant ---
mutate "${ORIG}" spaced.sh '8d;2s/$/ /'; run "${ORIG}" "${M}"
is_refused 'case 8a: a trailing space added as well, no range' "${ONE_LINE}"
run "${ORIG}" "${M}" 8
is_refused 'case 8b: a trailing space added as well, range given' '^mutant-sane: REFUSED the mutant is not the original with exactly line\(s\) 8 removed$'
mutate "${TEXT}" crlf.txt '3d;s/$/\r/'; run "${TEXT}" "${M}"
is_refused 'case 8c: CRLF line endings introduced' "${ONE_LINE}"
sed -e 4d -- "${ORIG}" | head -c -1 >"${WORK}/no-final-newline.sh"
chmod 755 -- "${WORK}/no-final-newline.sh"
run "${ORIG}" "${WORK}/no-final-newline.sh"
is_refused 'case 8d: the final newline removed as well' "${ONE_LINE}"
mutate "${TEXT}" exec.txt 3d; chmod 755 -- "${M}"; run "${TEXT}" "${M}"
is_refused 'case 8e: the exec bit gained' "^mutant-sane: REFUSED the mutant's mode 755 differs from the original's 644$"
META='echo "a&b \t \\ $1 [x]* s/.*/&/"'
META_ONE_BACKSLASH='echo "a&b \t \ $1 [x]* s/.*/&/"'
replace_literally "${ORIG}" meta.sh 8 "${META}"; run "${ORIG}" "${M}" 8 --replaced-with "${META}"
is_sane 'case 8f: & and backslashes in the text, matched literally'
run "${ORIG}" "${M}" 8 --replaced-with "${META_ONE_BACKSLASH}"
is_refused 'case 8g: one backslash fewer in the text' "${REPLACED}"
mutate "${ORIG}" meta-sed.sh "8s#.*#${META}#"; run "${ORIG}" "${M}" 8 --replaced-with "${META}"
is_refused 'case 8h: a mutant whose & and backslashes sed interpreted' "${REPLACED}"
mkdir -- "${WORK}/with space"
SPACED="${WORK}/with space/greet orig.sh"
cp -p -- "${ORIG}" "${SPACED}"
mutate "${SPACED}" 'with space/one line.sh' 8d; run "${SPACED}" "${M}" 8
is_sane 'case 8i: an original path with spaces, deletion'
replace_literally "${SPACED}" 'with space/bye one.sh' 8 "${BYE}"; run "${SPACED}" "${M}" 8 --replaced-with "${BYE}"
is_sane 'case 8j: an original path with spaces, replacement'
run "${SPACED}" "${WORK}/with space/missing one.sh"
is_refused 'case 8k: a missing mutant path with spaces is named whole' "${NOT_ON_DISK}/.*/with space/missing one.sh$"

if [ "${fails}" -eq 0 ]; then
    printf 'mutant-sane-test: all cases passed\n'
    exit 0
fi
printf 'mutant-sane-test: %s check(s) failed\n' "${fails}" >&2
exit 1
