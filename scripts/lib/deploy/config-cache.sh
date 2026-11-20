# fleet-deploy-lib 2026-11-19 sha256:9b0c13141d57e6ebde116f146736bc06daea7e63ccf4bcc4fff5c70a5242675e
# shellcheck shell=bash
# Laravel's cached config holds APP_KEY and the database passwords, so it is owner-only. decision: config-cache-owner-only

# shellcheck source=scripts/lib/deploy/ownership.sh
. "$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/ownership.sh"

# config_cache_file <caller> <app-dir>: prints <app-dir>/bootstrap/cache/config.php, or nothing when there is none;
# 1, refusing as <caller>, for a tree that is not its own real path or a cache reached through a link.
config_cache_file() {
    local dir=${2:-} file
    while [[ $dir == ?*/ ]]; do dir=${dir%/}; done
    refuse_unless_own_dir "$1" "$dir" || return 1
    file=$dir/bootstrap/cache/config.php
    [[ -e $file || -L $file ]] || return 0
    [[ -f $file && $(/usr/bin/realpath -e -- "$file") == "$file" ]] \
        || { printf 'REFUSED: %s: %q is not a plain file of its own path (a link in it?)\n' "$1" "$file" >&2; return 1; }
    printf '%s\n' "$file"
}

# config_cache_private <app-dir>: run after every config:cache. The app tree's owner, never root, makes it 0600; 1 on any failure.
config_cache_private() {
    local dir=${1:-} file ids uid gid owner
    file=$(config_cache_file config_cache_private "$dir") || return 1
    [[ -n $file ]] || { printf 'REFUSED: config_cache_private: no %s/bootstrap/cache/config.php: run it after config:cache\n' "${dir%/}" >&2; return 1; }
    ids=$(PATH=${DEPLOY_EXEC_PATH:-/usr/sbin:/usr/bin:/sbin:/bin} stat -c '%u %g' -- "$dir" "$file") || { printf 'REFUSED: config_cache_private: could not read who owns %q and its cached config\n' "$dir" >&2; return 1; }
    { read -r uid gid; read -r owner _; } <<<"$ids"
    [[ $owner != 0 ]] || { printf 'REFUSED: config_cache_private: root owns %q: config:cache must run as the app user\n' "$file" >&2; return 1; }
    [[ $owner == "$uid" ]] || { printf 'REFUSED: config_cache_private: uid %s owns %q, not uid %s, who owns the app tree\n' "$owner" "$file" "$uid" >&2; return 1; }
    # As root, chmod runs as the app tree's owner, read from the vetted tree, never from a path below it. decision: config-cache-owner-only
    if [[ $(/usr/bin/id -u) == 0 ]]; then
        PATH=${DEPLOY_EXEC_PATH:-/usr/sbin:/usr/bin:/sbin:/bin} /usr/bin/setpriv --reuid="$uid" --regid="$gid" --clear-groups -- chmod 600 -- "$file"
    else
        PATH=${DEPLOY_EXEC_PATH:-/usr/sbin:/usr/bin:/sbin:/bin} chmod 600 -- "$file"
    fi || { printf 'REFUSED: config_cache_private: chmod 600 failed on %q\n' "$file" >&2; return 1; }
    config_cache_check "$dir" >/dev/null
}

# config_cache_check <app-dir>: the VERIFY. 0 and one line when there is no cached config or nobody but its owner
# can read or write it; 1 otherwise.
config_cache_check() {
    local file mode
    file=$(config_cache_file config_cache_check "${1:-}") || return 1
    [[ -n $file ]] || { printf 'no cached config under %s\n' "${1%/}"; return 0; }
    mode=$(/usr/bin/stat -c %a -- "$file") || return 1
    (( (8#$mode & 8#077) == 0 )) || { printf 'REFUSED: config_cache_check: %q is %s: group or others can reach APP_KEY and the database passwords. Run config_cache_private on the app tree.\n' "$file" "$mode" >&2; return 1; }
    printf 'cached config %s is %s, owner-only\n' "$file" "$mode"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then config_cache_check "$@"; exit; fi
