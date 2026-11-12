# fleet-deploy-lib 2026-11-12 sha256:5bf36e7fab5f5e7c8ff4b26c479f9e2875f334146b02466d3028cb997b5969d6
# shellcheck shell=bash
# preflight prints what the box looked like and never refuses; refuse_if_dirty sits ahead of every
# command that moves the checkout. Both checks refuse a failing git status and a file the index hides from it.

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
    deploy_git_or_refuse $GIT --no-optional-locks -c core.fsmonitor=false status --porcelain || rc=$?
    status=$DEPLOY_GIT_OUT
    [ "$rc" = 0 ] || refuse "git status exited $rc in $ROOT, so the checkout is not known to be clean; a deploy never fast-forwards over it."
    [ -z "$status" ] || refuse "the checkout is dirty; a deploy never fast-forwards over uncommitted work."
    deploy_refuse_if_index_hides_edits
}

# A skip-worktree (S) or assume-unchanged (lowercase) file is one git status never reads (card 753).
deploy_refuse_if_index_hides_edits() {
    local rc=0 kind=assume-unchanged flagged=$'\n([[:lower:]]|S) ([^\n]*)'
    # shellcheck disable=SC2086
    deploy_git_or_refuse $GIT --no-optional-locks -c core.fsmonitor=false ls-files -v || rc=$?
    [ "$rc" = 0 ] || refuse "git ls-files exited $rc in $ROOT, so no tracked file is known to be read by git status; a deploy never runs over it."
    [[ $'\n'$DEPLOY_GIT_OUT =~ $flagged ]] || return 0
    [ "${BASH_REMATCH[1]}" != S ] || kind=skip-worktree
    refuse "$ROOT marks ${BASH_REMATCH[2]} $kind, so git status never read it and a deploy never runs over it. Clear the flag (git update-index --no-$kind), then deploy."
}

# Tracked files only: an untracked file is the app's own. A status git could not give is no clean tree.
deploy_refuse_if_tracked_dirty() {
    local tracked rc=0
    deploy_git_plain "$ROOT/.git" || refuse "$(deploy_git_plain_refusal "$ROOT")."
    # shellcheck disable=SC2086
    deploy_git_or_refuse $GIT --no-optional-locks -c core.fsmonitor=false status --porcelain --untracked-files=no || rc=$?
    tracked=$DEPLOY_GIT_OUT
    [ "$rc" = 0 ] || refuse "git status exited $rc in $ROOT, so the tracked files are not known to be the merge and nothing runs over them."
    [ -z "$tracked" ] || {
        detail "$tracked"
        refuse "tracked files in $ROOT are modified, so the tree is not the merged commit and neither a fast-forward nor a build runs over it. Commit them or restore them, then deploy."
    }
    deploy_refuse_if_index_hides_edits
    say 'TREE tracked files clean'
}
