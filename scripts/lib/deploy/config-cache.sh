# fleet-deploy-lib 2026-11-19 sha256:61c3d417494686587bbeef82b4c138388f4c648ea4021ece135480e79854a57e
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

# config_cache_private <app-dir>: run after every config:cache. Its owner, never root, makes it 0600; 1 on any failure.
config_cache_private() {
    local file uid gid
    file=$(config_cache_file config_cache_private "${1:-}") || return 1
    [[ -n $file ]] || { printf 'REFUSED: config_cache_private: no %s/bootstrap/cache/config.php: run it after config:cache\n' "${1%/}" >&2; return 1; }
    read -r uid gid < <(/usr/bin/stat -c '%u %g' -- "$file") || return 1
    [[ $uid != 0 ]] || { printf 'REFUSED: config_cache_private: root owns %q: config:cache must run as the app user\n' "$file" >&2; return 1; }
    # As root, chmod runs as the owner's uid (a container uid may have no host name), so a link swapped in
    # reaches only what that uid could change already.
    if [[ $(/usr/bin/id -u) == 0 ]]; then
        PATH=${DEPLOY_EXEC_PATH:-/usr/sbin:/usr/bin:/sbin:/bin} /usr/bin/setpriv --reuid="$uid" --regid="$gid" --clear-groups -- chmod 600 -- "$file"
    else
        PATH=${DEPLOY_EXEC_PATH:-/usr/sbin:/usr/bin:/sbin:/bin} chmod 600 -- "$file"
    fi || { printf 'REFUSED: config_cache_private: chmod 600 failed on %q\n' "$file" >&2; return 1; }
    config_cache_check "$1" >/dev/null
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
