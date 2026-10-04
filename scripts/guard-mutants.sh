#!/usr/bin/env bash
# T5, automatically: deletes each guard line in a fresh copy of a tree and expects the test to go red.
set -uo pipefail

usage() {
    cat >&2 <<'EOF'
usage: guard-mutants.sh -r ROOT -w WORKDIR [-j N] MANIFEST

Copies ROOT once per entry into a fresh mktemp -d beneath WORKDIR, deletes the entry's
guard line there, runs the test, and judges the saved output. ROOT is never written;
every copy is removed on any exit. -j N runs N entries at once (default 1).

MANIFEST is plain text, one "key: value" per line; blank lines and # lines are skipped.
  test: <command>      exactly once; run by bash with the copy as its working directory
                       and TMPDIR set to a directory of its own
  timeout: <seconds>   optional, for each run of the test (default 120)
  file: <path>         starts an entry; the file holding the guard, relative to ROOT
  line: <text>         the guard line, a fixed string (not a regex); it must equal exactly
                       one line of the file, blanks around either side ignored
  expect: <text>       required; a fixed string the test prints when the guard is gone,
                       the gate's own failure line
A guard is one physical line: a "\" continuation is two lines, and only one is deleted.
expect is matched as a fixed substring of the output, and blanks after it count.
Give -r a plain directory or clone: a test can write through a symlink or a worktree's .git link.
Run it as an unprivileged user (nobody) in a work dir that user owns: a mutant runs with your rights.

The test runs on an unmutated copy first; unless that exits 0 the run is ERROR and
nothing is judged. Then, per entry:
  caught    the test exited non-zero and printed expect
  SURVIVED  the test exited 0 with the guard gone
  errored   non-zero without expect, timed out, the line matched 0 or 2+ lines,
            or the unmutated test already prints expect, so it proves nothing
One line per entry, then "guard-mutants: <n> caught, <s> survived, <e> errored of <t>".
Exit 0 only when every entry is caught and there is at least one; 1 otherwise; 2 usage.
EOF
}

die() { printf 'guard-mutants: %s\n' "$1" >&2; exit 2; }

ROOT='' WORK='' JOBS=1
while getopts r:w:j:h opt; do
    case "$opt" in
        r) ROOT=$OPTARG ;;
        w) WORK=$OPTARG ;;
        j) JOBS=$OPTARG ;;
        *) usage; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || { usage; exit 2; }
MANIFEST=$1
[ -d "$ROOT" ] || die "-r names no directory: '$ROOT'"
[ -d "$WORK" ] || die "-w names no directory: '$WORK'"
[ -f "$MANIFEST" ] || die "no manifest file '$MANIFEST'"
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die "-j takes a whole number above 0, not '$JOBS'"
ROOT=$(realpath -e -- "$ROOT") WORK=$(realpath -e -- "$WORK")
[[ "$WORK/" != "$ROOT/"* ]] || die "the work directory $WORK is inside the root $ROOT"

TEST='' TIMEOUT=120 n=0 ln=0
FILES=() LINES=() EXPECTS=()
while IFS= read -r l || [ -n "$l" ]; do
    ln=$((ln + 1))
    [[ $l != *$'\r'* ]] || die "manifest line $ln holds a carriage return; save the file with Unix line ends"
    [[ $l =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $l == *:* ]] || die "manifest line $ln is not 'key: value'"
    key=${l%%:*} val=${l#*:} val=${val# }
    case "$key" in
        test)
            [ -z "$TEST" ] || die "manifest line $ln: a second test:"
            TEST=$val ;;
        timeout) TIMEOUT=$val ;;
        file) n=$((n + 1)); FILES[n]=$val ;;
        line|expect)
            [ "$n" -gt 0 ] || die "manifest line $ln: $key: before any file:"
            if [ "$key" = line ]; then
                [ -z "${LINES[n]+set}" ] || die "manifest line $ln: a second line: in one entry"
                val=${val#"${val%%[![:space:]]*}"} LINES[n]=${val%"${val##*[![:space:]]}"}
            else
                [ -z "${EXPECTS[n]+set}" ] || die "manifest line $ln: a second expect: in one entry"
                EXPECTS[n]=$val
            fi ;;
        *) die "manifest line $ln: unknown key '$key'" ;;
    esac
done <"$MANIFEST"
[ -n "$TEST" ] || die "the manifest has no test:"
[[ $TIMEOUT =~ ^[1-9][0-9]*$ ]] || die "timeout: takes whole seconds above 0, not '$TIMEOUT'"
for ((k = 1; k <= n; k++)); do
    [ -n "${FILES[k]}" ] || die "entry $k has an empty file:"
    [ -n "${LINES[k]:-}" ] || die "entry $k (${FILES[k]}) has no line:"
    [ -n "${EXPECTS[k]:-}" ] || die "entry $k (${FILES[k]}) has no expect:, so any red would count, a syntax error included"
done

