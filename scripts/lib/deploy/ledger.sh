# fleet-deploy-lib 2026-09-19 sha256:3a108fde1ced1a9712d0db8996ffbf50825cc78339044343704f8ad97386f073
# shellcheck shell=bash
# One line per gate run: <sha> <ci|e2e> <utc> <rc> <log>. ci.sh and e2e.sh write it,
# gated reads it, and a head that is not in it green is refused. GATE_LEDGER_GIT is unquoted on purpose.
# The EXIT trap records; the gate script sets GATE_SUITE_PASSED=1 in its own shell right after
# the suite returns 0 — never exported, so no child gate inherits its parent's green.

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
    local kind=$1 rc=$2 log=${3:--} file dir sha
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
    local kind
    if [ "$BY_HAND" -eq 1 ]; then
        GATED='by hand'
        say "GATED BY HAND: the ledger was not read. #$PR deploys on a human's word — transition and rescue only."
        return 0
    fi
    [ -f "$LEDGER" ] || refuse "no gate ledger at $LEDGER, so no head was ever gated on this box."
    for kind in ci e2e; do
        # Append-only, so the last line for (sha, kind) is the newest and it alone decides.
        awk -v sha="$HEAD_SHA" -v kind="$kind" \
            '$1 == sha && $2 == kind { rc = $4; seen = 1 } END { exit (seen && rc == "0") ? 0 : 1 }' "$LEDGER" \
            || refuse "the ledger holds no green $kind for ${HEAD_SHA:0:7}: gate that head, then deploy."
    done
    # shellcheck disable=SC2034  # the project's finish() prints it
    GATED=ledger
    say "GATED ${HEAD_SHA:0:7} ci and e2e both green in $LEDGER"
}
