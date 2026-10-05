#!/usr/bin/env bash
# Guards scripts/lib/deploy/: every function, every sentence and every header hash,
# against fakes in a temp directory. DEPLOY_LIB_DIR=<copy> runs the list against a copy.
#
#   scripts/lib/deploy/test.sh
#   DEPLOY_LIB_DIR=/tmp/mutant scripts/lib/deploy/test.sh   the red proofs
#
# It reads no checkout, runs no docker, no gh and no heavy-work. Fixture commits run the
# real fleet hook (S1); the hook canary reads its log, so the suite runs as root.
# FAKE_CALLS strings stay single-quoted on purpose: the driver eval's them. WORK is fixed under
# /srv/worker-scratch (root 755, exec), never TMPDIR: summary.sh refuses /tmp and /run is noexec.
# shellcheck disable=SC2016
set -uo pipefail

[ "$(id -u)" = 0 ] || { printf 'lib test.sh commits through the fleet hook: run it as root (advisor ruling 2026-10-03)\n' >&2; exit 1; }
[ -z "${LIB_TEST_ROOT_PROBE:-}" ] || { printf 'PAST THE ROOT CHECK\n'; exit 3; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${DEPLOY_LIB_DIR:-${SCRIPT_DIR}}"
PR_NUMBER=73
MISSING_SHA=0000000000000000000000000000000000000001

fails=0
pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }

contains() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 — no [$3] in:"$'\n'"$2" ;;
    esac
}

absent() {
    case "$2" in
        *"$3"*) fail "$1 — [$3] is there and must not be:"$'\n'"$2" ;;
        *) pass "$1" ;;
    esac
}

equals() {
    if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi
}

matches() {
    if printf '%s' "$2" | grep -qE "$3"; then pass "$1"; else fail "$1 — [$2] does not match /$3/"; fi
}

WORK="$(mktemp -d -p /srv/worker-scratch deploy-lib-test.XXXXXXXX)" || { printf 'cannot make a work directory under /srv/worker-scratch\n' >&2; exit 1; }
trap 'rm -rf "${WORK}"' EXIT
GHE_WORKFLOW='name: ci'$'\n''on: [push, workflow_dispatch]'
GHE_WSUM="$(printf '%s\n' "${GHE_WORKFLOW}" | sha256sum | cut -d' ' -f1)"
DEVNULL_BEFORE="$(stat -c '%a %u %g %F' /dev/null)"

git_at() { git -C "$ROOT" -c user.name=t -c user.email=t@example.invalid "$@"; }

# S1: fixture commits go through the real fleet hook; bracketed letters keep these lines off their own list.
# What is covered, and the loud false positives (merge's no-stat flag, a dash-n in a message): docs/DECISIONS.md.
HOOK_BYPASS='--no[-]v(e(r(i(fy?)?)?)?)?([^A-Za-z-]|$)|HUSK[Y]=0|GIT_CONFI[G]_[A-Z0-9_]+|(^|[^A-Za-z0-9_])HOM[E]=|XDG_CONFIG_HOM[E]=|commit-tre[e]|fast-impor[t]|hash-objec[t][^;|&]*[[:space:]]-[A-Za-z]*w|(commi[t]|merg[e])[^;|&]*[[:space:]]-[A-Za-z]*n[A-Za-z]*([[:space:]]|$)'
HOOK_BYPASS_ANY_CASE='core[.]hooks[p]ath'
scan_bypasses() {
    local joined any_case
    joined="$(awk '{ if (buf == "") start = NR; if (sub(/\\$/, "")) { buf = buf $0 " "; next } print start ":" buf $0; buf = "" }' "$1")" || return 2
    BYPASSES="$(printf '%s\n' "${joined}" | grep -E -- "$2")"
    case $? in 0|1) ;; *) return 2 ;; esac
    any_case="$(printf '%s\n' "${joined}" | grep -iE -- "$3")"
    case $? in 0|1) ;; *) return 2 ;; esac
    BYPASSES+=$'\n'"${any_case}"
}
scan_bypasses "${BASH_SOURCE[0]}" "${HOOK_BYPASS}" "${HOOK_BYPASS_ANY_CASE}" \
    || fail "the hook-bypass scan could not read ${BASH_SOURCE[0]} or run its grep"
absent 'no fixture skips the fleet hook (S1)' "${BYPASSES}" ':'
scan_bypasses "${BASH_SOURCE[0]}" '(' "${HOOK_BYPASS_ANY_CASE}" 2>/dev/null
equals 'a broken grep in the bypass scan fails it' "$?" 2
scan_bypasses "${BASH_SOURCE[0]}" "${HOOK_BYPASS}" '(' 2>/dev/null
equals 'a broken any-case grep in the bypass scan fails it' "$?" 2
scan_bypasses "${BASH_SOURCE[0]}.missing" "${HOOK_BYPASS}" "${HOOK_BYPASS_ANY_CASE}" 2>/dev/null
equals 'an unreadable file in the bypass scan fails it' "$?" 2

write_driver() {
    mkdir -p "${CASE}/lib"
    cp "${LIB_DIR}/summary.sh" "${LIB_DIR}/resolve.sh" "${LIB_DIR}/ledger.sh" \
       "${LIB_DIR}/preflight.sh" "${LIB_DIR}/cleanup.sh" "${CASE}/lib/"
    cat >"${CASE}/lib/driver.sh" <<'SH'
#!/usr/bin/env bash
set -u
D="$(cd -- "$(dirname -- "$0")" && pwd)"
. "${D}/summary.sh"
. "${D}/resolve.sh"
. "${D}/ledger.sh"
. "${D}/preflight.sh"
. "${D}/cleanup.sh"
printf 'LIBS SOURCED\n'
ROOT=$DEPLOY_ROOT
GIT=$DEPLOY_GIT
GH=$DEPLOY_GH
HEAVY=$DEPLOY_HEAVY
LEDGER=$DEPLOY_LEDGER
WT_GIT=$DEPLOY_WT_GIT
REAP=$DEPLOY_REAP
DOCKER=$DEPLOY_DOCKER
PROC_ROOT=$DEPLOY_PROC_ROOT
CLEANUP_ROOT_UID=$DEPLOY_ROOT_UID
PR=$FAKE_PR
BY_HAND=$FAKE_BY_HAND
BEFORE=$FAKE_BEFORE
GATED=''
HEAD_SHA=''
MERGE_SHA=''
cd "$ROOT" || exit 64
deploy_log_open "$PR"
eval "$FAKE_CALLS"
SH
    chmod 0755 "${CASE}/lib/driver.sh"
}

write_fakes() {
    cat >"${BIN}/gh" <<'SH'
#!/bin/sh
[ -n "${FAKE_GH_ARGV_LOG:-}" ] && printf '%s\n' "$*" >>"${FAKE_GH_ARGV_LOG}"
# The GitHub e2e route: check runs and one workflow run per check suite, from saved JSON.
if [ "$1" = api ]; then
    [ "${GH_TOKEN:-}" = "$(cat "${FAKE_GHE_DIR}/token.expected" 2>/dev/null)" ] && echo token-matches >>"${FAKE_GHE_DIR}/token.seen"
    for a; do case $a in check_suite_id=*) suite=${a#check_suite_id=} ;; esac; done
    case " $* " in
        *'/check-runs '*) cat "${FAKE_GHE_DIR}/checks.json"; exit "${FAKE_GHE_RC:-0}" ;;
        *'/actions/runs '*) cat "${FAKE_GHE_DIR}/runs-${suite:-none}.json"; exit "${FAKE_GHE_RUNS_RC:-0}" ;;
    esac
    exit 1
fi
case " $* " in
    *' -R '*) : ;;
    *) echo 'gh: no repository resolved (use -R owner/repo)' >&2; exit 1 ;;
esac
[ -n "${FAKE_GH_FAIL:-}" ] && { echo 'gh: no such pull request' >&2; exit 1; }
cat "${FAKE_GH_JSON}"
SH
    # --status answers whatever the case asked for, and always on more than one line:
    # pre-flight quotes the serializer's first line, not its report.
    cat >"${BIN}/heavy-work" <<'SH'
#!/bin/sh
[ "$1" = '--status' ] && { printf '%s\nlast: label=noise\n' "${FAKE_HEAVY_STATUS:-free}"; exit 0; }
exit 0
SH
    # The reaper fake answers the read-only run and the --apply run separately, and
    # records its argv: --expect is an argument, so only the argv proves it was passed.
    cat >"${BIN}/reap" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${FAKE_REAP_ARGV_LOG}"
case " $* " in
    *' --apply '*) printf '%s\n' "${FAKE_REAP_APPLY_OUT}"; exit "${FAKE_REAP_APPLY_RC:-0}" ;;
esac
printf '%s\n' "${FAKE_REAP_DRY_OUT}"
exit "${FAKE_REAP_DRY_RC:-0}"
SH
    # FAKE_DOCKER_DIRTY names a tracked file this fake appends to, which is how the
    # dirty-after-the-check case reaches `worktree remove` with a modified tree.
    cat >"${BIN}/docker" <<'SH'
#!/bin/sh
[ -n "${FAKE_DOCKER_DIRTY:-}" ] && printf 'dirtied after the dirty check\n' >>"${FAKE_DOCKER_DIRTY}"
case "$1" in
    ps) printf '%s\n' "${FAKE_DOCKER_IDS}" ;;
    inspect) printf '%s\n' "${FAKE_DOCKER_MOUNTS}" ;;
