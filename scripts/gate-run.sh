#!/usr/bin/env bash
# shellcheck disable=SC2015  # every A && B || die here ends in an exit
# gate-run.sh <app> <sha40> <script> [--keep] [--artifacts-to <dir>] [--ledger <file>] [-- args]: a gate script run as root
# from a root-owned export of one sha on GitHub, with the lib copied out of the box clone. decision: gate-run-exports-one-sha
set -uo pipefail

if [ "$(/usr/bin/readlink -f "$0")" = /srv/engineering-standards/scripts/gate-run.sh ] && compgen -v GATE_RUN_T_ >/dev/null; then
    printf 'gate-run: WARNING: the test overrides %s are ignored at /srv/engineering-standards/scripts/gate-run.sh\n' "$(compgen -v GATE_RUN_T_ | paste -sd ' ' -)" >&2
    unset "${!GATE_RUN_T_@}"
fi

RUN_BASE=${GATE_RUN_T_RUN_BASE:-/run}
LIB_CLONE=${GATE_RUN_T_LIB_CLONE:-/srv/engineering-standards}
LIB_UID=${GATE_RUN_T_UID:-0}
GIT_BIN=/usr/bin/git
LIB_SUBS=(scripts/lib/gate scripts/lib/deploy)

die() { printf 'gate-run: REFUSED: %s\n' "$*" >&2; exit 2; }

[ $# -ge 3 ] || die "usage: gate-run.sh <app> <sha40> <script> [--keep] [--artifacts-to <dir>] [--ledger <file>] [-- args]"
app=$1 sha=$2 script=$3
shift 3
keep=0 artifacts='' ledger=''
while [ $# -gt 0 ]; do
    case $1 in
        --keep) keep=1; shift ;;
        --artifacts-to) [ $# -ge 2 ] || die "--artifacts-to takes a directory"; artifacts=$2; shift 2 ;;
        --ledger) [ $# -ge 2 ] || die "--ledger takes a file"; ledger=$2; shift 2 ;;
        --) shift; break ;;
        *) die "after <script> only --keep, --artifacts-to, --ledger and -- args are accepted" ;;
    esac
