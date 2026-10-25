# fleet-deploy-lib 2026-10-25.3 sha256:d40e60731ec8149043e49695b30daff60f457bef7b5816a3af8ec824bb8b09ad
# shellcheck shell=bash

# deploy_cleanup removes the worktrees and the scratch lanes of the one pull request
# that just deployed. It is wired as an EXIT trap: it never exits, never returns non-zero.

# Sourcing discards an inherited marker: only an assignment made in this deploy's own
# shell, on the line before a success-path finish, stands for a deploy that reached it.
unset DEPLOY_SUCCEEDED

# find, timeout, grep and realpath are pinned to the binary: an exported shell function of that name
# must not decide what a removal run looks inside or keeps.
CLEANUP_FIND=/usr/bin/find
CLEANUP_TIMEOUT=/usr/bin/timeout
CLEANUP_GREP=/usr/bin/grep
CLEANUP_REALPATH=/usr/bin/realpath
# Lane labels are read only below this root; a worktree outside it meets none.
CLEANUP_SCRATCH_ROOT=/srv/worker-scratch

cleanup_reason() {
    case ",${CLEANUP_REASONS}," in
        *",$1,"*) ;;
        *) CLEANUP_REASONS="${CLEANUP_REASONS}${CLEANUP_REASONS:+,}$1" ;;
    esac
}

cleanup_keep() {
    cleanup_reason "$1"
    CLEANUP_KEPT=$((CLEANUP_KEPT + 1))
    detail "CLEANUP keep $1 $2"
}

# Every name the cleanup reads is assigned by the project's deploy.sh. A default here
# would let a deploy that assigned nothing run the real reaper with --apply.
cleanup_unassigned() {
    local n out=''
    for n in PR GIT GH ROOT WT_GIT REAP DOCKER PROC_ROOT CLEANUP_ROOT_UID; do
        [ -n "${!n-}" ] || out="${out}${out:+ }$n"
    done
    printf '%s' "$out"
}