esac
exit "${FAKE_DOCKER_RC:-0}"
SH
    chmod 0755 "${BIN}"/*
}

# A checkout on L, origin/main on the merge M of the pull request head H. Nothing
# here is a real checkout: every path is under mktemp -d.
# Each case copies a repository built once per kind, so a run commits through the fleet hook
# a handful of times, not once per case — see docs/DECISIONS.md.
fixture_template() {
    local ROOT="${WORK}/.template-$1"
    [ -d "${ROOT}" ] && return 0
    mkdir -p "${ROOT}/app"
    git init -q -b main "${ROOT}"
    printf 'base\n' >"${ROOT}/app/base.txt"
    mkdir -p "${ROOT}/.github/workflows"
    printf '%s\n' "${GHE_WORKFLOW}" >"${ROOT}/.github/workflows/ci.yml"
    git_at add app/base.txt .github/workflows/ci.yml
    git_at commit -q -m base

    git_at checkout -q -b pr
    printf 'feature\n' >"${ROOT}/app/feature.txt"
    git_at add app/feature.txt
    git_at commit -q -m feature

    git_at checkout -q main
    if [ "$1" = 'trees-differ' ]; then
        git_at merge -q --no-ff --no-commit pr >/dev/null 2>&1
        printf 'smuggled\n' >"${ROOT}/app/smuggled.txt"
        git_at add app/smuggled.txt
        git_at commit -q -m merge
    else
        git_at merge -q --no-ff -m merge pr
    fi

    git_at checkout -q -b side main^1
    printf 'side\n' >"${ROOT}/app/side.txt"
    git_at add app/side.txt
    git_at commit -q -m side
    git_at update-ref refs/fixture/side HEAD
    git_at checkout -q main
    git_at branch -q -D side
}

fixture() {
    CASE="${WORK}/$1"
    ROOT="${CASE}/root"
    BIN="${CASE}/bin"
    LEDGER="${CASE}/ledger"
    LOGS="${CASE}/logs"
    mkdir -p "${BIN}" "${LOGS}"
    : >"${LEDGER}"

    fixture_template "${2:-plain}"
    cp -a "${WORK}/.template-${2:-plain}" "${ROOT}"
    LIVE_SHA="$(git_at rev-parse main^1)"
    LIVE_SHORT="$(git_at rev-parse --short main^1)"
    HEAD_SHA="$(git_at rev-parse pr)"
    MERGE_SHA="$(git_at rev-parse main)"
    FIXTURE_SIDE_SHA="$(git_at rev-parse refs/fixture/side)"
    git_at update-ref -d refs/fixture/side

    git clone -q --bare "${ROOT}" "${CASE}/origin.git"
    git_at remote add origin "${CASE}/origin.git"
    git_at reset -q --hard "${LIVE_SHA}"
    git_at fetch -q origin

    printf '{"headRefOid":"%s","mergeCommit":{"oid":"%s"},"state":"MERGED"}\n' \
        "${HEAD_SHA}" "${MERGE_SHA}" >"${CASE}/gh.json"
    printf '%s ci 2026-09-18T20:00:00Z 0 -\n%s e2e 2026-09-18T20:30:00Z 0 -\n' \
        "${HEAD_SHA}" "${HEAD_SHA}" >"${LEDGER}"
    write_fakes
    write_driver
}

run_lib() {
    local logenv repoenv
    if [ -n "${LOG_DIR_UNSET:-}" ]; then
        logenv="DEPLOY_LOG_ROOT=${CASE}/logroot"
    else
        logenv="DEPLOY_LOG_DIR=${LOGS}"
    fi
    if [ "${REPO_OVERRIDE:-DEFAULT}" = 'NONE' ]; then
        repoenv=''
    else
        repoenv="FLEET_DEPLOY_REPO=${REPO_OVERRIDE:-gcotcheza/fixture}"
    fi
    mergeenv="${MERGE_SHA_ENV:+FLEET_DEPLOY_MERGE_SHA=${MERGE_SHA_ENV}}"
    # Simulates an operator's `export GATE_SUITE_PASSED=1` (or a CI wrapper's) already
    # present in the environment BEFORE driver.sh sources ledger.sh.
    suiteenv="${SUITE_PASSED_ENV:+GATE_SUITE_PASSED=${SUITE_PASSED_ENV}}"
    # The same move for the arming guard: set in the environment before driver.sh
    # sources ledger.sh, GATE_ARMED would buy a row for a run that armed nothing.
    armedenv="${ARMED_ENV:+GATE_ARMED=1}"
    # And for the success marker: exported before driver.sh sources cleanup.sh, it would
    # buy the removals of a deploy that refused.
    succeededenv="${SUCCEEDED_ENV:+DEPLOY_SUCCEEDED=1}"
    ARGVFILE="${CASE}/gh-argv.log"
    REAPARGV="${CASE}/reap-argv.log"
    # shellcheck disable=SC2086  # repoenv is empty or one NAME=value; "" would be env's command
    OUT="$(env \
        PATH="${BIN}:${PATH}" \
        FAKE_GH_JSON="${CASE}/gh.json" \
        FAKE_GH_FAIL="${GH_FAIL:-}" \
        FAKE_GH_ARGV_LOG="${ARGVFILE}" \
        FAKE_GHE_DIR="${CASE}/ghe-fake" \
        FAKE_GHE_RC="${GHE_RC-0}" \
        FAKE_GHE_RUNS_RC="${GHE_RUNS_RC-0}" \
        DEPLOY_GITHUB_E2E_DIR="${CASE}/ghe" \
        ${GHE_TOKEN_PATH:+DEPLOY_GITHUB_E2E_TOKEN=${GHE_TOKEN_PATH}} \
        FAKE_HEAVY_STATUS="${HEAVY_STATUS:-free}" \
        FAKE_PR="${PR_NUMBER}" \
        FAKE_BY_HAND="${BY_HAND:-0}" \
        FAKE_BEFORE="${LIVE_SHORT}" \
        FAKE_CALLS="$1" \
        EXTRA_DONE="${EXTRA:-}" \
        DEPLOY_ROOT="${ROOT}" \
        DEPLOY_RECORD_ROOT="${CASE}/records" \
        DEPLOY_GIT="git -C ${ROOT}" \
        DEPLOY_GH="${BIN}/gh" \
        DEPLOY_HEAVY="${BIN}/heavy-work" \
        DEPLOY_LEDGER="${LEDGER}" \
        DEPLOY_WT_GIT="${WT_GIT_SEAM-git}" \
        DEPLOY_REAP="${REAP_SEAM-${BIN}/reap}" \
        DEPLOY_DOCKER="${DOCKER_SEAM-${BIN}/docker}" \
        DEPLOY_PROC_ROOT="${PROC_ROOT_SEAM-${CASE}/proc}" \
        DEPLOY_ROOT_UID="${ROOT_UID_SEAM-61234}" \
        FAKE_REAP_ARGV_LOG="${REAPARGV}" \
        FAKE_REAP_DRY_OUT="${REAP_DRY_OUT-candidates: 0  set: ${EMPTY_SET}  kept: 0  errors: 0}" \
        FAKE_REAP_DRY_RC="${REAP_DRY_RC-0}" \
        FAKE_REAP_APPLY_OUT="${REAP_APPLY_OUT-reaped: 1  kept: 0}" \
        FAKE_REAP_APPLY_RC="${REAP_APPLY_RC-0}" \
        FAKE_DOCKER_IDS="${DOCKER_IDS-}" \
        FAKE_DOCKER_MOUNTS="${DOCKER_MOUNTS-}" \
        FAKE_DOCKER_RC="${DOCKER_RC-0}" \
        FAKE_DOCKER_DIRTY="${DOCKER_DIRTY-}" \
        ${repoenv} \
        ${mergeenv} \
        ${suiteenv} \
        ${armedenv} \
        ${succeededenv} \
        "${logenv}" \
        bash "${DRIVER_DIR:-${CASE}/lib}/driver.sh" 2>&1)"
    RC=$?
    LOGFILE="$(find "${LOGS}" "${CASE}/logroot" -name '*.log' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)"
    BY_HAND=''
    GH_FAIL=''
    EXTRA=''
    LOG_DIR_UNSET=''
    REPO_OVERRIDE=''
    MERGE_SHA_ENV=''
    DRIVER_DIR=''
    SUITE_PASSED_ENV=''
    ARMED_ENV=''
    SUCCEEDED_ENV=''
    HEAVY_STATUS=''
    # Unset, not emptied: a case that assigns an empty seam means "the deploy assigned
    # none", which is a different thing from a case that never mentioned it.
    unset WT_GIT_SEAM REAP_SEAM DOCKER_SEAM PROC_ROOT_SEAM ROOT_UID_SEAM
    unset REAP_DRY_OUT REAP_DRY_RC REAP_APPLY_OUT REAP_APPLY_RC
    unset DOCKER_IDS DOCKER_MOUNTS DOCKER_RC DOCKER_DIRTY
    unset GHE_RC GHE_RUNS_RC GHE_TOKEN_PATH
}

# The one not-green refusal, written out once: it names the kind that is missing, what
# every row says, and the three routes — without claiming any project's flag exists.
ROUTES='a commit is gated before it is merged, and once it is in main only a route the gate documents for that (a base override, where it has one) can gate it — or deploy with --gated-by-hand, which records this as ungated.'
no_green() { printf 'REFUSED: the ledger holds no green %s for %s (%s): %s' "$1" "${2:0:7}" "$3" "${ROUTES}"; }

# The row count of a ledger a refusal may have left un-created.
rows() { if [ -s "$1" ]; then wc -l <"$1"; else printf '0'; fi; }

# Every writer case arms the way a gate does: the git seam first, then the sha.
armed() { printf "GATE_LEDGER_GIT='git -C %s'; gate_ledger_arm; %s" "${ROOT}" "$1"; }

BY_HAND=''
GH_FAIL=''
EXTRA=''
LOG_DIR_UNSET=''
REPO_OVERRIDE=''
MERGE_SHA_ENV=''
DRIVER_DIR=''
SUITE_PASSED_ENV=''
ARMED_ENV=''
HEAVY_STATUS=''

# --- 0. fixture commits run the real fleet hook, and it is seen to run (backlog 264) ---
HOOK_LOG=/var/log/fleet-secrets-check.log
clean_lines() {
    if [ -r "${HOOK_LOG}" ]; then grep -c ' caller=root .*result=clean$' "${HOOK_LOG}" || true
    else printf 'unreadable'; fi
}
grew() {
    case "$2$3" in
        *[!0-9]*|'') fail "$1 — ${HOOK_LOG} could not be counted (before [$2], after [$3])" ;;
        *) if [ "$3" -gt "$2" ]; then pass "$1 ($2 -> $3)"; else fail "$1 — stayed at $2 -> $3"; fi ;;
    esac
}
SUITE_CLEAN_BEFORE="$(clean_lines)"

# App users are capped at 30 hook calls a minute and this suite makes about 250.
mkdir -p "${WORK}/notroot"
printf '#!/bin/sh\necho 1000\n' >"${WORK}/notroot/id"
chmod 0755 "${WORK}/notroot/id"
OUT="$(PATH="${WORK}/notroot:${PATH}" LIB_TEST_ROOT_PROBE=1 bash "${SCRIPT_DIR}/test.sh" 2>&1)"
RC=$?
contains 'a run that is not root is refused, naming the ruling' "${OUT}" \
    'lib test.sh commits through the fleet hook: run it as root (advisor ruling 2026-10-03)'
equals 'and the refusal exits' "RC=${RC}" 'RC=1'
absent 'and nothing past the check runs' "${OUT}" 'PAST THE ROOT CHECK'
OUT="$(LIB_TEST_ROOT_PROBE=1 bash "${SCRIPT_DIR}/test.sh" 2>&1)"
RC=$?
equals 'a leaked probe variable can never pass a gate' "RC=${RC}" 'RC=3'

fixture hook-canary
CANARY_BEFORE="$(clean_lines)"
printf 'canary\n' >"${ROOT}/app/canary.txt"
git_at add app/canary.txt
git_at commit -q -m canary
grew 'a clean fixture commit reaches the real checker as root' "${CANARY_BEFORE}" "$(clean_lines)"

PLANTED="ghp_$(tr -dc A-Za-z0-9 </dev/urandom | head -c36)"
printf 'token = "%s"\n' "${PLANTED}" >"${ROOT}/app/planted.txt"
git_at add app/planted.txt
CANARY_HEAD="$(git_at rev-parse HEAD)"
OUT="$(git_at commit -q -m planted 2>&1)"
RC=$?
contains 'a planted token is refused by the hook' "${OUT}" 'BLOCKED by secrets guard (gitleaks)'
absent 'and the refusal is a non-zero exit' "RC=${RC}" 'RC=0'
equals 'and no commit is made' "$(git_at rev-parse HEAD)" "${CANARY_HEAD}"
case "${OUT}" in
    *"${PLANTED}"*) fail 'the hook printed the token it caught (S2)' ;;
    *) pass 'and the hook never prints the token it caught' ;;
esac

# --- 1. the vendoring header on every lib file --------------------------------
VERSION_DECLARED="$(head -1 "${LIB_DIR}/VERSION")"
matches 'VERSION is a date, with an optional same-day serial' "${VERSION_DECLARED}" '^[0-9]{4}-[0-9]{2}-[0-9]{2}(\.[0-9]+)?$'
EMPTY_SET="$(printf '' | sha256sum | cut -d' ' -f1)"
for f in summary resolve ledger preflight cleanup compose literal; do
    line1="$(head -1 "${LIB_DIR}/${f}.sh")"
    body="$(tail -n +2 "${LIB_DIR}/${f}.sh" | sha256sum | cut -d' ' -f1)"
    equals "${f}.sh header" "${line1}" "# fleet-deploy-lib ${VERSION_DECLARED} sha256:${body}"
done

# --- 1b. -R: the fake rejects a missing repo; REPO comes from FLEET_DEPLOY_REPO alone, never
#            from origin; FLEET_DEPLOY_MERGE_SHA must be gh's merge commit (backlog 317) ---
fixture fake-gh-strict
run_lib 'out=$("$GH" pr view 73 --json state 2>&1); rc=$?; printf "RC=%s MSG=%s\n" "$rc" "$out" >&3'
contains 'the fake gh itself rejects a call with no -R' "${OUT}" \
    'RC=1 MSG=gh: no repository resolved (use -R owner/repo)'

fixture repo-from-env
run_lib 'resolve'
contains 'resolve passes FLEET_DEPLOY_REPO to gh as -R' "$(cat "${ARGVFILE}")" '-R gcotcheza/fixture'
contains 'and resolves' "${OUT}" \
    "RESOLVED #73 head ${HEAD_SHA:0:7} merge ${MERGE_SHA:0:7} is origin/main, trees identical"

fixture repo-unset
git_at config remote.origin.url 'git@github.com:gcotcheza/fixture.git'
REPO_OVERRIDE='NONE'
run_lib 'resolve'
contains 'with FLEET_DEPLOY_REPO unset it refuses, though origin names a GitHub repository' "${OUT}" \
    "REFUSED: FLEET_DEPLOY_REPO is unset: root names the repository, never the checkout's origin. Deploy with: fleet-deploy <app> <PR#>"
absent 'and gh is never called' "$(cat "${ARGVFILE}" 2>/dev/null)" 'pr view'
absent 'resolve.sh never reads the origin URL' "$(cat "${LIB_DIR}/resolve.sh")" 'get-url'

fixture repo-malformed
REPO_OVERRIDE='gcotcheza/a/b'
run_lib 'resolve'
contains 'a FLEET_DEPLOY_REPO that is not owner/repo is refused' "${OUT}" \
    "REFUSED: FLEET_DEPLOY_REPO 'gcotcheza/a/b' is not owner/repo."
absent 'and gh is never called with it' "$(cat "${ARGVFILE}" 2>/dev/null)" 'pr view'

fixture merge-sha-matches
MERGE_SHA_ENV="${MERGE_SHA}"
run_lib 'resolve'
contains 'FLEET_DEPLOY_MERGE_SHA equal to gh'"'"'s merge commit resolves' "${OUT}" \
    "RESOLVED #73 head ${HEAD_SHA:0:7} merge ${MERGE_SHA:0:7} is origin/main, trees identical"

fixture merge-sha-differs
MERGE_SHA_ENV="${HEAD_SHA}"
run_lib 'resolve'
contains 'FLEET_DEPLOY_MERGE_SHA other than gh'"'"'s merge commit is refused' "${OUT}" \
    "REFUSED: gh names merge commit ${MERGE_SHA} for PR #73, not ${HEAD_SHA}, the one fleet-deploy exported scripts/ at."
absent 'and nothing resolves' "${OUT}" 'RESOLVED #73'

# --- 1c. the self-location guard: root runs no copy anyone else can write (backlog 317) ---
# relib <dir>: a copy of the libs and the driver in <dir>, made by root.
relib() { mkdir -p "$1"; cp -p "${CASE}/lib/"*.sh "$1/"; }

fixture src-root-700
relib "${CASE}/r700/lib"; chmod 700 "${CASE}/r700" "${CASE}/r700/lib"
DRIVER_DIR="${CASE}/r700/lib"
run_lib 'say "RAN FROM ROOT 700"'
contains 'a copy in a root 700 directory runs' "${OUT}" 'RAN FROM ROOT 700'

fixture src-app-owned
relib "${CASE}/app/lib"; chown -R nobody "${CASE}/app"
DRIVER_DIR="${CASE}/app/lib"
run_lib 'say "RAN FROM APP DIR"'
contains 'a copy the app user owns is refused' "${OUT}" \
    "REFUSED: ${CASE}/app/lib/driver.sh is not owned by root, so root does not run it. Deploy with: fleet-deploy <app> <PR#>"
absent 'before anything past the libs runs' "${OUT}" 'LIBS SOURCED'
equals 'and exits 1' "${RC}" '1'

fixture src-old-command
mkdir -p "${ROOT}/scripts"; relib "${ROOT}/scripts/lib"; chown -R nobody "${ROOT}"
DRIVER_DIR="${ROOT}/scripts/lib"
run_lib 'say "OLD COMMAND RAN"'
contains 'the old command, the tree'"'"'s own deploy.sh run by root, is refused' "${OUT}" \
    "REFUSED: ${ROOT}/scripts/lib/driver.sh is not owned by root, so root does not run it. Deploy with: fleet-deploy <app> <PR#>"
absent 'and nothing of it runs' "${OUT}" 'OLD COMMAND RAN'

fixture src-lib-app-owned
relib "${CASE}/mixed/lib"; chown nobody "${CASE}/mixed/lib/summary.sh"
DRIVER_DIR="${CASE}/mixed/lib"
run_lib 'say "RAN WITH APP LIB"'
contains 'a root deploy.sh beside a summary.sh the app user owns is refused' "${OUT}" \
    "REFUSED: ${CASE}/mixed/lib/summary.sh is not owned by root"
absent 'and nothing past the libs runs' "${OUT}" 'LIBS SOURCED'

fixture src-group-writable
relib "${CASE}/gw/lib"; chmod 775 "${CASE}/gw"
DRIVER_DIR="${CASE}/gw/lib"
run_lib 'say "RAN FROM GROUP DIR"'
contains 'a copy under a group-writable directory is refused' "${OUT}" \
    "REFUSED: ${CASE}/gw is writable by group or others, so root does not run it. Deploy with: fleet-deploy <app> <PR#>"
absent 'before anything past the libs runs' "${OUT}" 'LIBS SOURCED'

fixture src-symlink
relib "${CASE}/sl/lib"; rm "${CASE}/sl/lib/driver.sh"; ln -s "${CASE}/lib/driver.sh" "${CASE}/sl/lib/driver.sh"
DRIVER_DIR="${CASE}/sl/lib"
run_lib 'say "RAN THROUGH A LINK"'
contains 'a deploy.sh that is a symlink is refused, even to a root file' "${OUT}" \
    "REFUSED: ${CASE}/sl/lib/driver.sh is a symlink, so root does not run it. Deploy with: fleet-deploy <app> <PR#>"

fixture src-inside-root
mkdir -p "${ROOT}/scripts"; relib "${ROOT}/scripts/lib"
DRIVER_DIR="${ROOT}/scripts/lib"
run_lib 'say "RAN INSIDE ROOT"'
contains 'a root-owned copy inside ROOT is refused when ROOT is known' "${OUT}" \
    "REFUSED: ${ROOT}/scripts/lib is at or inside ROOT ${ROOT}, so root does not run it. Deploy with: fleet-deploy <app> <PR#>"
absent 'and nothing after deploy_log_open runs' "${OUT}" 'RAN INSIDE ROOT'

# --- 2. resolve ----------------------------------------------------------------
fixture resolved
run_lib 'resolve'
contains 'a merged PR whose merge is the tip resolves' "${OUT}" \
    "RESOLVED #73 head ${HEAD_SHA:0:7} merge ${MERGE_SHA:0:7} is origin/main, trees identical"
contains 'the gh json goes to the log, not the summary' "$(cat "${LOGFILE}")" '"state":"MERGED"'
absent 'the gh json is not a summary line' "${OUT}" '"state":"MERGED"'

fixture not-merged
sed -i 's/"MERGED"/"OPEN"/' "${CASE}/gh.json"
run_lib 'resolve'
contains 'an unmerged PR is refused' "${OUT}" \
    "REFUSED: PR #73 is OPEN, not MERGED. Only a merged pull request deploys."

fixture gh-unreadable
GH_FAIL=1
run_lib 'resolve'
contains 'a gh that cannot read the PR is refused' "${OUT}" 'REFUSED: gh could not read PR #73.'

fixture no-shas
printf '{"headRefOid":"","mergeCommit":{"oid":""},"state":"MERGED"}\n' >"${CASE}/gh.json"
run_lib 'resolve'
contains 'a PR with no head and no merge commit is refused' "${OUT}" \
    'REFUSED: PR #73 names no head commit and no merge commit.'

# 2026-09-27: an unreadable commit makes `git diff` exit 128, and the else branch read
# that as "the trees differ" — gating a merge commit git cannot read.
fixture head-unreadable
printf '{"headRefOid":"%s","mergeCommit":{"oid":"%s"},"state":"MERGED"}\n' \
    "${MISSING_SHA}" "${MERGE_SHA}" >"${CASE}/gh.json"
run_lib 'resolve'
contains 'a head commit git cannot read is refused' "${OUT}" \
    "REFUSED: git cannot read PR #73's head commit ${MISSING_SHA}: run 'git fetch origin refs/pull/73/head', then deploy."
absent 'and is never read as a tree of its own' "${OUT}" \
    'so the merge commit itself is what must be gated'

fixture merge-unreadable
printf '{"headRefOid":"%s","mergeCommit":{"oid":"%s"},"state":"MERGED"}\n' \
    "${HEAD_SHA}" "${MISSING_SHA}" >"${CASE}/gh.json"
run_lib 'resolve'
contains 'a merge commit git cannot read is refused' "${OUT}" \
    "REFUSED: git cannot read PR #73's merge commit ${MISSING_SHA}: run 'git fetch origin ${MISSING_SHA}', then deploy."
absent 'and nothing resolves on the strength of it' "${OUT}" 'RESOLVED #73'

# Both commits readable and the tree they share is not: `git diff` exits 128 there too, and
# 128 is an answer to neither question the two branches below it ask.
fixture tree-unreadable
TREE="$(git_at rev-parse "${HEAD_SHA}^{tree}")"
rm -f "${ROOT}/.git/objects/${TREE:0:2}/${TREE:2}"
run_lib 'resolve'
contains 'a diff that exits neither 0 nor 1 is refused, never read as a difference' "${OUT}" \
    "REFUSED: the tree comparison of head ${HEAD_SHA} and merge ${MERGE_SHA} exited 128, which says neither same tree nor different: a deploy does not guess which commit it gates."
absent 'and no commit is gated on the strength of it' "${OUT}" 'RESOLVED #73'

fixture main-moved
git_at checkout -q -b later "${MERGE_SHA}"
git_at commit -q --allow-empty -m later
git_at push -q origin later:main
git_at checkout -q main
run_lib 'resolve'
contains 'a merge behind the tip is refused' "${OUT}" 'REFUSED: main moved since the merge: re-gate.'

fixture trees-differ trees-differ
run_lib 'resolve'
contains 'a merge tree that is not the head tree names the merge as the commit to gate' "${OUT}" \
    "RESOLVED #73 merge ${MERGE_SHA:0:7} is origin/main and its tree is not head ${HEAD_SHA:0:7}'s, so the merge commit itself is what must be gated"
absent 'and it is no longer refused for having a tree of its own' "${OUT}" \
    'merge tree differs from the gated head'

# --- 3. gated -------------------------------------------------------------------
fixture gated-ledger
run_lib 'resolve; gated; printf "GATED_IS %s\n" "$GATED" >&3'
contains 'a head green twice in the ledger is gated' "${OUT}" \
    "GATED ${HEAD_SHA:0:7} ci and e2e both green in ${LEDGER}"
contains 'and it says so in GATED' "${OUT}" "GATED_IS ledger head ${HEAD_SHA:0:7}"

# An ordinary merge commit has a tree of its own, and that tree is what deploys, so it is
# the commit the ledger must hold; the branch head's greens say nothing about it.
fixture trees-differ-ungated trees-differ
run_lib 'resolve; gated'
contains 'a green head does not gate a merge the ledger never saw' "${OUT}" \
    "$(no_green ci "${MERGE_SHA}" 'ci absent, e2e absent, e2e github: off (no config)')"

fixture trees-differ-gated trees-differ
printf '%s ci 2026-09-19T07:00:00Z 0 -\n%s e2e 2026-09-19T07:30:00Z 0 -\n' \
    "${MERGE_SHA}" "${MERGE_SHA}" >"${LEDGER}"
run_lib 'resolve; gated; printf "GATED_IS %s\n" "$GATED" >&3'
contains 'a merge commit green twice in the ledger is gated on the merge' "${OUT}" \
    "GATED ${MERGE_SHA:0:7} ci and e2e both green in ${LEDGER}"
contains 'and DONE says the merge was the commit that was gated' "${OUT}" \
    "GATED_IS ledger merge ${MERGE_SHA:0:7}"

# A caller that vendors this ledger.sh without the matching resolve.sh, or one that never
# reaches resolve, leaves GATE_SHA unset: under set -u that degrades to the head, never dies.
fixture gate-sha-unset
run_lib "HEAD_SHA=${HEAD_SHA}; "'gated; printf "GATED_IS %s\n" "$GATED" >&3'
contains 'a caller that never sets GATE_SHA falls back to the head instead of dying' "${OUT}" \
    "GATED ${HEAD_SHA:0:7} ci and e2e both green in ${LEDGER}"
contains 'and the fallback records itself as the head' "${OUT}" \
    "GATED_IS ledger head ${HEAD_SHA:0:7}"

# Set but empty is not the same as unset: a caller that initialises GATE_SHA='' for set -u
# and then skips or abandons resolve must be refused, never gated on the branch head.
fixture gate-sha-empty
run_lib "HEAD_SHA=${HEAD_SHA}; "'GATE_SHA=""; gated'
contains 'a set-but-empty GATE_SHA is refused, not quietly gated as the head' "${OUT}" \
    'REFUSED: GATE_SHA is set but empty: resolve did not finish, and gated cannot guess what deploys.'
absent 'and nothing is gated on the strength of it' "${OUT}" 'GATED'

fixture no-ledger
rm -f "${LEDGER}"
run_lib 'resolve; gated'
contains 'a missing ledger is refused' "${OUT}" \
    "REFUSED: no gate ledger at ${LEDGER}, so no head was ever gated on this box."

fixture head-absent
: >"${LEDGER}"
run_lib 'resolve; gated'
contains 'a head absent from the ledger is refused' "${OUT}" \
    "$(no_green ci "${HEAD_SHA}" 'ci absent, e2e absent, e2e github: off (no config)')"

fixture ledger-red
printf '%s ci 2026-09-18T20:00:00Z 1 -\n%s e2e 2026-09-18T20:30:00Z 0 -\n' \
    "${HEAD_SHA}" "${HEAD_SHA}" >"${LEDGER}"
run_lib 'resolve; gated'
contains 'a ci that exited non-zero is not a gate' "${OUT}" 'the ledger holds no green ci for'

fixture ci-only
printf '%s ci 2026-09-18T20:00:00Z 0 -\n' "${HEAD_SHA}" >"${LEDGER}"
run_lib 'resolve; gated'
contains 'ci without e2e is refused' "${OUT}" \
    "$(no_green e2e "${HEAD_SHA}" 'ci green, e2e absent, e2e github: off (no config)')"

fixture dirty-sha
printf '%s-dirty ci 2026-09-18T20:00:00Z 0 -\n%s-dirty e2e 2026-09-18T20:30:00Z 0 -\n' \
    "${HEAD_SHA}" "${HEAD_SHA}" >"${LEDGER}"
run_lib 'resolve; gated'
contains 'a -dirty sha never matches a deploy' "${OUT}" 'the ledger holds no green ci for'

fixture by-hand
rm -f "${LEDGER}"
BY_HAND=1
run_lib 'set -e; resolve; gated; printf "GATED_IS %s\n" "$GATED" >&3'
contains '--gated-by-hand says so out loud' "${OUT}" \
    "GATED BY HAND: #73 deploys on a human's word over the verdict above — transition and rescue only."
contains 'and by hand names the verdict it overrode, not an unread ledger' "${OUT}" \
    "GATE NOT GREEN head ${HEAD_SHA:0:7}: no gate ledger at ${LEDGER}"
contains 'and that verdict is what DONE will record' "${OUT}" \
    "GATED_IS by hand over [NOT GREEN head ${HEAD_SHA:0:7}: no gate ledger at ${LEDGER}]"
absent 'and a ledger that is not there is still not a refusal by hand' "${OUT}" 'REFUSED'

# By hand is the rescue path, so it never refuses — but it reads the rows first and
# prints the verdict it is overriding, per kind, so DONE records what was overridden.
fixture by-hand-over-red
printf '%s ci 2026-09-30T20:00:00Z 1 -\n%s e2e 2026-09-30T20:30:00Z 0 -\n' \
    "${HEAD_SHA}" "${HEAD_SHA}" >"${LEDGER}"
BY_HAND=1
run_lib 'set -e; resolve; gated; printf "GATED_IS %s\n" "$GATED" >&3'
contains 'by hand over a red ci row prints the row it overrides' "${OUT}" \
    "GATE NOT GREEN head ${HEAD_SHA:0:7}: ci red, e2e green"
contains 'and DONE carries the verdict by hand overrode' "${OUT}" \
    "GATED_IS by hand over [NOT GREEN head ${HEAD_SHA:0:7}: ci red, e2e green]"
absent 'and a red row is not a refusal by hand either' "${OUT}" 'REFUSED'

fixture by-hand-over-absent
: >"${LEDGER}"
BY_HAND=1
run_lib 'set -e; resolve; gated'
contains 'by hand over a head no gate ever judged says absent, per kind' "${OUT}" \
    "GATE NOT GREEN head ${HEAD_SHA:0:7}: ci absent, e2e absent"

fixture by-hand-over-merge trees-differ
BY_HAND=1
run_lib 'set -e; resolve; gated'
contains 'by hand over an ungated merge names the merge, not the head' "${OUT}" \
    "GATE NOT GREEN merge ${MERGE_SHA:0:7}: ci absent, e2e absent"

fixture by-hand-over-green
BY_HAND=1
run_lib 'set -e; resolve; gated; printf "GATED_IS %s\n" "$GATED" >&3'
contains 'by hand over a green ledger records the green verdict it did not override' "${OUT}" \
    "GATED_IS by hand over [GREEN head ${HEAD_SHA:0:7}: ci green, e2e green]"
contains 'and the flag is told it was not needed' "${OUT}" \
    'GATE BY HAND: --gated-by-hand was passed and the verdict above is green anyway.'

# The one lookup on a path that never used to read the ledger: a reader that cannot read a
# row says so, and under the set -e every caller runs it does not take the deploy with it.
fixture by-hand-unreadable-row
mkdir -p "${CASE}/shim"
printf '#!/bin/sh\nexit 2\n' >"${CASE}/shim/awk"
chmod 0755 "${CASE}/shim/awk"
BY_HAND=1
run_lib "set -e; resolve; PATH=${CASE}/shim:\$PATH; "'gated; printf "GATED_IS %s\n" "$GATED" >&3'
contains 'a row the reader cannot read is unreadable, never green' "${OUT}" \
    "GATE NOT GREEN head ${HEAD_SHA:0:7}: ci unreadable, e2e unreadable"
contains 'and the line after gated still runs' "${OUT}" \
    "GATED_IS by hand over [NOT GREEN head ${HEAD_SHA:0:7}: ci unreadable, e2e unreadable, e2e github: off (no config)]"

# The refusal has to be followable by every caller: a commit already in main cannot be
# gated where it stands by a gate that scans origin/main..HEAD.
fixture refusal-names-the-routes
: >"${LEDGER}"
run_lib 'resolve; gated'
contains 'the refusal names the kind that is missing and what both rows say' "${OUT}" \
    "REFUSED: the ledger holds no green ci for ${HEAD_SHA:0:7} (ci absent, e2e absent, e2e github: off (no config)):"
contains 'and gating the commit before the merge' "${OUT}" 'a commit is gated before it is merged'
contains 'and the gate-documented route for a commit already in main' "${OUT}" \
    'once it is in main only a route the gate documents for that (a base override, where it has one) can gate it'
contains 'and --gated-by-hand as the stated-ungated route' "${OUT}" \
    '--gated-by-hand, which records this as ungated.'
absent 'and never asks for a head already in main to be gated where it stands' "${OUT}" \
    'then deploy.'

fixture ledger-green-then-red
printf '%s ci 2026-09-18T20:00:00Z 0 -\n%s ci 2026-09-18T22:00:00Z 1 -\n%s e2e 2026-09-18T20:30:00Z 0 -\n' \
    "${HEAD_SHA}" "${HEAD_SHA}" "${HEAD_SHA}" >"${LEDGER}"
run_lib 'resolve; gated'
contains 'a later red overrides an earlier green' "${OUT}" \
    "$(no_green ci "${HEAD_SHA}" 'ci red, e2e green')"

fixture ledger-red-then-green
printf '%s ci 2026-09-18T20:00:00Z 1 -\n%s ci 2026-09-18T22:00:00Z 0 -\n%s e2e 2026-09-18T20:30:00Z 0 -\n' \
    "${HEAD_SHA}" "${HEAD_SHA}" "${HEAD_SHA}" >"${LEDGER}"
run_lib 'resolve; gated'
contains 'a later green overrides an earlier red, which is a genuine re-run' "${OUT}" \
    "GATED ${HEAD_SHA:0:7} ci and e2e both green in ${LEDGER}"

# "Newest wins" is append order, not the timestamp column: the second line here
# carries the EARLIER clock time but is appended after the first, and it alone decides.
fixture ledger-append-order-not-timestamp
printf '%s ci 2026-09-19T22:00:00Z 0 -\n%s ci 2026-09-18T20:00:00Z 1 -\n%s e2e 2026-09-18T20:30:00Z 0 -\n' \
    "${HEAD_SHA}" "${HEAD_SHA}" "${HEAD_SHA}" >"${LEDGER}"
run_lib 'resolve; gated'
contains 'the later-appended line decides even though its own timestamp is earlier' "${OUT}" \
    "$(no_green ci "${HEAD_SHA}" 'ci red, e2e green')"

# 2026-09-19: a killed e2e recorded rc 0 over a head that was already green, and the
# reader took any green. Both halves of that are proved here, together.
fixture killed-run-regression
printf '%s ci 2026-09-19T05:00:00Z 0 -\n%s e2e 2026-09-19T05:30:00Z 0 -\n' \
    "${LIVE_SHA}" "${LIVE_SHA}" >"${LEDGER}"
run_lib "$(armed "GATE_LEDGER=${LEDGER} gate_ledger_record e2e 0 - >&3 2>&3; HEAD_SHA=${LIVE_SHA}; gated")"
contains 'the killed run is recorded as a failure' "${OUT}" \
    'gate-ledger: rc 0 without GATE_SUITE_PASSED — the run did not finish; recorded as a failure'
contains 'and the head it was green on before is no longer gated' "${OUT}" \
    "$(no_green e2e "${LIVE_SHA}" 'ci green, e2e red, e2e github: off (no config)')"

# --- 3a. GitHub e2e: root's config and token, and a fake gh serving saved check-run and run JSON ---
# The shapes are ghie-writes run 37240193529's (read-only gh api, 2026-10-05), trimmed to what is read.
GHE_REPO=gcotcheza/fixture
ghe_check() { # id suite sha app-id status conclusion|null completed_at|null name
    local concl=null at=null
    [ "$6" = null ] || concl="\"$6\""
    [ "$7" = null ] || at="\"$7\""
    printf '{"id":%s,"name":"%s","head_sha":"%s","status":"%s","conclusion":%s,"started_at":"2026-10-04T22:29:18Z","completed_at":%s,"html_url":"https://github.com/%s/actions/runs/1/job/%s","app":{"id":%s,"slug":"github-actions","name":"GitHub Actions"},"check_suite":{"id":%s}}' \
        "$1" "$8" "$3" "$5" "${concl}" "${at}" "${GHE_REPO}" "$1" "$4" "$2"
}
ghe_checks() { # check run objects; GHE_TOTAL overrides the count the page claims
    local IFS=,
    printf '{"total_count":%s,"check_runs":[%s]}\n' "${GHE_TOTAL:-$#}" "$*" >"${CASE}/ghe-fake/checks.json"
    GHE_TOTAL=''
}
ghe_run_json() { # run event path repo head-repo suite
    printf '{"id":%s,"name":"ci","event":"%s","status":"completed","conclusion":"success","head_sha":"%s","path":"%s","check_suite_id":%s,"html_url":"https://github.com/%s/actions/runs/%s","repository":{"full_name":"%s"},"head_repository":{"full_name":"%s"}}' \
        "$1" "$2" "${HEAD_SHA}" "$3" "$6" "$4" "$1" "$4" "$5"
}
ghe_run() { # suite run event path repo head-repo [check_suite_id in the body]
    printf '{"total_count":1,"workflow_runs":[%s]}\n' "$(ghe_run_json "$2" "$3" "$4" "$5" "$6" "${7:-$1}")" >"${CASE}/ghe-fake/runs-$1.json"
}
# Root's config and token for the fixture's app (ROOT's basename, "root"), owned by the seam's root
# uid, the ledger's ci green on $1 and e2e absent, and one green push run of the pinned workflow.
ghe_fixture() {
    mkdir -p "${CASE}/ghe" "${CASE}/ghe-fake"
    printf '%s ci 2026-10-04T20:00:00Z 0 -\n' "$1" >"${LEDGER}"
    GHE_TOKEN="ghp_$(tr -dc A-Za-z0-9 </dev/urandom | head -c36)"
    printf '%s\n' "${GHE_TOKEN}" >"${CASE}/ghe/token"
    printf '%s\n' "${GHE_TOKEN}" >"${CASE}/ghe-fake/token.expected"
    printf 'R=%s\nN=e2e\nW=.github/workflows/ci.yml\nW_SHA256=%s\n' "${GHE_REPO}" "${GHE_WSUM}" >"${CASE}/ghe/root"
    chown 61234 "${CASE}/ghe" "${CASE}/ghe/root" "${CASE}/ghe/token"
    chmod 0755 "${CASE}/ghe"
    chmod 0644 "${CASE}/ghe/root"
    chmod 0600 "${CASE}/ghe/token"
    ghe_checks "$(ghe_check 900 700 "$1" 15368 completed success 2026-10-04T22:33:11Z e2e)"
    ghe_run 700 800 push .github/workflows/ci.yml "${GHE_REPO}" "${GHE_REPO}"
}
ghe_gated() { run_lib 'resolve; gated; printf "GATED_IS %s\n" "$GATED" >&3'; }
ghe_refused() { # test name, the e2e github item gated must print
    contains "$1" "${OUT}" "$(no_green e2e "${HEAD_SHA}" "ci green, e2e absent, $2")"
    absent 'and nothing is gated on GitHub' "${OUT}" 'GATED_IS ledger ci + github'
}
ghe_none() { ghe_refused "$1" "e2e github: none for ${HEAD_SHA:0:7}"; }
ghe_api_calls() { grep -c '^api ' "${ARGVFILE}" 2>/dev/null; }

fixture ghe-green
ghe_fixture "${HEAD_SHA}"
ghe_gated
contains 'a green push run of the pinned workflow on the gated sha turns e2e green' "${OUT}" \
    "GATED ${HEAD_SHA:0:7} ci green in ${LEDGER}, e2e github:green run 800: https://github.com/${GHE_REPO}/actions/runs/800 completed 2026-10-04T22:33:11Z"
contains 'and GATED names the source, the run, the workflow, the check and the sha' "${OUT}" \
    "GATED_IS ledger ci + github e2e ${GHE_REPO} run 800 (.github/workflows/ci.yml, e2e) on ${HEAD_SHA:0:7}"
absent 'and nothing is refused' "${OUT}" 'REFUSED'
contains 'the check runs are asked for by sha and check name, every page entry' "$(cat "${ARGVFILE}")" \
    "api -X GET repos/${GHE_REPO}/commits/${HEAD_SHA}/check-runs -f check_name=e2e -f filter=all -f per_page=100"
contains 'and the workflow run by its check suite' "$(cat "${ARGVFILE}")" \
    "api -X GET repos/${GHE_REPO}/actions/runs -f check_suite_id=700"
equals 'gh got root'"'"'s token through GH_TOKEN on both calls' "$(grep -c token-matches "${CASE}/ghe-fake/token.seen" 2>/dev/null)" 2
absent 'and the token is in no output (S2)' "${OUT}" "${GHE_TOKEN}"
absent 'nor in the deploy log' "$(cat "${LOGFILE}")" "${GHE_TOKEN}"
absent 'nor on any gh argv' "$(cat "${ARGVFILE}")" "${GHE_TOKEN}"
equals 'and the route never writes the box ledger' "$(rows "${LEDGER}")" 1

fixture ghe-ledger-red
ghe_fixture "${HEAD_SHA}"
printf '%s e2e 2026-10-04T21:00:00Z 1 -\n' "${HEAD_SHA}" >>"${LEDGER}"
ghe_gated
contains 'a red e2e row is also answered by a green run on GitHub' "${OUT}" \
    "GATED_IS ledger ci + github e2e ${GHE_REPO} run 800 (.github/workflows/ci.yml, e2e) on ${HEAD_SHA:0:7}"

fixture ghe-ledger-green
ghe_fixture "${HEAD_SHA}"
printf '%s e2e 2026-10-04T21:00:00Z 0 -\n' "${HEAD_SHA}" >>"${LEDGER}"
ghe_gated
contains 'a green e2e row never asks GitHub' "${OUT}" "GATED_IS ledger head ${HEAD_SHA:0:7}"
equals 'and gh api is not called' "$(ghe_api_calls)" 0

fixture ghe-ci-never
ghe_fixture "${HEAD_SHA}"
printf '%s e2e 2026-10-04T21:00:00Z 0 -\n' "${HEAD_SHA}" >"${LEDGER}"
ghe_gated
contains 'ci never comes from GitHub, even with a green run there' "${OUT}" \
    "$(no_green ci "${HEAD_SHA}" 'ci absent, e2e green')"
equals 'and gh api is not called for it' "$(ghe_api_calls)" 0

fixture ghe-merge trees-differ
ghe_fixture "${MERGE_SHA}"
ghe_gated
contains 'when the trees differ the merge is asked for, the sha gated reads' "$(cat "${ARGVFILE}")" \
    "repos/${GHE_REPO}/commits/${MERGE_SHA}/check-runs"
contains 'and GATED names the merge' "${OUT}" \
    "GATED_IS ledger ci + github e2e ${GHE_REPO} run 800 (.github/workflows/ci.yml, e2e) on ${MERGE_SHA:0:7}"

fixture ghe-by-hand
ghe_fixture "${HEAD_SHA}"
BY_HAND=1
ghe_gated
contains '--gated-by-hand over a GitHub green still records by hand' "${OUT}" \
    "GATED_IS by hand over [GREEN head ${HEAD_SHA:0:7}: ci green, e2e absent, e2e github:green run 800]"

fixture ghe-token-path
ghe_fixture "${HEAD_SHA}"
mkdir -p "${CASE}/elsewhere"
mv "${CASE}/ghe/token" "${CASE}/elsewhere/token"
GHE_TOKEN_PATH="${CASE}/elsewhere/token"
ghe_gated
contains 'DEPLOY_GITHUB_E2E_TOKEN moves the token file' "${OUT}" 'GATED_IS ledger ci + github e2e'

fixture ghe-no-config
ghe_fixture "${HEAD_SHA}"
rm -f "${CASE}/ghe/root"
ghe_gated
ghe_refused 'no config for the app is the route off' 'e2e github: off (no config)'
absent 'and says nothing more' "${OUT}" 'GITHUB E2E'
equals 'and gh api is not called' "$(ghe_api_calls)" 0

fixture ghe-no-token
ghe_fixture "${HEAD_SHA}"
rm -f "${CASE}/ghe/token"
ghe_gated
ghe_refused 'no token is the route off: ledger only, never green' 'e2e github: off (no token)'
absent 'and says nothing more' "${OUT}" 'GITHUB E2E'
equals 'and gh api is not called' "$(ghe_api_calls)" 0

fixture ghe-token-mode
ghe_fixture "${HEAD_SHA}"
chmod 0644 "${CASE}/ghe/token"
ghe_gated
ghe_refused 'a token others can read is the route off' 'e2e github: off (no token)'
contains 'and says why' "${OUT}" "GITHUB E2E ${CASE}/ghe/token is not a non-empty root 600 file"

fixture ghe-config-owner
ghe_fixture "${HEAD_SHA}"
chown 0 "${CASE}/ghe/root"
ghe_gated
ghe_refused 'a config root does not own is the route off' 'e2e github: off (no config)'
contains 'and says why' "${OUT}" "GITHUB E2E ${CASE}/ghe/root is not a root-owned file in a directory only root can write"

fixture ghe-config-dir
ghe_fixture "${HEAD_SHA}"
chmod 0777 "${CASE}/ghe"
ghe_gated
ghe_refused 'a config in a directory others can write is the route off' 'e2e github: off (no config)'

fixture ghe-config-line
ghe_fixture "${HEAD_SHA}"
printf 'X=1\n' >>"${CASE}/ghe/root"
ghe_gated
ghe_refused 'a config line that is not R, N, W or W_SHA256 is the route off' 'e2e github: off (no config)'
contains 'and says why' "${OUT}" "GITHUB E2E ${CASE}/ghe/root has a line that is not R=, N=, W= or W_SHA256="

fixture ghe-config-value
ghe_fixture "${HEAD_SHA}"
sed -i 's/^W_SHA256=.*/W_SHA256=abc/' "${CASE}/ghe/root"
ghe_gated
ghe_refused 'a W_SHA256 that is not 64 hex is the route off' 'e2e github: off (no config)'
contains 'and says why' "${OUT}" "GITHUB E2E ${CASE}/ghe/root does not name R=<owner/repo>"

