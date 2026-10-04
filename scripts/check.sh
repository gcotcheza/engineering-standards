#!/usr/bin/env bash
# The repo's own gate. Cheapest first (T3), in measured cost order — the measurement,
# the pairs that sit within noise of each other, and the step that outgrew its old slot
# are in docs/DECISIONS.md. Re-measure before reordering.
#   1) bash -n on every tracked .sh file, then fleet-lint-guard-diff over scripts/ and a
#      canary it must flag — a missing lint is a loud failure, never a skip (C9)
#   2) scripts/version-text-pair.sh and its own test — VERSION and
#      ENGINEERING-STANDARDS.md move together, or neither moves
#   3) scripts/fleet-versions-test.sh, the fleet check's own test
#   4) scripts/fleet-budget-test.sh, the budget gate's own test
#   5) scripts/queue-start-test.sh, the queue tick's and the owners lint's test
#   6) shellcheck, style severity, in the pinned image — a missing image is a
#      loud failure here, never a silent skip (C9)
#   7) scripts/gate-image-tags-test.sh, the T9 image-tag check's own test
#   8) scripts/guard-mutants-test.sh, the T5 mutation runner's own test (as nobody when root)
#   9) the vendored deploy library's own test.sh (scripts/lib/deploy/test.sh)
#
#   scripts/check.sh            all nine steps; records a FULL run to the fleet ledger
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
        3) printf 'fleet-versions-test.sh' ;;
        4) printf 'fleet-budget-test.sh' ;;
        5) printf 'queue-start-test.sh' ;;
        6) printf 'shellcheck' ;;
        7) printf 'gate-image-tags-test.sh' ;;
        8) printf 'guard-mutants-test.sh' ;;
        9) printf 'deploy-lib test.sh' ;;
    esac
}

FULL_RUN=1
ONLY=0
case "${1:-}" in
    "") ;;
    --only)
        case "${2:-}" in 1|2|3|4|5|6|7|8|9) ONLY=$2; FULL_RUN=0 ;; *) echo "usage: check.sh [--only N]  (N is 1 to 9)" >&2; exit 2 ;; esac ;;
    *) echo "usage: check.sh [--only N]  (N is 1 to 9)" >&2; exit 2 ;;
esac

# Invoked by the EXIT trap only, which shellcheck cannot follow (SC2317).
# shellcheck disable=SC2317
cleanup() {
    local code=$?
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
    case "$1" in 1) step_1 ;; 2) step_2 ;; 3) step_3 ;; 4) step_4 ;; 5) step_5 ;; 6) step_6 ;; 7) step_7 ;; 8) step_8 ;; 9) step_9 ;; esac
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
}

step_3() {
    "${REPO_ROOT}/scripts/fleet-versions-test.sh" || fail_step 3
}

step_4() {
    "${REPO_ROOT}/scripts/fleet-budget-test.sh" || fail_step 4
}

step_5() {
    "${REPO_ROOT}/scripts/queue-start-test.sh" || fail_step 5
}

step_6() {
    if ! docker image inspect "${SHELLCHECK_IMAGE}" >/dev/null 2>&1; then
        printf 'shellcheck image %s is not present on this box — refusing to treat a missing image as a pass (C9).\n' \
            "${SHELLCHECK_IMAGE}" >&2
        fail_step 6
    fi
    local files
    files=$("${GIT}" ls-files '*.sh')
    [ -n "${files}" ] || return 0
    # shellcheck disable=SC2086
    docker run --rm --network none -v "${REPO_ROOT}:/mnt:ro" -w /mnt \
        "${SHELLCHECK_IMAGE}" --severity=style ${files} || fail_step 6
}

step_7() {
    "${REPO_ROOT}/scripts/gate-image-tags-test.sh" || fail_step 7
}

# The suite refuses root (rule 26), so a root gate runs it as nobody in a dir nobody owns.
step_8() {
    [ "$(id -u)" -eq 0 ] || { "${REPO_ROOT}/scripts/guard-mutants-test.sh" || fail_step 8; return; }
    gm_dir=$(mktemp -d -p "${GUARD_MUTANTS_TEST_DIR:-/srv/worker-scratch}" guard-mutants-gate.XXXXXXXX) || fail_step 8
    chown nobody:nogroup "${gm_dir}" \
        && (cd -- "${gm_dir}" && GUARD_MUTANTS_TEST_DIR=${gm_dir} setpriv --reuid=nobody --regid=nogroup --clear-groups \
            "${REPO_ROOT}/scripts/guard-mutants-test.sh")
    gm_rc=$?
    rm -rf -- "${gm_dir:?}"
    [ "${gm_rc}" -eq 0 ] || fail_step 8
}

step_9() {
    "${REPO_ROOT}/scripts/lib/deploy/test.sh" || fail_step 9
}

for n in 1 2 3 4 5 6 7 8 9; do run_step "${n}"; done

# shellcheck disable=SC2034  # the EXIT trap's gate_ledger_record reads it
GATE_SUITE_PASSED=1

printf '=== GATE OK ===\n'
exit 0
