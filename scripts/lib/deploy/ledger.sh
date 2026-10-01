# fleet-deploy-lib 2026-10-01 sha256:a281580a116832242a2d0535bbe625acdb36a12db10603c07e0755f964a25a4f
# shellcheck shell=bash
# One line per gate run: <sha> <ci|e2e> <utc> <rc> <log>. ci.sh and e2e.sh write it,
# gated reads it, and the commit GATE_SHA names is refused unless it is in there green —
# by hand reads the same rows and prints the verdict it overrides instead of refusing.
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
    local kind sha what v kinds='' notgreen='' verdict='' refusal=''
    # Unset is a caller without the matching resolve.sh; set but empty is a resolve that
    # was skipped or did not finish, and that one is refused rather than read as the head.
    sha=${GATE_SHA-$HEAD_SHA}
    what=${GATE_WHAT-head}
    if [ -z "$sha" ]; then
        verdict='NOT GREEN no commit resolved, so the ledger could not be read'
        refusal="GATE_SHA is set but empty: resolve did not finish, and gated cannot guess what deploys."
    elif [ ! -f "$LEDGER" ]; then
        verdict="NOT GREEN $what ${sha:0:7}: no gate ledger at $LEDGER"
        refusal="no gate ledger at $LEDGER, so no head was ever gated on this box."
    else
        for kind in ci e2e; do
            # Append-only, so the last line for (sha, kind) is the newest and it alone decides.
            v=$(awk -v sha="$sha" -v kind="$kind" \
                '$1 == sha && $2 == kind { rc = $4; seen = 1 }
                 END { printf "%s", (!seen ? "absent" : (rc == "0" ? "green" : "red")) }' "$LEDGER") \
                || v=unreadable
            kinds="${kinds:+$kinds, }$kind $v"
            [ "$v" = green ] || notgreen=${notgreen:-$kind}
        done
        verdict="$what ${sha:0:7}: $kinds"
        if [ -n "$notgreen" ]; then
            verdict="NOT GREEN $verdict"
            refusal="the ledger holds no green $notgreen for ${sha:0:7} ($kinds): a commit is gated before it is merged, and once it is in main only a route the gate documents for that (a base override, where it has one) can gate it — or deploy with --gated-by-hand, which records this as ungated."
        fi
    fi
    if [ -n "$refusal" ] && [ "$BY_HAND" -eq 1 ]; then
        # shellcheck disable=SC2034  # the project's finish() prints it
        GATED="by hand over [$verdict]"
        say "GATE $verdict"
        say "GATED BY HAND: #$PR deploys on a human's word over the verdict above — transition and rescue only."
        return 0
    fi
    [ -z "$refusal" ] || refuse "$refusal"
    # shellcheck disable=SC2034  # the project's finish() prints it
    GATED="ledger $what ${sha:0:7}"
    say "GATED ${sha:0:7} ci and e2e both green in $LEDGER"
    if [ "$BY_HAND" -eq 1 ]; then
        # shellcheck disable=SC2034  # the project's finish() prints it
        GATED="by hand over [GREEN $verdict]"
        say "GATE BY HAND: --gated-by-hand was passed and the verdict above is green anyway."
    fi
}