fixture ghe-no-workflow
ghe_fixture "${HEAD_SHA}"
sed -i 's|^W=.*|W=.github/workflows/missing.yml|' "${CASE}/ghe/root"
ghe_gated
ghe_none 'a workflow the gated sha does not carry is not green'
contains 'and says why' "${OUT}" "GITHUB E2E ${HEAD_SHA:0:7} has no .github/workflows/missing.yml"

fixture ghe-workflow-edited
ghe_fixture "${HEAD_SHA}"
sed -i "s/^W_SHA256=.*/W_SHA256=$(printf 'edited\n' | sha256sum | cut -d' ' -f1)/" "${CASE}/ghe/root"
ghe_gated
ghe_none 'a workflow whose content at the sha is not the pinned one is not green'
contains 'and says why' "${OUT}" "is not the workflow root pinned in W_SHA256"
equals 'and gh api is not called' "$(ghe_api_calls)" 0

fixture ghe-other-sha
ghe_fixture "${HEAD_SHA}"
ghe_checks "$(ghe_check 900 700 "${LIVE_SHA}" 15368 completed success 2026-10-04T22:33:11Z e2e)"
ghe_gated
ghe_none 'a green check run on another sha is not green'

fixture ghe-other-app
ghe_fixture "${HEAD_SHA}"
ghe_checks "$(ghe_check 900 700 "${HEAD_SHA}" 99999 completed success 2026-10-04T22:33:11Z e2e)"
ghe_gated
ghe_none 'a check run of the same name from another app is not green'

