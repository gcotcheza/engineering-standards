#!/usr/bin/env bash
# Fakes only: a fake backlog, owners file, registries, budget script, systemctl
# and heavy-work drive the real scripts/queue-start.sh and
# scripts/backlog-owners-lint.py through their seams. No tmux, no delivery, no
# real backlog. QUEUE_START_SH / OWNERS_LINT_PY / DIALOG_LIB_SH point at scratch
# copies for the red proofs.
#
#   scripts/queue-start-test.sh
#   QUEUE_START_SH=/tmp/mutant.sh scripts/queue-start-test.sh   the red proofs
#   scripts/guard-mutants.sh scripts/queue-start.sh scripts/queue-start-mutants.txt   T5's sweep
#   scripts/guard-mutants.sh scripts/backlog-owners-lint.py scripts/backlog-owners-lint-mutants.txt
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${QUEUE_START_SH:-${SCRIPT_DIR}/queue-start.sh}"
LINT="${OWNERS_LINT_PY:-${SCRIPT_DIR}/backlog-owners-lint.py}"
DLIB="${DIALOG_LIB_SH:-${SCRIPT_DIR}/lib/dialog-lib.sh}"

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

# Column order, the leading ● and the --state=active filtering are copied from
# this box's real `systemctl list-units --all --no-legend`.
cat >"${WORK}/systemctl" <<'SH'
#!/usr/bin/env bash
d="$(dirname "$0")"
rc="$(cat "$d/systemctl-rc" 2>/dev/null || echo 0)"
[ "$rc" = 0 ] || exit "$rc"
args=" $* "
[ -f "$d/deploy-units" ] || exit 0
while read -r app active; do
    [ -n "${app:-}" ] || continue
    case "$args" in *" $app-deploy-"*) ;; *) continue ;; esac
    case "$args" in *" --state=active "*) [ "$active" = active ] || continue ;; esac
    case "$active" in failed|not-found) printf '\xe2\x97\x8f ' ;; *) printf '  ' ;; esac
    printf '%s-deploy-pr80.service loaded %s start Deploy %s\n' "$app" "$active" "$app"
done <"$d/deploy-units"
exit 0
SH

cat >"${WORK}/heavy-work" <<'SH'
#!/usr/bin/env bash
d="$(dirname "$0")"
[ "${1:-}" = --status ] || exit 2
cat "$d/heavy-status" 2>/dev/null
exit "$(cat "$d/heavy-rc" 2>/dev/null || echo 0)"
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
        QS_STATE="${STATE_FILE:-${WORK}/state}" QS_REGISTRY_DIR="${WORK}/reg" \
        QS_BUDGET_SH="${WORK}/budget" QS_APP_OWNERS="${WORK}/app-owners" \
        QS_SYSTEMCTL="${SYSTEMCTL_BIN:-${WORK}/systemctl}" \
        QS_HEAVY_WORK="${HEAVY_BIN:-${WORK}/heavy-work}" \
        QS_LOCK="${WORK}/lock" QS_ALLOW_ANY_PATH=1 QS_DIALOG_LIB="${QS_LIB:-${DLIB}}" \
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

# --- 4. a deploy unit for one of the session's apps -> skipped ----------------
printf 'ghiecode active\n' >"${WORK}/deploy-units"
run --dry-run
matches 'case 4: an active deploy unit skips the session' "${OUT}" 'skip advisor: a deploy unit is active for ghiecode'
lacks   'case 4: and nothing is said to it' "${OUT}" "${SENT_A}"

printf 'ghiecode activating\n' >"${WORK}/deploy-units"
run --dry-run
matches 'case 4b: an activating deploy unit skips the session' "${OUT}" 'skip advisor: a deploy unit is active for ghiecode'
lacks   'case 4b: and nothing is said to it' "${OUT}" "${SENT_A}"

printf 'ghiecode deactivating\n' >"${WORK}/deploy-units"
run --dry-run
matches 'case 4c: a deactivating deploy unit skips the session' "${OUT}" 'skip advisor: a deploy unit is active for ghiecode'

printf 'ghiecode inactive\n' >"${WORK}/deploy-units"
run --dry-run
contains 'case 4d: an inactive unit listed by --all is not busy' "${OUT}" "${SENT_A}"

printf 'ghiecode failed\n' >"${WORK}/deploy-units"
run --dry-run
contains 'case 4e: a failed unit behind the ● marker is not busy' "${OUT}" "${SENT_A}"

SYSTEMCTL_BIN="${WORK}/no-such-systemctl" run --dry-run
matches 'case 4f: a missing systemctl is busy, not idle' "${OUT}" 'skip advisor: systemctl could not be asked about ghiecode \(exit 127\)'
lacks   'case 4f: and nothing is said to it' "${OUT}" "${SENT_A}"

