# fleet-deploy-lib 2026-09-19 sha256:b0853842f7d6e759bf8d0546ae839460b45a3526d91571d83c112e74fce47f7d
# shellcheck shell=bash
# resolve <PR#> proves three things before anything moves: gh says MERGED, the merge
# commit IS origin/main, and its tree is the tree that was gated. $GH and $GIT are the caller's.

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
    $GIT diff --quiet "$HEAD_SHA" "$MERGE_SHA" || refuse "merge tree differs from the gated head: re-gate the merge commit."
    say "RESOLVED #$PR head ${HEAD_SHA:0:7} merge ${MERGE_SHA:0:7} is origin/main, trees identical"
}
