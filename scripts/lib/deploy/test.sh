#!/usr/bin/env bash
# Guards scripts/lib/deploy/: every function, every sentence and every header hash,
# against fakes in a temp directory. DEPLOY_LIB_DIR=<copy> runs the list against a copy.
#
#   scripts/lib/deploy/test.sh
#   DEPLOY_LIB_DIR=/tmp/mutant scripts/lib/deploy/test.sh   the red proofs
#
# It reads no checkout, runs no docker, no gh and no heavy-work.
# FAKE_CALLS strings stay single-quoted on purpose: the driver eval's them.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${DEPLOY_LIB_DIR:-${SCRIPT_DIR}}"
PR_NUMBER=73

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

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

git_at() { git -C "$ROOT" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.invalid "$@"; }

write_driver() {
    mkdir -p "${CASE}/lib"
    cp "${LIB_DIR}/summary.sh" "${LIB_DIR}/resolve.sh" "${LIB_DIR}/ledger.sh" \
       "${LIB_DIR}/preflight.sh" "${CASE}/lib/"
    cat >"${CASE}/lib/driver.sh" <<'SH'
#!/usr/bin/env bash
set -u
D="$(cd -- "$(dirname -- "$0")" && pwd)"
. "${D}/summary.sh"
. "${D}/resolve.sh"
. "${D}/ledger.sh"
. "${D}/preflight.sh"
ROOT=$DEPLOY_ROOT
GIT=$DEPLOY_GIT
GH=$DEPLOY_GH
HEAVY=$DEPLOY_HEAVY
LEDGER=$DEPLOY_LEDGER
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
case " $* " in
    *' -R '*) : ;;
    *) echo 'gh: no repository resolved (use -R owner/repo)' >&2; exit 1 ;;
esac
[ -n "${FAKE_GH_FAIL:-}" ] && { echo 'gh: no such pull request' >&2; exit 1; }
cat "${FAKE_GH_JSON}"
SH
    cat >"${BIN}/heavy-work" <<'SH'
