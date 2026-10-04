#!/usr/bin/env bash
# Fixtures only: a small project with three guards drives the real scripts/guard-mutants.sh.
# Red proofs: GUARD_MUTANTS_SH=<mutant copy>; GUARD_MUTANTS_TEST_DIR=<dir> moves the work dir.
# shellcheck disable=SC2016  # the fixtures hold shell text, quoted literally
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK=$(realpath -e -- "${GUARD_MUTANTS_SH:-${SCRIPT_DIR}/guard-mutants.sh}") || exit 1
# /srv/worker-scratch (root 755, exec), as scripts/lib/deploy/test.sh: never /tmp.
WORK=$(mktemp -d -p "${GUARD_MUTANTS_TEST_DIR:-/srv/worker-scratch}" guard-mutants-test.XXXXXXXX) || exit 1
trap 'rm -rf -- "${WORK:?}"' EXIT

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
has()    { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1: no [$3] in $(tr '\n' '|' <"$2")"; fi; }
empty_dir() { if [ -z "$(ls -A -- "$2")" ]; then pass "$1: work dir left empty"; else fail "$1: work dir left $(ls -A -- "$2")"; fi; }

P=$WORK/proj
mkdir -p "$P" "$WORK/outside" "$WORK/shared"
cat >"$P/lib.sh" <<'EOF'
validate() {
    [ -n "$1" ] || { echo "refused: empty"; return 1; }
    [ "${#1}" -le 8 ] || { echo "refused: long"; return 1; }
    case "$1" in
        *..*) echo "refused: dotdot"; return 1 ;;
    esac
    return 0
}
note() {
    echo "note: $1"
    return 0
}
EOF
cat >"$P/test.sh" <<'EOF'
#!/usr/bin/env bash
. ./lib.sh || exit 3
f=0
validate "" >/dev/null && { echo "FAIL empty input is refused"; f=1; }
validate "abcdefghij" >/dev/null && { echo "FAIL long input is refused"; f=1; }
validate "a..b" >/dev/null && { echo "FAIL dotdot is refused"; f=1; }
validate "ab" >/dev/null || { echo "FAIL plain input is accepted"; f=1; }
exit "$f"
EOF
cat >"$P/toothless.sh" <<'EOF'
#!/usr/bin/env bash
. ./lib.sh || exit 3
validate "ab" >/dev/null || { echo "FAIL plain input is accepted"; exit 1; }
EOF
cat >"$P/slow.sh" <<'EOF'
#!/usr/bin/env bash
. ./lib.sh || exit 3
validate "" >/dev/null && { echo "FAIL empty input is refused"; sleep 30; }
exit 0
EOF
cat >"$P/hang.sh" <<'EOF'
#!/usr/bin/env bash
. ./lib.sh || exit 3
validate "" >/dev/null && { echo "$$" >"${HANG_PID:?}"; exec sleep 30; }
exit 0
EOF
cat >"$P/par.sh" <<'EOF'
#!/usr/bin/env bash
echo "$$" >"${TMPDIR:?}/owner"
sleep 1
[ "$(cat "$TMPDIR/owner")" = "$$" ] || { echo "CLOBBERED"; exit 9; }
exec ./test.sh
EOF
printf 'guard\n' >"$WORK/outside/g.sh"
printf '1.0\n01\n1\n  1e0\n' >"$P/nums.txt"
ln -s "$WORK/outside" "$P/outlink"
chmod 755 "$P"/*.sh

tree_sum() { (cd -- "$1" && { find . -printf '%p %y %m %l\n' | sort; find . -type f -exec sha256sum {} + | sort; }) | sha256sum; }
BEFORE=$(tree_sum "$P")
OUTSIDE=$(sha256sum <"$WORK/outside/g.sh")

E_EMPTY='file: lib.sh
line: [ -n "$1" ] || { echo "refused: empty"; return 1; }
expect: FAIL empty input is refused'
E_LONG='file: lib.sh
line: [ "${#1}" -le 8 ] || { echo "refused: long"; return 1; }
expect: FAIL long input is refused'
E_DOTDOT='file: lib.sh
line:      *..*) echo "refused: dotdot"; return 1 ;;
expect: FAIL dotdot is refused'

manifest() { local f=$WORK/$1.manifest; shift; printf '%s\n' "$@" >"$f"; }
run() {
    local c=$1 m=$2; shift 2
    mkdir -p "$WORK/w-$c"
    "$CHECK" -r "$P" -w "$WORK/w-$c" "$@" "$WORK/$m.manifest" >"$WORK/$c.out" 2>"$WORK/$c.err"
    echo "$?" >"$WORK/$c.rc"
}
rc() { cat -- "$WORK/$1.rc"; }
summary() { grep '^guard-mutants: ' "$WORK/$1.out"; }

manifest real '# comments and blank lines are skipped' '' 'test: ./test.sh' "$E_EMPTY" "$E_LONG" "$E_DOTDOT"
run real real
equals "real: exit" "$(rc real)" 0
equals "real: summary" "$(summary real)" "guard-mutants: 3 caught, 0 survived, 0 errored of 3"
has "real: a line per entry" "$WORK/real.out" 'caught   lib.sh: *..*) echo "refused: dotdot"; return 1 ;; (rc=1, expect printed)'
equals "real: lines printed" "$(wc -l <"$WORK/real.out")" 4
empty_dir real "$WORK/w-real"

manifest toothless 'test: ./toothless.sh' "$E_EMPTY" "$E_DOTDOT"
run toothless toothless
equals "toothless: exit" "$(rc toothless)" 1
equals "toothless: summary" "$(summary toothless)" "guard-mutants: 0 caught, 2 survived, 0 errored of 2"
has "toothless: says SURVIVED" "$WORK/toothless.out" 'SURVIVED lib.sh: [ -n "$1" ]'

manifest match 'test: ./test.sh' "$E_EMPTY" \
    'file: lib.sh' 'line: [ -z "nothing like this" ]' 'expect: FAIL empty input is refused' \
    'file: lib.sh' 'line: return 0' 'expect: FAIL plain input is accepted'
run match match
equals "match: exit" "$(rc match)" 1
equals "match: summary" "$(summary match)" "guard-mutants: 1 caught, 0 survived, 2 errored of 3"
has "match: zero matches named" "$WORK/match.out" 'the line matches 0 lines, not one'
has "match: two matches named" "$WORK/match.out" 'the line matches 2 lines, not one'

manifest baseline 'test: ./test.sh && exit 4' "$E_EMPTY"
run baseline baseline
equals "baseline: exit" "$(rc baseline)" 1
equals "baseline: only the ERROR line" "$(cat "$WORK/baseline.out")" \
    "guard-mutants: ERROR, the test fails on an unmutated copy (4); nothing judged"
empty_dir baseline "$WORK/w-baseline"

manifest syntax 'test: ./test.sh' 'file: lib.sh' 'line: esac' 'expect: FAIL dotdot is refused'
run syntax syntax
equals "syntax error: exit" "$(rc syntax)" 1
equals "syntax error: summary" "$(summary syntax)" "guard-mutants: 0 caught, 0 survived, 1 errored of 1"
has "syntax error: errored, not caught" "$WORK/syntax.out" 'errored  lib.sh: esac (rc=3 without the expect string)'

manifest loud 'test: echo checking; ./test.sh' 'file: lib.sh' 'line: esac' 'expect: checking'
run loud loud
equals "baseline prints expect: summary" "$(summary loud)" "guard-mutants: 0 caught, 0 survived, 1 errored of 1"
has "baseline prints expect: named" "$WORK/loud.out" '(the unmutated test prints the expect string too)'

manifest metachar 'test: ./test.sh >/dev/null || { echo "FAIL axb (step 3)"; exit 1; }' \
    'file: lib.sh' 'line: [ -n "$1" ] || { echo "refused: empty"; return 1; }' 'expect: FAIL a.b (step 3)'
run metachar metachar
equals "regex characters in expect: summary" "$(summary metachar)" "guard-mutants: 0 caught, 0 survived, 1 errored of 1"

manifest numeric 'test: grep -qx 1 nums.txt || { echo "FAIL the line 1 is gone"; exit 1; }' \
    'file: nums.txt' 'line: 1' 'expect: FAIL the line 1 is gone'
run numeric numeric
equals "1 is not 1.0, 01 or 1e0: summary" "$(summary numeric)" "guard-mutants: 1 caught, 0 survived, 0 errored of 1"

manifest leftover 'test: sleep 0.3; while read -r p; do ! kill -0 "$p" 2>/dev/null || { echo "LEFTOVER $p"; exit 7; }; done <"${LEFTOVERS:?}"; sleep 30 & echo "$!" >>"$LEFTOVERS"; ./test.sh' "$E_EMPTY"
: >"$WORK/leftovers"
LEFTOVERS=$WORK/leftovers run leftover leftover
equals "leftover: summary" "$(summary leftover)" "guard-mutants: 1 caught, 0 survived, 0 errored of 1"
alive=0
while read -r pid; do kill -0 "$pid" 2>/dev/null && { alive=$((alive + 1)); kill "$pid"; }; done <"$WORK/leftovers"
equals "leftover: processes a test left behind are ended" "$alive" 0

manifest timeout 'test: ./slow.sh' 'timeout: 2' "$E_EMPTY"
run timeout timeout
equals "timeout: summary" "$(summary timeout)" "guard-mutants: 0 caught, 0 survived, 1 errored of 1"
has "timeout: named" "$WORK/timeout.out" '(timed out after 2s)'

manifest escape 'test: ./test.sh' \
    'file: outlink/g.sh' 'line: guard' 'expect: FAIL' \
    'file: ../outside/g.sh' 'line: guard' 'expect: FAIL'
run escape escape
equals "escape: summary" "$(summary escape)" "guard-mutants: 0 caught, 0 survived, 2 errored of 2"
equals "escape: the file outside the root is untouched" "$(sha256sum <"$WORK/outside/g.sh")" "$OUTSIDE"

manifest none 'test: ./test.sh'
run none none
equals "no entries: exit" "$(rc none)" 1
equals "no entries: summary" "$(summary none)" "guard-mutants: 0 caught, 0 survived, 0 errored of 0"

manifest noexpect 'test: ./test.sh' 'file: lib.sh' 'line: esac'
run noexpect noexpect
equals "no expect: exit" "$(rc noexpect)" 2
has "no expect: named" "$WORK/noexpect.err" 'entry 1 (lib.sh) has no expect:'
manifest blankexpect 'test: ./test.sh' 'file: lib.sh' 'line: esac' 'expect:'
run blankexpect blankexpect
equals "blank expect: exit" "$(rc blankexpect)" 2

usage_case() {
    local c=$1 want=$2; shift 2
    manifest "$c" "$@"
    run "$c" "$c"
    equals "usage $c: exit" "$(rc "$c")" 2
    has "usage $c: named" "$WORK/$c.err" "$want"
    empty_dir "usage $c" "$WORK/w-$c"
}
usage_case notest 'has no test:' "$E_EMPTY"
usage_case twotests 'a second test:' 'test: ./test.sh' 'test: ./test.sh'
usage_case nokey 'is not' 'test: ./test.sh' 'just words'
usage_case unknown "unknown key 'lines'" 'test: ./test.sh' 'file: lib.sh' 'lines: esac'
usage_case orphan 'line: before any file:' 'test: ./test.sh' 'line: esac'
usage_case twolines 'a second line:' 'test: ./test.sh' 'file: lib.sh' 'line: esac' 'line: esac' 'expect: x'
usage_case twoexpects 'a second expect:' 'test: ./test.sh' 'file: lib.sh' 'line: esac' 'expect: x' 'expect: y'
usage_case noline 'has no line:' 'test: ./test.sh' 'file: lib.sh' 'line:   ' 'expect: x'
usage_case nofile 'has an empty file:' 'test: ./test.sh' 'file:' 'line: esac' 'expect: x'
usage_case badtimeout "timeout: takes whole seconds" 'test: ./test.sh' 'timeout: 0'
usage_case crlf 'holds a carriage return' $'test: ./test.sh\r'

run badjobs real -j 0
equals "usage -j 0: exit" "$(rc badjobs)" 2
has "usage -j 0: named" "$WORK/badjobs.err" '-j takes a whole number'
run badopt real -x
equals "usage bad option: exit" "$(rc badopt)" 2
has "usage bad option: prints usage" "$WORK/badopt.err" 'usage: guard-mutants.sh'
"$CHECK" -r "$P" -w "$WORK" >/dev/null 2>"$WORK/noarg.err"
equals "usage no manifest argument: exit" "$?" 2
has "usage no manifest argument: prints usage" "$WORK/noarg.err" 'usage: guard-mutants.sh'
mkdir -p "$P/.scratch-inside"
"$CHECK" -r "$P" -w "$P/.scratch-inside" "$WORK/real.manifest" >"$WORK/inside.out" 2>"$WORK/inside.err"
equals "inside root: exit" "$?" 2
has "inside root: named" "$WORK/inside.err" 'is inside the root'
rmdir "$P/.scratch-inside"
"$CHECK" -r "$P/lib.sh" -w "$WORK" "$WORK/real.manifest" >/dev/null 2>"$WORK/noroot.err"
equals "root not a directory: exit" "$?" 2
has "root not a directory: named" "$WORK/noroot.err" '-r names no directory'
"$CHECK" -r "$P" -w "$WORK/real.manifest" "$WORK/real.manifest" >/dev/null 2>"$WORK/nowork.err"
equals "work dir not a directory: exit" "$?" 2
has "work dir not a directory: named" "$WORK/nowork.err" '-w names no directory'
"$CHECK" -r "$P" -w "$WORK" "$WORK/no-such.manifest" >/dev/null 2>"$WORK/nomanifest.err"
equals "missing manifest: exit" "$?" 2
has "missing manifest: named" "$WORK/nomanifest.err" 'no manifest file'

manifest jobs 'test: mkdir "${JLOCK:?}" || { echo OVERLAP; exit 7; }; sleep 0.3; rmdir "$JLOCK"; exec ./test.sh' "$E_EMPTY" "$E_LONG" "$E_DOTDOT"
JLOCK=$WORK/jlock run jobs jobs -j 1
equals "jobs cap: summary" "$(summary jobs)" "guard-mutants: 3 caught, 0 survived, 0 errored of 3"

# Two whole invocations at once, -j 3 each, one work dir and one inherited TMPDIR between them.
manifest par 'test: ./par.sh' "$E_EMPTY" "$E_LONG" "$E_DOTDOT"
mkdir -p "$WORK/w-par"
pids=()
for i in 1 2; do
    TMPDIR=$WORK/shared "$CHECK" -r "$P" -w "$WORK/w-par" -j 3 "$WORK/par.manifest" >"$WORK/par$i.out" 2>&1 &
    pids[i]=$!
done
for i in 1 2; do wait "${pids[i]}"; echo "$?" >"$WORK/par$i.rc"; done
equals "parallel: first exit" "$(rc par1)" 0
equals "parallel: second exit" "$(rc par2)" 0
equals "parallel: first summary" "$(summary par1)" "guard-mutants: 3 caught, 0 survived, 0 errored of 3"
equals "parallel: second summary" "$(summary par2)" "guard-mutants: 3 caught, 0 survived, 0 errored of 3"
equals "parallel: identical reports" "$(sha256sum <"$WORK/par1.out")" "$(sha256sum <"$WORK/par2.out")"
empty_dir parallel "$WORK/w-par"

manifest term 'test: ./hang.sh' 'timeout: 60' "$E_EMPTY"
mkdir -p "$WORK/w-term"
HANG_PID=$WORK/hang.pid "$CHECK" -r "$P" -w "$WORK/w-term" "$WORK/term.manifest" >"$WORK/term.out" 2>&1 &
runner=$!
for _ in $(seq 100); do [ -s "$WORK/hang.pid" ] && break; sleep 0.1; done
kill -TERM "$runner"
wait "$runner"
equals "sigterm: exit" "$?" 143
hung=$(cat "$WORK/hang.pid" 2>/dev/null)
if [ -n "$hung" ] && kill -0 "$hung" 2>/dev/null; then
    fail "sigterm: test process gone (pid $hung still runs)"; kill "$hung" 2>/dev/null
else pass "sigterm: test process gone"; fi
empty_dir sigterm "$WORK/w-term"

# A signal to the runner while an entry's tree is being copied: the runner waits for that copy,
# the test it was about to start never starts, and nothing it started outlives it.
REAL_CP=$(command -v cp)
mkdir -p "$WORK/shim"
printf '#!/usr/bin/env bash\n[ "$1" != -a ] || echo >>"$CP_CALLS"\n[ "$1" != -a ] || [ "$(wc -l <"$CP_CALLS")" -lt 2 ] || { echo "$$" >"$CP_SLOW"; sleep 2; }\nexec %s "$@"\n' "$REAL_CP" >"$WORK/shim/cp"
chmod 755 "$WORK/shim/cp"
window_signal() {
    local c=$1 sig=$2 launcher hung cpid
    manifest "$c" 'test: ./hang.sh' 'timeout: 60' "$E_EMPTY"
    mkdir -p "$WORK/w-$c"; rm -f -- "$WORK/hang.pid" "$WORK/cp.calls" "$WORK/cp.slow"
    PATH=$WORK/shim:$PATH CP_CALLS=$WORK/cp.calls CP_SLOW=$WORK/cp.slow HANG_PID=$WORK/hang.pid \
        setsid perl -e '$SIG{INT} = $SIG{HUP} = "DEFAULT"; exec @ARGV' \
        bash -c 'echo "$$" >"$0"; exec "$@"' "$WORK/$c.rpid" "$CHECK" -r "$P" -w "$WORK/w-$c" "$WORK/$c.manifest" \
        >"$WORK/$c.out" 2>&1 </dev/null &
    launcher=$!
    for _ in $(seq 100); do [ -s "$WORK/cp.slow" ] && break; sleep 0.1; done
    kill -"$sig" "$(cat "$WORK/$c.rpid")"
    for _ in $(seq 80); do kill -0 "$launcher" 2>/dev/null || break; sleep 0.1; done
    hung=$(cat "$WORK/hang.pid" 2>/dev/null)
    if [ -z "$hung" ]; then pass "$c: the test never started"
    else fail "$c: the test never started (pid $hung ran)"; kill "$hung" 2>/dev/null; fi
    { wait "$launcher"; } 2>/dev/null
    cpid=$(cat "$WORK/cp.slow" 2>/dev/null)
    if [ -n "$cpid" ] && kill -0 "$cpid" 2>/dev/null; then fail "$c: nothing outlives the runner (copy $cpid runs)"
    else pass "$c: nothing outlives the runner"; fi
    sleep 2.5
    empty_dir "$c" "$WORK/w-$c"
}
window_signal "window TERM" TERM
window_signal "window INT" INT
window_signal "window HUP" HUP 2>/dev/null

# What a terminal sends: the signal to the runner's whole process group, INT and HUP not ignored.
group_signal() {
    local c=$1 sig=$2 want=$3 launcher hung
    manifest "$c" 'test: ./hang.sh' 'timeout: 60' "$E_EMPTY"
    mkdir -p "$WORK/w-$c"; rm -f -- "$WORK/hang.pid"
    HANG_PID=$WORK/hang.pid setsid perl -e '$SIG{INT} = $SIG{HUP} = "DEFAULT"; exec @ARGV' \
        bash -c 'echo "$$" >"$0"; exec "$@"' "$WORK/$c.rpid" "$CHECK" -r "$P" -w "$WORK/w-$c" "$WORK/$c.manifest" \
        >"$WORK/$c.out" 2>&1 </dev/null &
    launcher=$!
    for _ in $(seq 100); do [ -s "$WORK/hang.pid" ] && break; sleep 0.1; done
    kill -"$sig" -- "-$(cat "$WORK/$c.rpid")"
    { wait "$launcher"; } 2>/dev/null
    equals "$c: exit" "$?" "$want"
    sleep 0.5
    hung=$(cat "$WORK/hang.pid" 2>/dev/null)
    if [ -n "$hung" ] && kill -0 "$hung" 2>/dev/null; then
        fail "$c: test process gone (pid $hung still runs)"; kill "$hung" 2>/dev/null
    else pass "$c: test process gone"; fi
    empty_dir "$c" "$WORK/w-$c"
}
group_signal sigint INT 130
group_signal sighup HUP 129

equals "the caller's tree is byte-identical" "$(tree_sum "$P")" "$BEFORE"

if [ "$fails" -eq 0 ]; then printf 'guard-mutants-test: all checks passed\n'; exit 0; fi
printf 'guard-mutants-test: %d check(s) failed\n' "$fails"
exit 1