fixture ghe-other-name
ghe_fixture "${HEAD_SHA}"
ghe_checks "$(ghe_check 900 700 "${HEAD_SHA}" 15368 completed success 2026-10-04T22:33:11Z lint)"
ghe_gated
ghe_none 'a check run of another name is not green'

fixture ghe-other-workflow
ghe_fixture "${HEAD_SHA}"
ghe_run 700 800 push .github/workflows/other.yml "${GHE_REPO}" "${GHE_REPO}"
ghe_gated
ghe_none 'a run of the same check name from another workflow is not green'

fixture ghe-fork
ghe_fixture "${HEAD_SHA}"
ghe_run 700 800 push .github/workflows/ci.yml "${GHE_REPO}" someone/fixture
ghe_gated
ghe_none 'a run whose head repository is a fork is not green'

fixture ghe-other-repo
ghe_fixture "${HEAD_SHA}"
ghe_run 700 800 push .github/workflows/ci.yml someone/fixture "${GHE_REPO}"
ghe_gated
ghe_none 'a run of another repository is not green'

fixture ghe-pull-request
ghe_fixture "${HEAD_SHA}"
ghe_run 700 800 pull_request .github/workflows/ci.yml "${GHE_REPO}" "${GHE_REPO}"
ghe_gated
ghe_none 'a green pull_request run is not green: it tested the merge ref, not the sha'

fixture ghe-dispatch
ghe_fixture "${HEAD_SHA}"
ghe_run 700 800 workflow_dispatch .github/workflows/ci.yml "${GHE_REPO}" "${GHE_REPO}"
ghe_gated
contains 'a green workflow_dispatch run on the sha is green' "${OUT}" 'GATED_IS ledger ci + github e2e'

fixture ghe-suite-mismatch
ghe_fixture "${HEAD_SHA}"
ghe_run 700 800 push .github/workflows/ci.yml "${GHE_REPO}" "${GHE_REPO}" 999
ghe_gated
ghe_none 'a workflow run of another check suite is not green'

for ghe_c in neutral skipped; do
    fixture "ghe-${ghe_c}"
    ghe_fixture "${HEAD_SHA}"
    ghe_checks "$(ghe_check 900 700 "${HEAD_SHA}" 15368 completed "${ghe_c}" 2026-10-04T22:33:11Z e2e)"
    ghe_gated
    ghe_none "a ${ghe_c} run is not green"
    contains 'and says why' "${OUT}" "GITHUB E2E the newest e2e run on ${HEAD_SHA:0:7}, 800, is completed ${ghe_c}"
done

fixture ghe-in-progress
ghe_fixture "${HEAD_SHA}"
ghe_checks "$(ghe_check 901 701 "${HEAD_SHA}" 15368 in_progress null null e2e)" \
    "$(ghe_check 900 700 "${HEAD_SHA}" 15368 completed success 2026-10-04T22:33:11Z e2e)"
ghe_run 701 801 push .github/workflows/ci.yml "${GHE_REPO}" "${GHE_REPO}"
ghe_gated
ghe_none 'a run still in progress is newer than any finished one, and not green'

fixture ghe-newest-wins
ghe_fixture "${HEAD_SHA}"
ghe_checks "$(ghe_check 901 701 "${HEAD_SHA}" 15368 completed failure 2026-10-04T23:10:00Z e2e)" \
    "$(ghe_check 900 700 "${HEAD_SHA}" 15368 completed success 2026-10-04T22:33:11Z e2e)"
ghe_run 701 801 push .github/workflows/ci.yml "${GHE_REPO}" "${GHE_REPO}"
ghe_gated
ghe_none 'an older success under a newer failure is not green'
contains 'and says why' "${OUT}" "GITHUB E2E the newest e2e run on ${HEAD_SHA:0:7}, 801, is completed failure"

fixture ghe-newer-pull-request
ghe_fixture "${HEAD_SHA}"
ghe_checks "$(ghe_check 901 701 "${HEAD_SHA}" 15368 completed failure 2026-10-04T23:10:00Z e2e)" \
    "$(ghe_check 900 700 "${HEAD_SHA}" 15368 completed success 2026-10-04T22:33:11Z e2e)"
ghe_run 701 801 pull_request .github/workflows/ci.yml "${GHE_REPO}" "${GHE_REPO}"
ghe_gated
contains 'a newer pull_request run is not the sha'"'"'s run, so the push run decides' "${OUT}" \
    "GATED_IS ledger ci + github e2e ${GHE_REPO} run 800"

fixture ghe-none
ghe_fixture "${HEAD_SHA}"
ghe_checks
ghe_gated
ghe_none 'no check run at all is not green'
absent 'and says nothing more' "${OUT}" 'GITHUB E2E'

fixture ghe-blank-token
ghe_fixture "${HEAD_SHA}"
printf '\n' >"${CASE}/ghe/token"
ghe_gated
ghe_refused 'a token file holding only a newline never reaches gh, which would fall back to its own login' 'e2e github: unreadable'
equals 'and gh api is not called' "$(ghe_api_calls)" 0

fixture ghe-gh-fails
ghe_fixture "${HEAD_SHA}"
GHE_RC=1
ghe_gated
ghe_refused 'gh exiting 1 is unreadable even when it printed a green page' 'e2e github: unreadable'
contains 'and says why' "${OUT}" "GITHUB E2E gh or jq failed on the check runs of ${HEAD_SHA:0:7}, so it counts as not green"

fixture ghe-run-gh-fails
ghe_fixture "${HEAD_SHA}"
GHE_RUNS_RC=1
ghe_gated
ghe_refused 'gh exiting 1 on the workflow run is unreadable' 'e2e github: unreadable'
contains 'and says why' "${OUT}" 'GITHUB E2E gh or jq failed on the workflow run of check run 900'

fixture ghe-bad-json
ghe_fixture "${HEAD_SHA}"
printf 'rate limited\n' >"${CASE}/ghe-fake/checks.json"
ghe_gated
ghe_refused 'a page that is not JSON is unreadable' 'e2e github: unreadable'

fixture ghe-empty-body
ghe_fixture "${HEAD_SHA}"
: >"${CASE}/ghe-fake/checks.json"
ghe_gated
ghe_refused 'an empty answer is unreadable, not none' 'e2e github: unreadable'

fixture ghe-run-bad-json
ghe_fixture "${HEAD_SHA}"
printf '{"workflow_runs":' >"${CASE}/ghe-fake/runs-700.json"
ghe_gated
ghe_refused 'a workflow run that is not JSON is unreadable' 'e2e github: unreadable'

fixture ghe-partial-page
ghe_fixture "${HEAD_SHA}"
GHE_TOTAL=2
ghe_checks "$(ghe_check 900 700 "${HEAD_SHA}" 15368 completed success 2026-10-04T22:33:11Z e2e)"
ghe_gated
ghe_refused 'a page that holds fewer check runs than it counts is unreadable' 'e2e github: unreadable'

fixture ghe-two-runs
ghe_fixture "${HEAD_SHA}"
printf '{"total_count":2,"workflow_runs":[%s,%s]}\n' \
    "$(ghe_run_json 800 push .github/workflows/ci.yml "${GHE_REPO}" "${GHE_REPO}" 700)" \
    "$(ghe_run_json 802 push .github/workflows/ci.yml "${GHE_REPO}" "${GHE_REPO}" 702)" \
    >"${CASE}/ghe-fake/runs-700.json"
ghe_gated
ghe_refused 'a check suite answered by two workflow runs is unreadable' 'e2e github: unreadable'

# --- 3b. test scope: docs-only owes no row, non-UI owes ci, anything else ci and e2e ------
# One template: bare (no declaration), live (declaration), and one branch per class off it.
NL=$'\n'
scope_template() {
    local ROOT="${WORK}/.template-scope"
    [ -d "${ROOT}" ] && return 0
    mkdir -p "${ROOT}/app"
    git init -q -b main "${ROOT}"
    scope_commit() {
        local name=$1 from=$2 f
        shift 2
        [ -z "${from}" ] || git_at checkout -q --detach "${from}"
        for f in "$@"; do
            mkdir -p "${ROOT}/$(dirname "${f%%=*}")"
            printf '%s\n' "${f#*=}" >"${ROOT}/${f%%=*}"
            git_at add "${f%%=*}"
        done
        git_at commit -q -m "${name}"
        git_at update-ref "refs/scope/${name}" HEAD
    }
    scope_commit bare '' 'app/base.txt=base'
    scope_commit live refs/scope/bare \
        ".fleet/test-scope=# fixture${NL}docs docs/${NL}docs *.md${NL}non-ui scripts/${NL}non-ui tests/  # gate-only"
    scope_commit docs refs/scope/live 'docs/guide.md=g' 'README.md=r'
    scope_commit nonui refs/scope/live 'scripts/deploy.sh=d' 'tests/x.sh=t'
    scope_commit lib refs/scope/live 'scripts/lib/deploy/ledger.sh=l'
    scope_commit ui refs/scope/live 'resources/css/x.css=c'
    scope_commit mixed refs/scope/live 'scripts/a.sh=a' 'app/x.php=x'
    scope_commit newdir refs/scope/live 'newdir/x.txt=n'
    scope_commit e2epath refs/scope/live 'e2e/specs/a.spec.js=e'
    scope_commit deepmd refs/scope/live 'resources/views/mail.md=m'
    scope_commit decl refs/scope/live ".fleet/test-scope=non-ui scripts/${NL}non-ui app/"
    scope_commit nodecl refs/scope/bare 'scripts/deploy.sh=d'
    scope_commit e2elive refs/scope/bare ".fleet/test-scope=non-ui scripts/${NL}non-ui e2e/"
    scope_commit e2edecl refs/scope/e2elive 'scripts/x.sh=x'
    git_at checkout -q --detach refs/scope/live
    mkdir -p "${ROOT}/docs"
    ln -s ../resources/x.css "${ROOT}/docs/x.css"
    git_at add docs/x.css
    git_at commit -q -m symlink
    git_at update-ref refs/scope/symlink HEAD
    # Over 64 KB of --raw output with the symlink line first: a reader that exits early
    # SIGPIPEs its writer, and under pipefail that once read as "no symlink".
    git_at checkout -q --detach refs/scope/live
    mkdir -p "${ROOT}/docs/bulk"
    ln -s ../../resources/x.css "${ROOT}/docs/bulk/0-link.css"
    for i in $(seq -w 1 900); do printf '%s\n' "${i}" >"${ROOT}/docs/bulk/zz-a-long-enough-name-to-fill-the-pipe-${i}.md"; done
    git_at add docs/bulk
    git_at commit -q -m bigsymlink
    git_at update-ref refs/scope/bigsymlink HEAD
    git_at checkout -q main
}