#!/bin/sh
[ "$1" = '--status' ] && { echo 'free'; exit 0; }
exit 0
SH
    chmod 0755 "${BIN}"/*
}

# A checkout on L, origin/main on the merge M of the pull request head H. Nothing
# here is a real checkout: every path is under mktemp -d.
fixture() {
    CASE="${WORK}/$1"
    ROOT="${CASE}/root"
    BIN="${CASE}/bin"
    LEDGER="${CASE}/ledger"
    LOGS="${CASE}/logs"
    mkdir -p "${ROOT}/app" "${BIN}" "${LOGS}"
    : >"${LEDGER}"

    git init -q -b main "${ROOT}"
    printf 'base\n' >"${ROOT}/app/base.txt"
    git_at add app/base.txt
    git_at commit -q --no-verify -m base
    LIVE_SHA="$(git_at rev-parse HEAD)"
    LIVE_SHORT="$(git_at rev-parse --short HEAD)"

    git_at checkout -q -b pr
    printf 'feature\n' >"${ROOT}/app/feature.txt"
    git_at add app/feature.txt
    git_at commit -q --no-verify -m feature
    HEAD_SHA="$(git_at rev-parse HEAD)"

    git_at checkout -q main
    if [ "${2:-}" = 'trees-differ' ]; then
        git_at merge -q --no-ff --no-commit pr >/dev/null 2>&1
        printf 'smuggled\n' >"${ROOT}/app/smuggled.txt"
        git_at add app/smuggled.txt
        git_at commit -q --no-verify -m merge
    else
        git_at merge -q --no-ff --no-verify -m merge pr
    fi
    MERGE_SHA="$(git_at rev-parse HEAD)"

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
        repoenv="DEPLOY_GH_REPO=${REPO_OVERRIDE:-gcotcheza/fixture}"
    fi
    ARGVFILE="${CASE}/gh-argv.log"
    # shellcheck disable=SC2086  # repoenv is empty or one NAME=value; "" would be env's command
    OUT="$(env \
        PATH="${BIN}:${PATH}" \
        FAKE_GH_JSON="${CASE}/gh.json" \
        FAKE_GH_FAIL="${GH_FAIL:-}" \
        FAKE_GH_ARGV_LOG="${ARGVFILE}" \
        FAKE_PR="${PR_NUMBER}" \
        FAKE_BY_HAND="${BY_HAND:-0}" \
        FAKE_BEFORE="${LIVE_SHORT}" \
        FAKE_CALLS="$1" \
        EXTRA_DONE="${EXTRA:-}" \
        DEPLOY_ROOT="${ROOT}" \
        DEPLOY_GIT="git -C ${ROOT}" \
        DEPLOY_GH="${BIN}/gh" \
        DEPLOY_HEAVY="${BIN}/heavy-work" \
        DEPLOY_LEDGER="${LEDGER}" \
        ${repoenv} \
        "${logenv}" \
        bash "${CASE}/lib/driver.sh" 2>&1)"
    LOGFILE="$(find "${LOGS}" "${CASE}/logroot" -name '*.log' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)"
    BY_HAND=''
    GH_FAIL=''
    EXTRA=''
    LOG_DIR_UNSET=''
    REPO_OVERRIDE=''
}

BY_HAND=''
GH_FAIL=''
EXTRA=''
LOG_DIR_UNSET=''
REPO_OVERRIDE=''

# --- 1. the vendoring header on every lib file --------------------------------
VERSION_DECLARED="$(head -1 "${LIB_DIR}/VERSION")"
matches 'VERSION is a date' "${VERSION_DECLARED}" '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
for f in summary resolve ledger preflight; do
    line1="$(head -1 "${LIB_DIR}/${f}.sh")"
    body="$(tail -n +2 "${LIB_DIR}/${f}.sh" | sha256sum | cut -d' ' -f1)"
    equals "${f}.sh header" "${line1}" "# fleet-deploy-lib ${VERSION_DECLARED} sha256:${body}"
done

# --- 1b. -R: the fake rejects a missing repo; gh_repo parses the three URL forms;
#            DEPLOY_GH_REPO overrides; an unparsable origin refuses before any gh call ---
fixture fake-gh-strict
run_lib 'out=$("$GH" pr view 73 --json state 2>&1); rc=$?; printf "RC=%s MSG=%s\n" "$rc" "$out" >&3'
contains 'the fake gh itself rejects a call with no -R' "${OUT}" \
    'RC=1 MSG=gh: no repository resolved (use -R owner/repo)'

fixture gh-repo-scp
git_at remote set-url origin 'git@github.com:gcotcheza/x.git'
run_lib 'printf "REPO_IS %s\n" "$(gh_repo)" >&3'
contains 'scp-style origin (git@github.com:owner/repo.git) parses' "${OUT}" 'REPO_IS gcotcheza/x'

fixture gh-repo-ssh
git_at remote set-url origin 'ssh://git@github.com/gcotcheza/x.git'
run_lib 'printf "REPO_IS %s\n" "$(gh_repo)" >&3'
contains 'ssh:// origin parses' "${OUT}" 'REPO_IS gcotcheza/x'

fixture gh-repo-https-nogit
git_at remote set-url origin 'https://github.com/gcotcheza/x'
run_lib 'printf "REPO_IS %s\n" "$(gh_repo)" >&3'
contains 'https origin without .git parses' "${OUT}" 'REPO_IS gcotcheza/x'

fixture gh-repo-https-git
git_at remote set-url origin 'https://github.com/gcotcheza/x.git'
run_lib 'printf "REPO_IS %s\n" "$(gh_repo)" >&3'
contains 'https origin with .git parses' "${OUT}" 'REPO_IS gcotcheza/x'

fixture gh-repo-resolve-passes-R
run_lib 'resolve'
contains 'resolve passes -R through to gh' "$(cat "${ARGVFILE}")" '-R gcotcheza/fixture'
contains 'and still resolves' "${OUT}" \
    "RESOLVED #73 head ${HEAD_SHA:0:7} merge ${MERGE_SHA:0:7} is origin/main, trees identical"

fixture gh-repo-override-wins
REPO_OVERRIDE='gcotcheza/override-wins'
run_lib 'resolve'
contains 'DEPLOY_GH_REPO overrides origin (which here is unparsable)' "$(cat "${ARGVFILE}")" \
    '-R gcotcheza/override-wins'
contains 'and resolve still succeeds' "${OUT}" \
    "RESOLVED #73 head ${HEAD_SHA:0:7} merge ${MERGE_SHA:0:7} is origin/main, trees identical"

fixture gh-repo-unparsable
REPO_OVERRIDE='NONE'
run_lib 'resolve'
contains 'an unparsable origin is refused before any gh call' "${OUT}" \
    "REFUSED: origin's URL (${CASE}/origin.git) does not name a GitHub repository; set DEPLOY_GH_REPO."
absent 'no gh call was made' "$(cat "${ARGVFILE}" 2>/dev/null)" 'pr view'

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

fixture main-moved
git_at checkout -q -b later "${MERGE_SHA}"
git_at commit -q --no-verify --allow-empty -m later
git_at push -q origin later:main
git_at checkout -q main
run_lib 'resolve'
contains 'a merge behind the tip is refused' "${OUT}" 'REFUSED: main moved since the merge: re-gate.'

fixture trees-differ trees-differ
run_lib 'resolve'
contains 'a merge tree that is not the gated tree is refused' "${OUT}" \
    "REFUSED: merge tree differs from the gated head: re-gate the merge commit."

# --- 3. gated -------------------------------------------------------------------
fixture gated-ledger
run_lib 'resolve; gated; printf "GATED_IS %s\n" "$GATED" >&3'
contains 'a head green twice in the ledger is gated' "${OUT}" \
    "GATED ${HEAD_SHA:0:7} ci and e2e both green in ${LEDGER}"
contains 'and it says so in GATED' "${OUT}" 'GATED_IS ledger'

fixture no-ledger
rm -f "${LEDGER}"
run_lib 'resolve; gated'
contains 'a missing ledger is refused' "${OUT}" \
    "REFUSED: no gate ledger at ${LEDGER}, so no head was ever gated on this box."

fixture head-absent
: >"${LEDGER}"
run_lib 'resolve; gated'
contains 'a head absent from the ledger is refused' "${OUT}" \
    "REFUSED: the ledger holds no green ci for ${HEAD_SHA:0:7}: gate that head, then deploy."

fixture ledger-red
printf '%s ci 2026-09-18T20:00:00Z 1 -\n%s e2e 2026-09-18T20:30:00Z 0 -\n' \
    "${HEAD_SHA}" "${HEAD_SHA}" >"${LEDGER}"
run_lib 'resolve; gated'
contains 'a ci that exited non-zero is not a gate' "${OUT}" 'the ledger holds no green ci for'

fixture ci-only
printf '%s ci 2026-09-18T20:00:00Z 0 -\n' "${HEAD_SHA}" >"${LEDGER}"
run_lib 'resolve; gated'
contains 'ci without e2e is refused' "${OUT}" \
    "REFUSED: the ledger holds no green e2e for ${HEAD_SHA:0:7}: gate that head, then deploy."

fixture dirty-sha
printf '%s-dirty ci 2026-09-18T20:00:00Z 0 -\n%s-dirty e2e 2026-09-18T20:30:00Z 0 -\n' \
    "${HEAD_SHA}" "${HEAD_SHA}" >"${LEDGER}"
run_lib 'resolve; gated'
contains 'a -dirty sha never matches a deploy' "${OUT}" 'the ledger holds no green ci for'

fixture by-hand
rm -f "${LEDGER}"
BY_HAND=1
run_lib 'resolve; gated; printf "GATED_IS %s\n" "$GATED" >&3'
contains '--gated-by-hand says so out loud' "${OUT}" \
    "GATED BY HAND: the ledger was not read. #73 deploys on a human's word — transition and rescue only."
contains 'and by hand is what DONE will record' "${OUT}" 'GATED_IS by hand'

fixture ledger-green-then-red
printf '%s ci 2026-09-18T20:00:00Z 0 -\n%s ci 2026-09-18T22:00:00Z 1 -\n%s e2e 2026-09-18T20:30:00Z 0 -\n' \
    "${HEAD_SHA}" "${HEAD_SHA}" "${HEAD_SHA}" >"${LEDGER}"
run_lib 'resolve; gated'
contains 'a later red overrides an earlier green' "${OUT}" \
    "REFUSED: the ledger holds no green ci for ${HEAD_SHA:0:7}: gate that head, then deploy."

fixture ledger-red-then-green
printf '%s ci 2026-09-18T20:00:00Z 1 -\n%s ci 2026-09-18T22:00:00Z 0 -\n%s e2e 2026-09-18T20:30:00Z 0 -\n' \
    "${HEAD_SHA}" "${HEAD_SHA}" "${HEAD_SHA}" >"${LEDGER}"
run_lib 'resolve; gated'
contains 'a later green overrides an earlier red, which is a genuine re-run' "${OUT}" \
    "GATED ${HEAD_SHA:0:7} ci and e2e both green in ${LEDGER}"

# 2026-09-19: a killed e2e recorded rc 0 over a head that was already green, and the
# reader took any green. Both halves of that are proved here, together.
fixture killed-run-regression
printf '%s ci 2026-09-19T05:00:00Z 0 -\n%s e2e 2026-09-19T05:30:00Z 0 -\n' \
    "${LIVE_SHA}" "${LIVE_SHA}" >"${LEDGER}"
run_lib "GATE_LEDGER=${LEDGER} GATE_LEDGER_GIT='git -C ${ROOT}' gate_ledger_record e2e 0 - >&3 2>&3; HEAD_SHA=${LIVE_SHA}; gated"
contains 'the killed run is recorded as a failure' "${OUT}" \
    'gate-ledger: rc 0 without GATE_SUITE_PASSED — the run did not finish; recorded as a failure'
contains 'and the head it was green on before is no longer gated' "${OUT}" \
    "REFUSED: the ledger holds no green e2e for ${LIVE_SHA:0:7}: gate that head, then deploy."

# --- 4. the ledger writer --------------------------------------------------------
fixture ledger-writer
WRITTEN="${CASE}/written"
run_lib "GATE_SUITE_PASSED=1 GATE_LEDGER=${WRITTEN} GATE_LEDGER_GIT='git -C ${ROOT}' gate_ledger_record ci 0 /tmp/ci.log >&3"
contains 'the writer says where it wrote' "${OUT}" "gate-ledger: ${LIVE_SHA:0:7} ci rc=0 -> ${WRITTEN}"
matches 'the ledger line is <sha> <kind> <utc> <rc> <log>' "$(tail -1 "${WRITTEN}")" \
    "^${LIVE_SHA} ci [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z 0 /tmp/ci\.log$"
printf 'uncommitted\n' >>"${ROOT}/app/base.txt"
run_lib "GATE_LEDGER=${WRITTEN} GATE_LEDGER_GIT='git -C ${ROOT}' gate_ledger_record e2e 1 /tmp/e2e.log >&3"
matches 'a dirty tree records <sha>-dirty' "$(tail -1 "${WRITTEN}")" \
    "^${LIVE_SHA}-dirty e2e [0-9-]+T[0-9:]+Z 1 /tmp/e2e\.log$"

fixture ledger-unwritable
run_lib "GATE_LEDGER=/proc/nope/ledger GATE_LEDGER_GIT='git -C ${ROOT}' gate_ledger_record ci 0 - >&3 2>&3; printf 'STILL HERE\n' >&3"
contains 'a ledger it cannot write is said out loud' "${OUT}" 'is NOT recorded'
contains 'and the gate carries on regardless' "${OUT}" 'STILL HERE'

fixture ledger-writer-flag
WRITTEN="${CASE}/written"
run_lib "GATE_SUITE_PASSED=1 GATE_LEDGER=${WRITTEN} GATE_LEDGER_GIT='git -C ${ROOT}' gate_ledger_record ci 0 /tmp/ci.log >&3 2>&3"
contains 'rc 0 with GATE_SUITE_PASSED is recorded green' "${OUT}" \
    "gate-ledger: ${LIVE_SHA:0:7} ci rc=0 -> ${WRITTEN}"
matches 'and the line it writes says rc 0' "$(tail -1 "${WRITTEN}")" \
    "^${LIVE_SHA} ci [0-9-]+T[0-9:]+Z 0 /tmp/ci\.log$"

fixture ledger-writer-no-flag
WRITTEN="${CASE}/written"
run_lib "GATE_LEDGER=${WRITTEN} GATE_LEDGER_GIT='git -C ${ROOT}' gate_ledger_record e2e 0 - >&3 2>&3"
contains 'rc 0 without the flag says the run did not finish' "${OUT}" \
    'gate-ledger: rc 0 without GATE_SUITE_PASSED — the run did not finish; recorded as a failure'
matches 'and a failure is what it writes' "$(tail -1 "${WRITTEN}")" \
    "^${LIVE_SHA} e2e [0-9-]+T[0-9:]+Z 1 -$"

fixture ledger-writer-nonzero
WRITTEN="${CASE}/written"
run_lib "GATE_LEDGER=${WRITTEN} GATE_LEDGER_GIT='git -C ${ROOT}' gate_ledger_record ci 7 - >&3 2>&3"
matches 'a non-zero rc is written unchanged' "$(tail -1 "${WRITTEN}")" \
    "^${LIVE_SHA} ci [0-9-]+T[0-9:]+Z 7 -$"
absent 'and the flag is never mentioned for it' "${OUT}" 'GATE_SUITE_PASSED'

# --- 5. pre-flight ----------------------------------------------------------------
fixture preflight-clean
run_lib 'preflight; refuse_if_dirty; printf "PAST THE DIRTY CHECK\n" >&3'
matches 'pre-flight prints load, memory and the serializer' "${OUT}" \
    'PRE-FLIGHT load [0-9.]+ [0-9.]+ [0-9.]+ available [0-9]+MB heavy-work free'
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

fixture finish
run_lib 'GATED=ledger; finish abc1234; printf "NOT REACHED\n" >&3'
contains 'DONE names what is live, what was, and how it was gated' "${OUT}" \
    "DONE #73 live abc1234 was ${LIVE_SHORT} gated ledger log "
contains 'and the paperwork line follows it' "${OUT}" \
    "PAPERWORK PR #73 deployed "
contains 'the paperwork line ends with where it goes' "${OUT}" '— backlog and handoff'
absent 'finish ends the deploy' "${OUT}" 'NOT REACHED'

fixture finish-extra
EXTRA='root-owned 0 drift none'
run_lib 'GATED="by hand"; finish abc1234'
contains 'a project adds its own facts to DONE' "${OUT}" \
    "DONE #73 live abc1234 was ${LIVE_SHORT} gated by hand root-owned 0 drift none log "

if [ "${fails}" -eq 0 ]; then
    printf '\ndeploy-lib-test: all checks passed\n'
    exit 0
fi
printf '\ndeploy-lib-test: %s check(s) failed\n' "${fails}" >&2
exit 1
