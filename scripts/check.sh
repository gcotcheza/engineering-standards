#!/usr/bin/env bash
# The repo's own gate. Cheapest first (T3), in measured cost order — the measurement,
# the pairs that sit within noise of each other, and the step that outgrew its old slot
# are in docs/DECISIONS.md. Re-measure before reordering.
#   1) bash -n on every tracked .sh file, then fleet-lint-guard-diff over scripts/ and a
#      canary it must flag — a missing lint is a loud failure, never a skip (C9)
#   2) scripts/version-text-pair.sh and its own test — VERSION and
#      ENGINEERING-STANDARDS.md move together, or neither moves — then
#      scripts/deploy-lib-version.sh and its test (a lib change raises the lib's
#      VERSION), W7's decisions-check.sh on this tree, the W4 closing-line test, and
#      S1's scripts/hook-bypass-scan.sh on this tree and its own test
#   3) scripts/guard-mutants-test.sh, the T5 guard-mutant runner's own test
#   4) scripts/fleet-versions-test.sh, the fleet check's own test
#   5) scripts/fleet-budget-test.sh, the budget gate's own test
#   6) scripts/queue-start-test.sh, the queue tick's and the owners lint's test
#   7) shellcheck, style severity, in the pinned image — a missing image is a
#      loud failure here, never a silent skip (C9)
#   8) scripts/gate-image-tags-test.sh, the T9 image-tag check's own test
#   9) the vendored deploy library's own test.sh (scripts/lib/deploy/test.sh), twice: from
#      this tree, then from a copy owned by nobody, as an app's ci.sh runs it
#  10) scripts/decisions-check-test.sh and decisions-rollup-test.sh, W7's fixtures
#  11) scripts/gate-run-test.sh, gate-run.sh's planted attacks, against a throwaway repo and a fake docker
#
#   scripts/check.sh            all eleven steps; records a FULL run to the fleet ledger
#   scripts/check.sh --only N   step N alone, for debugging — a partial run,
#                                so nothing is recorded (the ledger only hears
#                                about a full gate run)
#
# A row names the commit the run was armed on; if HEAD moved under the gate, or the
# gate never armed, nothing is recorded and the run says so.
# Prints === GATE OK === or === GATE FAILED (step N: name) ===, exit 0/1.
# CHECK_GIT and GATE_LEDGER are scripts/lib/deploy/ledger.sh's own seams.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# Every step and the ledger stamp read the repo, never the caller's directory.
cd -- "${REPO_ROOT}" || exit 2
GIT=${CHECK_GIT:-git}
SHELLCHECK_IMAGE='koalaman/shellcheck:v0.10.0'
GUARD_DIFF_LINT='/usr/local/sbin/fleet-lint-guard-diff'

# scripts/lib/deploy/ is read read-only here (sourcing the ledger is fine; the
# gate never writes under it) — see docs/DECISIONS.md.
# shellcheck source=scripts/lib/deploy/ledger.sh
. "${SCRIPT_DIR}/lib/deploy/ledger.sh"
GATE_LEDGER_GIT="${GIT}"
# The commit this run judges, pinned before step 1 can move it.
gate_ledger_arm

step_name() {
    case "$1" in
        1) printf 'bash -n, guard-diff lint' ;;
        2) printf 'version-text-pair' ;;
        3) printf 'guard-mutants-test.sh' ;;
        4) printf 'fleet-versions-test.sh' ;;
        5) printf 'fleet-budget-test.sh' ;;
        6) printf 'queue-start-test.sh' ;;
        7) printf 'shellcheck' ;;
        8) printf 'gate-image-tags-test.sh' ;;
        9) printf 'deploy-lib test.sh' ;;
        10) printf 'decisions tests' ;;
        11) printf 'gate-run-test.sh' ;;
    esac
}

