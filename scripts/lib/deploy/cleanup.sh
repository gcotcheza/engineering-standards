# fleet-deploy-lib 2026-10-04.4 sha256:0fadd7581e986b3ea96ce4548bebbc2583cd4f11de240447186167a14da1abd2
# shellcheck shell=bash

# deploy_cleanup removes the worktrees and the scratch lanes of the one pull request
# that just deployed. It is wired as an EXIT trap: it never exits, never returns non-zero.

# Sourcing discards an inherited marker: only an assignment made in this deploy's own
# shell, on the line before a success-path finish, stands for a deploy that reached it.
unset DEPLOY_SUCCEEDED

# find is pinned to the binary: an exported shell function named find must not decide
# which directories a removal run looks inside.
CLEANUP_FIND=/usr/bin/find

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
    local wt=$1 rc=0 ids out t
    ids=$(${DOCKER-} ps -q 2>&1) || rc=$?
    [ "$rc" = 0 ] || { cleanup_keep mounts "$wt (docker ps exited ${rc}, so no container could be ruled out)"; return 1; }
    [ -n "$ids" ] || return 0
    rc=0
    # shellcheck disable=SC2086  # ids is a list of container ids, one argument each
    out=$(${DOCKER-} inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' $ids 2>&1) || rc=$?
    [ "$rc" = 0 ] || { cleanup_keep mounts "$wt (docker inspect exited ${rc}, so no container could be ruled out)"; return 1; }
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        case "$t" in
            "$wt"|"$wt"/*) cleanup_keep mounts "$wt (a running container mounts $t)"; return 1 ;;
        esac
    done <<<"$out"
    return 0
}

cleanup_rootfiles() {
    local wt=$1 rc=0 out
    out=$("${CLEANUP_FIND}" -P "$wt" -uid "${CLEANUP_ROOT_UID-}" -print -quit 2>&1) || rc=$?
    [ "$rc" = 0 ] || { cleanup_keep rootfiles "$wt (find exited ${rc}, so root-owned files could not be ruled out)"; return 1; }
    [ -z "$out" ] || { cleanup_keep rootfiles "$wt (uid ${CLEANUP_ROOT_UID-} owns $out)"; return 1; }
    return 0
}

cleanup_envfiles() {
    local wt=$1 rc=0 out
    # Any depth (api/.env, api/.env.d/prod), but not vendored packages' own .envrc files.
    out=$(${WT_GIT-} -C "$wt" ls-files -o -i --exclude-standard -- '.env*' ':(glob)**/.env*' ':(glob)**/.env*/**' \
        ':(glob,exclude)**/vendor/**' ':(glob,exclude)**/node_modules/**' 2>&1) || rc=$?
    [ "$rc" = 0 ] || { cleanup_keep envfiles "$wt (ls-files exited ${rc}, so an ignored .env could not be ruled out)"; return 1; }
    [ -z "$out" ] || { cleanup_keep envfiles "$wt (it carries an ignored $out)"; return 1; }
    return 0
}

cleanup_worktree() {
    local wt=$1 head=$2 rc=0 out
    [ -n "$head" ] || { cleanup_keep headInMain "$wt (git named no HEAD for it)"; return 0; }
    ${GIT-} merge-base --is-ancestor "$head" origin/main >/dev/null 2>&1 || rc=$?
    if [ "$rc" != 0 ]; then
        rc=0
        out=$(${GIT-} branch -r --contains "$head" 2>/dev/null) || rc=$?
        { [ "$rc" = 0 ] && [ -n "$out" ]; } \
            || { cleanup_keep headOnRemote "$wt (head ${head:0:7} is not in origin/main and no remote branch contains it)"; return 0; }
    fi
    rc=0
    out=$(${WT_GIT-} -C "$wt" --no-optional-locks status --porcelain 2>&1) || rc=$?
    [ "$rc" = 0 ] || { cleanup_keep status "$wt (status --porcelain exited ${rc}, so uncommitted work could not be ruled out)"; return 0; }
    [ -z "$out" ] || { cleanup_keep dirty "$wt (uncommitted or untracked work)"; return 0; }
    cleanup_procs "$wt" || return 0
    cleanup_mounts "$wt" || return 0
    cleanup_rootfiles "$wt" || return 0
    cleanup_envfiles "$wt" || return 0
    rc=0
    ${GIT-} worktree remove "$wt" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || { cleanup_keep remove "$wt (worktree remove exited ${rc}; it is never re-run with --force)"; return 0; }
    CLEANUP_REMOVED=$((CLEANUP_REMOVED + 1))
    detail "CLEANUP removed $wt"
    return 0
}

cleanup_worktrees() {
    local head_ref=$1 rc=0 list line block=0 path='' head='' entry
    local -a sel=()
    list=$(${GIT-} worktree list --porcelain 2>&1) || rc=$?
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
    rc=0
    ${GIT-} merge-base --is-ancestor "${merge_sha:-missing}" origin/main >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] \
        || { say "CLEANUP #${PR-} worktrees not examined (mergeInMain: merge ${merge_sha:-unreadable} is not an ancestor of origin/main) scratch not reaped (mergeInMain)"; return 0; }

    cleanup_worktrees "$head_ref"
    cleanup_scratch
    say "CLEANUP #${PR-} worktrees ${CLEANUP_WT_PART} scratch ${CLEANUP_SC_PART}"
    return 0
}
