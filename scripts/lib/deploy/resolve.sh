# fleet-deploy-lib 2026-10-01 sha256:bf6b71a0d4b6153491fb5f942879ed1e27b60c203f35c7b0ebf361d820bc8f6a
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
    local json state tip origin_url diff_rc
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
        || refuse "git diff of head ${HEAD_SHA} and merge ${MERGE_SHA} exited ${diff_rc}, which says neither same tree nor different: a deploy does not guess which commit it gates."
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
