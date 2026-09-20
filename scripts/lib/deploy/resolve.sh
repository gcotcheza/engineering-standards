# fleet-deploy-lib 2026-09-20 sha256:55e914fbd6cd98d515e610f8a4d0dba90275fe5180c97d12ce32ffda8755312a
# shellcheck shell=bash
# resolve <PR#> proves gh says MERGED and the merge commit IS origin/main, then sets
# GATE_SHA: the commit whose tree deploys, and so the commit that must be gated.

json_value() {
    printf '%s' "$1" | tr ',{}' '\n' \
        | sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -1
}

# gh_repo prints owner/repo from `$GIT remote get-url origin`, understanding
# git@github.com:owner/repo.git, ssh://git@github.com/owner/repo.git and
# https://github.com/owner/repo(.git). Anything else: no output, exit 1.
gh_repo() {
    local url path
    url=$($GIT remote get-url origin 2>/dev/null) || return 1
    case "$url" in
        git@github.com:*)       path=${url#git@github.com:} ;;
        ssh://git@github.com/*) path=${url#ssh://git@github.com/} ;;
        https://github.com/*)   path=${url#https://github.com/} ;;
        *) return 1 ;;
    esac
    path=${path%.git}
    printf '%s' "$path" | grep -qE '^[^/]+/[^/]+$' || return 1
    printf '%s\n' "$path"
}

resolve() {
    local json state tip origin_url
    REPO="${DEPLOY_GH_REPO:-}"
    if [ -z "$REPO" ]; then
        REPO="$(gh_repo)" || {
            origin_url="$($GIT remote get-url origin 2>/dev/null)"
            refuse "origin's URL (${origin_url}) does not name a GitHub repository; set DEPLOY_GH_REPO."
        }
    fi
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
    $GIT fetch origin || refuse "git fetch origin failed; a deploy does not read a stale remote."
    tip=$($GIT rev-parse origin/main)
    [ "$tip" = "$MERGE_SHA" ] || refuse "main moved since the merge: re-gate."
    if $GIT diff --quiet "$HEAD_SHA" "$MERGE_SHA"; then
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