FULL_RUN=1
ONLY=0
case "${1:-}" in
    "") ;;
    --only)
        case "${2:-}" in 1|2|3|4|5|6|7|8|9|10|11) ONLY=$2; FULL_RUN=0 ;; *) echo "usage: check.sh [--only N]  (N is 1 to 11)" >&2; exit 2 ;; esac ;;
    *) echo "usage: check.sh [--only N]  (N is 1 to 11)" >&2; exit 2 ;;
esac

# Invoked by the EXIT trap only, which shellcheck cannot follow (SC2317).
# shellcheck disable=SC2317
cleanup() {
    local code=$?
    [ -z "${APP_OWNED_LIB:-}" ] || rm -rf -- "${APP_OWNED_LIB}"
    if [ "${FULL_RUN}" -eq 1 ]; then
        gate_ledger_record ci "${code}" -
    else
        printf 'gate-ledger: a partial run (--only) records nothing\n' >&2
    fi
    exit "${code}"
}
trap cleanup EXIT

fail_step() {
    printf '=== GATE FAILED (step %s: %s) ===\n' "$1" "$(step_name "$1")" >&2
    exit 1
}

run_step() {
    [ "${FULL_RUN}" -eq 1 ] || [ "${ONLY}" -eq "$1" ] || return 0
    printf -- '--- step %s: %s ---\n' "$1" "$(step_name "$1")"
    case "$1" in 1) step_1 ;; 2) step_2 ;; 3) step_3 ;; 4) step_4 ;; 5) step_5 ;; 6) step_6 ;; 7) step_7 ;; 8) step_8 ;; 9) step_9 ;; 10) step_10 ;; 11) step_11 ;; esac
}

step_1() {
    local f
    while IFS= read -r f; do
        bash -n "$f" || fail_step 1
    done < <("${GIT}" ls-files '*.sh')
    if [ ! -x "${GUARD_DIFF_LINT}" ]; then
        printf '%s is missing or not executable — refusing to treat a skipped lint as a pass (C9).\n' "${GUARD_DIFF_LINT}" >&2
        fail_step 1
    fi
    "${GUARD_DIFF_LINT}" scripts || fail_step 1
    local canary_file canary rc
    canary_file=$(mktemp --suffix=.sh) || fail_step 1
    printf 'git %s HEAD\n' diff >"${canary_file}"
    canary=$("${GUARD_DIFF_LINT}" "${canary_file}" 2>&1)
    rc=$?
    rm -f -- "${canary_file}"
    if [ "${rc}" -ne 1 ] || [[ ${canary} != *'--no-ext-diff'* ]]; then
        printf 'the guard-diff lint passed a bare diff call (exit %s), so its green on scripts/ says nothing.\n%s\n' "${rc}" "${canary}" >&2
        fail_step 1
    fi
}

step_2() {
    VERSION_PAIR_GIT="${GIT}" "${REPO_ROOT}/scripts/version-text-pair.sh" "${REPO_ROOT}" || fail_step 2
    "${REPO_ROOT}/scripts/version-text-pair-test.sh" || fail_step 2
    DEPLOY_LIB_VERSION_GIT="${GIT}" "${REPO_ROOT}/scripts/deploy-lib-version.sh" "${REPO_ROOT}" || fail_step 2
    "${REPO_ROOT}/scripts/deploy-lib-version-test.sh" || fail_step 2
    DECISIONS_GIT="${GIT}" bash "${REPO_ROOT}/scripts/decisions-check.sh" "${REPO_ROOT}" || fail_step 2
    bash "${REPO_ROOT}/scripts/w4-closing-line-test.sh" || fail_step 2
    # The prose names the routes; the two mutant tables are test data that rewrite the root gate's env -i lines.
    HOOK_BYPASS_GIT="${GIT}" bash "${REPO_ROOT}/scripts/hook-bypass-scan.sh" "${REPO_ROOT}" CHANGELOG.md ENGINEERING-STANDARDS.md ROLLOUT.md \
        scripts/gate-run-mutants.txt scripts/gate-run-lib-run-mutants.txt || fail_step 2
    bash "${REPO_ROOT}/scripts/hook-bypass-scan-test.sh" || fail_step 2
}

