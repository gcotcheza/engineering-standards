# fleet-deploy-lib 2026-11-05 sha256:9a4c2d40f009ed2927eac614b6db60b947db60b14cf8e478a8bfce22f9a38cca
# shellcheck shell=bash
# A gate's --base <sha> stands only when its range holds all of origin/main..HEAD, or on a merged head all
# the main-line commit taking HEAD in brought. decision: one-base-vet-for-every-gate

_base_vet_refuse() {
    printf '%s\n' "$@" >&2
    return 2
}

# _base_vet_in <a> <b> <given> <git>…: 0 when a is an ancestor of b, 1 when not, any other merge-base exit refuses (2).
_base_vet_in() {
    local a=$1 b=$2 given=$3 rc=0
    shift 3
    "$@" merge-base --is-ancestor "$a" "$b" 2>/dev/null || rc=$?
    [ "$rc" -gt 1 ] || return "$rc"
    _base_vet_refuse "git could not say whether $a is in $b (merge-base exited $rc), so the base $given cannot be vetted."
}

# _base_vet <head> <given> <rev> <fetch hint> <ancestor hint> <git>…: base_vet's work, judged at <head>.
_base_vet() {
    local head=$1 given=$2 rev=$3 fetch_hint=$4 ancestor_hint=$5 base mainline landed floor c listed
    local in_head=0 in_main=0 merged=0 in_c in_floor=1
    shift 5
    base=$("$@" rev-parse --verify --quiet "${rev}^{commit}" 2>/dev/null) ||
        { _base_vet_refuse "the base $given is not a commit in this clone."; return; }
    _base_vet_in "$base" "$head" "$given" "$@" || in_head=$?
    [ "$in_head" -ne 1 ] || { _base_vet_refuse "the base $given is not an ancestor of $head, so $given..$head is not what this head is made of." ${ancestor_hint:+"$ancestor_hint"}; return; }
    [ "$in_head" -eq 0 ] || return 2
    "$@" rev-parse --verify --quiet origin/main >/dev/null 2>&1 ||
        { _base_vet_refuse 'origin/main is not in this clone, so nothing here can say the base is behind it.' ${fetch_hint:+"$fetch_hint"}; return; }
    _base_vet_in "$base" origin/main "$given" "$@" || in_main=$?
    [ "$in_main" -ne 1 ] || { _base_vet_refuse "the base $given is ahead of origin/main, so $given..$head leaves out commits this branch added."; return; }
    [ "$in_main" -eq 0 ] || return 2
    _base_vet_in "$head" origin/main "$given" "$@" || merged=$?
    [ "$merged" -le 1 ] || return 2
    if [ "$merged" -eq 0 ]; then
        mainline=$("$@" rev-list --first-parent origin/main 2>/dev/null) ||
            { listed=$?; _base_vet_refuse "git could not list origin/main's first parents (rev-list exited $listed), so no floor is known for the base $given."; return; }
        landed=''
        for c in $mainline; do
            in_c=0
            "$@" merge-base --is-ancestor "$head" "$c" 2>/dev/null || in_c=$?
            [ "$in_c" -ne 1 ] || break
            [ "$in_c" -eq 0 ] || { _base_vet_refuse "git could not say whether $head is in $c (merge-base exited $in_c), so no floor is known for the base $given."; return; }
            landed=$c
        done
        floor=$("$@" rev-parse --verify --quiet "${landed}^1" 2>/dev/null) || floor=''
        [ -z "$floor" ] || { in_floor=0; _base_vet_in "$base" "$floor" "$given" "$@" || in_floor=$?; }
        [ "$in_floor" -ne 1 ] || { _base_vet_refuse "the base $given is inside what $head merged into origin/main (at ${landed:0:12}), so $given..$head leaves some of it out: give ${floor:-its first parent}."; return; }
        [ "$in_floor" -eq 0 ] || return 2
    fi
    printf '%s\n' "$base"
}

# sha=$(base_vet [--head <sha>] <base> <fetch hint> <ancestor hint, or ''> <git>…) || exit 2: refusal on stderr.
base_vet() {
    local head=HEAD
    if [ "${1:-}" = --head ]; then
        head=${2:-}
        shift 2 || shift
    fi
    if [ "$#" -lt 4 ] || [ -z "${1:-}" ] || [ -z "$head" ]; then
        _base_vet_refuse 'base_vet: usage: base_vet [--head <sha>] <base> <fetch hint> <ancestor hint or empty> <git command>...'
        return
    fi
    _base_vet "$head" "$1" "$@"
}

# base_vet_armed <base> <vetted sha> <armed sha> <fetch hint> <ancestor hint, or ''> <git>… || exit 2: base_vet again, at the armed sha.
base_vet_armed() {
    local given=${1:-} base=${2:-} armed=${3:-}
    if [ "$#" -lt 6 ] || [ -z "$given" ] || [ -z "$base" ]; then
        _base_vet_refuse 'base_vet_armed: usage: base_vet_armed <base> <vetted sha> <armed sha> <fetch hint> <ancestor hint or empty> <git command>...'
        return
    fi
    shift 3
    [ -n "$armed" ] || { _base_vet_refuse "the gate armed no commit, so nothing says the base $given is in the head this run records."; return; }
    _base_vet "$armed" "$given" "$base" "$@" >/dev/null || return 2
}
