# fleet-deploy-lib 2026-09-18 sha256:8e3bd128c45613cb6c089154f88d41370fbd00e1002de8bb36d9840990e5c02e
# shellcheck shell=bash
# resolve <PR#> proves three things before anything moves: gh says MERGED, the merge
# commit IS origin/main, and its tree is the tree that was gated. $GH and $GIT are the caller's.

json_value() {
    printf '%s' "$1" | tr ',{}' '\n' \
        | sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -1
}

resolve() {
    local json state tip
    json=$($GH pr view "$PR" --json state,headRefOid,mergeCommit) \
        || refuse "gh could not read PR #$PR."
    detail "$json"
    state=$(json_value "$json" state)
    HEAD_SHA=$(json_value "$json" headRefOid)
    MERGE_SHA=$(json_value "$json" oid)
    [ "$state" = MERGED ] \
        || refuse "PR #$PR is ${state:-unreadable}, not MERGED. Only a merged pull request deploys."
    { [ -n "$HEAD_SHA" ] && [ -n "$MERGE_SHA" ]; } \
        || refuse "PR #$PR names no head commit and no merge commit."
    $GIT fetch origin || refuse "git fetch origin failed; a deploy does not read a stale remote."
    tip=$($GIT rev-parse origin/main)
    [ "$tip" = "$MERGE_SHA" ] || refuse "main moved since the merge: re-gate."
    $GIT diff --quiet "$HEAD_SHA" "$MERGE_SHA" || refuse "merge tree differs from the gated head: re-gate the merge commit."
    say "RESOLVED #$PR head ${HEAD_SHA:0:7} merge ${MERGE_SHA:0:7} is origin/main, trees identical"
}
