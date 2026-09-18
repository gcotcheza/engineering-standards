# fleet-deploy-lib 2026-09-18 sha256:b1073ff2ca5ad5f255b2dbe7fab379c8435deb4b7a2151c95544f1103e659368
# shellcheck shell=bash
# say prints one summary line on stdout and in the log; detail goes to the log alone.
# The caller sets ROOT, PR, BEFORE and GATED before deploy_log_open opens fd 3.

say()    { printf '%s\n' "$*" >&3; printf '%s\n' "$*"; }
detail() { printf '%s\n' "$*"; }
refuse() { say "REFUSED: $*"; exit 1; }

deploy_log_open() {
    local dir
    dir=${DEPLOY_LOG_DIR:-${DEPLOY_LOG_ROOT:-/root/personal-vps-deploys}/$(basename "$ROOT")}
    mkdir -p "$dir" || { printf 'deploy.sh: cannot write logs to %s\n' "$dir" >&2; exit 1; }
    LOG="$dir/$(date -u +%Y%m%dT%H%M%SZ)-pr$1.log"
    exec 3>&1
    exec >>"$LOG" 2>&1
}

fail_tail() {
    say "$1 FAILED rc=$2 — the last 20 lines of $LOG:"
    tail -20 "$LOG" >&3
}

finish() {
    say "DONE #$PR live $1 was $BEFORE gated $GATED${EXTRA_DONE:+ $EXTRA_DONE} log $LOG"
    say "PAPERWORK PR #$PR deployed $(date -u +%FT%TZ) live $1 was $BEFORE gated $GATED — backlog and handoff"
    exit 0
}
