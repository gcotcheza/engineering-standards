# fleet-deploy-lib 2026-10-05.4 sha256:60295991f8cf7f1ff110a9f534968f8c183b66b57deae210a3b7ecefc609a612
# shellcheck shell=bash
# resolve <PR#> proves gh says MERGED and the merge commit IS origin/main, then sets
# GATE_SHA: the commit whose tree deploys, and so the commit that must be gated.

json_value() {
    printf '%s' "$1" | tr ',{}' '\n' \
        | sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -1
}

# REPO is root's to name, never the checkout's origin: fleet-deploy sets FLEET_DEPLOY_REPO, and the
# merge commit it exported scripts/ at in FLEET_DEPLOY_MERGE_SHA. docs/DECISIONS.md (backlog 317)
resolve() {
    local json state tip diff_rc
    REPO="${FLEET_DEPLOY_REPO:-}"
    [ -n "$REPO" ] || refuse "FLEET_DEPLOY_REPO is unset: root names the repository, never the checkout's origin. Deploy with: fleet-deploy <app> <PR#>"
    [[ $REPO =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || refuse "FLEET_DEPLOY_REPO '$REPO' is not owner/repo."
    json=$($GH pr view "$PR" -R "$REPO" --json state,headRefOid,mergeCommit) \
        || refuse "gh could not read PR #$PR."
    detail "$json"
    state=$(json_value "$json" state)
    HEAD_SHA=$(json_value "$json" headRefOid)
    MERGE_SHA=$(json_value "$json" oid)
    [ "$state" = MERGED ] \
        || refuse "PR #$PR is ${state:-unreadable}, not MERGED. Only a merged pull request deploys."
    { [ -n "$HEAD_SHA" ] && [ -n "$MERGE_SHA" ]; } \
        || refuse "PR #$PR names no head commit and no merge commit."
    [ -z "${FLEET_DEPLOY_MERGE_SHA:-}" ] || [ "$MERGE_SHA" = "$FLEET_DEPLOY_MERGE_SHA" ] || refuse "gh names merge commit $MERGE_SHA for PR #$PR, not $FLEET_DEPLOY_MERGE_SHA, the one fleet-deploy exported scripts/ at."
    $GIT fetch origin || refuse "git fetch origin failed; a deploy does not read a stale remote."
    # Both commits are proved readable before any comparison: an unreadable one makes
    # `git diff` exit 128, which is not "the trees differ".
    $GIT cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null \
        || refuse "git cannot read PR #$PR's head commit ${HEAD_SHA}: run 'git fetch origin refs/pull/$PR/head', then deploy."
    $GIT cat-file -e "${MERGE_SHA}^{commit}" 2>/dev/null \
        || refuse "git cannot read PR #$PR's merge commit ${MERGE_SHA}: run 'git fetch origin ${MERGE_SHA}', then deploy."
    tip=$($GIT rev-parse origin/main)
    [ "$tip" = "$MERGE_SHA" ] || refuse "main moved since the merge: re-gate."
    if $GIT diff --quiet "$HEAD_SHA" "$MERGE_SHA"; then
        diff_rc=0
    else
        diff_rc=$?
    fi
    [ "$diff_rc" = 0 ] || [ "$diff_rc" = 1 ] \
        || refuse "the tree comparison of head ${HEAD_SHA} and merge ${MERGE_SHA} exited ${diff_rc}, which says neither same tree nor different: a deploy does not guess which commit it gates."
    if [ "$diff_rc" = 0 ]; then
        GATE_SHA=$HEAD_SHA
        GATE_WHAT='head'
        say "RESOLVED #$PR head ${HEAD_SHA:0:7} merge ${MERGE_SHA:0:7} is origin/main, trees identical"
    else
        # Read by ledger.sh, which the shell that sources this file also sources.
        # shellcheck disable=SC2034
        GATE_SHA=$MERGE_SHA
        # shellcheck disable=SC2034
        GATE_WHAT='merge'
        say "RESOLVED #$PR merge ${MERGE_SHA:0:7} is origin/main and its tree is not head ${HEAD_SHA:0:7}'s, so the merge commit itself is what must be gated"
    fi
}
