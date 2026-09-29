# fleet-deploy-lib 2026-09-29 sha256:99595cd0672c3498708d8fa15c9d49e5c4abb2bb017f768367c091f07fecde06
# shellcheck shell=bash
# One line per gate run: <sha> <ci|e2e> <utc> <rc> <log>. ci.sh and e2e.sh write it,
# gated reads it, and the commit GATE_SHA names is refused unless it is in there green.
# GATE_LEDGER_GIT is unquoted on purpose.
# The EXIT trap records; sourcing this file discards any inherited GATE_SUITE_PASSED.
# The gate script sets it itself, in its own shell, right after its suite returns 0.
# GATE_ARMED_SHA is discarded on sourcing too: the gate calls gate_ledger_arm itself,
# after GATE_LEDGER_GIT and before its first step.

unset GATE_SUITE_PASSED GATE_ARMED GATE_ARMED_SHA

# The commit the run begins on. gate_ledger_record writes no row for any other.
gate_ledger_arm() {
    local git=${GATE_LEDGER_GIT:-git}
    GATE_ARMED=1
    # shellcheck disable=SC2086
    GATE_ARMED_SHA=$($git rev-parse HEAD 2>/dev/null) || GATE_ARMED_SHA=''
    [ -n "$GATE_ARMED_SHA" ] || printf 'gate-ledger: arming could not name HEAD, so this run will record nothing\n' >&2
    return 0
}

gate_ledger_sha() {
    local git=${GATE_LEDGER_GIT:-git} sha
    # shellcheck disable=SC2086
    sha=$($git rev-parse HEAD 2>/dev/null) || return 1
    # shellcheck disable=SC2086
    if [ -n "$($git --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        sha="${sha}-dirty"
    fi
    printf '%s' "$sha"
}

gate_ledger_record() {
    local kind=$1 rc=$2 log=${3:--} file dir sha now
    if [ "${GATE_ARMED:-0}" != 1 ]; then
        printf 'gate-ledger: gate_ledger_arm was never called, so the %s run (rc=%s) is NOT recorded\n' "$kind" "$rc" >&2
        return 0
    fi
    if [ "$rc" = 0 ] && [ "${GATE_SUITE_PASSED:-}" != 1 ]; then
        printf 'gate-ledger: rc 0 without GATE_SUITE_PASSED — the run did not finish; recorded as a failure\n' >&2
        rc=1
    fi
    file=${GATE_LEDGER:-/var/lib/fleet/gate-ledger}
    dir=$(dirname "$file")

    sha=$(gate_ledger_sha) || {
        printf 'gate-ledger: git could not name HEAD, so the %s run (rc=%s) is NOT recorded\n' "$kind" "$rc" >&2
        return 0
    }
    # One reading of the tree stamps the row and answers "did HEAD move?".
    now=${sha%-dirty}
    if [ "$now" != "$GATE_ARMED_SHA" ]; then
        printf 'gate-ledger: HEAD is %s but the run began at %s, so the %s run (rc=%s) is NOT recorded\n' \
            "$now" "${GATE_ARMED_SHA:-an unreadable HEAD}" "$kind" "$rc" >&2
        return 0
    fi
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || {
        printf 'gate-ledger: cannot create %s, so the %s run (rc=%s) is NOT recorded\n' "$dir" "$kind" "$rc" >&2
        return 0
    }
    printf '%s %s %s %s %s\n' "$sha" "$kind" "$(date -u +%FT%TZ)" "$rc" "$log" >>"$file" || {
        printf 'gate-ledger: cannot append to %s, so the %s run (rc=%s) is NOT recorded\n' "$file" "$kind" "$rc" >&2
        return 0
    }
    printf 'gate-ledger: %s %s rc=%s -> %s\n' "${sha:0:7}" "$kind" "$rc" "$file"
}

gated() {
    local kind sha what
    if [ "$BY_HAND" -eq 1 ]; then
        GATED='by hand'
        say "GATED BY HAND: the ledger was not read. #$PR deploys on a human's word — transition and rescue only."
        return 0
    fi
    # Unset is a caller without the matching resolve.sh; set but empty is a resolve that
    # was skipped or did not finish, and that one is refused rather than read as the head.
    sha=${GATE_SHA-$HEAD_SHA}
    what=${GATE_WHAT-head}
    [ -n "$sha" ] || refuse "GATE_SHA is set but empty: resolve did not finish, and gated cannot guess what deploys."
    [ -f "$LEDGER" ] || refuse "no gate ledger at $LEDGER, so no head was ever gated on this box."
    for kind in ci e2e; do
        # Append-only, so the last line for (sha, kind) is the newest and it alone decides.
        awk -v sha="$sha" -v kind="$kind" \
            '$1 == sha && $2 == kind { rc = $4; seen = 1 } END { exit (seen && rc == "0") ? 0 : 1 }' "$LEDGER" \
            || refuse "the ledger holds no green $kind for ${sha:0:7}: gate that $what, then deploy."
    done
    # shellcheck disable=SC2034  # the project's finish() prints it
    GATED="ledger $what ${sha:0:7}"
    say "GATED ${sha:0:7} ci and e2e both green in $LEDGER"
}
