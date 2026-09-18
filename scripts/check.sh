#!/usr/bin/env bash
# The repo's own gate — cheapest checks first (T3):
#   1) bash -n on every tracked .sh file
#   2) shellcheck, style severity, in the pinned image — a missing image is a
#      loud failure here, never a silent skip (C9)
#   3) the vendored deploy library's own test.sh (scripts/lib/deploy/test.sh)
#   4) scripts/fleet-versions-test.sh, the fleet check's own test
#
#   scripts/check.sh            all four steps; records a FULL run to the fleet ledger
#   scripts/check.sh --only N   step N alone, for debugging — a partial run,
#                                so nothing is recorded (the ledger only hears
#                                about a full gate run)
#
# Prints === GATE OK === or === GATE FAILED (step N: name) ===, exit 0/1.
# CHECK_GIT and GATE_LEDGER are scripts/lib/deploy/ledger.sh's own seams.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
GIT=${CHECK_GIT:-git}
SHELLCHECK_IMAGE='koalaman/shellcheck:v0.10.0'

# scripts/lib/deploy/ is read read-only here (sourcing the ledger is fine; the
# gate never writes under it) — see docs/DECISIONS.md.
# shellcheck source=scripts/lib/deploy/ledger.sh
. "${SCRIPT_DIR}/lib/deploy/ledger.sh"
GATE_LEDGER_GIT="${GIT}"

step_name() {
    case "$1" in
        1) printf 'bash -n' ;;
        2) printf 'shellcheck' ;;
        3) printf 'deploy-lib test.sh' ;;
        4) printf 'fleet-versions-test.sh' ;;
    esac
}

FULL_RUN=1
ONLY=0
case "${1:-}" in
    "") ;;
    --only) ONLY=${2:?"--only needs a step number"}; FULL_RUN=0 ;;
    *) echo "usage: check.sh [--only N]" >&2; exit 2 ;;
esac

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
    "step_$1"
}

step_1() {
    local f
    while IFS= read -r f; do
        bash -n "$f" || fail_step 1
    done < <(cd "${REPO_ROOT}" && "${GIT}" ls-files '*.sh')
}

step_2() {
    if ! docker image inspect "${SHELLCHECK_IMAGE}" >/dev/null 2>&1; then
        printf 'shellcheck image %s is not present on this box — refusing to treat a missing image as a pass (C9).\n' \
            "${SHELLCHECK_IMAGE}" >&2
        fail_step 2
    fi
    local files
    files=$(cd "${REPO_ROOT}" && "${GIT}" ls-files '*.sh')
    [ -n "${files}" ] || return 0
    # shellcheck disable=SC2086
    docker run --rm --network none -v "${REPO_ROOT}:/mnt:ro" -w /mnt \
        "${SHELLCHECK_IMAGE}" --severity=style ${files} || fail_step 2
}

step_3() {
    "${REPO_ROOT}/scripts/lib/deploy/test.sh" || fail_step 3
}

step_4() {
    "${REPO_ROOT}/scripts/fleet-versions-test.sh" || fail_step 4
}

for n in 1 2 3 4; do run_step "${n}"; done

printf '=== GATE OK ===\n'
exit 0
