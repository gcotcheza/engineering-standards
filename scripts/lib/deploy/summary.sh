# fleet-deploy-lib 2026-10-03 sha256:fe581a66d61affabe7914af47d7eb3ca64fcca9f1ff23b36f4ff9b5556d37b1c
# shellcheck shell=bash
# Root runs a deploy only from files root alone can write, never from inside ROOT: no switch turns
# this off, and fleet-deploy's export passes it. docs/DECISIONS.md (backlog 317)
deploy_src_root_only() {
    local main=${BASH_SOURCE[${#BASH_SOURCE[@]}-1]} f d r
    DEPLOY_SRC_ERR=''
    for f in "$main" "${BASH_SOURCE[0]}"; do
        d=$(cd -P -- "$(dirname -- "$f")" 2>/dev/null && pwd -P) || { DEPLOY_SRC_ERR="cannot find the directory $f runs from"; return 1; }
        f="${d%/}/$(basename -- "$f")"
        while :; do
            [ ! -L "$f" ] || { DEPLOY_SRC_ERR="$f is a symlink"; return 1; }
            [ "$(stat -L -c %u "$f" 2>/dev/null)" = 0 ] || { DEPLOY_SRC_ERR="$f is not owned by root"; return 1; }
            (( (8#$(stat -L -c %a "$f" 2>/dev/null || echo 777) & 8#022) == 0 )) || { DEPLOY_SRC_ERR="$f is writable by group or others"; return 1; }
            [ "$f" != / ] || break
            f=$(dirname -- "$f")
        done
    done
    [ -n "${1:-}" ] || return 0
    r=$(cd -P -- "$1" 2>/dev/null && pwd -P) || r=$1
    d=$(cd -P -- "$(dirname -- "$main")" && pwd -P)
    case "${d%/}/" in "${r%/}"/*) DEPLOY_SRC_ERR="$d is at or inside ROOT $r"; return 1 ;; esac
}
deploy_src_refusal() { printf 'REFUSED: %s, so root does not run it. Deploy with: fleet-deploy <app> <PR#>\n' "$DEPLOY_SRC_ERR" >&2; }
if ! deploy_src_root_only; then deploy_src_refusal; [[ $- == *i* ]] && return 1; exit 1; fi

# say prints one summary line on stdout and in the log; detail goes to the log alone.
# The caller sets ROOT, PR, BEFORE and GATED before deploy_log_open opens fd 3, and finish takes MERGE_SHA.

say()    { printf '%s\n' "$*" >&3; printf '%s\n' "$*"; }
detail() { printf '%s\n' "$*"; }
refuse() { say "REFUSED: $*"; exit 1; }

deploy_log_open() {
    local dir
    deploy_src_root_only "$ROOT" || { deploy_src_refusal; exit 1; }
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
deploy_head_file() {
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

deploy_owned_by_me() { [ "$(stat -c %u:%a "$1" 2>/dev/null)" = "$(id -u):$2" ]; }

deploy_record_safe() {
    local d
    d=$(dirname "$1")
    [ -d "$d" ] && [ ! -L "$d" ] && deploy_owned_by_me "$d" 700 || return 1
    [ -e "$1" ] || [ -L "$1" ] || return 0
    [ -f "$1" ] && [ ! -L "$1" ] && deploy_owned_by_me "$1" 600
}

deploy_is_full_sha() { [[ ${1:-} =~ ^[0-9a-f]{40}$ ]]; }

# Root's record of what is live: one row by path, so no step's output reaches it. docs/DECISIONS.md
deploy_record_row() {
    local kind=$1 sha=$2 rest=$3 name f landed lead=''
    DEPLOY_RECORD_ERR=''
    [ -n "${ROOT:-}" ] || { DEPLOY_RECORD_ERR="ROOT is unset, so no record names this project."; return 1; }
    name=$(basename "$ROOT")
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { DEPLOY_RECORD_ERR="ROOT $ROOT ends in '$name', which is not a record name the live tripwire reads."; return 1; }
    [ -n "${DEPLOY_RECORD_ROOT:-}" ] || [[ $ROOT == /var/www/?* ]] || { DEPLOY_RECORD_ERR="ROOT $ROOT is not under /var/www/ and DEPLOY_RECORD_ROOT is unset: only a live tree writes the live record."; return 1; }
    f="${DEPLOY_RECORD_ROOT:-/var/lib/fleet/deploy-on-merge}/$name.record"
    deploy_is_full_sha "$sha" || { DEPLOY_RECORD_ERR="'$sha' is not a full 40-hex sha, and root's record $f takes nothing less."; return 1; }
    landed=$(deploy_head_file) || landed=''
    [ "$landed" = "$sha" ] || { DEPLOY_RECORD_ERR="$ROOT/.git/HEAD reads ${landed:-no main sha}, not $sha: root's record $f is not written."; return 1; }
    [ -e "$(dirname "$f")" ] || [ -L "$(dirname "$f")" ] || mkdir -m 700 "$(dirname "$f")" \
        || { DEPLOY_RECORD_ERR="cannot create the directory of root's record $f."; return 1; }
    deploy_record_safe "$f" || { DEPLOY_RECORD_ERR="root's record $f is not a 600 file in a 700 directory, both owned by uid $(id -u) and neither a symlink: nothing is written."; return 1; }
    [ ! -s "$f" ] || [ -z "$(tail -c 1 "$f")" ] || lead=$'\n'
    ( umask 077; printf '%s%s %s %s %s\n' "$lead" "$kind" "$sha" "$(date -u +%FT%TZ)" "$rest" >>"$f" ) \
        || { DEPLOY_RECORD_ERR="root's record $f did not take the row."; return 1; }
}

# For a runbook's rollback, in a subshell: deploy_record_rollback <full sha> <source>.
deploy_record_rollback() {
    [[ ${2:-} =~ ^[^[:space:]]+$ ]] || { printf 'REFUSED: a ROLLBACK row names its source in one word.\n' >&2; return 1; }
    [ "$2" != RED ] || { printf 'REFUSED: RED is not a source: the live tripwire reads it as a RED verdict.\n' >&2; return 1; }
    deploy_record_row ROLLBACK "${1:-}" "$2" || { printf 'REFUSED: %s\n' "$DEPLOY_RECORD_ERR" >&2; return 1; }
    printf 'ROLLBACK %s recorded\n' "$1"
}

finish() {
    local red='' w extra=()
    deploy_is_full_sha "$1" || refuse "finish takes the full 40-hex MERGE_SHA since deploy-lib 2026-10-03, and was handed '$1': re-vendoring changes the caller too."
    [ "$1" = "${MERGE_SHA:-}" ] || refuse "finish was handed $1, not the merge commit resolve read from GitHub (${MERGE_SHA:-none}): no DONE without root's record row."
    read -ra extra <<<"${EXTRA_DONE:-}"
    for w in "${extra[@]}"; do [ -z "$red" ] && [ "$w" != RED ] || red+=" $w"; done
    deploy_record_row DONE "$1" "$LOG$red" || refuse "$DEPLOY_RECORD_ERR No DONE without root's record row."
    say "DONE #$PR live $1 was $BEFORE gated $GATED${EXTRA_DONE:+ $EXTRA_DONE} log $LOG"
    say "PAPERWORK PR #$PR deployed $(date -u +%FT%TZ) live $1 was $BEFORE gated $GATED — backlog and handoff"
    exit 0
}
