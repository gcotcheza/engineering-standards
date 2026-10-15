# fleet-deploy-lib 2026-10-15 sha256:2238db6d81072a733445b940129e56688c149763ca29625c65d993def7680aef
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

# The app user: DEPLOY_APP_USER, else ROOT's last part, which every app's account is named after.
deploy_app_user() { printf '%s' "${DEPLOY_APP_USER:-$(basename -- "$ROOT")}"; }

# deploy_git_plain <.git>: a fast path, by stat only, over the files where a FIFO was seen to hang git;
# not a complete list. docs/DECISIONS.md (deploy-lib 2026-10-11.1)
deploy_git_plain() {
    local g=${1:-} f
    [[ $g == /* && -d $g && ! -L $g ]] || return 1
    [[ -f $g/HEAD && ! -L $g/HEAD ]] || return 1
    for f in "$g"/{config,commondir,packed-refs,refs/heads/main,index,info/attributes,info/exclude} "$g"/worktrees/*/{HEAD,commondir,gitdir,index,locked}; do [[ ! -L $f && ( -f $f || ! -e $f ) ]] || return 1; done
}
deploy_git_plain_refusal() { printf '%s/.git is not a plain git directory (a link, a FIFO or a non-file where git reads), so git is not run in it' "$1"; }

# deploy_git_bounded <git argv…>: git under a timeout, its output read back from unlinked root files,
# never a pipe a setsid grandchild can hold open; stdout in DEPLOY_GIT_OUT. docs/DECISIONS.md (card 441)
deploy_git_bounded() {
    local n=${DEPLOY_GIT_TIMEOUT:-300} o e wo we rc=0
    DEPLOY_GIT_OUT='' DEPLOY_GIT_STDERR='' DEPLOY_GIT_ERR=''
    [[ $n =~ ^[1-9][0-9]{0,4}$ ]] || { DEPLOY_GIT_ERR="DEPLOY_GIT_TIMEOUT '$n' is not a whole number of seconds from 1 to 99999"; return 1; }
    o=$(mktemp -p /tmp deploy-git.XXXXXXXX) || { DEPLOY_GIT_ERR='no temp file could hold git output'; return 1; }
    e=$(mktemp -p /tmp deploy-git.XXXXXXXX) || { rm -f -- "${o:?}"; DEPLOY_GIT_ERR='no temp file could hold git output'; return 1; }
    exec {wo}>"$o" {we}>"$e" || { rm -f -- "${o:?}" "${e:?}"; DEPLOY_GIT_ERR='no temp file could hold git output'; return 1; }
    # Unlinked while open, before git starts: a deploy killed mid-git leaves no file, and no trap is touched.
    rm -f -- "${o:?}" "${e:?}"
    /usr/bin/timeout -k 5 "$n" "$@" </dev/null >&"$wo" 2>&"$we" 3>&- {wo}>&- {we}>&- || rc=$?
    DEPLOY_GIT_OUT=$(<"/dev/fd/$wo")
    DEPLOY_GIT_STDERR=$(<"/dev/fd/$we")
    exec {wo}>&- {we}>&-
    [ -z "$DEPLOY_GIT_STDERR" ] || printf '%s\n' "$DEPLOY_GIT_STDERR" >&2
    case $rc in 124|137) DEPLOY_GIT_ERR="git did not answer in ${n}s"; printf '%s: %s\n' "$DEPLOY_GIT_ERR" "$*" >&2 ;; esac
    return "$rc"
}

# deploy_git_or_refuse <git argv…>: deploy_git_bounded, where a git that did not answer stops the deploy.
deploy_git_or_refuse() {
    local rc=0
    deploy_git_bounded "$@" || rc=$?
    [ -z "$DEPLOY_GIT_ERR" ] || refuse "$DEPLOY_GIT_ERR: $*"
    return "$rc"
}

# The live commit, read by git as the app user through git-as: root opens nothing under ROOT/.git.
deploy_head_file() {
    local as=${DEPLOY_GIT_AS:-git-as} user
    user=$(deploy_app_user)
    deploy_git_plain "$ROOT/.git" || return 1
    deploy_git_bounded "$as" "$user" -C "$ROOT" symbolic-ref -q HEAD || return 1
    [ "$DEPLOY_GIT_OUT" = refs/heads/main ] || return 1
    deploy_git_bounded "$as" "$user" -C "$ROOT" rev-parse --verify -q 'refs/heads/main^{commit}' || return 1
    printf '%s' "$DEPLOY_GIT_OUT"
}

# deploy_build_hash <dir>: one sha256 over every regular file under <dir> and its path, read as the
# app user; find -P lists no link, so none is followed or hashed. Unreadable is a refusal.
deploy_build_hash() {
    local user out
    user=$(deploy_app_user)
    [[ ${1:-} == /* ]] || { printf "REFUSED: deploy_build_hash: '%s' is not an absolute directory\n" "${1:-}" >&2; return 1; }
    # shellcheck disable=SC2016  # $1 is the inner bash's, by design
    out=$(sudo -n -u "$user" -- bash -c 'set -o pipefail; cd -- "$1" && find -P . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum --' _ "${1:-}") \
        || { printf 'REFUSED: %s could not be hashed as %s, so no build is named\n' "${1:-}" "$user" >&2; return 1; }
    printf '%s\n' "$out" | sha256sum | cut -d' ' -f1
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