# scope_fixture <case> <checkout-at> <gated-commit>: GATE_SHA is the gated commit, the checkout is live.
scope_fixture() {
    CASE="${WORK}/$1"
    ROOT="${CASE}/root"
    BIN="${CASE}/bin"
    LEDGER="${CASE}/ledger"
    LOGS="${CASE}/logs"
    mkdir -p "${BIN}" "${LOGS}"
    : >"${LEDGER}"
    scope_template
    cp -a "${WORK}/.template-scope" "${ROOT}"
    git_at checkout -q --detach "refs/scope/$2"
    LIVE_SHORT="$(git_at rev-parse --short HEAD)"
    SCOPE_SHA="$(git_at rev-parse "refs/scope/$3")"
    write_fakes
    write_driver
}
scope_rows() { : >"${LEDGER}"; for k in "$@"; do printf '%s %s 2026-10-04T10:00:00Z 0 -\n' "${SCOPE_SHA}" "${k}" >>"${LEDGER}"; done; }
scope_gated() { run_lib "GATE_SHA=${SCOPE_SHA}; GATE_WHAT=head; "'gated; printf "GATED_IS %s\n" "$GATED" >&3'; }
RULE='per test-scope 2026-10-04'

scope_fixture scope-docs live docs
rm -f "${LEDGER}"
scope_gated
contains 'a docs-only diff is gated with no ledger at all' "${OUT}" \
    "GATED ${SCOPE_SHA:0:7} no gate row owed: docs-only diff (*.md, docs/) ${RULE}"
contains 'and DONE records that no row was owed' "${OUT}" "GATED_IS no row owed head ${SCOPE_SHA:0:7} (docs-only)"

scope_fixture scope-nonui live nonui
scope_rows ci
scope_gated
contains 'a non-UI diff with one green ci row is gated, naming the rule' "${OUT}" \
    "GATED ${SCOPE_SHA:0:7} ci green in ${LEDGER}; e2e not required: non-UI diff (scripts/, tests/) ${RULE}"
contains 'and the scope line says why' "${OUT}" "SCOPE non-ui: non-UI diff (scripts/, tests/) ${RULE}"
contains 'and DONE records ci alone' "${OUT}" "GATED_IS ledger head ${SCOPE_SHA:0:7} ci (non-UI)"

scope_fixture scope-nonui-no-ci live nonui
scope_rows e2e
scope_gated
contains 'a non-UI diff with no ci row is refused, whatever e2e says' "${OUT}" \
    "$(no_green ci "${SCOPE_SHA}" 'ci absent')"
absent 'and is not gated' "${OUT}" "GATED ${SCOPE_SHA:0:7}"

scope_fixture scope-lib live lib
scope_rows ci
scope_gated
contains 'a vendored lib under a declared scripts/ is non-UI' "${OUT}" "e2e not required: non-UI diff (scripts/)"

scope_fixture scope-ui-ci-only live ui
scope_rows ci
scope_gated
contains 'a UI diff without e2e is refused' "${OUT}" "$(no_green e2e "${SCOPE_SHA}" 'ci green, e2e absent, e2e github: off (no config)')"
contains 'and the scope line names the UI path' "${OUT}" "SCOPE ui: UI path: resources/css/x.css ${RULE}"

scope_fixture scope-ui-both live ui
scope_rows ci e2e
scope_gated
contains 'a UI diff with ci and e2e green is gated' "${OUT}" "GATED ${SCOPE_SHA:0:7} ci and e2e both green in ${LEDGER}"
contains 'and DONE records the ledger as before' "${OUT}" "GATED_IS ledger head ${SCOPE_SHA:0:7}"

scope_fixture scope-no-declaration bare nodecl
scope_rows ci
scope_gated
contains 'with no declaration a scripts-only diff owes e2e' "${OUT}" "$(no_green e2e "${SCOPE_SHA}" 'ci green, e2e absent, e2e github: off (no config)')"
contains 'and the scope line says there was no declaration' "${OUT}" \
    "SCOPE ui: ${SCOPE_SHA:0:7} declares no .fleet/test-scope, so every path is UI ${RULE}"

scope_fixture scope-new-dir live newdir
scope_rows ci
scope_gated
contains 'an undeclared new top-level path is UI' "${OUT}" "SCOPE ui: UI path: newdir/x.txt ${RULE}"
contains 'and owes e2e' "${OUT}" 'the ledger holds no green e2e for'

scope_fixture scope-mixed live mixed
scope_rows ci
scope_gated
contains 'a mixed diff is UI, naming the UI path' "${OUT}" "SCOPE ui: UI path: app/x.php ${RULE}"
contains 'and owes e2e' "${OUT}" 'the ledger holds no green e2e for'

scope_fixture scope-e2e-path live e2epath
scope_rows ci
scope_gated
contains 'an e2e/ path is UI' "${OUT}" "SCOPE ui: UI path: e2e/specs/a.spec.js ${RULE}"

scope_fixture scope-e2e-declared e2elive e2edecl
scope_rows ci
scope_gated
contains 'a declaration that lists e2e/ is refused, so a scripts-only diff is UI' "${OUT}" \
    "SCOPE ui: .fleet/test-scope line 2 declares e2e/, and e2e/ is always UI, so the declaration is refused and every path is UI ${RULE}"
contains 'and owes e2e' "${OUT}" 'the ledger holds no green e2e for'

scope_fixture scope-deep-md live deepmd
scope_rows ci
scope_gated
contains 'a root-level *.md entry does not reach a nested .md' "${OUT}" "SCOPE ui: UI path: resources/views/mail.md ${RULE}"

scope_fixture scope-declaration-change live decl
scope_rows ci
scope_gated
contains 'a change to the declaration is UI, even one that declares app/ non-UI' "${OUT}" \
    "SCOPE ui: UI path: .fleet/test-scope ${RULE}"

scope_fixture scope-symlink live symlink
scope_rows ci
scope_gated
contains 'a symlink in a declared docs directory makes the diff UI' "${OUT}" \
    "SCOPE ui: symlink or submodule: docs/x.css, so every path is UI ${RULE}"

scope_fixture scope-big-symlink live bigsymlink
scope_rows ci
RAW_BYTES="$(git_at diff --raw --no-abbrev --no-renames HEAD "${SCOPE_SHA}" | wc -c)"
if [ "${RAW_BYTES}" -gt 65536 ]; then pass "the raw diff is over a pipe buffer (${RAW_BYTES} bytes)"
else fail "the raw diff is only ${RAW_BYTES} bytes, so this case proves nothing about SIGPIPE"; fi
equals 'and its first line is the symlink' "$(git_at diff --raw --no-abbrev --no-renames HEAD "${SCOPE_SHA}" | awk 'NR == 1 { print $2 }')" '120000'
run_lib "set -o pipefail; GATE_SHA=${SCOPE_SHA}; GATE_WHAT=head; "'gated'
contains 'under pipefail, a symlink first in a 64 KB+ diff still makes it UI' "${OUT}" \
    "SCOPE ui: symlink or submodule: docs/bulk/0-link.css, so every path is UI ${RULE}"

scope_fixture scope-diff-fails live docs
rm -f "${LEDGER}"
run_lib "GATE_SHA=${MISSING_SHA}; GATE_WHAT=head; gated"
contains 'a diff git cannot produce is UI' "${OUT}" \
    "SCOPE ui: git could not list what ${MISSING_SHA:0:7} changes on "
contains 'and is refused, not gated' "${OUT}" "REFUSED: no gate ledger at ${LEDGER}"

scope_fixture scope-by-hand live nonui
BY_HAND=1
scope_gated
contains 'by hand over a non-UI diff names only the ci row it owed' "${OUT}" \
    "GATE NOT GREEN head ${SCOPE_SHA:0:7}: ci absent"
absent 'and refuses nothing' "${OUT}" 'REFUSED'

# The classifier on its own: declarations the fixtures do not carry.
scope_fixture scope-pure live docs
scope_classify() { run_lib "$(printf 'test_scope_classify %q <<<%q; printf "SCOPE=%%s WHY=%%s\\n" "$SCOPE" "$SCOPE_WHY" >&3' "$1" "$2")"; }
scope_classify 'non-ui .fleet/' '.fleet/test-scope'
contains 'the declaration file is UI even where its directory is declared' "${OUT}" 'SCOPE=ui WHY=UI path: .fleet/test-scope'
scope_classify 'docs e2e' 'scripts/a.sh'
contains 'an exact e2e entry refuses the declaration too' "${OUT}" 'line 1 declares e2e, and e2e/ is always UI'
for bad in 'non-ui /' 'non-ui ../x/' 'non-ui *' 'non-ui scripts/*' 'ui scripts/' 'non-ui scripts/ tests/' 'non-ui'; do
    scope_classify "${bad}" 'scripts/a.sh'
    contains "a malformed entry [${bad}] refuses the declaration" "${OUT}" \
        "SCOPE=ui WHY=.fleet/test-scope line 1 is not '<docs|non-ui> <dir/ | *.ext | path>'"
done
scope_classify 'non-ui scripts/' ''
contains 'an empty diff is UI' "${OUT}" 'SCOPE=ui WHY=the diff names no path'
scope_classify '' 'scripts/a.sh'
contains 'an empty declaration declares nothing non-UI' "${OUT}" 'SCOPE=ui WHY=UI path: scripts/a.sh'
scope_classify $'non-ui scripts/\ndocs scripts/README.md' $'scripts/README.md'
contains 'an exact docs entry beats the directory it sits in' "${OUT}" 'SCOPE=docs WHY=docs-only diff (scripts/README.md)'
scope_classify $'docs docs/\nnon-ui docs/tools/' $'docs/tools/x.sh'
contains 'the longer directory wins: a script under a docs tree is non-UI' "${OUT}" 'SCOPE=non-ui WHY=non-UI diff (docs/tools/)'
scope_classify $'non-ui docs/tools/\ndocs docs/' $'docs/tools/x.sh'
contains 'and the order of the lines does not change it' "${OUT}" 'SCOPE=non-ui WHY=non-UI diff (docs/tools/)'
scope_classify $'docs scripts/\nnon-ui scripts/' $'scripts/a.sh'
contains 'a tie goes to non-UI, the stricter' "${OUT}" 'SCOPE=non-ui WHY=non-UI diff (scripts/)'
scope_classify $'non-ui *.json\nnon-ui *.lock' $'composer.json'
contains 'a root glob does not reach composer.json' "${OUT}" 'SCOPE=ui WHY=UI path: composer.json'
scope_classify $'non-ui scripts/' $'scripts/package-lock.json'
contains 'a directory does not reach a lockfile under it' "${OUT}" 'SCOPE=ui WHY=UI path: scripts/package-lock.json'
scope_classify $'non-ui composer.lock' $'composer.lock'
contains 'an exact entry does reach a lockfile' "${OUT}" 'SCOPE=non-ui WHY=non-UI diff (composer.lock)'
for m in npm-shrinkwrap.json bun.lock bun.lockb Gemfile.lock; do
    scope_classify $'non-ui scripts/\nnon-ui *.json\nnon-ui *.lock\nnon-ui *.lockb' "${m}"$'\n'"scripts/${m}"
    contains "a glob or a directory does not reach ${m}" "${OUT}" "SCOPE=ui WHY=UI path: ${m} and 1 more"
    scope_classify "non-ui ${m}" "${m}"
    contains "an exact entry does reach ${m}" "${OUT}" "SCOPE=non-ui WHY=non-UI diff (${m})"
done
scope_classify $'non-ui scripts/\r' $'scripts/a.sh'
contains 'a CRLF declaration is refused' "${OUT}" "SCOPE=ui WHY=.fleet/test-scope line 1 is not"
scope_classify 'non-ui scripts/' $'scripts/a.sh\nscriptsx/b.sh\nc.sh\nd.sh'
contains 'a directory entry matches only under it, and the count of the rest is named' "${OUT}" \
    'SCOPE=ui WHY=UI path: scriptsx/b.sh and 2 more'

# --- 4. the ledger writer --------------------------------------------------------
fixture ledger-writer
WRITTEN="${CASE}/written"
run_lib "$(armed "GATE_SUITE_PASSED=1 GATE_LEDGER=${WRITTEN} gate_ledger_record ci 0 /tmp/ci.log >&3")"
contains 'the writer says where it wrote' "${OUT}" "gate-ledger: ${LIVE_SHA:0:7} ci rc=0 -> ${WRITTEN}"
matches 'the ledger line is <sha> <kind> <utc> <rc> <log>' "$(tail -1 "${WRITTEN}")" \
    "^${LIVE_SHA} ci [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z 0 /tmp/ci\.log$"

# Backlog 268: a red run on an uncommitted tree used to land as <sha>-dirty.
fixture ledger-writer-dirty
WRITTEN="${CASE}/written"
printf 'uncommitted\n' >>"${ROOT}/app/base.txt"
run_lib "$(armed "set -e; GATE_LEDGER=${WRITTEN} gate_ledger_record e2e 1 /tmp/e2e.log >&3 2>&3; printf 'TEARDOWN RAN\n' >&3")"
contains 'a dirty tree is refused in the words of the rule' "${OUT}" \
    'gate-ledger: dirty tree: no ledger row — commit, then gate the tip'
contains 'and a set -e caller still reaches its teardown' "${OUT}" 'TEARDOWN RAN'
equals 'and no row is written, dirty-stamped or not' "$(rows "${WRITTEN}")" '0'

fixture ledger-unwritable
run_lib "$(armed "GATE_LEDGER=/proc/nope/ledger gate_ledger_record ci 0 - >&3 2>&3; printf 'STILL HERE\n' >&3")"
contains 'a ledger it cannot write is said out loud' "${OUT}" 'is NOT recorded'
contains 'and the gate carries on regardless' "${OUT}" 'STILL HERE'

fixture ledger-writer-flag
WRITTEN="${CASE}/written"
run_lib "$(armed "GATE_SUITE_PASSED=1 GATE_LEDGER=${WRITTEN} gate_ledger_record ci 0 /tmp/ci.log >&3 2>&3")"
contains 'rc 0 with GATE_SUITE_PASSED is recorded green' "${OUT}" \
    "gate-ledger: ${LIVE_SHA:0:7} ci rc=0 -> ${WRITTEN}"
matches 'and the line it writes says rc 0' "$(tail -1 "${WRITTEN}")" \
    "^${LIVE_SHA} ci [0-9-]+T[0-9:]+Z 0 /tmp/ci\.log$"

fixture ledger-writer-no-flag
WRITTEN="${CASE}/written"
run_lib "$(armed "GATE_LEDGER=${WRITTEN} gate_ledger_record e2e 0 - >&3 2>&3")"
contains 'rc 0 without the flag says the run did not finish' "${OUT}" \
    'gate-ledger: rc 0 without GATE_SUITE_PASSED — the run did not finish; recorded as a failure'
matches 'and a failure is what it writes' "$(tail -1 "${WRITTEN}")" \
    "^${LIVE_SHA} e2e [0-9-]+T[0-9:]+Z 1 -$"

fixture ledger-writer-nonzero
WRITTEN="${CASE}/written"
run_lib "$(armed "GATE_LEDGER=${WRITTEN} gate_ledger_record ci 7 - >&3 2>&3")"
matches 'a non-zero rc is written unchanged' "$(tail -1 "${WRITTEN}")" \
    "^${LIVE_SHA} ci [0-9-]+T[0-9:]+Z 7 -$"
absent 'and the flag is never mentioned for it' "${OUT}" 'GATE_SUITE_PASSED'

fixture ledger-env-exported-before-source
WRITTEN="${CASE}/written"
SUITE_PASSED_ENV=1
run_lib "$(armed "GATE_LEDGER=${WRITTEN} gate_ledger_record ci 0 /tmp/ci.log >&3 2>&3")"
contains 'an operator export inherited before sourcing is discarded, not honoured' "${OUT}" \
    'gate-ledger: rc 0 without GATE_SUITE_PASSED — the run did not finish; recorded as a failure'
matches 'and it is written as a failure' "$(tail -1 "${WRITTEN}")" \
    "^${LIVE_SHA} ci [0-9-]+T[0-9:]+Z 1 /tmp/ci\.log$"

