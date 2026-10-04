# fleet-deploy-lib 2026-10-04.2 sha256:7571425b712fb0ec4dd782506b7e95b68c5b1de841830da502b4b3f89c10dad7
# shellcheck shell=bash
# One line per gate run: <sha> <ci|e2e> <utc> <rc> <log>. ci.sh and e2e.sh write it,
# gated reads it, and the commit GATE_SHA names is refused unless it holds the rows its test
# scope owes green (none, ci, or ci and e2e) — by hand prints the verdict it overrides instead.
# GATE_LEDGER_GIT is unquoted on purpose.
# The EXIT trap records; sourcing this file discards any inherited GATE_SUITE_PASSED.
# The gate script sets it itself, in its own shell, right after its suite returns 0.
# GATE_ARMED_SHA is discarded on sourcing too: the gate calls gate_ledger_arm itself,
# after GATE_LEDGER_GIT and before its first step.
# Fleet convention: a step exiting 75 ends the gate at once with
# `=== GATE NOT RUN (step N: name — heavy-work gave up) ===` and exit 75, never GATE FAILED.

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

# Exit 1: HEAD unreadable. Exit 2: the tree is dirty, and a dirty tree gets no row at all.
gate_ledger_sha() {
    local git=${GATE_LEDGER_GIT:-git} sha
    # shellcheck disable=SC2086
    sha=$($git rev-parse HEAD 2>/dev/null) || return 1
    # shellcheck disable=SC2086
    if [ -n "$($git --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        printf 'gate-ledger: dirty tree: no ledger row — commit, then gate the tip\n' >&2
        return 2
    fi
    printf '%s' "$sha"
}

gate_ledger_record() {
    local kind=$1 rc=$2 log=${3:--} file dir sha shrc=0
    if [ "${GATE_ARMED:-0}" != 1 ]; then
        printf 'gate-ledger: gate_ledger_arm was never called, so the %s run (rc=%s) is NOT recorded\n' "$kind" "$rc" >&2
        return 0
    fi
    if [ "$rc" = 75 ]; then
        printf 'gate-ledger: heavy-work gave up (rc=75), so the %s run is NOT recorded — it never ran\n' "$kind" >&2
        return 0
    fi
    if [ "$rc" = 0 ] && [ "${GATE_SUITE_PASSED:-}" != 1 ]; then
        printf 'gate-ledger: rc 0 without GATE_SUITE_PASSED — the run did not finish; recorded as a failure\n' >&2
        rc=1
    fi
    file=${GATE_LEDGER:-/var/lib/fleet/gate-ledger}
    dir=$(dirname "$file")

    sha=$(gate_ledger_sha) || shrc=$?
    case $shrc in
        0) ;;
        2) return 0 ;;
        *)
            printf 'gate-ledger: git could not name HEAD, so the %s run (rc=%s) is NOT recorded\n' "$kind" "$rc" >&2
            return 0
            ;;
    esac
    if [ "$sha" != "$GATE_ARMED_SHA" ]; then
        printf 'gate-ledger: HEAD is %s but the run began at %s, so the %s run (rc=%s) is NOT recorded\n' \
            "$sha" "${GATE_ARMED_SHA:-an unreadable HEAD}" "$kind" "$rc" >&2
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

# Ghie's test scopes: a docs-only diff owes no row, a non-UI diff owes ci, any other owes ci and e2e.
# The project names its docs and non-UI paths in TEST_SCOPE_FILE; the allowlist's why: docs/DECISIONS.md.
TEST_SCOPE_FILE=.fleet/test-scope
TEST_SCOPE_RULE='test-scope 2026-10-04'

TEST_SCOPE_MANIFESTS=' composer.json composer.lock package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lock bun.lockb Gemfile.lock '