RUN=$(mktemp -d -p "$WORK" guard-mutants.XXXXXXXX) || die "cannot make a directory beneath $WORK"
# Invoked by the EXIT trap only, which shellcheck cannot follow (SC2317).
# shellcheck disable=SC2317
cleanup() {
    local f pg st
    : >"${RUN:?}/stopping"
    for f in "$RUN"/m*/pg; do
        read -r pg st 2>/dev/null <"$f" || continue
        # A pid is signalled only while it is still the process that wrote it: same start time.
        { [ -n "$st" ] && [ "$(starttime "$pg")" = "$st" ]; } || continue
        kill -TERM -- "-$pg" "$pg" 2>/dev/null
    done
    wait
    rm -rf -- "${RUN:?}"
}
trap cleanup EXIT

starttime() { local s f; read -r s 2>/dev/null <"/proc/$1/stat" || return 1; read -ra f <<<"${s##*) }"; printf '%s' "${f[19]}"; }
put() { printf '%s\t%s\n' "$2" "$3" >"${RUN:?}/res.$1"; }

# Counts (MODE=count) or drops (MODE=drop) the lines equal to NEEDLE once both are trimmed.
match_lines() {
    NEEDLE=$2 MODE=$1 awk '
        BEGIN { want = ENVIRON["NEEDLE"]; gsub(/^[ \t]+|[ \t]+$/, "", want) }
        { t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t) }
        t "" == want "" { c++; if (ENVIRON["MODE"] == "drop") next }
        ENVIRON["MODE"] == "drop" { print }
        END { if (ENVIRON["MODE"] == "count") print c + 0 }' "$3"
}

# run_one K: entry K in a directory of its own; K=0 is the unmutated baseline.
run_one() {
    local k=$1 m tree out rc count tp v why
    m=$(mktemp -d -p "${RUN:?}" "m$k.XXXXXX") || { put "$k" errored "cannot make its directory"; return; }
    tree=$m/tree out=$m/out
    { mkdir -- "$m/tmp" && cp -a -- "$ROOT" "$tree"; } || { put "$k" errored "cannot copy the root"; return; }
    export TMPDIR="$m/tmp"
    if [ "$k" -gt 0 ]; then
        [[ "$(realpath -e -- "$tree/${FILES[k]}" 2>/dev/null)" == "$tree"/* ]] || { put "$k" errored "no such file inside the root"; return; }
        count=$(match_lines count "${LINES[k]}" "$tree/${FILES[k]}")
        [ "$count" = 1 ] || { put "$k" errored "the line matches ${count:-no} lines, not one"; return; }
        { match_lines drop "${LINES[k]}" "$tree/${FILES[k]}" >"$m/mutant" && cat -- "$m/mutant" >"$tree/${FILES[k]}"; } \
            || { put "$k" errored "cannot write the mutant"; return; }
    fi
    # timeout leads a process group of its own; pg names it, with its start time, before anything runs.
    (p=$BASHPID; echo "$p $(starttime "$p")" >"$m/pg"; [ ! -e "$RUN/stopping" ] || exit 143; cd -- "$tree" && exec timeout -k 5 "$TIMEOUT" bash -c "$TEST") >"$out" 2>&1 </dev/null &
    tp=$!
    wait "$tp"; rc=$?
    kill -TERM -- "-$tp" 2>/dev/null; rm -f -- "$m/pg"
    if [ "$k" -eq 0 ]; then
        [ "$rc" -eq 0 ] || tail -n 5 -- "$out" >&2
        cp -- "$out" "$RUN/base.out"; put 0 base "$rc"; return
    fi
    v=caught why="rc=$rc, expect printed"
    [ "$rc" -ne 0 ] || { v=SURVIVED; why="the test passed without this line"; }
    [ "$rc" -eq 0 ] || grep -qF -- "${EXPECTS[k]}" "$out" || { v=errored; why="rc=$rc without the expect string"; }
    { [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ]; } || { v=errored; why="timed out after ${TIMEOUT}s"; }
    [ "$rc" -eq 0 ] || ! grep -qF -- "${EXPECTS[k]}" "$RUN/base.out" || { v=errored; why="the unmutated test prints the expect string too"; }
    put "$k" "$v" "$why"
}

run_one 0 &
wait $!
base=$(cut -f2 "$RUN/res.0" 2>/dev/null)
[ "$base" = 0 ] || { printf 'guard-mutants: ERROR, the test fails on an unmutated copy (%s); nothing judged\n' "${base:-no result}"; exit 1; }

running=0
for ((k = 1; k <= n; k++)); do
    if [ "$running" -ge "$JOBS" ]; then wait -n; running=$((running - 1)); fi
    run_one "$k" &
    running=$((running + 1))
done
wait

c=0 s=0 e=0
for ((k = 1; k <= n; k++)); do
    { IFS=$'\t' read -r v why <"$RUN/res.$k"; } 2>/dev/null || { v=errored why="no result"; }
    case "$v" in caught) c=$((c + 1)) ;; SURVIVED) s=$((s + 1)) ;; *) v=errored; e=$((e + 1)) ;; esac
    printf '%-8s %s: %s (%s)\n' "$v" "${FILES[k]}" "${LINES[k]}" "$why"
done
printf 'guard-mutants: %d caught, %d survived, %d errored of %d\n' "$c" "$s" "$e" "$n"
{ [ "$s" -eq 0 ] && [ "$e" -eq 0 ] && [ "$n" -gt 0 ]; } || exit 1
exit 0