printf '7\n' >"${WORK}/systemctl-rc"
run --dry-run
matches 'case 4g: a failing systemctl is busy, not idle' "${OUT}" 'skip advisor: systemctl could not be asked about ghiecode \(exit 7\)'
rm -f "${WORK}/systemctl-rc" "${WORK}/deploy-units"

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
contains 'case 5b: a free status whose last: line names the session is not a held slot' "${OUT}" "${SENT_A}"
lacks    'case 5b: and the session is not called busy' "${OUT}" 'skip advisor: heavy-work holds a slot'

printf '3\n' >"${WORK}/heavy-rc"
run --dry-run
matches 'case 5c: a failing heavy-work is busy, not idle' "${OUT}" 'skip advisor: heavy-work could not be asked \(exit 3\)'
lacks   'case 5c: and nothing is said to it' "${OUT}" "${SENT_A}"
rm -f "${WORK}/heavy-rc"

HEAVY_BIN="${WORK}/no-such-heavy-work" run --dry-run
matches 'case 5d: a missing heavy-work is busy, not idle' "${OUT}" 'skip advisor: heavy-work could not be asked \(exit 127\)'
lacks   'case 5d: and nothing is said to it' "${OUT}" "${SENT_A}"

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

# --- 10c. a dry run creates neither the state file nor its directory ----------
STATE_FILE="${WORK}/nodir/state" run --dry-run
equals 'case 10c: a dry run creates no state directory' "$( [ -e "${WORK}/nodir" ] && echo yes || echo no)" no

# --- 10d. a state file that exists but cannot be read says so -----------------
ln -s "${WORK}/nowhere" "${WORK}/dangling"
STATE_FILE="${WORK}/dangling" run --dry-run
matches 'case 10d: an unreadable state file is logged' "${OUT}" 'state file .*dangling exists but cannot be read'
rm -f "${WORK}/dangling"

# --- 10e/10f. a busy pane: our sentence stays queued, a foreign line does not -
# Real (non-dry-run) delivery through a fake tmux: capture-pane/send-keys/
# display-message are faked; the row never empties, only its content differs.
mkdir -p "${WORK}/bin" "${WORK}/tmuxstate"
cat >"${WORK}/bin/tmux" <<'SH'
#!/usr/bin/env bash
d="${FAKE_TMUX_DIR:?}"
shift; shift; sub="$1"; shift
mode="$(cat "$d/mode" 2>/dev/null || echo idle)"
case "$sub" in
  capture-pane)
    case "$mode" in
      busy)    [ -s "$d/typed" ] && printf '❯ %s\n' "$(cat "$d/typed")" || printf '❯ \n' ;;
      foreign) [ -s "$d/typed" ] && printf '❯ some other pending thought\n' || printf '❯ \n' ;;
      screen)  cat "$d/screen" ;;
      busydialog) [ -s "$d/typed" ] && { cat "$d/screen"; printf '❯ %s\n' "$(cat "$d/typed")"; } || printf '❯ \n' ;;
      *)       printf '❯ \n' ;;
    esac ;;
  send-keys)
    printf '%s\n' "${@: -1}" >>"$d/keys"
    case "${@: -1}" in Enter) ;; C-u) rm -f "$d/typed" ;; *) printf '%s' "${@: -1}" >"$d/typed" ;; esac ;;
  display-message) printf '2' ;;
esac
SH
chmod 755 "${WORK}/bin/tmux"

live() {
    OUT="$(QS_OWNERS="${WORK}/owners" QS_BACKLOG="${WORK}/backlog.md" \
        QS_STATE="${WORK}/state" QS_REGISTRY_DIR="${WORK}/reg" \
        QS_BUDGET_SH="${WORK}/budget" QS_APP_OWNERS="${WORK}/app-owners" \
        QS_SYSTEMCTL="${WORK}/systemctl" QS_HEAVY_WORK="${WORK}/heavy-work" \
        QS_LOCK="${WORK}/lock" QS_ALLOW_ANY_PATH=1 QS_SETTLE=0 \
        QS_TMUX_SOCK="${WORK}/fake.sock" FAKE_TMUX_DIR="${WORK}/tmuxstate" \
        QS_DIALOG_LIB="${QS_LIB:-${DLIB}}" \
        PATH="${WORK}/bin:${PATH}" "${CHECK}" "$@" 2>&1)"
    RC=$?
}