# --- 4b. the armed sha: a row names the commit the run began on, or there is no row ---
# A commit landing between gate_ledger_arm and the EXIT trap. The row would otherwise
# clear a tree no step ever read.
fixture ledger-head-moved
WRITTEN="${CASE}/written"
FIXGIT="git -C ${ROOT} -c user.name=t -c user.email=t@example.invalid"
run_lib "$(armed "printf 'late\n' >${ROOT}/app/late.txt; ${FIXGIT} add app/late.txt; ${FIXGIT} commit -q -m late; GATE_SUITE_PASSED=1 GATE_LEDGER=${WRITTEN} gate_ledger_record ci 0 /tmp/ci.log >&3 2>&3")"
LATE_SHA="$(git_at rev-parse HEAD)"
contains 'a commit landing mid-run is refused, naming both commits' "${OUT}" \
    "gate-ledger: HEAD is ${LATE_SHA} but the run began at ${LIVE_SHA}, so the ci run (rc=0) is NOT recorded"
equals 'and the ledger stays empty' "$(rows "${WRITTEN}")" '0'
absent 'no green row for the commit the gate never read' "$(cat "${WRITTEN}" 2>/dev/null)" "${LATE_SHA}"
absent 'and none for the commit it was armed on either' "$(cat "${WRITTEN}" 2>/dev/null)" "${LIVE_SHA}"

fixture ledger-never-armed
WRITTEN="${CASE}/written"
run_lib "GATE_LEDGER_GIT='git -C ${ROOT}'; GATE_SUITE_PASSED=1 GATE_LEDGER=${WRITTEN} gate_ledger_record ci 0 - >&3 2>&3; printf 'STILL HERE\n' >&3"
contains 'a gate that never armed gets no row' "${OUT}" \
    'gate-ledger: gate_ledger_arm was never called, so the ci run (rc=0) is NOT recorded'
equals 'and nothing is written' "$(rows "${WRITTEN}")" '0'
contains 'and the gate carries on regardless' "${OUT}" 'STILL HERE'

fixture ledger-armed-env-before-source
WRITTEN="${CASE}/written"
ARMED_ENV=1
run_lib "GATE_LEDGER_GIT='git -C ${ROOT}'; GATE_SUITE_PASSED=1 GATE_LEDGER=${WRITTEN} gate_ledger_record ci 0 - >&3 2>&3"
contains 'an inherited GATE_ARMED is discarded on sourcing, not honoured' "${OUT}" \
    'gate-ledger: gate_ledger_arm was never called, so the ci run (rc=0) is NOT recorded'
equals 'and it buys no row' "$(rows "${WRITTEN}")" '0'

fixture ledger-arm-unreadable
WRITTEN="${CASE}/written"
run_lib "GATE_LEDGER_GIT='git -C ${CASE}/nope'; gate_ledger_arm 2>&3; GATE_LEDGER_GIT='git -C ${ROOT}'; GATE_SUITE_PASSED=1 GATE_LEDGER=${WRITTEN} gate_ledger_record ci 0 - >&3 2>&3"
contains 'arming that cannot name HEAD says so at once' "${OUT}" \
    'gate-ledger: arming could not name HEAD, so this run will record nothing'
contains 'and the row is refused rather than guessed' "${OUT}" \
    "gate-ledger: HEAD is ${LIVE_SHA} but the run began at an unreadable HEAD, so the ci run (rc=0) is NOT recorded"
equals 'and nothing is written' "$(rows "${WRITTEN}")" '0'

# --- 4c. heavy-work gave up: a run that never started is not a verdict ---------------
# 2026-10-02: a suite that waited out its hour for a slot reached the ledger as rc 1, so
# the ledger called that commit red and a green re-run was needed to undo a run that
# never happened.
fixture ledger-heavy-work-giveup
WRITTEN="${CASE}/written"
run_lib "$(armed "GATE_LEDGER=${WRITTEN} gate_ledger_record ci 75 /tmp/ci.log >&3 2>&3; printf 'STILL HERE\n' >&3")"
contains 'a give-up by the serializer is refused as a run that never ran' "${OUT}" \
    'gate-ledger: heavy-work gave up (rc=75), so the ci run is NOT recorded — it never ran'
equals 'and nothing is written' "$(rows "${WRITTEN}")" '0'
absent 'and no row calls the commit anything' "$(cat "${WRITTEN}" 2>/dev/null)" "${LIVE_SHA}"
contains 'and the gate carries on regardless' "${OUT}" 'STILL HERE'

# The row the give-up did not write is read as absent — the tip is still ungated and
# still needs a run, which is not the same claim as a red row it never earned.
fixture ledger-giveup-row-absent
printf '%s e2e 2026-10-02T05:30:00Z 0 -\n' "${LIVE_SHA}" >"${LEDGER}"
run_lib "$(armed "GATE_LEDGER=${LEDGER} gate_ledger_record ci 75 - >&3 2>&3; HEAD_SHA=${LIVE_SHA}; gated")"
contains 'the ci a give-up never ran reads absent, never red' "${OUT}" \
    "$(no_green ci "${LIVE_SHA}" 'ci absent, e2e green')"

# --- 5. pre-flight ----------------------------------------------------------------
fixture preflight-clean
# A busy slot, because the line quotes whatever the serializer answers — pinning the
# word 'free' here would tie the test to the stub's mood rather than to pre-flight.
HEAVY_STATUS='busy pid=4242 label=another-gate'
run_lib 'preflight; refuse_if_dirty; printf "PAST THE DIRTY CHECK\n" >&3'
matches 'pre-flight prints load, memory and whatever the serializer answers' "${OUT}" \
    'PRE-FLIGHT load [0-9.]+ [0-9.]+ [0-9.]+ available [0-9]+MB heavy-work busy pid=4242 label=another-gate'
absent 'and its first line only' "${OUT}" 'last: label=noise'
contains 'a clean checkout passes' "${OUT}" 'PAST THE DIRTY CHECK'

fixture preflight-dirty
printf 'uncommitted\n' >>"${ROOT}/app/base.txt"
run_lib 'refuse_if_dirty; printf "PAST THE DIRTY CHECK\n" >&3'
contains 'a dirty checkout is refused' "${OUT}" \
    'REFUSED: the checkout is dirty; a deploy never fast-forwards over uncommitted work.'
absent 'and nothing after it runs' "${OUT}" 'PAST THE DIRTY CHECK'

# --- 6. the summary ----------------------------------------------------------------
fixture summary
run_lib 'say "A SUMMARY LINE"; detail "a detail line"; printf "LOG %s\n" "$LOG" >&3'
contains 'say reaches stdout' "${OUT}" 'A SUMMARY LINE'
contains 'say reaches the log too' "$(cat "${LOGFILE}")" 'A SUMMARY LINE'
absent 'detail never reaches stdout' "${OUT}" 'a detail line'
contains 'detail reaches the log' "$(cat "${LOGFILE}")" 'a detail line'
matches 'the log is named <utc>-pr<N>.log' "${LOGFILE}" \
    "^${LOGS}/[0-9]{8}T[0-9]{6}Z-pr73\.log$"

fixture log-dir-default
LOG_DIR_UNSET=1
run_lib 'say "A SUMMARY LINE"'
matches 'with no DEPLOY_LOG_DIR the log lands in a per-project subdirectory' "${LOGFILE}" \
    "^${CASE}/logroot/root/[0-9]{8}T[0-9]{6}Z-pr73\.log$"

fixture fail-tail
run_lib 'detail "step 3 composer"; detail "compose: composer failed"; fail_tail "STEPS 2-8" 1'
contains 'a failed phase says which rc' "${OUT}" 'STEPS 2-8 FAILED rc=1 — the last 20 lines of '
contains 'and prints the tail of its log' "${OUT}" 'compose: composer failed'

# A deploy's fast-forward, as the deploy's own uid would make it; finish then reads it back as files.
LAND='MERGE_SHA=$($GIT rev-parse origin/main); $GIT reset -q --hard "$MERGE_SHA"; '
RECORD_ROWS='$1 == "DONE" || $1 == "ROLLBACK" || $1 == "SEED" { r = $0 } END { printf "%s", r }'
RECORD_VERDICT='{ v = $2 ~ /^[0-9a-f]{40}$/ && $2 == sha ? 0 : 4; for (i = 3; i <= NF; i++) if (v == 0 && $i == "RED") v = 5 } END { print v + 0 }'
tripwire_verdict() { awk "${RECORD_ROWS}" "$1" | awk -v sha="$2" "${RECORD_VERDICT}"; }

fixture finish
run_lib "${LAND}"'GATED=ledger; finish "$MERGE_SHA"; printf "NOT REACHED\n" >&3'
contains 'DONE names what is live, what was, and how it was gated' "${OUT}" \
    "DONE #73 live ${MERGE_SHA} was ${LIVE_SHORT} gated ledger log "
contains 'and the paperwork line follows it' "${OUT}" \
    "PAPERWORK PR #73 deployed "
contains 'the paperwork line ends with where it goes' "${OUT}" '— backlog and handoff'
absent 'finish ends the deploy' "${OUT}" 'NOT REACHED'

fixture finish-extra
EXTRA='root-owned 0 drift none'
run_lib "${LAND}"'GATED="by hand"; finish "$MERGE_SHA"'
contains 'a project adds its own facts to DONE' "${OUT}" \
    "DONE #73 live ${MERGE_SHA} was ${LIVE_SHORT} gated by hand root-owned 0 drift none log "

# --- 6b. root's record ------------------------------------------------------------
# Each case's record is ${CASE}/records/root.record; the live tripwire's own awk reads it.
RECORD_UTC='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
unrecorded() {
    equals "$1: the exit" "RC=${RC}" 'RC=1'
    absent "$1: and no DONE line" "${OUT}" 'DONE #73'
    equals "$1: and no record row" "$(rows "${CASE}/records/root.record")" '0'
}

fixture record-done
run_lib "${LAND}"'GATED=ledger; finish "$MERGE_SHA"'
equals 'finish appends one row to root'\''s record' "$(rows "${CASE}/records/root.record")" '1'
matches 'the row is DONE, the full merge sha, the time and the log' "$(cat "${CASE}/records/root.record")" \
    "^DONE ${MERGE_SHA} ${RECORD_UTC} ${LOGFILE}\$"
equals 'the live tripwire'\''s awk reads that sha as deployed' "$(tripwire_verdict "${CASE}/records/root.record" "${MERGE_SHA}")" '0'
equals 'a new record is a 600 file in a 700 directory' \
    "$(stat -c %u:%a "${CASE}/records/root.record" "${CASE}/records" | tr '\n' ' ')" "$(id -u):600 $(id -u):700 "

fixture record-forged
run_lib 'runuser -u nobody -- sh -c "echo DONE \#1 live '"${FIXTURE_SIDE_SHA}"'"; '"${LAND}"'GATED=ledger; finish "$MERGE_SHA"'
contains 'an app-uid step can print a DONE row into the log' "$(cat "${LOGFILE}")" "DONE #1 live ${FIXTURE_SIDE_SHA}"
equals 'and root'\''s record still names the merge commit alone' \
    "$(awk '{ print $1, $2 }' "${CASE}/records/root.record")" "DONE ${MERGE_SHA}"

fixture record-red
EXTRA='root-owned 0 RED fpm-not-reloaded'
run_lib "${LAND}"'GATED=ledger; finish "$MERGE_SHA"'
matches 'a RED on DONE reaches the record row' "$(cat "${CASE}/records/root.record")" \
    "^DONE ${MERGE_SHA} ${RECORD_UTC} ${LOGFILE} RED fpm-not-reloaded\$"
equals 'and the live tripwire'\''s awk reads it as DONE carrying RED' "$(tripwire_verdict "${CASE}/records/root.record" "${MERGE_SHA}")" '5'

fixture record-not-landed
run_lib 'MERGE_SHA=$($GIT rev-parse origin/main); GATED=ledger; finish "$MERGE_SHA"'
contains 'a HEAD that is not the merge commit is refused' "${OUT}" \
    "REFUSED: ${ROOT}/.git/HEAD reads ${LIVE_SHA}, not ${MERGE_SHA}: root's record ${CASE}/records/root.record is not written."
unrecorded 'not landed'

fixture record-not-merge
run_lib "${LAND}"'X=$($GIT rev-parse HEAD^1); $GIT reset -q --hard "$X"; GATED=ledger; finish "$X"'
contains 'a landed sha that is not the merge commit is refused' "${OUT}" \
    "REFUSED: finish was handed ${LIVE_SHA}, not the merge commit resolve read from GitHub (${MERGE_SHA})"
unrecorded 'not the merge commit'

fixture record-short
run_lib "${LAND}"'GATED=ledger; finish "${MERGE_SHA:0:7}"'
contains 'a short sha is refused, naming the re-vendor' "${OUT}" \
    "REFUSED: finish takes the full 40-hex MERGE_SHA since deploy-lib 2026-10-03, and was handed '${MERGE_SHA:0:7}': re-vendoring changes the caller too."
unrecorded 'short sha'
run_lib "${LAND}"'GATED=ledger; finish "${MERGE_SHA:0:39}g"'
contains 'a non-hex sha is refused' "${OUT}" \
    "REFUSED: finish takes the full 40-hex MERGE_SHA since deploy-lib 2026-10-03, and was handed '${MERGE_SHA:0:39}g'"
unrecorded 'non-hex sha'

fixture record-no-root
run_lib "${LAND}"'GATED=ledger; ROOT=""; finish "$MERGE_SHA"'
contains 'with no ROOT nothing names the record' "${OUT}" 'REFUSED: ROOT is unset, so no record names this project.'
equals 'no ROOT: the exit' "RC=${RC}" 'RC=1'
equals 'no ROOT: and nothing is created' "$(find "${CASE}/records" 2>/dev/null | wc -l)" '0'

unsafe() { printf "REFUSED: root's record %s/records/root.record is not a 600 file in a 700 directory" "${CASE}"; }
fixture record-dir-755
mkdir -m 755 "${CASE}/records"
run_lib "${LAND}"'GATED=ledger; finish "$MERGE_SHA"'
contains 'a 755 record directory is refused' "${OUT}" "$(unsafe)"
unrecorded 'dir 755'

fixture record-file-644
mkdir -m 700 "${CASE}/records"
: >"${CASE}/records/root.record"
chmod 644 "${CASE}/records/root.record"
run_lib "${LAND}"'GATED=ledger; finish "$MERGE_SHA"'
contains 'a 644 record file is refused' "${OUT}" "$(unsafe)"
unrecorded 'file 644'

fixture record-symlink
mkdir -m 700 "${CASE}/records"
( umask 077; : >"${CASE}/elsewhere" )
ln -s "${CASE}/elsewhere" "${CASE}/records/root.record"
run_lib "${LAND}"'GATED=ledger; finish "$MERGE_SHA"'
contains 'a record that is a symlink is refused' "${OUT}" "$(unsafe)"
unrecorded 'symlink'
equals 'symlink: and its target takes no row' "$(rows "${CASE}/elsewhere")" '0'

fixture record-detached
run_lib "${LAND}"'$GIT checkout -q --detach; GATED=ledger; finish "$MERGE_SHA"'
contains 'a detached HEAD is refused' "${OUT}" "REFUSED: ${ROOT}/.git/HEAD reads no main sha, not ${MERGE_SHA}"
unrecorded 'detached HEAD'

fixture record-other-branch
run_lib "${LAND}"'$GIT checkout -q -b other; GATED=ledger; finish "$MERGE_SHA"'
contains 'a HEAD on another branch is refused' "${OUT}" "REFUSED: ${ROOT}/.git/HEAD reads no main sha, not ${MERGE_SHA}"
unrecorded 'another branch'

# Landed on the test's side, so the case can rearrange .git before the deploy reads it.
landed_at() { git_at reset -q --hard "${MERGE_SHA}"; }

fixture record-packed
landed_at
git_at pack-refs --all
run_lib "MERGE_SHA=${MERGE_SHA}; GATED=ledger; finish \"\$MERGE_SHA\""
equals 'a main that lives only in packed-refs is read' "$(awk '{ print $1, $2 }' "${CASE}/records/root.record")" "DONE ${MERGE_SHA}"

fixture record-packed-wrong
landed_at
git_at pack-refs --all
sed -i "s#^[0-9a-f]* refs/heads/main\$#${LIVE_SHA} refs/heads/main#" "${ROOT}/.git/packed-refs"
run_lib "MERGE_SHA=${MERGE_SHA}; GATED=ledger; finish \"\$MERGE_SHA\""
contains 'a packed main naming another commit is refused' "${OUT}" "REFUSED: ${ROOT}/.git/HEAD reads ${LIVE_SHA}, not ${MERGE_SHA}"
unrecorded 'packed main elsewhere'

fixture record-ref-symlink
landed_at
mv "${ROOT}/.git/refs/heads/main" "${CASE}/main-ref"
ln -s "${CASE}/main-ref" "${ROOT}/.git/refs/heads/main"
run_lib "MERGE_SHA=${MERGE_SHA}; GATED=ledger; finish \"\$MERGE_SHA\""
contains 'a refs/heads/main that is a symlink is refused' "${OUT}" "REFUSED: ${ROOT}/.git/HEAD reads no main sha, not ${MERGE_SHA}"
unrecorded 'main ref symlink'

fixture record-head-symlink
landed_at
mv "${ROOT}/.git/HEAD" "${CASE}/HEAD-file"
ln -s "${CASE}/HEAD-file" "${ROOT}/.git/HEAD"
run_lib "MERGE_SHA=${MERGE_SHA}; GATED=ledger; finish \"\$MERGE_SHA\""
contains 'a HEAD that is a symlink is refused' "${OUT}" "REFUSED: ${ROOT}/.git/HEAD reads no main sha, not ${MERGE_SHA}"
unrecorded 'HEAD symlink'

