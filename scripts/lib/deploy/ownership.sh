# fleet-deploy-lib 2026-10-24 sha256:c7fcbea08eed19e8bb81efa8569c94ba3d9383f9990fbcbd20482d37aa6a0c12
# shellcheck shell=bash
# Root hands its own paths in an app tree back to the app user, never through a link. docs/DECISIONS.md (card 363)

# chown_root_owned <dir> <user>:<group> [<find -path pattern to leave alone>…]; 1 on any failure.
chown_root_owned() {
    local dir=${1:-} owner=${2:-} skip=() p
    [[ $dir == /* && -d $dir && ! -L $dir ]] || { printf 'REFUSED: chown_root_owned: %s is not a plain absolute directory\n' "$dir" >&2; return 1; }
    [[ $owner =~ ^[a-z_][a-z0-9_-]*:[a-z_][a-z0-9_-]*$ ]] || { printf "REFUSED: chown_root_owned: '%s' is not user:group\n" "$owner" >&2; return 1; }
    shift 2
    for p in "$@"; do skip+=(-not -path "$p"); done
    PATH=${DEPLOY_EXEC_PATH:-/usr/sbin:/usr/bin:/sbin:/bin} /usr/bin/find -P "$dir" -xdev -user "${DEPLOY_ROOT_UID:-0}" "${skip[@]}" -execdir chown -h "$owner" {} + \
        || { printf 'REFUSED: chown_root_owned: find or chown failed under %s, so root-owned paths may remain\n' "$dir" >&2; return 1; }
}

# root_owned_count <dir>: how many paths on <dir>'s filesystem root owns, <dir>/.claude/* aside; 1 if find fails.
root_owned_count() {
    local dir=${1:-} found
    [[ $dir == /* && -d $dir && ! -L $dir ]] || { printf 'REFUSED: root_owned_count: %s is not a plain absolute directory\n' "$dir" >&2; return 1; }
    [[ $dir != *[\*\?\[\\]* ]] || { printf 'REFUSED: root_owned_count: %s holds a glob character (* ? [ or \\)\n' "$dir" >&2; return 1; }
    found=$(/usr/bin/find -P "$dir" -xdev -ignore_readdir_race -user "${DEPLOY_ROOT_UID:-0}" -not -path "${dir%/}/.claude/*" -printf .) \
        || { printf 'REFUSED: root_owned_count: find failed under %s, so the count of root-owned paths is unknown\n' "$dir" >&2; return 1; }
    printf '%s\n' "${#found}"
}