rm -f "${WORK}/tmuxstate/typed"
echo busy >"${WORK}/tmuxstate/mode"
live --once advisor
contains 'case 10e: a pane still holding our line is logged as queued' "${OUT}" 'queued in a busy pane advisor:0.0: advisor item 71 (the line is consumed at its next turn)'
lacks    'case 10e: and it is not called undelivered' "${OUT}" 'not delivered advisor'
matches  'case 10e: the item is recorded like a normal delivery' "$(cat "${WORK}/state" 2>/dev/null)" '^71 advisor [0-9]+$'
rm -f "${WORK}/state"

rm -f "${WORK}/tmuxstate/typed"
echo foreign >"${WORK}/tmuxstate/mode"
live --once advisor
matches 'case 10f: a foreign line keeps the old not-delivered behaviour' "${OUT}" 'not delivered advisor: item 71 \(rc 3\) — retrying next tick'
lacks   'case 10f: no queued-pane line for a foreign line' "${OUT}" 'queued in a busy pane'
equals  'case 10f: nothing is recorded for a foreign line' "$( [ -e "${WORK}/state" ] && echo yes || echo no)" no
rm -f "${WORK}/tmuxstate/mode" "${WORK}/tmuxstate/typed"

# --- 10g-10k. card 581: the shared dialog check (scripts/lib/dialog-lib.sh) ---
FX_list=$'⏺ MoneyWise upgrade is ready for you to merge: PR #19\n\n  - Nothing changes in how the app behaves for you. Merging doesn\'t deploy; orbit deploys afterwards.\n\n  Your asks:\n  1. Merge PR #19 when you are happy with it.\n  2. No rush: fill in ~/.config/fleet/personal-identifiers so the secrets check also blocks your personal details.\n\n────────────\n❯ \n────────────\n  ⏵⏵ auto mode on'
FX_frame=$'╭──────────╮\n│ Do you want to make this edit to a.txt?\n│ ❯ 1. Yes\n│   2. No, and tell Claude what to do differently\n╰──────────╯'
FX_footer=$' Do you want to make this edit to a.txt?\n   1. Yes\n   2. No, and tell Claude what to do differently\n\n Esc to cancel · Tab to amend'
FX_cursor=$' Bash command\n   ls /srv\n ❯ 1. Yes'
FX_dialog=$'Bash(rm -rf /srv/x)\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No'
FX_sgr=$' Do you want to make this edit to a.txt?\n \e[38;5;153m❯\e[0m 1. Yes\n   2. No'
FX_edite=$'\e[38;2;177;185;249m────────────\n\e[39m \e[1mEdit file\n\e[0m a.txt\n  1 -old\n  1 +new\n\n Do you want to make this edit to \e[1ma.txt\e[0m?\n \e[38;2;177;185;249m❯ 1. Yes\n\e[39m   2. Yes, allow all edits during this session \e[2m(shift+tab)\n\e[0m   3. No, and tell Claude what to do differently \e[2m(esc)\e[0m'
FX_nbsp=$' Do you want to make this edit to a.txt?\n ❯\xc2\xa01. Yes\n   2. Yes, allow all edits during this session\n   3. No, and tell Claude what to do differently'
FX_framecursor=$'╭──────────╮\n│ Bash command\n│   ls /srv\n│ ❯ 1. Yes\n╰──────────╯'
FX_proceed=$'Bash(rm -rf /srv/x)\n\nDo you want to proceed?\n  Allow once\n  Deny, and tell Claude what to do'
FX_ulcolon=$' Do you want to make this edit to a.txt?\n \e[4:3m❯\e[24m 1. Yes\n\e[4:3m   2. No\e[0m'
FX_osc8=$' Do you want to make this edit to a.txt?\n \e]8;;file:///a\e\\❯\e]8;;\e\\ 1. Yes\n   2. No'
FX_block=$' Choose a model\n ❯ 1. Opus\n   2. Sonnet'
FX_confirm=$' Exit Claude Code?\n Enter to confirm · Esc to cancel'
FX_blocknbsp=$' Choose a model\n ❯\xc2\xa01. Opus\n   2. Sonnet'
FX_framedblock=$'│ ❯ 1. Postgres\n│   2. SQLite\n│ Enter to select · Esc to cancel'
FX_framenbsp=$'│ Bash command\n│ ❯\xc2\xa01. Yes'
FX_cursorNo=$' Bash command\n ❯ 2. No'
FX_badutf8=$' Bash command\n ❯ 1. Yes \xe2\x9d'
FX_cursornbsp=$' Bash command\n ❯\xc2\xa01. Yes'

# Every dialog screen, verdict 0; FX_list alone is 1. A new FX_ literal is added here by name.
DIALOG_FX='frame footer cursor dialog sgr edite nbsp framecursor proceed ulcolon osc8 block confirm
  blocknbsp framedblock framenbsp cursorNo badutf8 cursornbsp'
typed() { [ -e "${WORK}/tmuxstate/typed" ] && echo yes || echo no; }

