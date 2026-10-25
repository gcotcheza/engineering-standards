# fleet-deploy-lib 2026-10-25.1 sha256:ef2826bb21fdada63443e1cfa43069efd3ac5728723bbc4ed864cc9383ae5d3d
# shellcheck shell=bash
# preflight prints what the box looked like and never refuses; refuse_if_dirty sits ahead of every
# command that moves the checkout. Both checks refuse a git status that fails.

preflight() {
    local load avail status
    load=$(cut -d' ' -f1-3 /proc/loadavg)
    avail=$(free -m | awk '/^Mem:/ { print $7 }')
    status=$($HEAVY --status 2>&1 | head -1)
    say "PRE-FLIGHT load $load available ${avail}MB heavy-work $status"
}

refuse_if_dirty() {
    local status rc=0
    deploy_git_plain "$ROOT/.git" || refuse "$(deploy_git_plain_refusal "$ROOT")."
    # shellcheck disable=SC2086
    deploy_git_or_refuse $GIT --no-optional-locks status --porcelain || rc=$?
    status=$DEPLOY_GIT_OUT
    [ "$rc" = 0 ] || refuse "git status exited $rc in $ROOT, so the checkout is not known to be clean; a deploy never fast-forwards over it."
    [ -z "$status" ] || refuse "the checkout is dirty; a deploy never fast-forwards over uncommitted work."
}

# Tracked files only: an untracked file is the app's own. A status git could not give is no clean tree.
deploy_refuse_if_tracked_dirty() {
    local tracked rc=0
    deploy_git_plain "$ROOT/.git" || refuse "$(deploy_git_plain_refusal "$ROOT")."
    # shellcheck disable=SC2086
    deploy_git_or_refuse $GIT --no-optional-locks status --porcelain --untracked-files=no || rc=$?
    tracked=$DEPLOY_GIT_OUT
    [ "$rc" = 0 ] || refuse "git status exited $rc in $ROOT, so the tracked files are not known to be the merge and nothing runs over them."
    [ -z "$tracked" ] || {
        detail "$tracked"
        refuse "tracked files in $ROOT are modified, so the tree is not the merged commit and neither a fast-forward nor a build runs over it. Commit them or restore them, then deploy."
    }
    say 'TREE tracked files clean'
}