step_3() {
    bash "${REPO_ROOT}/scripts/guard-mutants-test.sh" || fail_step 3
}

step_4() {
    "${REPO_ROOT}/scripts/fleet-versions-test.sh" || fail_step 4
}

step_5() {
    "${REPO_ROOT}/scripts/fleet-budget-test.sh" || fail_step 5
}

step_6() {
    "${REPO_ROOT}/scripts/queue-start-test.sh" || fail_step 6
}

step_7() {
    if ! docker image inspect "${SHELLCHECK_IMAGE}" >/dev/null 2>&1; then
        printf 'shellcheck image %s is not present on this box — refusing to treat a missing image as a pass (C9).\n' \
            "${SHELLCHECK_IMAGE}" >&2
        fail_step 7
    fi
    local files
    files=$("${GIT}" ls-files '*.sh')
    [ -n "${files}" ] || return 0
    # shellcheck disable=SC2086
    docker run --rm --network none -v "${REPO_ROOT}:/mnt:ro" -w /mnt \
        "${SHELLCHECK_IMAGE}" --severity=style ${files} || fail_step 7
}

step_8() {
    "${REPO_ROOT}/scripts/gate-image-tags-test.sh" || fail_step 8
}

step_9() {
    "${REPO_ROOT}/scripts/lib/deploy/test.sh" || fail_step 9
    # An app vendors the lib into a tree it owns; a case that sources it in place is refused there.
    APP_OWNED_LIB=$(mktemp -d -p /srv/worker-scratch deploy-lib-app-owned.XXXXXXXX) || fail_step 9
    chmod 755 -- "${APP_OWNED_LIB}" || fail_step 9
    # A lane with no PR carries the label form the scratch lint accepts (card 537).
    printf 'kind=lane\ncard=537\nowner=%s\n' "${FLEET_SCRATCH_OWNER:-pv}" >"${APP_OWNED_LIB}/.fleet-scratch" || fail_step 9
    if [ "$(cat -- "${APP_OWNED_LIB}/.fleet-scratch" 2>&1)" != $'kind=lane\ncard=537\nowner='"${FLEET_SCRATCH_OWNER:-pv}" ]; then
        printf 'the app-owned copy of the deploy lib does not carry the kind=lane label, so the scratch lint would refuse it.\n' >&2
        fail_step 9
    fi
    cp -r -- "${REPO_ROOT}/scripts/lib/deploy" "${APP_OWNED_LIB}/deploy" || fail_step 9
    chown -R nobody: -- "${APP_OWNED_LIB}/deploy" || fail_step 9
    chmod -R a-w -- "${APP_OWNED_LIB}/deploy" || fail_step 9
    if [ "$(stat -c %U "${APP_OWNED_LIB}/deploy/summary.sh")" != nobody ]; then
        printf 'the app-owned copy of the deploy lib is not owned by nobody, so its run proves nothing.\n' >&2
        fail_step 9
    fi
    printf -- '--- step 9: deploy-lib test.sh again, from %s/deploy (owner nobody, DEPLOY_LIB_DIR unset) ---\n' "${APP_OWNED_LIB}"
    env -u DEPLOY_LIB_DIR bash "${APP_OWNED_LIB}/deploy/test.sh" || fail_step 9
}

step_10() {
    bash "${REPO_ROOT}/scripts/decisions-check-test.sh" || fail_step 10
    bash "${REPO_ROOT}/scripts/decisions-rollup-test.sh" || fail_step 10
}

step_11() {
    bash "${REPO_ROOT}/scripts/gate-run-test.sh" || fail_step 11
}

for n in 1 2 3 4 5 6 7 8 9 10 11; do run_step "${n}"; done

# shellcheck disable=SC2034  # the EXIT trap's gate_ledger_record reads it
GATE_SUITE_PASSED=1

printf '=== GATE OK ===\n'
exit 0
