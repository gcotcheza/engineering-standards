# fleet-deploy-lib 2026-10-05.4 sha256:f21d8dbddb5bfeec074282412e363925e1b902d04ec12d83d9b9d8b255130675
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