done
[ -z "$artifacts" ] || [[ $artifacts =~ ^/[A-Za-z0-9._/-]+$ && /$artifacts/ != */../* ]] || die "--artifacts-to is not an absolute path of [A-Za-z0-9._/-] without .."
[[ $app =~ ^[a-z0-9-]+$ ]] || die "the app name is not one word of a-z, 0-9 and -"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "the sha is not 40 lowercase hex: a branch, HEAD or a short sha names no fixed bytes"
[[ $script =~ ^scripts/[A-Za-z0-9._/-]+\.sh$ && /$script/ != */../* && /$script/ != */./* ]] || die "the script is not a path under scripts/ ending in .sh"

# >>> clone-lib (fleet-deploy's checks, here over LIB_SUBS)
LIB_REF=refs/remotes/origin/main
clone_git() { env -i PATH=/usr/bin:/bin HOME=/root GIT_NO_REPLACE_OBJECTS=1 "$GIT_BIN" -C / --no-optional-locks --git-dir="$LIB_CLONE/.git" --work-tree="$LIB_CLONE" "$@"; }

root_only() { # $1 -> 0 when no symlink, owned by root, and nobody else can write it
    [ ! -L "$1" ] || return 1
    [[ $(stat -L -c %u "$1" 2>/dev/null) == @(0|"$LIB_UID") ]] || return 1
    (( (8#$(stat -L -c %a "$1" 2>/dev/null || echo 777) & 8#022) == 0 ))
}

root_only_chain() { # $1 and every parent up to /; BAD names the first that is not root's alone
    local d=$1
    while :; do
        root_only "$d" || { BAD=$d; return 1; }
        case $d in /) return 0 ;; /*) d=$(dirname "$d") ;; *) BAD=$d; return 1 ;; esac
    done
}

clone_lib() { # destination -> LIB_SHA; 1 and LIB_ERR on refusal
    local d=$1 c=$LIB_CLONE sub bad meta path mode type obj list=()
    LIB_SHA='' LIB_ERR=''
    [ -d "$c" ] && [ ! -L "$c" ] && [ -d "$c/.git" ] && [ ! -L "$c/.git" ] || { LIB_ERR="$c is not a git clone"; return 1; }
    root_only_chain "$c" || { LIB_ERR="$BAD is a symlink, not root's, or writable by others: the gate lib is not read from under it"; return 1; }
    bad=$(cd / && find "$c" "$c/scripts" "$c/scripts/lib" -maxdepth 0 \( ! -uid "$LIB_UID" -o -type l -o -perm /022 \) -print 2>&1 && find "$c/.git" "${LIB_SUBS[@]/#/$c/}" \( ! -uid "$LIB_UID" -o -type l -o -perm /022 \) -print 2>&1) || bad="find failed under $c"
    [ -z "$bad" ] || { LIB_ERR="$c is not root's alone: $(printf '%s' "$bad" | tr '\n' ' ' | cut -c1-160)"; return 1; }
    [ "$LIB_REF" != refs/heads/main ] || [ "$(clone_git symbolic-ref -q HEAD 2>/dev/null)" = refs/heads/main ] || { LIB_ERR="$c is not on main"; return 1; }
    LIB_SHA=$(clone_git rev-parse --verify --quiet "$LIB_REF^{commit}" 2>/dev/null) && [[ $LIB_SHA =~ ^[0-9a-f]{40}$ ]] || { LIB_ERR="$c $LIB_REF does not resolve to a sha1 commit"; return 1; }
    bad=$(clone_git status --porcelain=v1 --untracked-files=all --ignored=matching -- "${LIB_SUBS[@]}" 2>/dev/null) || bad="git status failed"
    [ -z "$bad" ] || { LIB_ERR="$c has modified, untracked or ignored files under the lib: $(printf '%s' "$bad" | tr '\n' ' ' | cut -c1-160)"; return 1; }
    [ "$(clone_git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" = "$LIB_SHA" ] || { LIB_ERR="$c HEAD is not its origin/main ${LIB_SHA:0:7}: only main as merged on GitHub is read"; return 1; }
    for sub in "${LIB_SUBS[@]}"; do
        mapfile -d '' -t list < <(clone_git ls-tree -r -z "$LIB_SHA" -- "$sub/"; printf 'rc=%s\0' "$?")
        [ "${list[-1]:-}" = rc=0 ] || { LIB_ERR="git ls-tree of $sub at ${LIB_SHA:0:7} failed"; return 1; }
        unset 'list[-1]'
        mkdir -p "$d/$sub" || { LIB_ERR="cannot create $sub in the run directory"; return 1; }
        for meta in "${list[@]}"; do
            path=${meta#*$'\t'}
            read -r mode type obj <<<"${meta%%$'\t'*}"
            [[ $path =~ ^$sub/[A-Za-z0-9._-]+$ && $type == blob && ( $mode == 100644 || $mode == 100755 ) ]] || { LIB_ERR="$path at ${LIB_SHA:0:7} is $type mode $mode, not a plain file in $sub"; return 1; }
            clone_git cat-file blob "$obj" >"$d/$path" || { LIB_ERR="cannot write $path from ${LIB_SHA:0:7}"; return 1; }
            chmod 644 "$d/$path" || { LIB_ERR="cannot set the mode of $path"; return 1; }
        done
    done
    [ -s "$d/scripts/lib/gate/run.sh" ] && [ -s "$d/scripts/lib/deploy/compose.sh" ] || { LIB_ERR="run.sh or compose.sh is missing at ${LIB_SHA:0:7}"; return 1; }
}
# <<< clone-lib

if [ -n "$ledger" ]; then
    [[ $ledger =~ ^/[A-Za-z0-9._/-]+$ && /$ledger/ != */../* && /$ledger/ != */./* ]] || die "--ledger is not an absolute path of [A-Za-z0-9._/-] without . or .."
    root_only_chain "$(dirname -- "$ledger")" && { [ ! -e "$ledger" ] && [ ! -L "$ledger" ] || { [ -f "$ledger" ] && root_only "$ledger"; }; } || die "--ledger $ledger is not a root-only file in a directory chain only root can write"
fi

umask 022
gates=$RUN_BASE/$app-gate
[ -e "$gates" ] || [ -L "$gates" ] || mkdir -m 755 "$gates" || die "cannot create $gates"
root_only "$gates" && [ -d "$gates" ] || die "$gates is a symlink, not a directory, not root's, or writable by others"
run=$(mktemp -d "$gates/XXXXXXXXXX") || die "no run directory under $gates"
id=${run##*/}
[[ $id =~ ^[A-Za-z0-9]{10}$ ]] || { rmdir -- "$run"; die "mktemp named the run $id, not 10 letters and digits"; }
chmod 755 "$run" || { rmdir -- "$run"; die "cannot set the mode of $run"; }
clone_lib "$run/lib" || { rm -rf -- "${gates:?}/${id:?}"; die "the gate lib could not be read from the box clone: $LIB_ERR"; }
printf 'gate-run: lib %s from %s %s\n' "${LIB_SUBS[*]}" "$LIB_CLONE" "${LIB_SHA:0:12}"

cd / || die "cannot cd to /"
exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
    GATE_RUN_DIR="$run" GATE_RUN_KEEP="$keep" GATE_RUN_ARTIFACTS="$artifacts" GATE_RUN_LIB_SHA="$LIB_SHA" GATE_RUN_LEDGER="$ledger" \
    GATE_RUN_T_URL_PREFIX="${GATE_RUN_T_URL_PREFIX:-}" GATE_RUN_T_SRC="${GATE_RUN_T_SRC:-}" GATE_RUN_T_LEDGER="${GATE_RUN_T_LEDGER:-}" \
    GATE_RUN_T_BUILD_BASE="${GATE_RUN_T_BUILD_BASE:-}" GATE_RUN_T_ENV_DIR="${GATE_RUN_T_ENV_DIR:-}" GATE_RUN_T_PATH="${GATE_RUN_T_PATH:-}" \
    GATE_RUN_T_APP_USER="${GATE_RUN_T_APP_USER:-}" GATE_RUN_T_UID="${GATE_RUN_T_UID:-}" GATE_RUN_T_DF="${GATE_RUN_T_DF:-}" \
    /bin/bash "$run/lib/scripts/lib/gate/run.sh" "$app" "$sha" "$script" "$@"
