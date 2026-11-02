# fleet-deploy-lib 2026-11-02 sha256:caf78a8d4a6d2e5f6e26d80366dbef9aabac368f45e1996709f50863014fcd1f
# shellcheck shell=bash
# A gate's --base <sha> stands only when its range holds all of origin/main..HEAD, or on a merged head all
# the main-line commit taking HEAD in brought. decision: one-base-vet-for-every-gate

# The gate's git is the caller's: a word list (git-as app -C tree) or a function name, ahead of the git arguments.
_base_vet_refuse() {
    printf '%s\n' "$@" >&2
    return 2
}

# _base_vet_in <a> <b> <given> <git>…: 0 when a is an ancestor of b, 1 when not, any other merge-base exit refuses (2).
_base_vet_in() {
    local a=$1 b=$2 given=$3 rc
    shift 3
    "$@" merge-base --is-ancestor "$a" "$b" 2>/dev/null
    rc=$?
    [ "$rc" -gt 1 ] || return "$rc"
    _base_vet_refuse "git could not say whether $a is in $b (merge-base exited $rc), so the base $given cannot be vetted."
}

# base_vet <base> <fetch hint> <ancestor hint, or ''> <git>…: the base's sha on stdout, or its refusal on stderr and 2.
base_vet() {
    local given=${1:-} fetch_hint=${2:-} ancestor_hint=${3:-} base landed floor c in_head in_main merged in_c in_floor
    if [ "$#" -lt 4 ] || [ -z "$given" ]; then
        _base_vet_refuse 'base_vet: usage: base_vet <base> <fetch hint> <ancestor hint or empty> <git command>...'
        return
    fi
    shift 3
    base=$("$@" rev-parse --verify --quiet "${given}^{commit}" 2>/dev/null) ||
        { _base_vet_refuse "the base $given is not a commit in this clone."; return; }
    _base_vet_in "$base" HEAD "$given" "$@"
    in_head=$?
    [ "$in_head" -ne 1 ] || { _base_vet_refuse "the base $given is not an ancestor of HEAD, so $given..HEAD is not what this head is made of." ${ancestor_hint:+"$ancestor_hint"}; return; }
    [ "$in_head" -eq 0 ] || return 2
    "$@" rev-parse --verify --quiet origin/main >/dev/null 2>&1 ||
        { _base_vet_refuse 'origin/main is not in this clone, so nothing here can say the base is behind it.' ${fetch_hint:+"$fetch_hint"}; return; }
    _base_vet_in "$base" origin/main "$given" "$@"
    in_main=$?
    [ "$in_main" -ne 1 ] || { _base_vet_refuse "the base $given is ahead of origin/main, so $given..HEAD leaves out commits this branch added."; return; }
    [ "$in_main" -eq 0 ] || return 2
    _base_vet_in HEAD origin/main "$given" "$@"
    merged=$?
    [ "$merged" -le 1 ] || return 2
    if [ "$merged" -eq 0 ]; then
        # The floor is the first parent of the main-line commit that took HEAD in, never HEAD^1.
        landed=''
        for c in $("$@" rev-list --first-parent origin/main); do
            "$@" merge-base --is-ancestor HEAD "$c" 2>/dev/null
            in_c=$?
            [ "$in_c" -ne 1 ] || break
            [ "$in_c" -eq 0 ] || { _base_vet_refuse "git could not say whether HEAD is in $c (merge-base exited $in_c), so no floor is known for the base $given."; return; }
            landed=$c
        done
        floor=$("$@" rev-parse --verify --quiet "${landed}^1" 2>/dev/null) || floor=''
        in_floor=1
        [ -z "$floor" ] || { _base_vet_in "$base" "$floor" "$given" "$@"; in_floor=$?; }
        [ "$in_floor" -ne 1 ] || { _base_vet_refuse "the base $given is inside what HEAD merged into origin/main (at ${landed:0:12}), so $given..HEAD leaves some of it out: give ${floor:-its first parent}."; return; }
        [ "$in_floor" -eq 0 ] || return 2
    fi
    printf '%s\n' "$base"
}

# base_vet_armed <base> <vetted sha> <armed sha> <git>…: 0 when the commit the run records still holds the base; else 2.
base_vet_armed() {
    local given=${1:-} base=${2:-} armed=${3:-} in_armed
    if [ "$#" -lt 4 ] || [ -z "$given" ] || [ -z "$base" ]; then
        _base_vet_refuse 'base_vet_armed: usage: base_vet_armed <base> <vetted sha> <armed sha> <git command>...'
        return
    fi
    shift 3
    [ -n "$armed" ] || { _base_vet_refuse "the gate armed no commit, so nothing says the base $given is in the head this run records."; return; }
    _base_vet_in "$base" "$armed" "$given" "$@"
    in_armed=$?
    [ "$in_armed" -ne 1 ] || { _base_vet_refuse "the base $given is not an ancestor of $armed, the commit this run records: HEAD moved after the base was vetted." 'Run the gate again on the head you mean to record.'; return; }
    [ "$in_armed" -eq 0 ] || return 2
}
