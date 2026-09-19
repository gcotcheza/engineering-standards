#!/usr/bin/env bash
# Fakes only: a fake backlog, owners file, registries, budget script, systemctl
# and heavy-work drive the real scripts/queue-start.sh and
# scripts/backlog-owners-lint.py through their seams. No tmux, no delivery, no
# real backlog. QUEUE_START_SH / OWNERS_LINT_PY point at scratch copies for the
# red proofs.
#
#   scripts/queue-start-test.sh
#   QUEUE_START_SH=/tmp/mutant.sh scripts/queue-start-test.sh   the red proofs
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${QUEUE_START_SH:-${SCRIPT_DIR}/queue-start.sh}"
LINT="${OWNERS_LINT_PY:-${SCRIPT_DIR}/backlog-owners-lint.py}"

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals()   { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
matches()  { if printf '%s' "$2" | grep -qE "$3"; then pass "$1"; else fail "$1 — [$2] does not match /$3/"; fi; }
contains() { if printf '%s' "$2" | grep -qF "$3"; then pass "$1"; else fail "$1 — [$2] does not contain [$3]"; fi; }
lacks()    { if printf '%s' "$2" | grep -qF "$3"; then fail "$1 — [$2] must not contain [$3]"; else pass "$1"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "${WORK}/reg"

cat >"${WORK}/backlog.md" <<'MD'
## Waiting on your answer
<details><summary><b>90.</b> Something for Ghie</summary>x</details>
## Queued work (nothing for you)
<details><summary><b>71.</b> Alpha item</summary>x</details>
<details><summary><b>72.</b> Beta item</summary>x</details>
<details><summary><b>33.</b> Gamma item</summary>x</details>
<details><summary><b>69.</b> Delta item</summary>x</details>
## Recently decided
<details><summary><b>12.</b> Old item</summary>x</details>
MD

cat >"${WORK}/owners" <<'OWN'
# item session [hold]
71 advisor
72 personal-vps
33 advisor
69 kidsquest hold
OWN

printf 'ghiecode        advisor:0.0\nscribly         claude:0.0\n' >"${WORK}/app-owners"

cat >"${WORK}/budget" <<'SH'
#!/usr/bin/env bash
cat "$(dirname "$0")/budget-out"
grep -q '^ok ' "$(dirname "$0")/budget-out" && exit 0
exit 1
SH
printf 'ok 5h 10%%/50 week-all 20%%/60 week-fable 30%%/60\n' >"${WORK}/budget-out"

cat >"${WORK}/systemctl" <<'SH'
#!/usr/bin/env bash
[ -f "$(dirname "$0")/deploy-active" ] || exit 0
for a in "$@"; do case "$a" in *-deploy-*) grep -F "${a%-\*}" "$(dirname "$0")/deploy-active" >/dev/null && echo "${a%\*}1234.service loaded active running deploy" ;; esac; done
exit 0
SH

cat >"${WORK}/heavy-work" <<'SH'
#!/usr/bin/env bash
d="$(dirname "$0")"
[ "${1:-}" = --status ] && cat "$d/heavy-status" 2>/dev/null
exit 0
SH
chmod 755 "${WORK}/budget" "${WORK}/systemctl" "${WORK}/heavy-work"

# The real `--status` when both slots are free: the `last:` lines are the job
# that finished, not a held slot.
cat >"${WORK}/heavy-status-free" <<'ST'
free
  last: label=memento-album-e2e
  last: session=advisor
  last: slot=both
ST
cp "${WORK}/heavy-status-free" "${WORK}/heavy-status"

: >"${WORK}/reg/advisor-workers.active"
: >"${WORK}/reg/personal-vps-workers.active"
: >"${WORK}/reg/kidsquest-workers.active"

run() {
    OUT="$(QS_OWNERS="${WORK}/owners" QS_BACKLOG="${WORK}/backlog.md" \
        QS_STATE="${WORK}/state" QS_REGISTRY_DIR="${WORK}/reg" \
        QS_BUDGET_SH="${WORK}/budget" QS_APP_OWNERS="${WORK}/app-owners" \
        QS_SYSTEMCTL="${WORK}/systemctl" QS_HEAVY_WORK="${WORK}/heavy-work" \
        QS_LOCK="${WORK}/lock" QS_ALLOW_ANY_PATH=1 \
        "${CHECK}" "$@" 2>&1)"
    RC=$?
}

SENT_A='[queue-start automation] budget ok (5h 10%/50 week-all 20%/60 week-fable 30%/60): next queued item for advisor is 71 — Alpha item. Start it by your rules, or mark it hold in /root/backlog-owners.'
SENT_P='[queue-start automation] budget ok (5h 10%/50 week-all 20%/60 week-fable 30%/60): next queued item for personal-vps is 72 — Beta item. Start it by your rules, or mark it hold in /root/backlog-owners.'

# --- 1. the happy tick: one sentence per idle session, right pane --------------
run --dry-run
contains 'case 1: advisor gets the exact sentence' "${OUT}" "${SENT_A}"
contains 'case 1: personal-vps gets the exact sentence' "${OUT}" "${SENT_P}"
matches  'case 1: advisor pane' "${OUT}" 'dry-run advisor: pane advisor:0\.0'
matches  'case 1: personal-vps pane is claude:0.0' "${OUT}" 'dry-run personal-vps: pane claude:0\.0'
equals   'case 1: exit code' "${RC}" 0
equals   'case 1: no state written by a dry run' "$( [ -e "${WORK}/state" ] && echo yes || echo no)" no

# --- 2. a busy session (non-empty registry) is skipped ------------------------
printf 'opus5-worker pid 1234\n' >"${WORK}/reg/advisor-workers.active"
run --dry-run
matches 'case 2: a non-empty registry skips the session' "${OUT}" 'skip advisor: a builder is listed'
lacks   'case 2: and nothing is said to it' "${OUT}" "${SENT_A}"
: >"${WORK}/reg/advisor-workers.active"

# --- 3. a session that keeps no registry file is not idle ---------------------
printf '69 orbit\n' >>"${WORK}/owners"
run --dry-run
matches 'case 3: a missing registry file skips the session' "${OUT}" 'skip orbit: no readable registry file'
sed -i '/^69 orbit$/d' "${WORK}/owners"

# --- 4. a deploy unit active for one of the session's apps -> skipped ---------
printf 'ghiecode-deploy\n' >"${WORK}/deploy-active"
run --dry-run
matches 'case 4: an active deploy unit skips the session' "${OUT}" 'skip advisor: a deploy unit is active for ghiecode'
lacks   'case 4: and nothing is said to it' "${OUT}" "${SENT_A}"
rm -f "${WORK}/deploy-active"

# --- 5. heavy-work: the real HELD form skips, the real free form does not ------
cat >"${WORK}/heavy-status" <<'ST'
HELD, 2 queued behind:
slot 1:
  label=orbit-e2e-leaving
  pid=1354481
  since=2026-09-19T13:41:56+00:00
  session=advisor
  cmd=bash scripts/e2e.sh
  slot=both
ST
run --dry-run
matches 'case 5: the real HELD form skips the session' "${OUT}" 'skip advisor: heavy-work holds a slot'
lacks   'case 5: and nothing is said to it' "${OUT}" "${SENT_A}"

cp "${WORK}/heavy-status-free" "${WORK}/heavy-status"
run --dry-run
contains 'case 5b: `free` plus `last: session=advisor` is not a held slot' "${OUT}" "${SENT_A}"
lacks    'case 5b: and the session is not called busy' "${OUT}" 'skip advisor: heavy-work holds a slot'

# --- 6. the top item announced within 24h -> silence, NEVER the next one down -
printf '71 advisor %s\n' "$(date +%s)" >"${WORK}/state"
run --dry-run
matches 'case 6: a deduped top item skips the session' "${OUT}" 'skip advisor: item 71 was announced within'
lacks   'case 6: no walk-down to item 33' "${OUT}" 'is 33'
rm -f "${WORK}/state"

# --- 7. an entry older than 24h is announced again ----------------------------
printf '71 advisor %s\n' "$(( $(date +%s) - 90000 ))" >"${WORK}/state"
run --dry-run
contains 'case 7: an entry older than 24h speaks again' "${OUT}" "${SENT_A}"
rm -f "${WORK}/state"

# --- 8. the session's top item is marked hold -> silence ----------------------
matches 'case 8: a held top item skips the session' "$(run --dry-run; printf '%s' "${OUT}")" 'skip kidsquest: its top item 69 is marked hold'

# --- 9. budget hold -> one reason, nothing to anybody -------------------------
printf 'hold week-all meter 67%% is at or above its cap 60\n' >"${WORK}/budget-out"
run --dry-run
matches 'case 9: the hold reason is logged once' "${OUT}" 'budget says no: hold week-all meter 67%'
equals  'case 9: exactly one budget line' "$(printf '%s\n' "${OUT}" | grep -c 'budget says no')" 1
lacks   'case 9: and no session is told anything' "${OUT}" 'next queued item'
printf 'ok 5h 10%%/50 week-all 20%%/60 week-fable 30%%/60\n' >"${WORK}/budget-out"

# --- 10. --once names one session only ----------------------------------------
run --dry-run --once personal-vps
contains 'case 10: --once speaks to the named session' "${OUT}" "${SENT_P}"
lacks    'case 10: and to nobody else' "${OUT}" 'for advisor'

# --- 10b. lines parked with `hold` in the session column name no session ----
printf '33 hold\n' >>"${WORK}/owners"
run --dry-run
matches 'case 10b: parked lines are skipped by name' "${OUT}" 'skip the parked lines: they name no session'
lacks   'case 10b: and are never called an unknown session' "${OUT}" 'unknown session [hold]'
sed -i '/^33 hold$/d' "${WORK}/owners"

# --- 11. the owners lint ------------------------------------------------------
lint() { LOUT="$("${LINT}" "${WORK}/backlog.md" "$1" 2>&1)"; LRC=$?; }

cat >"${WORK}/owners-good" <<'OWN'
71 advisor
72 personal-vps
33 advisor
69 kidsquest hold
OWN
lint "${WORK}/owners-good"
matches 'case 11a: a complete owners file is green' "${LOUT}" 'all owned'
equals  'case 11a: exit code' "${LRC}" 0

grep -v '^33 ' "${WORK}/owners-good" >"${WORK}/owners-missing"
lint "${WORK}/owners-missing"
matches 'case 11b: a queued item with no owner is red, by number' "${LOUT}" 'queued items with no owners line: 33'
equals  'case 11b: exit code' "${LRC}" 1

sed 's/^33 advisor/33 nosuchsession/' "${WORK}/owners-good" >"${WORK}/owners-badsession"
lint "${WORK}/owners-badsession"
matches 'case 11c: an unknown session is red' "${LOUT}" "item 33 names unknown session 'nosuchsession'"
equals  'case 11c: exit code' "${LRC}" 1

{ cat "${WORK}/owners-good"; printf '404 advisor\n'; } >"${WORK}/owners-ghost"
lint "${WORK}/owners-ghost"
matches 'case 11d: an item that is not in the backlog is red' "${LOUT}" 'item 404 is not in the backlog'

{ cat "${WORK}/owners-good"; printf 'advisor 33 please\n'; } >"${WORK}/owners-malformed"
lint "${WORK}/owners-malformed"
matches 'case 11e: a malformed line is red' "${LOUT}" 'line 5: not .<item> <session> \[hold\].'

if [ "${fails}" -eq 0 ]; then
    printf '\nqueue-start-test: all checks passed\n'
    exit 0
fi
printf '\nqueue-start-test: %s check(s) failed\n' "${fails}" >&2
exit 1