cleanup_procs() {
    local wt=$1 d target seen=0
    for d in "${PROC_ROOT-}"/[0-9]*; do
        [ -d "$d" ] || continue
        seen=1
        target=$(readlink -- "$d/cwd" 2>/dev/null) || continue
        case "$target" in
            "$wt"|"$wt"/*) cleanup_keep procs "$wt (a running process has its working directory inside it)"; return 1 ;;
        esac
    done
    [ "$seen" = 1 ] || { cleanup_keep procs "$wt (no process list under ${PROC_ROOT-}, so no process could be ruled out)"; return 1; }
    return 0
}

cleanup_mounts() {
    local wt=$1 rc=0 ids out t s
    ids=$(${DOCKER-} ps -q 2>&1) || rc=$?
    [ "$rc" = 0 ] || { cleanup_keep mounts "$wt (docker ps exited ${rc}, so no container could be ruled out)"; return 1; }
    [ -n "$ids" ] || return 0
    rc=0
    # shellcheck disable=SC2086  # ids is a list of container ids, one argument each
    out=$(${DOCKER-} inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' $ids 2>&1) || rc=$?
    [ "$rc" = 0 ] || { cleanup_keep mounts "$wt (docker inspect exited ${rc}, so no container could be ruled out)"; return 1; }
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        # A bind source can be written through a link of its own, so its real path is compared too.
        s=$("${CLEANUP_REALPATH}" -m -- "$t" 2>/dev/null) || { cleanup_keep mounts "$wt (the real path of mount $t could not be read)"; return 1; }
        case "$t" in
            "$wt"|"$wt"/*) cleanup_keep mounts "$wt (a running container mounts $t)"; return 1 ;;
        esac
        case "$s" in
            "$wt"|"$wt"/*) cleanup_keep mounts "$wt (a running container mounts $t, which is $s)"; return 1 ;;
        esac
    done <<<"$out"
    return 0
}

cleanup_rootfiles() {
    local wt=$1 rc=0 out
    # The slash: -P never enters a start point that is a link, and a worktree moved and linked
    # back is listed by its link path, so without it a root-owned file inside is never seen.
    out=$("${CLEANUP_FIND}" -P "$wt/" -uid "${CLEANUP_ROOT_UID-}" -print -quit 2>&1) || rc=$?
    [ "$rc" = 0 ] || { cleanup_keep rootfiles "$wt (find exited ${rc}, so root-owned files could not be ruled out)"; return 1; }
    [ -z "$out" ] || { cleanup_keep rootfiles "$wt (uid ${CLEANUP_ROOT_UID-} owns $out)"; return 1; }
    return 0
}

cleanup_envfiles() {
    local wt=$1 rc=0 out
    # A .env* name, or a file in a .env* folder, at any depth; none inside a vendor/ or node_modules/ folder.
    # shellcheck disable=SC2086
    deploy_git_bounded ${WT_GIT-} -C "$wt" -c core.fsmonitor=false ls-files -o -i --exclude-standard -- '.env*' ':(glob)**/.env*' ':(glob)**/.env*/**' \
        ':(glob,exclude)**/vendor/**' ':(glob,exclude)**/node_modules/**' 2>/dev/null || rc=$?
    out=$DEPLOY_GIT_OUT$DEPLOY_GIT_STDERR
    [ "$rc" = 0 ] || { cleanup_keep envfiles "$wt (ls-files exited ${rc}, so an ignored .env could not be ruled out)"; return 1; }
    [ -z "$out" ] || { cleanup_keep envfiles "$wt (it carries an ignored $out)"; return 1; }
    return 0
}

# A clean or process filter is a program status and remove's own status run; no single -c turns all off.
# One only root could set (system scope) is root's own; any other keeps the tree (card 714).
cleanup_filters() {
    local wt=$1 rc=0 scope key named=''
    # shellcheck disable=SC2086
    deploy_git_bounded ${WT_GIT-} -C "$wt" -c core.fsmonitor=false config --show-scope --get-regexp '^filter\..*\.(clean|process)$' 2>/dev/null || rc=$?
    { [ -z "$DEPLOY_GIT_ERR" ] && { [ "$rc" = 0 ] || [ "$rc" = 1 ]; }; } \
        || { cleanup_keep filter "$wt (git config exited ${rc}, so a filter program could not be ruled out)"; return 1; }
    while IFS=$'\t' read -r scope key; do
        case $scope in ''|system) continue ;; esac
        named="${named}${named:+, }${key%% *} (${scope})"
    done <<<"$DEPLOY_GIT_OUT"
    [ -z "$named" ] || { cleanup_keep filter "$wt (its git config names a filter program, which status would run: ${named})"; return 1; }
    return 0
}

# A .fleet-scratch label with a keep= line in a directory between the scratch root and the
# worktree holds it, as the scratch reapers hold that lane (card 488).
cleanup_lanekeep() {
    local wt=$1 dir=$1 label rc
    case "$wt" in "${CLEANUP_SCRATCH_ROOT}"/?*) ;; *) return 0 ;; esac
    while dir=${dir%/*}; [ "${#dir}" -gt "${#CLEANUP_SCRATCH_ROOT}" ]; do
        label="${dir}/.fleet-scratch"
        [ ! -L "$label" ] || { cleanup_keep laneKeep "$wt ($label is a symbolic link, so a keep= could not be ruled out)"; return 1; }
        [ -e "$label" ] || continue
        [ -f "$label" ] || { cleanup_keep laneKeep "$wt ($label is not a plain file, so a keep= could not be ruled out)"; return 1; }
        rc=0
        "${CLEANUP_TIMEOUT}" 5 "${CLEANUP_GREP}" -q -m 1 -e '^keep=' -- "$label" </dev/null 2>/dev/null || rc=$?
        [ "$rc" != 0 ] || { cleanup_keep laneKeep "$wt (its lane label $label carries keep=)"; return 1; }
        [ "$rc" = 1 ] || { cleanup_keep laneKeep "$wt ($label could not be read (exit ${rc}), so a keep= could not be ruled out)"; return 1; }
    done
    return 0
}

# The by-hand removal of a linked worktree, every path %q-quoted: remove by the link path empties the
# target and fails, so the record is repaired to the real path, the link unlinked, and no --force used.
cleanup_linked_say() {
    local l r g
    printf -v l '%q' "$1"; printf -v r '%q' "$2"; printf -v g '%q' "${ROOT-}"
    say "CLEANUP #${PR-} kept $l -> $r: linked worktree, not removed; remove by hand with: git -C $g worktree repair $r && { [ ! -L $l ] || unlink -- $l; } && git -C $g worktree remove $r"
}

# Read-only preview (S7) of the ignored paths that remove deletes; 1 when they cannot be listed.
cleanup_linked_preview() {
    local real=$1 rc=0 n=0 shown='' p r
    printf -v r '%q' "$real"
    # The owner's tree may set core.fsmonitor, which runs a program: every git call in a worktree forces it off.
    # shellcheck disable=SC2086
    deploy_git_bounded ${WT_GIT-} -C "$real" --no-optional-locks -c core.fsmonitor=false -c core.quotePath=true \
        ls-files -o -i --exclude-standard --directory 2>/dev/null || rc=$?
    [ "$rc" = 0 ] || { say "CLEANUP #${PR-} kept $r: its ignored paths could not be listed (ls-files exited ${rc}), so no by-hand removal is printed"; return 1; }
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        n=$((n + 1))
        [ "$n" -gt 5 ] || shown="${shown} ${p}"
    done <<<"$DEPLOY_GIT_OUT"
    [ "$n" != 0 ] || { say "CLEANUP #${PR-} preview of $r: 0 ignored paths"; return 0; }
    [ "$n" -le 5 ] || shown="${shown} (and $((n - 5)) more)"
    say "CLEANUP #${PR-} preview of $r: ${n} ignored path(s), which worktree remove deletes:${shown}"
}

cleanup_worktree() {
    local wt=$1 head=$2 rc=0 out real
    cleanup_lanekeep "$wt" || return 0
    [ -n "$head" ] || { cleanup_keep headInMain "$wt (git named no HEAD for it)"; return 0; }
    # shellcheck disable=SC2086
    deploy_git_bounded ${GIT-} merge-base --is-ancestor "$head" origin/main 2>/dev/null || rc=$?
    [ -z "$DEPLOY_GIT_ERR" ] || { cleanup_keep headInMain "$wt (merge-base: $DEPLOY_GIT_ERR, so head ${head:0:7} is not known to be in origin/main)"; return 0; }
    if [ "$rc" != 0 ]; then
        rc=0
        # shellcheck disable=SC2086
        deploy_git_bounded ${GIT-} branch -r --contains "$head" 2>/dev/null || rc=$?
        [ -z "$DEPLOY_GIT_ERR" ] || { cleanup_keep headOnRemote "$wt (branch -r: $DEPLOY_GIT_ERR, so no remote branch is known to contain head ${head:0:7})"; return 0; }
        { [ "$rc" = 0 ] && [ -n "$DEPLOY_GIT_OUT" ]; } \
            || { cleanup_keep headOnRemote "$wt (head ${head:0:7} is not in origin/main and no remote branch contains it)"; return 0; }
    fi
    cleanup_filters "$wt" || return 0
    rc=0
    # shellcheck disable=SC2086
    deploy_git_bounded ${WT_GIT-} -C "$wt" --no-optional-locks -c core.fsmonitor=false status --porcelain 2>/dev/null || rc=$?
    out=$DEPLOY_GIT_OUT$DEPLOY_GIT_STDERR
    [ "$rc" = 0 ] || { cleanup_keep status "$wt (status --porcelain exited ${rc}, so uncommitted work could not be ruled out)"; return 0; }
    [ -z "$out" ] || { cleanup_keep dirty "$wt (uncommitted or untracked work)"; return 0; }
    # A worktree reached through a link is never removed: remove empties the target, then fails on the link.
    real=$("${CLEANUP_REALPATH}" -e -- "$wt" 2>/dev/null) || { cleanup_keep realpath "$wt (its real path could not be read, so a link could not be ruled out)"; return 0; }
    cleanup_procs "$real" || return 0
    cleanup_mounts "$real" || return 0
    cleanup_rootfiles "$real" || return 0
    cleanup_envfiles "$real" || return 0
    # Only now the preview and by-hand line: remove deletes ignored files, so a refusal above prints none.
    [ "$real" = "$wt" ] || { cleanup_keep link "$wt (linked to $real)"; cleanup_linked_preview "$real" && cleanup_linked_say "$wt" "$real"; return 0; }
    # Read again just before remove, whose own status runs a filter or fsmonitor as root's git; with locks
    # its status also writes the index and fires post-index-change as root, so none are taken.
    cleanup_filters "$real" || return 0
    rc=0
    # shellcheck disable=SC2086
    deploy_git_bounded ${GIT-} --no-optional-locks -c core.fsmonitor=false worktree remove "$wt" 2>/dev/null || rc=$?
    [ "$rc" = 0 ] || { cleanup_keep remove "$wt (worktree remove exited ${rc}; it is never re-run with --force)"; return 0; }
    CLEANUP_REMOVED=$((CLEANUP_REMOVED + 1))
    detail "CLEANUP removed $wt"
    return 0
}

cleanup_worktrees() {
    local head_ref=$1 rc=0 list line block=0 path='' head='' entry
    local -a sel=()
    # shellcheck disable=SC2086
    deploy_git_bounded ${GIT-} worktree list --porcelain || rc=$?
    list=$DEPLOY_GIT_OUT
    [ "$rc" = 0 ] || { CLEANUP_WT_PART="not listed (worktree list exited ${rc})"; return 0; }
    while IFS= read -r line; do
        case "$line" in
            'worktree '*) block=$((block + 1)); path=${line#worktree }; head='' ;;
            'HEAD '*) head=${line#HEAD } ;;
            'branch '*)
                if [ "$block" -gt 1 ] && [ "$path" != "${ROOT-}" ] && [ "${line#branch }" = "refs/heads/${head_ref}" ]; then
                    sel+=("${path}"$'\t'"${head}")
                fi
                ;;
        esac
    done <<<"$list"
    for entry in ${sel[@]+"${sel[@]}"}; do
        cleanup_worktree "${entry%%$'\t'*}" "${entry#*$'\t'}"
    done
    CLEANUP_WT_PART="removed ${CLEANUP_REMOVED} kept ${CLEANUP_KEPT} (${CLEANUP_REASONS:-none})"
    return 0
}

cleanup_scratch() {
    local rc=0 out sha count kept reaped reap=${REAP-}
    out=$($reap "${REPO-}" "${PR-}" 2>&1) || rc=$?
    detail "$out"
    case "$rc" in
        0|3) ;;
        *) say "CLEANUP #${PR-} scratch: ${reap##*/} exited ${rc} on its read-only run; no lane was reaped and the deploy is unchanged."
           CLEANUP_SC_PART="not reaped (dry run exited ${rc})"; return 0 ;;
    esac
    # A here-string and sed's own q, never a pipe into head: the caller runs under
    # pipefail, where the first stage's SIGPIPE would abort the EXIT handler.
    sha=$(sed -n '/^candidates: /{s/^candidates: [0-9][0-9]*  set: \([0-9a-f]\{64\}\)  kept: .*/\1/p;q}' <<<"$out")
    count=$(sed -n '/^candidates: /{s/^candidates: \([0-9][0-9]*\)  set: .*/\1/p;q}' <<<"$out")
    kept=$(sed -n '/^candidates: /{s/^candidates: [0-9][0-9]*  set: [0-9a-f]\{64\}  kept: \([0-9][0-9]*\)  .*/\1/p;q}' <<<"$out")
    { [ -n "$sha" ] && [ -n "$count" ] && [ -n "$kept" ]; } \
        || { say "CLEANUP #${PR-} scratch: ${reap##*/} printed no candidate set, so nothing was applied; read its lines in ${LOG:-the deploy log}."
             CLEANUP_SC_PART="not reaped (unreadable read-only run)"; return 0; }
    if [ "$count" = 0 ]; then
        CLEANUP_SC_PART="reaped 0 kept ${kept} (no lane is labelled ${REPO-} #${PR-})"
        [ "$kept" = 0 ] || CLEANUP_SC_PART="reaped 0 kept ${kept} (every labelled lane was kept (${kept}))"
        return 0
    fi
    rc=0
    out=$($reap "${REPO-}" "${PR-}" --expect "$sha" --apply 2>&1) || rc=$?
    detail "$out"
    case "$rc" in
        0|3) ;;
        4) say "CLEANUP #${PR-} scratch: ${reap##*/} stopped part-way (rc=4); read its reaped and intact lines in ${LOG:-the deploy log}. The deploy is unchanged."
           CLEANUP_SC_PART="partly reaped (apply exited 4)"; return 0 ;;
        *) say "CLEANUP #${PR-} scratch: ${reap##*/} exited ${rc} with --apply; read its lines in ${LOG:-the deploy log}. The deploy is unchanged."
           CLEANUP_SC_PART="not reaped (apply exited ${rc})"; return 0 ;;
    esac
    reaped=$(sed -n '/^reaped: [0-9]/{s/^reaped: \([0-9][0-9]*\)  kept: .*/\1/p;q}' <<<"$out")
    kept=$(sed -n '/^reaped: [0-9]/{s/^reaped: [0-9][0-9]*  kept: \([0-9][0-9]*\)$/\1/p;q}' <<<"$out")
    { [ -n "$reaped" ] && [ -n "$kept" ]; } \
        || { say "CLEANUP #${PR-} scratch: ${reap##*/} applied but printed no counts; read its lines in ${LOG:-the deploy log}."
             CLEANUP_SC_PART="applied, counts unreadable"; return 0; }
    CLEANUP_SC_PART="reaped ${reaped} kept ${kept}"
    return 0
}

