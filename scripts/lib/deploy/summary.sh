# fleet-deploy-lib 2026-10-03 sha256:aa8ae19a699ab5ce8704981bd67d9903ce7483db195a49b59a13392cf5ef9808
# shellcheck shell=bash
# say prints one summary line on stdout and in the log; detail goes to the log alone.
# The caller sets ROOT, PR, BEFORE and GATED before deploy_log_open opens fd 3, and finish takes MERGE_SHA.

say()    { printf '%s\n' "$*" >&3; printf '%s\n' "$*"; }
detail() { printf '%s\n' "$*"; }
refuse() { say "REFUSED: $*"; exit 1; }

deploy_log_open() {
    local dir
    dir=${DEPLOY_LOG_DIR:-${DEPLOY_LOG_ROOT:-/root/personal-vps-deploys}/$(basename "$ROOT")}
    mkdir -p "$dir" || { printf 'deploy.sh: cannot write logs to %s\n' "$dir" >&2; exit 1; }
    LOG="$dir/$(date -u +%Y%m%dT%H%M%SZ)-pr$1.log"
    exec 3>&1
    exec >>"$LOG" 2>&1
}

fail_tail() {
    say "$1 FAILED rc=$2 — the last 20 lines of $LOG:"
    tail -20 "$LOG" >&3
}

# The live commit, read as files and never through the checkout's own config.
head_file() {
    local g="$ROOT/.git" head sha
    [ -f "$g/HEAD" ] && [ ! -L "$g/HEAD" ] && head=$(head -c 200 "$g/HEAD") || return 1
    [ "$head" = 'ref: refs/heads/main' ] || return 1
    if [ -f "$g/refs/heads/main" ] && [ ! -L "$g/refs/heads/main" ]; then
        sha=$(head -c 200 "$g/refs/heads/main")
    elif [ -f "$g/packed-refs" ] && [ ! -L "$g/packed-refs" ]; then
        sha=$(awk '$2 == "refs/heads/main" { print $1; exit }' "$g/packed-refs") || return 1
    else
        return 1
    fi
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s' "$sha"
}

owned_by_me() { [ "$(stat -c %u:%a "$1" 2>/dev/null)" = "$(id -u):$2" ]; }

record_safe() {
    local d
    d=$(dirname "$1")
    [ -d "$d" ] && [ ! -L "$d" ] && owned_by_me "$d" 700 || return 1
    [ -e "$1" ] || [ -L "$1" ] || return 0
    [ -f "$1" ] && [ ! -L "$1" ] && owned_by_me "$1" 600
}

is_full_sha() { [[ ${1:-} =~ ^[0-9a-f]{40}$ ]]; }

# Root's record of what is live: one row by path, so no step's output reaches it. docs/DECISIONS.md
record_row() {
    local kind=$1 sha=$2 rest=$3 f landed
    RECORD_ERR=''
    [ -n "${ROOT:-}" ] || { RECORD_ERR="ROOT is unset, so no record names this project."; return 1; }
    f="${DEPLOY_RECORD_ROOT:-/var/lib/fleet/deploy-on-merge}/$(basename "$ROOT").record"
    is_full_sha "$sha" || { RECORD_ERR="'$sha' is not a full 40-hex sha, and root's record $f takes nothing less."; return 1; }
    landed=$(head_file) || landed=''
    [ "$landed" = "$sha" ] || { RECORD_ERR="$ROOT/.git/HEAD reads ${landed:-no main sha}, not $sha: root's record $f is not written."; return 1; }
    [ -e "$(dirname "$f")" ] || [ -L "$(dirname "$f")" ] || mkdir -m 700 "$(dirname "$f")" \
        || { RECORD_ERR="cannot create the directory of root's record $f."; return 1; }
    record_safe "$f" || { RECORD_ERR="root's record $f is not a 600 file in a 700 directory, both owned by uid $(id -u) and neither a symlink: nothing is written."; return 1; }
    ( umask 077; printf '%s %s %s %s\n' "$kind" "$sha" "$(date -u +%FT%TZ)" "$rest" >>"$f" ) \
        || { RECORD_ERR="root's record $f did not take the row."; return 1; }
}

# For a runbook's rollback, in a subshell: deploy_record_rollback <full sha> <source>.
deploy_record_rollback() {
    [[ ${2:-} =~ ^[^[:space:]]+$ ]] || { printf 'REFUSED: a ROLLBACK row names its source in one word.\n' >&2; return 1; }
    record_row ROLLBACK "${1:-}" "$2" || { printf 'REFUSED: %s\n' "$RECORD_ERR" >&2; return 1; }
    printf 'ROLLBACK %s recorded\n' "$1"
}

finish() {
    local red='' w extra=()
    is_full_sha "$1" || refuse "finish takes the full 40-hex MERGE_SHA since deploy-lib 2026-10-03, and was handed '$1': re-vendoring changes the caller too."
    [ "$1" = "${MERGE_SHA:-}" ] || refuse "finish was handed $1, not the merge commit resolve read from GitHub (${MERGE_SHA:-none}): no DONE without root's record row."
    read -ra extra <<<"${EXTRA_DONE:-}"
    for w in "${extra[@]}"; do [ -z "$red" ] && [ "$w" != RED ] || red+=" $w"; done
    record_row DONE "$1" "$LOG$red" || refuse "$RECORD_ERR No DONE without root's record row."
    say "DONE #$PR live $1 was $BEFORE gated $GATED${EXTRA_DONE:+ $EXTRA_DONE} log $LOG"
    say "PAPERWORK PR #$PR deployed $(date -u +%FT%TZ) live $1 was $BEFORE gated $GATED — backlog and handoff"
    exit 0
}
