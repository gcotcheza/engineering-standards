# fleet-deploy-lib 2026-10-05.4 sha256:b42d3fb07702fd6327019c4cf6bbefc072cbf25abbfb7dac889fbcf330715a07
# shellcheck shell=bash
# preflight prints what the box looked like and never refuses; refuse_if_dirty sits ahead of every
# command that moves the checkout, and refuse_if_tracked_dirty again ahead of every build or up.

preflight() {
    local load avail status
    load=$(cut -d' ' -f1-3 /proc/loadavg)
    avail=$(free -m | awk '/^Mem:/ { print $7 }')
    status=$($HEAVY --status 2>&1 | head -1)
    say "PRE-FLIGHT load $load available ${avail}MB heavy-work $status"
}

refuse_if_dirty() {
    [ -z "$($GIT --no-optional-locks status --porcelain)" ] \
        || refuse "the checkout is dirty; a deploy never fast-forwards over uncommitted work."
}

# Tracked files only: an untracked file is the app's own. A status git could not give is no clean tree.
refuse_if_tracked_dirty() {
    local tracked
    tracked=$($GIT --no-optional-locks status --porcelain --untracked-files=no) \
        || refuse "git status could not read the tracked files in $ROOT, so nothing builds over them unchecked."
    [ -z "$tracked" ] || {
        detail "$tracked"
        refuse "tracked files in $ROOT are modified, so the tree is not the merged commit and neither a fast-forward nor a build runs over it. Commit them or restore them, then deploy."
    }
    say 'TREE tracked files clean'
}
