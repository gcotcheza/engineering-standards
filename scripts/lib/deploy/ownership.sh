# fleet-deploy-lib 2026-11-05 sha256:d98da5ff137eac106bbcb62d76d227cd9a347787409395511fce28b99e1ce6d6
# shellcheck shell=bash
# Root hands its own paths in an app tree back to the app user, never through a link. docs/DECISIONS.md (card 363)

# chown_root_owned <dir> <user>:<group> [<find -path pattern to leave alone>…]; 1 on any failure.
chown_root_owned() {
    local dir=${1:-} owner=${2:-} skip=() p
    # A trailing slash hides a link from -L; find walks the trimmed path, which must be its own real path.
    while [[ $dir == ?*/ ]]; do dir=${dir%/}; done
    [[ $dir == /* && -d $dir && ! -L $dir ]] || { printf 'REFUSED: chown_root_owned: %s is not a plain absolute directory\n' "$dir" >&2; return 1; }
    [[ $(/usr/bin/realpath -e -- "$dir") == "$dir" ]] || { printf 'REFUSED: chown_root_owned: %s is not its own real path (a link above it, or a . .. or // part)\n' "$dir" >&2; return 1; }
    [[ $owner =~ ^[a-z_][a-z0-9_-]*:[a-z_][a-z0-9_-]*$ ]] || { printf "REFUSED: chown_root_owned: '%s' is not user:group\n" "$owner" >&2; return 1; }
    shift 2
    for p in "$@"; do skip+=(-not -path "$p"); done
    PATH=${DEPLOY_EXEC_PATH:-/usr/sbin:/usr/bin:/sbin:/bin} /usr/bin/find -P "$dir" -xdev -user "${DEPLOY_ROOT_UID:-0}" "${skip[@]}" -execdir chown -h "$owner" {} + \
        || { printf 'REFUSED: chown_root_owned: find or chown failed under %s, so root-owned paths may remain\n' "$dir" >&2; return 1; }
}

# root_owned_count <dir>: how many paths on <dir>'s filesystem root owns, <dir>/.claude/* aside; 1 if find fails.
root_owned_count() {
    local dir=${1:-} found
    # A trailing slash hides a link from -L; find walks the trimmed path, which must be its own real path.
    while [[ $dir == ?*/ ]]; do dir=${dir%/}; done
    [[ $dir == /* && -d $dir && ! -L $dir ]] || { printf 'REFUSED: root_owned_count: %s is not a plain absolute directory\n' "$dir" >&2; return 1; }
    [[ $(/usr/bin/realpath -e -- "$dir") == "$dir" ]] || { printf 'REFUSED: root_owned_count: %s is not its own real path (a link above it, or a . .. or // part)\n' "$dir" >&2; return 1; }
    [[ $dir != *[\*\?\[\\]* ]] || { printf 'REFUSED: root_owned_count: %s holds a glob character (* ? [ or \\)\n' "$dir" >&2; return 1; }
    found=$(/usr/bin/find -P "$dir" -xdev -ignore_readdir_race -user "${DEPLOY_ROOT_UID:-0}" -not -path "${dir%/}/.claude/*" -printf .) \
        || { printf 'REFUSED: root_owned_count: find failed under %s, so the count of root-owned paths is unknown\n' "$dir" >&2; return 1; }
    printf '%s\n' "${#found}"
}

# root_owned_check <dir>: the gate's refusal of any path on <dir>'s filesystem root owns, .claude included, each
# named with a remedy; 0 and one line on stdout when clean, 1 otherwise. A subshell: nothing it sets leaks.
root_owned_check() (
    local tree=${1:-} found user group note=''
    # root_owned_count's refusals: a link, or a path not its own, is never walked as clean. decision: gate-root-owned-check-lives-in-the-deploy-lib
    while [[ $tree == ?*/ ]]; do tree=${tree%/}; done
    [[ $tree == /* && -d $tree && ! -L $tree ]] || { printf 'REFUSED: root_owned_check: %s is not a plain absolute directory, so not one path was counted\n' "$tree" >&2; exit 1; }
    [[ $(/usr/bin/realpath -e -- "$tree") == "$tree" ]] || { printf 'REFUSED: root_owned_check: %s is not its own real path (a link above it, or a . .. or // part), so not one path was counted\n' "$tree" >&2; exit 1; }
    found=$(/usr/bin/find -P "${tree%/}/" -xdev -ignore_readdir_race -user "${DEPLOY_ROOT_UID:-0}" -print) \
        || { printf 'REFUSED: root_owned_check: find failed under %s, so a count nobody took is not a clean tree\n' "$tree" >&2; exit 1; }
    [[ -n $found ]] || { printf 'no root-owned path under %s\n' "$tree"; exit 0; }
    user=$(/usr/bin/stat -c %U -- "$tree") group=$(/usr/bin/stat -c %G -- "$tree")
    [[ $(/usr/bin/stat -c %u -- "$tree") != "${DEPLOY_ROOT_UID:-0}" ]] || note="Root owns the tree's own top too, so ${user} is not the app user: name the app user yourself."
    printf 'REFUSED: root_owned_check: %s path(s) under %s are owned by root:\n%s\n\n' "$(/usr/bin/wc -l <<<"$found")" "$tree" "$found" >&2
    printf '%s\n' "Fix the writer, never the file: a chown sweep hides the writer until the next run." \
        "An editor or a shell redirection run as root in this tree writes most of these: write as the owner, runuser -u ${user} -- …" \
        'A gate step running as root writes the rest (a service with no user: line, a mount target the daemon created, a host step writing without install(1)): repair that step.' \
        "The deploy sweeps only its own checkout, so this tree keeps these: once the writer is fixed, chown -R ${user}:${group} ${tree}, then run the check again." \
        ${note:+"$note"} >&2
    exit 1
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then root_owned_check "$@"; exit; fi