fixture record-other-owner
mkdir -m 700 "${CASE}/records"
( umask 077; : >"${CASE}/records/root.record" )
chown nobody "${CASE}/records/root.record"
run_lib "${LAND}"'GATED=ledger; finish "$MERGE_SHA"'
contains 'a 600 record owned by another uid is refused' "${OUT}" "$(unsafe)"
unrecorded 'another owner'

fixture record-live-default
run_lib 'MERGE_SHA=$($GIT rev-parse origin/main); unset DEPLOY_RECORD_ROOT; GATED=ledger; finish "$MERGE_SHA"'
contains 'a ROOT outside /var/www/ never defaults to the live record' "${OUT}" \
    "REFUSED: ROOT ${ROOT} is not under /var/www/ and DEPLOY_RECORD_ROOT is unset: only a live tree writes the live record."
equals 'live default: the exit' "RC=${RC}" 'RC=1'

fixture record-bad-name
run_lib "${LAND}"'ROOT="$ROOT/."; GATED=ledger; finish "$MERGE_SHA"'
contains 'a ROOT whose last part is not a record name is refused' "${OUT}" \
    "REFUSED: ROOT ${ROOT}/. ends in '.', which is not a record name the live tripwire reads."
equals 'bad name: the exit' "RC=${RC}" 'RC=1'
equals 'bad name: and nothing is created' "$(find "${CASE}/records" 2>/dev/null | wc -l)" '0'

fixture record-torn
mkdir -m 700 "${CASE}/records"
( umask 077; printf 'DONE %s 2026-10-03T00:00:00Z /torn' "${LIVE_SHA}" >"${CASE}/records/root.record" )
run_lib "${LAND}"'GATED=ledger; finish "$MERGE_SHA"'
equals 'a row after a torn last line starts on its own line' "$(tripwire_verdict "${CASE}/records/root.record" "${MERGE_SHA}")" '0'

fixture record-rollback
run_lib "${LAND}"'( deploy_record_rollback "$MERGE_SHA" runbook-rollback ) >&3 2>&3'
contains 'a rollback says what it recorded' "${OUT}" "ROLLBACK ${MERGE_SHA} recorded"
matches 'the ROLLBACK row is the full sha, the time and its source' "$(cat "${CASE}/records/root.record")" \
    "^ROLLBACK ${MERGE_SHA} ${RECORD_UTC} runbook-rollback\$"
equals 'and the live tripwire'\''s awk reads that sha as live' "$(tripwire_verdict "${CASE}/records/root.record" "${MERGE_SHA}")" '0'

fixture record-rollback-refused
run_lib "${LAND}"'( deploy_record_rollback "${MERGE_SHA:0:7}" runbook ) >&3 2>&3; echo "rc=$?" >&3; ( deploy_record_rollback "$MERGE_SHA" "two words" ) >&3 2>&3; echo "rc=$?" >&3; ( deploy_record_rollback "$MERGE_SHA" RED ) >&3 2>&3; echo "rc=$?" >&3'
contains 'a rollback with a short sha is refused' "${OUT}" \
    "REFUSED: '${MERGE_SHA:0:7}' is not a full 40-hex sha, and root's record ${CASE}/records/root.record takes nothing less."
contains 'a rollback whose source is not one word is refused' "${OUT}" 'REFUSED: a ROLLBACK row names its source in one word.'
contains 'a rollback whose source is RED is refused' "${OUT}" 'REFUSED: RED is not a source: the live tripwire reads it as a RED verdict.'
equals 'and each refusal returns 1' "$(printf '%s\n' "${OUT}" | grep -c '^rc=1$')" '3'
equals 'refused rollbacks: no record row' "$(rows "${CASE}/records/root.record")" '0'

# --- 7. the after-deploy cleanup ----------------------------------------------------
on_disk() { if [ -d "$1" ]; then printf 'there'; else printf 'gone'; fi; }

# base, headRef, and optionally the merge commit gh reports and the state.
gh_json() {
    printf '{"headRefOid":"%s","mergeCommit":{"oid":"%s"},"state":"%s","baseRefName":"%s","headRefName":"%s"}\n' \
        "${HEAD_SHA}" "${3:-${MERGE_SHA}}" "${4:-MERGED}" "$1" "$2" >"${CASE}/gh.json"
}

# The fixture plus a linked worktree on the pull request's branch, a `side` branch whose
# commit is on neither main nor a remote, and a process list holding one unrelated pid.
cleanup_fixture() {
    fixture "$1"
    WT="${CASE}/wt-pr"
    git_at worktree add -q "${WT}" pr
    git_at branch -q side "${FIXTURE_SIDE_SHA}"
    SIDE_SHA="${FIXTURE_SIDE_SHA}"
    mkdir -p "${CASE}/proc/1"
    ln -s "${CASE}" "${CASE}/proc/1/cwd"
    gh_json main pr
}

# Every cleanup case runs the wiring the projects will use — armed as an EXIT trap under
# the options their deploy scripts set — so each one also proves the deploy still ends 0.
CLEAN_CALL="${LAND}"'REPO=gcotcheza/fixture; set -eo pipefail; GATED=ledger; trap deploy_cleanup EXIT; DEPLOY_SUCCEEDED=1; finish "$MERGE_SHA"'
FAKE_SET="$(printf 'a-lane\n' | sha256sum | cut -d' ' -f1)"

cleanup_fixture cleanup-clean
DOCKER_IDS='c1'
DOCKER_MOUNTS="${CASE}/somewhere-else"
run_lib "${CLEAN_CALL}"
contains 'a merged, clean, unused worktree is removed' "${OUT}" \
    "CLEANUP #73 worktrees removed 1 kept 0 (none) scratch reaped 0 kept 0 (no lane is labelled gcotcheza/fixture #73)"
equals 'and it is gone from disk' "$(on_disk "${WT}")" 'gone'
equals 'the cleanup prints one summary line' "$(printf '%s\n' "${OUT}" | grep -c '^CLEANUP #')" '1'
equals 'and the deploy it hangs off still exits 0' "${RC}" '0'

cleanup_fixture cleanup-dirty
printf 'uncommitted\n' >>"${WT}/app/feature.txt"
run_lib "${CLEAN_CALL}"
contains 'a dirty worktree is kept and the reason names the check' "${OUT}" \
    'worktrees removed 0 kept 1 (dirty)'
equals 'and it is still on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-rootfiles
ROOT_UID_SEAM="$(stat -c %u "${WT}/app/base.txt")"
run_lib "${CLEAN_CALL}"
contains 'a worktree carrying a file owned by the privileged uid is kept' "${OUT}" \
    'worktrees removed 0 kept 1 (rootfiles)'
equals 'and it is still on disk' "$(on_disk "${WT}")" 'there'

# CLEANUP_FIND is the pin: a `find` earlier on PATH that answers nothing must not be
# what decides a tree carries no root-owned file.
cleanup_fixture cleanup-find-pinned
ROOT_UID_SEAM="$(stat -c %u "${WT}/app/base.txt")"
printf '#!/bin/sh\nexit 0\n' >"${BIN}/find"
chmod 0755 "${BIN}/find"
run_lib "${CLEAN_CALL}"
contains 'a find on PATH that answers nothing does not decide the root-owned check' "${OUT}" \
    'worktrees removed 0 kept 1 (rootfiles)'
equals 'and the pin left that worktree on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-head-nowhere
git_at worktree add -q "${CASE}/wt-side" side
gh_json main side
run_lib "${CLEAN_CALL}"
contains 'a head on neither main nor a remote branch is kept' "${OUT}" \
    'worktrees removed 0 kept 1 (headOnRemote)'
equals 'and it is still on disk' "$(on_disk "${CASE}/wt-side")" 'there'

cleanup_fixture cleanup-head-on-remote
git_at push -q origin side:refs/heads/side
git_at fetch -q origin
git_at worktree add -q "${CASE}/wt-side" side
gh_json main side
run_lib "${CLEAN_CALL}"
contains 'a head a remote branch still contains is removed' "${OUT}" \
    'worktrees removed 1 kept 0 (none)'
equals 'and it is gone from disk' "$(on_disk "${CASE}/wt-side")" 'gone'

cleanup_fixture cleanup-merge-not-in-main
gh_json main pr "${SIDE_SHA}"
run_lib "${CLEAN_CALL}"
contains 'a merge commit that is not an ancestor of origin/main examines nothing' "${OUT}" \
    "CLEANUP #73 worktrees not examined (mergeInMain: merge ${SIDE_SHA} is not an ancestor of origin/main) scratch not reaped (mergeInMain)"
equals 'and the worktree is still on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-base-not-main
gh_json release-2026 pr
run_lib "${CLEAN_CALL}"
contains 'a pull request merged into another base examines nothing' "${OUT}" \
    'CLEANUP #73 worktrees not examined (base: merged into release-2026, not main) scratch not reaped (base)'
equals 'and the worktree is still on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-not-merged
gh_json main pr "${MERGE_SHA}" OPEN
run_lib "${CLEAN_CALL}"
contains 'an unmerged pull request examines nothing' "${OUT}" \
    'CLEANUP #73 worktrees not examined (notMerged: state OPEN) scratch not reaped (notMerged)'
equals 'and the worktree is still on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-procs-inside
mkdir -p "${CASE}/proc/4242"
ln -s "${WT}/app" "${CASE}/proc/4242/cwd"
run_lib "${CLEAN_CALL}"
contains 'a worktree a running process sits in is kept' "${OUT}" \
    'worktrees removed 0 kept 1 (procs)'
equals 'and it is still on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-procs-unreadable
PROC_ROOT_SEAM="${CASE}/no-such-proc"
run_lib "${CLEAN_CALL}"
contains 'an unreadable process list keeps the worktree rather than reading as none' "${OUT}" \
    'worktrees removed 0 kept 1 (procs)'
equals 'and it is still on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-mounts
DOCKER_IDS='c1'
DOCKER_MOUNTS="${CASE}/wt-pr/storage"
run_lib "${CLEAN_CALL}"
contains 'a worktree a running container mounts is kept' "${OUT}" \
    'worktrees removed 0 kept 1 (mounts)'
equals 'and it is still on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-mounts-unreadable
DOCKER_RC=1
run_lib "${CLEAN_CALL}"
contains 'a docker that cannot be asked keeps the worktree' "${OUT}" \
    'worktrees removed 0 kept 1 (mounts)'
equals 'and it is still on disk' "$(on_disk "${WT}")" 'there'

# The dirty check passes, then the mounts step dirties the tree: the only shape in which
# `worktree remove` itself refuses, and so the only shape a --force would rescue.
cleanup_fixture cleanup-never-forced
DOCKER_IDS='c1'
DOCKER_MOUNTS="${CASE}/somewhere-else"
DOCKER_DIRTY="${WT}/app/feature.txt"
run_lib "${CLEAN_CALL}"
contains 'a tree that went dirty after the dirty check is kept, never forced' "${OUT}" \
    'worktrees removed 0 kept 1 (remove)'
equals 'and it is still on disk' "$(on_disk "${WT}")" 'there'

# Two guards keep the deployed checkout out of the candidates, and in a real repository
# each one covers for the other; ROOT is moved here so one case can fail one of them.
cleanup_fixture cleanup-first-block-excluded
gh_json main main
run_lib "REPO=gcotcheza/fixture; set -eo pipefail; GATED=ledger; ROOT=${CASE}/not-the-checkout; trap deploy_cleanup EXIT; DEPLOY_SUCCEEDED=1; exit 0"
contains 'the first worktree git lists is never a candidate' "${OUT}" \
    'CLEANUP #73 worktrees removed 0 kept 0 (none)'
equals 'and the checkout is still on disk' "$(on_disk "${ROOT}")" 'there'

cleanup_fixture cleanup-root-path-excluded
run_lib "REPO=gcotcheza/fixture; set -eo pipefail; GATED=ledger; ROOT=${WT}; trap deploy_cleanup EXIT; DEPLOY_SUCCEEDED=1; exit 0"
contains 'the worktree at the deployed path is never a candidate' "${OUT}" \
    'CLEANUP #73 worktrees removed 0 kept 0 (none)'
equals 'and it is still on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-worktree-list-unreadable
mkdir -p "${CASE}/shim"
printf '#!/bin/sh\ncase " $* " in *" worktree "*) exit 3 ;; esac\nexec git "$@"\n' >"${CASE}/shim/git"
chmod 0755 "${CASE}/shim/git"
run_lib "REPO=gcotcheza/fixture; set -eo pipefail; GATED=ledger; GIT=\"${CASE}/shim/git -C ${ROOT}\"; trap deploy_cleanup EXIT; DEPLOY_SUCCEEDED=1; ${LAND}finish \"\$MERGE_SHA\""
contains 'a worktree list that fails says so rather than reading as no worktrees' "${OUT}" \
    'CLEANUP #73 worktrees not listed (worktree list exited 3)'
equals 'and the worktree is still on disk' "$(on_disk "${WT}")" 'there'

# A worktree git lists without a HEAD line: the head is unknown, and an unknown head is
# kept on doubt rather than put through the two ancestry questions with an empty sha.
cleanup_fixture cleanup-head-unlisted
mkdir -p "${CASE}/shim"
printf '#!/bin/sh\ncase " $* " in *" worktree list "*) git "$@" | grep -v "^HEAD " ; exit 0 ;; esac\nexec git "$@"\n' >"${CASE}/shim/git"
chmod 0755 "${CASE}/shim/git"
run_lib "REPO=gcotcheza/fixture; set -eo pipefail; GATED=ledger; GIT=\"${CASE}/shim/git -C ${ROOT}\"; trap deploy_cleanup EXIT; DEPLOY_SUCCEEDED=1; ${LAND}finish \"\$MERGE_SHA\""
contains 'a worktree listed with no HEAD line is kept on doubt, not judged' "${OUT}" \
    'CLEANUP #73 worktrees removed 0 kept 1 (headInMain)'
equals 'and that worktree is still on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-reaper-error
REAP_DRY_RC=2
REAP_DRY_OUT='error:     /srv/worker-scratch/a-lane (label unreadable)'
run_lib "${CLEAN_CALL}"
contains 'a reaper that errors is loud' "${OUT}" \
    'CLEANUP #73 scratch: reap exited 2 on its read-only run; no lane was reaped and the deploy is unchanged.'
contains 'and the summary says no lane was reaped' "${OUT}" 'scratch not reaped (dry run exited 2)'
contains 'and the deploy still reports DONE' "${OUT}" "DONE #73 live ${MERGE_SHA}"
equals 'and the deploy exit code is unchanged' "${RC}" '0'

cleanup_fixture cleanup-apply-expect
REAP_DRY_OUT="candidate: /srv/worker-scratch/a-lane
candidates: 1  set: ${FAKE_SET}  kept: 0  errors: 0
dry run: nothing deleted. Re-run with --expect ${FAKE_SET} --apply to delete."
REAP_APPLY_OUT='reaped:    /srv/worker-scratch/a-lane
reaped: 1  kept: 0'
run_lib "${CLEAN_CALL}"
contains 'the summary carries the reaper own counts' "${OUT}" 'scratch reaped 1 kept 0'
contains 'and --apply ran with the hash the read-only run printed' "$(cat "${REAPARGV}")" \
    "gcotcheza/fixture 73 --expect ${FAKE_SET} --apply"

cleanup_fixture cleanup-no-head-branch
gh_json main ''
run_lib "${CLEAN_CALL}"
contains 'a pull request with no head branch examines nothing' "${OUT}" \
    'CLEANUP #73 worktrees not examined (headRef: gh named no head branch) scratch not reaped (headRef)'
equals 'and the worktree is still on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-dry-run-unreadable
REAP_DRY_OUT='fleet-scratch-reap: something else entirely'
run_lib "${CLEAN_CALL}"
contains 'a read-only run that printed no candidate set applies nothing' "${OUT}" \
    'printed no candidate set, so nothing was applied'
contains 'and the summary says so' "${OUT}" 'scratch not reaped (unreadable read-only run)'
equals 'and --apply was never called' "$(grep -c -- '--apply' "${REAPARGV}")" '0'

# No candidate is two different zeros: no lane carries the label at all, or every lane
# that does was kept on purpose. The second one is not "nothing is labelled".
cleanup_fixture cleanup-scratch-all-kept
REAP_DRY_OUT="candidates: 0  set: ${EMPTY_SET}  kept: 3  errors: 0"
run_lib "${CLEAN_CALL}"
contains 'no candidates but lanes kept says the lanes were kept, not that none is labelled' "${OUT}" \
    'scratch reaped 0 kept 3 (every labelled lane was kept (3))'
equals 'and --apply was never called for a kept lane' "$(grep -c -- '--apply' "${REAPARGV}")" '0'

