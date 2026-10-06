# fleet-deploy-lib 2026-10-05.4 sha256:9d5ad6680c800d473da70e80a946f43d21cf9a01a2a332c0660403afacb4189a
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
    status=$($GIT --no-optional-locks status --porcelain) || rc=$?
    [ "$rc" = 0 ] || refuse "git status exited $rc in $ROOT, so the checkout is not known to be clean; a deploy never fast-forwards over it."
    [ -z "$status" ] || refuse "the checkout is dirty; a deploy never fast-forwards over uncommitted work."
}

# Tracked files only: an untracked file is the app's own. A status git could not give is no clean tree.
deploy_refuse_if_tracked_dirty() {
    local tracked rc=0
    tracked=$($GIT --no-optional-locks status --porcelain --untracked-files=no) || rc=$?
    [ "$rc" = 0 ] || refuse "git status exited $rc in $ROOT, so the tracked files are not known to be the merge and nothing runs over them."
    [ -z "$tracked" ] || {
        detail "$tracked"
        refuse "tracked files in $ROOT are modified, so the tree is not the merged commit and neither a fast-forward nor a build runs over it. Commit them or restore them, then deploy."
    }
    say 'TREE tracked files clean'
}