QS_LIB="${WORK}/no-such-dialog-lib.sh" live --once advisor
equals   'case 10g: a dialog lib that does not load exits non-zero' "${RC}" 1
contains 'case 10g: and says so' "${OUT}" 'dialog check '"${WORK}"'/no-such-dialog-lib.sh did not load'
equals   'case 10g: in exactly one line' "$(printf '%s\n' "${OUT}" | grep -c .)" 1
equals   'case 10g: and types nothing' "$(typed)" no

printf 'DIALOG_LOCALE=C.UTF-8\n' >"${WORK}/hollow-lib.sh"
QS_LIB="${WORK}/hollow-lib.sh" live --once advisor
equals   'case 10h: a lib that defines no dialog_on exits non-zero' "${RC}" 1
contains 'case 10h: and says so' "${OUT}" 'hollow-lib.sh defines no dialog_on'
equals   'case 10h: in exactly one line' "$(printf '%s\n' "${OUT}" | grep -c .)" 1
equals   'case 10h: and types nothing' "$(typed)" no

echo screen >"${WORK}/tmuxstate/mode"
printf '%s\n\n❯ \n' "${FX_frame}" >"${WORK}/tmuxstate/screen"
live --once advisor
contains 'case 10i: a dialog on the pane defers delivery' "${OUT}" 'defer: pane advisor:0.0 is showing a dialog (dialog check rc 0)'
equals   'case 10i: and types nothing' "$(typed)" no

printf 'dialog_on(){ return 2; }\n' >"${WORK}/nolocale-lib.sh"
printf '%s\n' "${FX_list}" >"${WORK}/tmuxstate/screen"
QS_LIB="${WORK}/nolocale-lib.sh" live --once advisor
contains 'case 10j: a check that cannot read the pane (rc 2) counts as a dialog' "${OUT}" 'is showing a dialog (dialog check rc 2)'
equals   'case 10j: and types nothing' "$(typed)" no

live --once advisor
contains 'case 10k: a reply ending in a numbered list is not a dialog' "${OUT}" 'announced advisor: item 71'
equals   'case 10k: and the line is typed' "$(typed)" yes
rm -f "${WORK}/state" "${WORK}/tmuxstate/mode" "${WORK}/tmuxstate/typed" "${WORK}/tmuxstate/screen"

# The verdicts themselves: a reply's list is no dialog (1), every real dialog is (0),
# and a missing pinned locale fails closed (2).
verdict() { ( . "${DLIB}"; DIALOG_LOCALE="${2:-${DIALOG_LOCALE}}"; dialog_on "$1" >/dev/null ); printf '%s' "$?"; }
equals 'case 10l: FX_list' "$(verdict "${FX_list}")" 1
for fx in ${DIALOG_FX}; do
    v="FX_${fx}"
    equals "case 10l: FX_${fx}" "$(verdict "${!v}")" 0
done
equals 'case 10l: no pinned locale' "$(LC_ALL=C verdict "${FX_list}" xx_XX.UTF-8)" 2

# Our sentence stuck in the row while a dialog came up: not queued, so not recorded,
# and after the Enters only our own line is cleared (C-u), nothing else is typed.
rm -f "${WORK}/tmuxstate/keys"
echo busydialog >"${WORK}/tmuxstate/mode"
printf '%s\n' "${FX_frame}" >"${WORK}/tmuxstate/screen"
live --once advisor
lacks    'case 10m: a stuck line under a dialog is not called queued' "${OUT}" 'queued in a busy pane'
contains 'case 10m: it is not delivered' "${OUT}" 'not delivered advisor: item 71 (rc 3)'
equals   'case 10m: keys after our sentence' "$(tail -n +2 "${WORK}/tmuxstate/keys" | tr '\n' ' ')" 'Enter Enter Enter C-u '
equals   'case 10m: nothing is recorded' "$( [ -e "${WORK}/state" ] && echo yes || echo no)" no
rm -f "${WORK}/state" "${WORK}/tmuxstate/mode" "${WORK}/tmuxstate/typed" "${WORK}/tmuxstate/screen" "${WORK}/tmuxstate/keys"

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

sed 's/^33 advisor/33 health/' "${WORK}/owners-good" >"${WORK}/owners-health"
lint "${WORK}/owners-health"
matches 'case 11f: the retired health session is refused' "${LOUT}" "item 33 names unknown session 'health'"
equals  'case 11f: exit code' "${LRC}" 1

if [ "${fails}" -eq 0 ]; then
    printf '\nqueue-start-test: all checks passed\n'
    exit 0
fi
printf '\nqueue-start-test: %s check(s) failed\n' "${fails}" >&2
exit 1