cleanup_fixture cleanup-apply-kept
REAP_DRY_OUT="candidates: 1  set: ${FAKE_SET}  kept: 2  errors: 0"
REAP_APPLY_OUT='reaped: 1  kept: 2'
REAP_APPLY_RC=3
run_lib "${CLEAN_CALL}"
contains 'lanes kept on purpose are not an error' "${OUT}" 'scratch reaped 1 kept 2'

cleanup_fixture cleanup-apply-partway
REAP_DRY_OUT="candidates: 2  set: ${FAKE_SET}  kept: 0  errors: 0"
REAP_APPLY_OUT='reaped: 1  not removed: 1  kept: 0'
REAP_APPLY_RC=4
run_lib "${CLEAN_CALL}"
contains 'a reaper that stopped part-way is loud' "${OUT}" \
    'CLEANUP #73 scratch: reap stopped part-way (rc=4)'
contains 'and the summary says so' "${OUT}" 'scratch partly reaped (apply exited 4)'

cleanup_fixture cleanup-apply-error
REAP_DRY_OUT="candidates: 1  set: ${FAKE_SET}  kept: 0  errors: 0"
REAP_APPLY_RC=2
run_lib "${CLEAN_CALL}"
contains 'a reaper that refuses the apply is loud' "${OUT}" \
    'CLEANUP #73 scratch: reap exited 2 with --apply'
contains 'and the summary says so' "${OUT}" 'scratch not reaped (apply exited 2)'

cleanup_fixture cleanup-apply-counts-unreadable
REAP_DRY_OUT="candidates: 1  set: ${FAKE_SET}  kept: 0  errors: 0"
REAP_APPLY_OUT='reaped:    /srv/worker-scratch/a-lane'
run_lib "${CLEAN_CALL}"
contains 'an apply whose counts cannot be read says so rather than printing zeros' "${OUT}" \
    'scratch applied, counts unreadable'

cleanup_fixture cleanup-seam-unassigned
REAP_SEAM=''
run_lib "${CLEAN_CALL}"
contains 'a deploy that assigned no reaper is told, and removes nothing' "${OUT}" \
    'CLEANUP #73 did not run: the deploy assigned no REAP.'
equals 'and the worktree is still on disk' "$(on_disk "${WT}")" 'there'

# An ignored .env* is config and secrets, not reclaimable disk, so it keeps the tree even
# though the dirty check reads clean and every other check cleared it.
cleanup_fixture cleanup-envfiles
mkdir -p "${ROOT}/.git/info"
printf '.env\n' >>"${ROOT}/.git/info/exclude"
printf 'fixture\n' >"${WT}/.env"
run_lib "${CLEAN_CALL}"
contains 'an ignored .env file in a merged clean tree keeps it, and the reason names it' "${OUT}" \
    'worktrees removed 0 kept 1 (envfiles)'
contains 'and the deploy log names the file that kept it' "$(cat "${LOGFILE}")" \
    'CLEANUP keep envfiles'
equals 'and it is still on disk' "$(on_disk "${WT}")" 'there'

# The probe reaches any depth: reflection keeps its env file at api/.env.
cleanup_fixture cleanup-envfiles-nested
mkdir -p "${ROOT}/.git/info" "${WT}/api"
printf '.env*\n' >>"${ROOT}/.git/info/exclude"
printf 'fixture\n' >"${WT}/api/.env"
run_lib "${CLEAN_CALL}"
contains 'an ignored api/.env in a merged clean tree keeps it' "${OUT}" \
    'worktrees removed 0 kept 1 (envfiles)'
contains 'and the deploy log names the nested file' "$(cat "${LOGFILE}")" \
    'CLEANUP keep envfiles '"${WT}"' (it carries an ignored api/.env)'
equals 'and the nested-.env tree is still on disk' "$(on_disk "${WT}")" 'there'

# A top-level .env* directory: the plain term and the .env*/** term each reach inside it.
cleanup_fixture cleanup-envfiles-dir
mkdir -p "${ROOT}/.git/info" "${WT}/.env.d"
printf '.env*\n' >>"${ROOT}/.git/info/exclude"
printf 'fixture\n' >"${WT}/.env.d/prod"
run_lib "${CLEAN_CALL}"
contains 'an ignored .env.d/prod at the top of a merged clean tree keeps it' "${OUT}" \
    'worktrees removed 0 kept 1 (envfiles)'
equals 'and the .env.d tree is still on disk' "$(on_disk "${WT}")" 'there'

# A .env* directory below the top (api/.env.d/prod) is reached by neither term above it.
cleanup_fixture cleanup-envfiles-nested-dir
mkdir -p "${ROOT}/.git/info" "${WT}/api/.env.d"
printf '.env*\n' >>"${ROOT}/.git/info/exclude"
printf 'fixture\n' >"${WT}/api/.env.d/prod"
run_lib "${CLEAN_CALL}"
contains 'an ignored api/.env.d/prod in a merged clean tree keeps it' "${OUT}" \
    'worktrees removed 0 kept 1 (envfiles)'
contains 'and the deploy log names the file inside the nested directory' "$(cat "${LOGFILE}")" \
    'CLEANUP keep envfiles '"${WT}"' (it carries an ignored api/.env.d/prod)'
equals 'and the nested .env.d tree is still on disk' "$(on_disk "${WT}")" 'there'

# A vendored package's own .env* is not the app's config: kept on it, every tree would stay.
cleanup_fixture cleanup-envfiles-vendor
mkdir -p "${ROOT}/.git/info" "${WT}/vendor/x" "${WT}/api/vendor/y"
printf '.env*\nvendor/\n' >>"${ROOT}/.git/info/exclude"
printf 'fixture\n' >"${WT}/vendor/x/.env"
printf 'fixture\n' >"${WT}/api/vendor/y/.envrc"
run_lib "${CLEAN_CALL}"
contains 'an ignored .env* only under vendor/ does not keep the tree' "${OUT}" \
    'worktrees removed 1 kept 0 (none)'
equals 'and the vendor-only tree is gone from disk' "$(on_disk "${WT}")" 'gone'

cleanup_fixture cleanup-envfiles-node-modules
mkdir -p "${ROOT}/.git/info" "${WT}/node_modules/y" "${WT}/api/node_modules/dotenv"
printf '.env*\nnode_modules/\n' >>"${ROOT}/.git/info/exclude"
printf 'fixture\n' >"${WT}/node_modules/y/.env"
printf 'fixture\n' >"${WT}/api/node_modules/dotenv/.env.example"
run_lib "${CLEAN_CALL}"
contains 'an ignored .env* only under node_modules/ does not keep the tree' "${OUT}" \
    'worktrees removed 1 kept 0 (none)'
equals 'and the node_modules-only tree is gone from disk' "$(on_disk "${WT}")" 'gone'

cleanup_fixture cleanup-envfiles-none
mkdir -p "${ROOT}/.git/info" "${WT}/storage"
printf '.env*\nstorage/\n' >>"${ROOT}/.git/info/exclude"
printf 'fixture\n' >"${WT}/storage/app.log"
run_lib "${CLEAN_CALL}"
contains 'a tree whose only ignored files are not .env* is removed' "${OUT}" \
    'worktrees removed 1 kept 0 (none)'
equals 'and the tree with no .env is gone from disk' "$(on_disk "${WT}")" 'gone'

# The shims exit 3 and print nothing: an error on stdout would be read as a found file,
# which is the wrong reason reached by luck rather than the could-not-tell branch.
cleanup_fixture cleanup-envfiles-unreadable
mkdir -p "${CASE}/shim"
printf '#!/bin/sh\ncase " $* " in *" ls-files "*) exit 3 ;; esac\nexec git "$@"\n' >"${CASE}/shim/git"
chmod 0755 "${CASE}/shim/git"
WT_GIT_SEAM="${CASE}/shim/git"
run_lib "${CLEAN_CALL}"
contains 'a tree whose ignored .env files cannot be listed is kept on doubt' "${OUT}" \
    'worktrees removed 0 kept 1 (envfiles)'
equals 'and it is still on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-status-unreadable
mkdir -p "${CASE}/shim"
printf '#!/bin/sh\ncase " $* " in *" status "*) exit 3 ;; esac\nexec git "$@"\n' >"${CASE}/shim/git"
chmod 0755 "${CASE}/shim/git"
WT_GIT_SEAM="${CASE}/shim/git"
run_lib "${CLEAN_CALL}"
contains 'a status that could not be read is its own reason, not dirty' "${OUT}" \
    'worktrees removed 0 kept 1 (status)'
equals 'and it is still on disk' "$(on_disk "${WT}")" 'there'

# The two projects whose success-path handler calls deploy_cleanup unconditionally reach it
# on a refusal too; the marker is what makes that call safe.
cleanup_fixture cleanup-marker-unset
run_lib 'REPO=gcotcheza/fixture; set -eo pipefail; GATED=ledger; trap deploy_cleanup EXIT; refuse "the gate is red"'
contains 'a handler that fires without the success marker removes nothing' "${OUT}" \
    'CLEANUP #73 did not run: the deploy did not reach finish.'
equals 'and the worktree is still on disk' "$(on_disk "${WT}")" 'there'
equals 'and the refusal exit code is unchanged' "${RC}" '1'

cleanup_fixture cleanup-marker-from-environment
SUCCEEDED_ENV=1
run_lib 'REPO=gcotcheza/fixture; set -eo pipefail; GATED=ledger; trap deploy_cleanup EXIT; refuse "the gate is red"'
contains 'an inherited DEPLOY_SUCCEEDED is discarded on sourcing, not honoured' "${OUT}" \
    'CLEANUP #73 did not run: the deploy did not reach finish.'
equals 'and an environment-set marker leaves the worktree on disk' "$(on_disk "${WT}")" 'there'
equals 'and it does not change the refusal exit code either' "${RC}" '1'

# PR is caller-set like every seam, and the handler reads it as ${PR-}: unset, it says
# which name is missing and keeps everything, rather than dying under its callers' set -u.
cleanup_fixture cleanup-pr-unassigned
run_lib 'REPO=gcotcheza/fixture; set -eo pipefail; DEPLOY_SUCCEEDED=1; trap deploy_cleanup EXIT; unset PR; exit 0'
contains 'a deploy that assigned no PR is told, and removes nothing' "${OUT}" \
    'CLEANUP # did not run: the deploy assigned no PR.'
equals 'an unset PR leaves the worktree on disk' "$(on_disk "${WT}")" 'there'
equals 'and an unset PR under set -u still ends the deploy 0' "${RC}" '0'

cleanup_fixture cleanup-no-repo
run_lib "${LAND}"'set -eo pipefail; GATED=ledger; trap deploy_cleanup EXIT; DEPLOY_SUCCEEDED=1; finish "$MERGE_SHA"'
contains 'with no repository nothing is read and nothing is removed' "${OUT}" \
    'CLEANUP #73 did not run: REPO names no repository, so no pull request could be read.'
equals 'and the worktree is still on disk' "$(on_disk "${WT}")" 'there'

cleanup_fixture cleanup-gh-unreadable
GH_FAIL=1
run_lib "${CLEAN_CALL}"
contains 'an unreadable pull request removes nothing' "${OUT}" \
    'CLEANUP #73 did not run: gh could not read the pull request (rc=1); nothing is removed.'
equals 'and the worktree is still on disk' "$(on_disk "${WT}")" 'there'

# --- 8. root's compose (backlog 320): its own suite, which the red proofs also run as nobody ---
OUT="$(DEPLOY_LIB_DIR="${LIB_DIR}" bash "${SCRIPT_DIR}/compose-test.sh" 2>&1)"
RC=$?
contains 'compose-test.sh passes as root' "${OUT}" 'compose-test: all checks passed'
equals 'compose-test.sh exits' "${RC}" 0

# --- 9. a gate's literal: written once at column 0, read only as ${NAME} after (card 318) ----
LIT_VALUE=/srv/engineering-standards/scripts/lib/deploy/test.sh
LIT_READ='out="$(bash "${GATE_LIB_SUITE}" 2>&1)"'
literal_check() {
    printf '%s\n' "$@" >"${WORK}/literal-gate.sh"
    OUT="$(bash -c '. "$1"; gate_literal_once "$2" GATE_LIB_SUITE "$3"' _ "${LIB_DIR}/literal.sh" "${WORK}/literal-gate.sh" "${LIT_VALUE}" 2>&1)"
    RC=$?
}
for own in "GATE_LIB_SUITE=${LIT_VALUE}" "GATE_LIB_SUITE='${LIT_VALUE}'" "GATE_LIB_SUITE=\"${LIT_VALUE}\""; do
    literal_check '#!/usr/bin/env bash' '# the suite root runs' "${own}" 'run() {' "    ${LIT_READ}" '}'
    equals "the literal written as [${own}] and read as \${GATE_LIB_SUITE} passes" "${RC}:${OUT}" '0:'
done
while IFS= read -r form; do
    literal_check "GATE_LIB_SUITE=${LIT_VALUE}" "${form//<NL>/$'\n'}" "${LIT_READ}"
    equals "a second write [${form}] fails the guard" "${RC}" 1
    contains "and the refusal names it" "${OUT}" 'LITERAL GATE_LIB_SUITE refused: '"${WORK}"'/literal-gate.sh names it other than as ${GATE_LIB_SUITE} after its one write: '
done <<'FORMS'
GATE_LIB_SUITE=/srv/worker-scratch/branch/test.sh
    GATE_LIB_SUITE=/srv/worker-scratch/branch/test.sh
	[ -z "${GATE_LIB_SUITE_OVERRIDE:-}" ] || GATE_LIB_SUITE="${GATE_LIB_SUITE_OVERRIDE}"
: "${GATE_LIB_SUITE:=/srv/worker-scratch/branch/test.sh}"
export GATE_LIB_SUITE=/srv/worker-scratch/branch/test.sh
export "GATE_LIB_SUITE=/srv/worker-scratch/branch/test.sh"
"GATE_LIB_SUITE"=/srv/worker-scratch/branch/test.sh
'GATE_LIB_SUITE'=/srv/worker-scratch/branch/test.sh
declare GATE_"LIB_SUITE"=/srv/worker-scratch/branch/test.sh
GATE_LIB_\<NL>SUITE=/srv/worker-scratch/branch/test.sh
bash "$GATE_LIB_SUITE"
# a comment does not continue \<NL>GATE_LIB_SUITE=/srv/worker-scratch/branch/test.sh
: "<NL>#"; GATE_LIB_SUITE=/srv/worker-scratch/branch/test.sh
# GATE_LIB_SUITE named in a comment
FORMS
literal_check "    GATE_LIB_SUITE=${LIT_VALUE}" "${LIT_READ}"
equals 'an indented literal alone fails the guard' "${RC}" 1
contains 'and the refusal says the literal is owed at column 0' "${OUT}" "never writes GATE_LIB_SUITE=${LIT_VALUE} on a line of its own at column 0"
literal_check "${LIT_READ}" "GATE_LIB_SUITE=${LIT_VALUE}"
contains 'a read before the write is refused: it runs what the environment preset' "${OUT}" "after its one write: ${LIT_READ}"
literal_check 'GATE_LIB_SUITE=/srv/worker-scratch/branch/test.sh'
equals 'a gate that writes another value fails the guard' "${RC}" 1
contains 'and the refusal names the value it owes' "${OUT}" "never writes GATE_LIB_SUITE=${LIT_VALUE} on a line of its own at column 0"
literal_check
equals 'an empty gate fails the guard' "${RC}" 1
contains 'and the refusal names the value it owes' "${OUT}" "never writes GATE_LIB_SUITE=${LIT_VALUE}"
OUT="$(bash -c '. "$1"; gate_literal_once "$2" GATE_LIB_SUITE "$3"' _ "${LIB_DIR}/literal.sh" "${WORK}/no-such-gate.sh" "${LIT_VALUE}" 2>&1)"
equals 'a missing gate fails the guard' "$?" 1
contains 'and says it could not be scanned' "${OUT}" "LITERAL GATE_LIB_SUITE refused: ${WORK}/no-such-gate.sh could not be scanned"
OUT="$(bash -c '. "$1"; gate_literal_once "$2" GATE_LIB_SUITE "$3"' _ "${LIB_DIR}/literal.sh" "${WORK}" "${LIT_VALUE}" 2>&1)"
contains 'a directory in place of the gate is refused' "${OUT}" "${WORK} could not be scanned"
printf 'GATE.LIB=x\n' >"${WORK}/literal-gate.sh"
OUT="$(bash -c '. "$1"; gate_literal_once "$2" GATE.LIB x' _ "${LIB_DIR}/literal.sh" "${WORK}/literal-gate.sh" 2>&1)"
equals 'a name that is not a variable name fails the guard' "$?:${OUT}" '1:LITERAL refused: [GATE.LIB] is not a variable name'

grew 'the fixture commits added caller=root result=clean lines' \
    "${SUITE_CLEAN_BEFORE}" "$(clean_lines)"

equals '/dev/null keeps its mode and owner across the suite (rule 26)' "$(stat -c '%a %u %g %F' /dev/null)" "${DEVNULL_BEFORE}"

if [ "${fails}" -eq 0 ]; then
    printf '\ndeploy-lib-test: all checks passed\n'
    exit 0
fi
printf '\ndeploy-lib-test: %s check(s) failed\n' "${fails}" >&2
exit 1