# Prints how specific entry $1 is for path $2 (exact 3, dir 2, glob 1), or fails: no match.
# A dependency manifest at any depth is matched only by its exact path.
test_scope_matches() {
    case $1 in
        "$2") printf '3' ;;
        *) [[ $TEST_SCOPE_MANIFESTS != *" ${2##*/} "* ]] || return 1
           case $1 in
               */) [[ $2 == "$1"* ]] && printf '2' ;;
               '*.'*) [[ $2 != */* && $2 == *"${1#\*}" ]] && printf '1' ;;
               *) return 1 ;;
           esac ;;
    esac
}

# test_scope_classify <declaration text>, changed paths on stdin: sets SCOPE (docs|non-ui|ui) and SCOPE_WHY.
test_scope_classify() {
    local decl=$1 line kind entry extra n=0 path i hit rank best matched='' ui_first='' ui_n=0 total=0 nonui=0
    local -a classes=() entries=()
    SCOPE=ui
    while IFS= read -r line; do
        n=$((n + 1))
        read -r kind entry extra <<<"${line%%#*}"
        [ -n "$kind" ] || continue
        if [[ $entry =~ ^e2e(/|$) ]]; then
            SCOPE_WHY="$TEST_SCOPE_FILE line $n declares $entry, and e2e/ is always UI, so the declaration is refused and every path is UI"
            return 0
        fi
        if [ -n "$extra" ] || [[ ! $kind =~ ^(docs|non-ui)$ ]] || [[ $entry =~ (^|/)\.\.?(/|$) ]] \
            || [[ ! $entry =~ ^(([A-Za-z0-9._-]+/)+|\*\.[A-Za-z0-9]+|([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+)$ ]]; then
            SCOPE_WHY="$TEST_SCOPE_FILE line $n is not '<docs|non-ui> <dir/ | *.ext | path>', so the declaration is refused and every path is UI"
            return 0
        fi
        classes+=("$kind")
        entries+=("$entry")
    done <<<"$decl"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        total=$((total + 1))
        hit='' best=''
        if [ "$path" != "$TEST_SCOPE_FILE" ]; then
            # The most specific entry wins (rank, then length); a tie goes to non-ui, the stricter.
            for i in "${!entries[@]}"; do
                rank=$(test_scope_matches "${entries[i]}" "$path") || continue
                rank="$rank $(printf '%05d' "${#entries[i]}") $([ "${classes[i]}" = non-ui ] && echo 1 || echo 0)"
                if [ -z "$best" ] || [[ $rank > $best ]]; then best=$rank; hit=$i; fi
            done
        fi
        if [ -z "$hit" ]; then
            ui_n=$((ui_n + 1))
            ui_first=${ui_first:-$path}
            continue
        fi
        [ "${classes[hit]}" = docs ] || nonui=1
        [[ " $matched " == *" ${entries[hit]} "* ]] || matched="${matched:+$matched }${entries[hit]}"
    done
    if [ "$total" -eq 0 ]; then
        SCOPE_WHY='the diff names no path, so nothing shows it is not UI'
    elif [ "$ui_n" -gt 0 ]; then
        SCOPE_WHY="UI path: $ui_first$([ "$ui_n" -eq 1 ] || printf ' and %s more' $((ui_n - 1)))"
    elif [ "$nonui" -eq 1 ]; then
        SCOPE=non-ui
        SCOPE_WHY="non-UI diff (${matched// /, })"
    else
        SCOPE=docs
        SCOPE_WHY="docs-only diff (${matched// /, })"
    fi
}

# What deploying $1 changes on this checkout, classified by the declaration $1 itself carries.
test_scope_of() {
    local sha=$1 live raw paths links decl
    SCOPE=ui
    if ! live=$($GIT rev-parse HEAD 2>/dev/null); then
        SCOPE_WHY="git could not name the checkout's HEAD, so every path is UI"
    elif ! raw=$($GIT diff --no-ext-diff --no-textconv --no-renames --ignore-submodules=none --raw --no-abbrev "$live" "$sha" 2>/dev/null); then
        SCOPE_WHY="git could not list what ${sha:0:7} changes on ${live:0:7}, so every path is UI"
    elif paths=$(cut -s -f2- <<<"$raw") \
        && links=$(awk -F'\t' '!f && $1 ~ /^:(120000|160000) |^:[0-7]+ (120000|160000) / { f = $2 } END { printf "%s", f }' <<<"$raw") \
        && [ -n "$links" ]; then
        SCOPE_WHY="symlink or submodule: $links, so every path is UI"
    elif ! $GIT cat-file -e "$sha:$TEST_SCOPE_FILE" 2>/dev/null; then
        SCOPE_WHY="${sha:0:7} declares no $TEST_SCOPE_FILE, so every path is UI"
    elif ! decl=$($GIT show "$sha:$TEST_SCOPE_FILE" 2>/dev/null); then
        SCOPE_WHY="git could not read ${sha:0:7}:$TEST_SCOPE_FILE, so every path is UI"
    else
        test_scope_classify "$decl" <<<"$paths"
    fi
}

gated() {
    local kind sha what v owed kinds='' notgreen='' verdict='' refusal=''
    # Unset is a caller without the matching resolve.sh; set but empty is a resolve that
    # was skipped or did not finish, and that one is refused rather than read as the head.
    sha=${GATE_SHA-$HEAD_SHA}
    what=${GATE_WHAT-head}
    SCOPE=ui
    SCOPE_WHY='not classified, so every path is UI'
    if [ -z "$sha" ]; then
        verdict='NOT GREEN no commit resolved, so the ledger could not be read'
        refusal="GATE_SHA is set but empty: resolve did not finish, and gated cannot guess what deploys."
    else
        test_scope_of "$sha"
        say "SCOPE $SCOPE: $SCOPE_WHY per $TEST_SCOPE_RULE"
        case $SCOPE in
            docs) owed='' ;;
            non-ui) owed=ci ;;
            *) owed='ci e2e' ;;
        esac
        if [ -z "$owed" ]; then
            verdict="$what ${sha:0:7}: no row owed"
        elif [ ! -f "$LEDGER" ]; then
            verdict="NOT GREEN $what ${sha:0:7}: no gate ledger at $LEDGER"
            refusal="no gate ledger at $LEDGER, so no head was ever gated on this box."
        else
            for kind in $owed; do
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
    fi
    if [ -n "$refusal" ] && [ "$BY_HAND" -eq 1 ]; then
        # shellcheck disable=SC2034  # the project's finish() prints it
        GATED="by hand over [$verdict]"
        say "GATE $verdict"
        say "GATED BY HAND: #$PR deploys on a human's word over the verdict above — transition and rescue only."
        return 0
    fi
    [ -z "$refusal" ] || refuse "$refusal"
    case $SCOPE in
        docs)
            # shellcheck disable=SC2034  # the project's finish() prints it
            GATED="no row owed $what ${sha:0:7} (docs-only)"
            say "GATED ${sha:0:7} no gate row owed: $SCOPE_WHY per $TEST_SCOPE_RULE"
            ;;
        non-ui)
            # shellcheck disable=SC2034  # the project's finish() prints it
            GATED="ledger $what ${sha:0:7} ci (non-UI)"
            say "GATED ${sha:0:7} ci green in $LEDGER; e2e not required: $SCOPE_WHY per $TEST_SCOPE_RULE"
            ;;
        *)
            # shellcheck disable=SC2034  # the project's finish() prints it
            GATED="ledger $what ${sha:0:7}"
            say "GATED ${sha:0:7} ci and e2e both green in $LEDGER"
            ;;
    esac
    if [ "$BY_HAND" -eq 1 ]; then
        # shellcheck disable=SC2034  # the project's finish() prints it
        GATED="by hand over [GREEN $verdict]"
        say "GATE BY HAND: --gated-by-hand was passed and the verdict above is green anyway."
    fi
}