deploy_cleanup() {
    local rc=0 missing json state base head_ref merge_sha
    [ -n "${DEPLOY_SUCCEEDED-}" ] \
        || { say "CLEANUP #${PR-} did not run: the deploy did not reach finish."; return 0; }
    CLEANUP_REASONS=''
    CLEANUP_KEPT=0
    CLEANUP_REMOVED=0
    CLEANUP_WT_PART=''
    CLEANUP_SC_PART=''

    missing=$(cleanup_unassigned)
    [ -z "$missing" ] \
        || { say "CLEANUP #${PR-} did not run: the deploy assigned no ${missing}."; return 0; }
    [ -n "${REPO-}" ] \
        || { say "CLEANUP #${PR-} did not run: REPO names no repository, so no pull request could be read."; return 0; }

    json=$(${GH-} pr view "${PR-}" -R "${REPO-}" --json state,baseRefName,headRefName,mergeCommit 2>&1) || rc=$?
    detail "$json"
    [ "$rc" = 0 ] \
        || { say "CLEANUP #${PR-} did not run: gh could not read the pull request (rc=${rc}); nothing is removed."; return 0; }
    state=$(json_value "$json" state)
    base=$(json_value "$json" baseRefName)
    head_ref=$(json_value "$json" headRefName)
    merge_sha=$(json_value "$json" oid)

    [ "$state" = MERGED ] \
        || { say "CLEANUP #${PR-} worktrees not examined (notMerged: state ${state:-unreadable}) scratch not reaped (notMerged)"; return 0; }
    [ "$base" = main ] \
        || { say "CLEANUP #${PR-} worktrees not examined (base: merged into ${base:-unreadable}, not main) scratch not reaped (base)"; return 0; }
    [ -n "$head_ref" ] \
        || { say "CLEANUP #${PR-} worktrees not examined (headRef: gh named no head branch) scratch not reaped (headRef)"; return 0; }
    deploy_git_plain "${ROOT-}/.git" \
        || { say "CLEANUP #${PR-} did not run: $(deploy_git_plain_refusal "${ROOT-}")."; return 0; }
    rc=0
    # shellcheck disable=SC2086
    deploy_git_bounded ${GIT-} merge-base --is-ancestor "${merge_sha:-missing}" origin/main 2>/dev/null || rc=$?
    [ -z "$DEPLOY_GIT_ERR" ] \
        || { say "CLEANUP #${PR-} worktrees not examined (mergeInMain: merge-base: $DEPLOY_GIT_ERR) scratch not reaped (mergeInMain)"; return 0; }
    [ "$rc" = 0 ] \
        || { say "CLEANUP #${PR-} worktrees not examined (mergeInMain: merge ${merge_sha:-unreadable} is not an ancestor of origin/main) scratch not reaped (mergeInMain)"; return 0; }

    cleanup_worktrees "$head_ref"
    cleanup_scratch
    say "CLEANUP #${PR-} worktrees ${CLEANUP_WT_PART} scratch ${CLEANUP_SC_PART}"
    return 0
}
