#!/usr/bin/env bash
# =============================================================================
# queue-start — a session's next queued backlog item reaches it by itself, but
# only while the fleet's budget check says ok. Cron, every 30 minutes.
#
# For each session in the owners file (order = priority): deliver ONE line into
# its pane, with merge-notify's transport and its safety:
#   [queue-start automation] budget ok (<numbers>): next queued item for <s> is
#   <N> — <title>. Start it by your rules, or mark it hold in /root/backlog-owners.
#
# Idle means: the session keeps a registry file AND it is empty, no deploy unit
# is active for one of its apps, and heavy-work holds no slot for it. A missing
# registry is not idle — a session opts in by keeping one. No walk-down: only
# the session's top queued item is ever announced; held or already announced
# within 24 h means silence, never the next item down.
#
# Seams (tests only): QS_OWNERS QS_BACKLOG QS_STATE QS_REGISTRY_DIR QS_BUDGET_SH
#   QS_APP_OWNERS QS_SYSTEMCTL QS_HEAVY_WORK QS_TMUX_SOCK QS_LOCK QS_SETTLE
#   QS_ENTER_TRIES QS_DEDUPE_SECS QS_ALLOW_ANY_PATH.
# Exit: 0 always — a cron job that fails loudly at 3am is a pager, not a tool.
# =============================================================================
set -uo pipefail

OWNERS="${QS_OWNERS:-/root/backlog-owners}"
BACKLOG="${QS_BACKLOG:-/root/backlog.md}"
STATE="${QS_STATE:-/var/lib/fleet/queue-start.state}"
REG_DIR="${QS_REGISTRY_DIR:-/root}"
BUDGET="${QS_BUDGET_SH:-/usr/local/sbin/fleet-budget}"
APP_OWNERS="${QS_APP_OWNERS:-/etc/fleet/app-owners}"
SYSTEMCTL="${QS_SYSTEMCTL:-systemctl}"
HEAVY="${QS_HEAVY_WORK:-/usr/local/sbin/heavy-work}"
TMUX_SOCK="${QS_TMUX_SOCK:-/tmp/tmux-0/claude-remote}"
LOCK="${QS_LOCK:-/run/lock/queue-start.lock}"
SETTLE="${QS_SETTLE:-0.6}"
ENTER_TRIES="${QS_ENTER_TRIES:-3}"
DEDUPE_SECS="${QS_DEDUPE_SECS:-86400}"
KNOWN_SESSIONS='advisor personal-vps orbit health kidsquest'
DRY_RUN=0
ONLY=''

DIALOG_RE='Do you want to proceed[?]|^[[:space:]]*[^[:alnum:]]?[[:space:]]*[0-9]+\.[[:space:]]+(Yes|No)([[:space:],]|$)'
PROMPT_X=2

QUEUED="$(mktemp)" || exit 0
trap 'rm -f "$QUEUED"' EXIT

log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
loud(){ printf '%s queue-start: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; log "$*"; }

tmux_(){ timeout 10 tmux -S "$TMUX_SOCK" "$@"; }
path_ok(){ case "$1" in "$2"|"$2"/*) return 0 ;; esac ; return 1 ; }
valid_pane(){ [[ "${1:-}" =~ ^[a-z0-9_-]+:[0-9]+\.[0-9]+$ ]]; }
valid_session(){ case " $KNOWN_SESSIONS " in *" ${1:-} "*) return 0 ;; esac ; return 1 ; }
sanitize(){ printf '%s' "${1:-}" | tr -dc '[:print:]' | cut -c1-80; }
strip_ws(){ printf '%s' "${1:-}" | tr -d ' \t\r'; }
is_prefix(){ case "${1:-}" in "${2:-}"*) return 0 ;; esac ; return 1 ; }

input_text(){
  printf '%s' "$1" \
    | sed -E 's/\x1b\[2m[^\x1b]*(\x1b\[[0-9;]*m)?//g; s/\x1b\[[0-9;]*[a-zA-Z]//g' \
    | sed 's/.*❯//; s/\xc2\xa0/ /g' | tr -d ' \t\r'
}

prompt_row(){ printf '%s\n' "${1:-}" | grep -a '❯' | tail -1; }

# Clear the sentence we stranded in the input box, and only ours: a person's
# half-typed thought is never erased.
give_up_clear(){
  local pane="$1" row="$2" text="$3" stuck ours shorter
  stuck="$(input_text "$row")"; ours="$(strip_ws "$text")"
  [ -n "$stuck" ] || return 0
  shorter=${#stuck}
  [ "${#ours}" -lt "$shorter" ] && shorter=${#ours}
  if [ "$shorter" -ge 10 ] && { is_prefix "$stuck" "$ours" || is_prefix "$ours" "$stuck"; }; then
    if tmux_ send-keys -t "$pane" C-u; then
      log "cleared our own stranded line from pane $pane (give-up)"
    else
      loud "could not clear our own stranded line from pane $pane — it may block later ticks"
    fi
  else
    log "left pane $pane alone: the input line does not hold our sentence"
  fi
}

# 0 delivered (input line empty again), 3 unreadable or not accepted, 4 deferred.
deliver(){
  local pane="$1" text="$2" dialog_screen screen row cx try=0
  dialog_screen="$(tmux_ capture-pane -peJ -S -60 -t "$pane" 2>/dev/null)" || dialog_screen=''
  if [ -z "$dialog_screen" ]; then
    log "transport: pane $pane unreadable — nothing delivered"; return 3
  fi
  if printf '%s\n' "$dialog_screen" | grep -qE "$DIALOG_RE"; then
    log "defer: pane $pane is showing a permission dialog"; return 4
  fi
  screen="$(tmux_ capture-pane -peJ -S 0 -t "$pane" 2>/dev/null)" || screen=''
  if [ -z "$screen" ]; then
    log "transport: pane $pane unreadable — nothing delivered"; return 3
  fi
  row="$(prompt_row "$screen")"
  if [ -z "$row" ]; then
    log "defer: pane $pane shows no ❯ input row — nothing typed"; return 4
  fi
  cx="$(tmux_ display-message -p -t "$pane" '#{cursor_x}' 2>/dev/null)" || cx=''
  if [ -n "$cx" ] && [ "$cx" -gt "$PROMPT_X" ] 2>/dev/null; then
    log "defer: pane $pane has text in the input line (cursor at column $cx)"; return 4
  fi
  if [ -n "$(input_text "$row")" ]; then
    log "defer: pane $pane has text in the input line"; return 4
  fi
  tmux_ send-keys -t "$pane" -l -- "$text" || { log "transport: send-keys text failed for $pane"; return 3; }
  while [ "$try" -lt "$ENTER_TRIES" ]; do
    sleep "$SETTLE"
    tmux_ send-keys -t "$pane" Enter || { log "transport: send-keys Enter failed for $pane"; return 3; }
    sleep "$SETTLE"
    screen="$(tmux_ capture-pane -peJ -S 0 -t "$pane" 2>/dev/null)" || screen=''
    row="$(prompt_row "$screen")"
    if [ -n "$row" ] && [ -z "$(input_text "$row")" ]; then return 0; fi
    try=$((try + 1))
  done
  if [ -z "$row" ]; then
    log "defer: pane $pane has no ❯ input row after $ENTER_TRIES Enters — delivery unverified, not recorded"
    return 4
  fi
  give_up_clear "$pane" "$row" "$text"
  log "transport: pane $pane still holds the line after $ENTER_TRIES Enters"
  return 3
}

pane_for(){ case "$1" in personal-vps) printf 'claude:0.0' ;; *) printf '%s:0.0' "$1" ;; esac ; }

read_queued(){
  sed -n '/^## Queued work/,/^## Recently decided/p' "$BACKLOG" 2>/dev/null \
    | grep -oE '<summary><b>[0-9]+\.</b>[^<]*' \
    | sed -E 's|<summary><b>([0-9]+)\.</b>[[:space:]]*|\1 |' >"$QUEUED"
  [ -s "$QUEUED" ]
}

queued_title(){ awk -v n="$1" '$1==n {$1=""; sub(/^ /,""); print; exit}' "$QUEUED"; }

# A session that keeps no registry file has not opted in: not idle.
# `heavy-work --status` prints `  last: ...` lines from the finished job while it
# is free; those are history, never a held slot.
busy_reason(){
  local s="$1" reg pane app apane rest out
  reg="$REG_DIR/$s-workers.active"
  if [ ! -f "$reg" ] || [ ! -r "$reg" ]; then printf 'no readable registry file %s' "$reg"; return 0; fi
  [ -s "$reg" ] && { printf 'a builder is listed in %s' "$reg"; return 0; }
  pane="$(pane_for "$s")"
  if [ ! -r "$APP_OWNERS" ]; then printf 'app owners map %s is unreadable' "$APP_OWNERS"; return 0; fi
  while read -r app apane rest || [ -n "${app:-}" ]; do
    case "$app" in ''|'#'*) continue ;; esac
    [ "$apane" = "$pane" ] || continue
    out="$("$SYSTEMCTL" list-units --type=service --state=active --no-legend "$app-deploy-*" 2>/dev/null)"
    [ -n "$out" ] && { printf 'a deploy unit is active for %s' "$app"; return 0; }
  done <"$APP_OWNERS"
  if [ -x "$HEAVY" ]; then
    if "$HEAVY" --status 2>/dev/null | grep -v '^[[:space:]]*last:' | grep -qE "(^|[[:space:]])session=$s([[:space:]]|$)"; then
      printf 'heavy-work holds a slot for %s' "$s"; return 0
    fi
  fi
  return 0
}

top_item(){
  local s="$1" n sess flag rest title
  while read -r n sess flag rest || [ -n "${n:-}" ]; do
    case "$n" in ''|'#'*) continue ;; esac
    [[ "$n" =~ ^[0-9]+$ ]] || { log "skip malformed owners line: $(sanitize "$n ${sess:-} ${flag:-}")"; continue; }
    [ "$sess" = "$s" ] || continue
    title="$(queued_title "$n")"
    [ -n "$title" ] || continue
    printf '%s\t%s\t%s' "$n" "${flag:--}" "$title"
    return 0
  done <"$OWNERS"
  return 1
}

deduped(){
  local n="$1" s="$2" e now
  [ -r "$STATE" ] || return 1
  e="$(awk -v n="$n" -v s="$s" '$1==n && $2==s {v=$3} END{print v+0}' "$STATE" 2>/dev/null)"
  [ "${e:-0}" -gt 0 ] 2>/dev/null || return 1
  now="$(date +%s)"
  [ $(( now - e )) -lt "$DEDUPE_SECS" ]
}

record(){ printf '%s %s %s\n' "$1" "$2" "$(date +%s)" >>"$STATE"; }

owners_sessions(){ awk '$1 ~ /^[0-9]+$/ {print $2}' "$OWNERS" | awk '!seen[$0]++'; }

take_lock(){
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  exec 9>>"$LOCK" || { loud "lock file $LOCK cannot be opened — refusing to run"; return 1; }
  flock -n 9 || { log "another run holds the lock $LOCK — this tick does nothing"; return 1; }
  return 0
}

paths_ok(){
  [ "${QS_ALLOW_ANY_PATH:-0}" = 1 ] && return 0
  path_ok "$STATE" /var/lib/fleet && return 0
  loud "state file $STATE is outside /var/lib/fleet — refusing to run (QS_ALLOW_ANY_PATH=1 is for tests)"
  return 1
}

run_session(){
  local s="$1" numbers="$2" reason pick n flag title pane sentence rc
  if [ "$s" = parked ] || [ "$s" = hold ]; then log "skip the parked lines: they name no session"; return 0; fi
  if ! valid_session "$s"; then log "skip owners line: unknown session [$(sanitize "$s")]"; return 0; fi
  reason="$(busy_reason "$s")"
  if [ -n "$reason" ]; then log "skip $s: $reason"; return 0; fi
  if ! pick="$(top_item "$s")"; then log "skip $s: no queued item owned by it"; return 0; fi
  IFS=$'\t' read -r n flag title <<<"$pick"
  if [ "$flag" = hold ]; then log "skip $s: its top item $n is marked hold"; return 0; fi
  if deduped "$n" "$s"; then log "skip $s: item $n was announced within the last $DEDUPE_SECS s"; return 0; fi
  pane="$(pane_for "$s")"
  valid_pane "$pane" || { loud "skip $s: computed pane [$(sanitize "$pane")] is not a pane"; return 0; }
  sentence="[queue-start automation] budget ok ($numbers): next queued item for $s is $n — $title. Start it by your rules, or mark it hold in /root/backlog-owners."
  if [ "$DRY_RUN" = 1 ]; then
    log "dry-run $s: pane $pane"
    log "dry-run $s: $sentence"
    return 0
  fi
  deliver "$pane" "$sentence"; rc=$?
  if [ "$rc" -ne 0 ]; then log "not delivered $s: item $n (rc $rc) — retrying next tick"; return 0; fi
  if record "$n" "$s"; then
    log "announced $s: item $n -> $pane"
  else
    loud "DELIVERED BUT NOT RECORDED $s: item $n — $STATE is not writable, the same line will be typed again"
  fi
  return 0
}

usage(){ echo "usage: queue-start [--dry-run] [--once <session>]" >&2; }

main(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --once) shift; ONLY="${1:-}"; [ -n "$ONLY" ] || { usage; return 0; } ;;
      *) usage; return 0 ;;
    esac
    shift
  done
  paths_ok || return 0
  mkdir -p "$(dirname "$STATE")" 2>/dev/null
  [ "$DRY_RUN" = 1 ] || take_lock || return 0
  if [ ! -r "$OWNERS" ]; then loud "owners file $OWNERS is unreadable — nothing announced"; return 0; fi
  if ! read_queued; then loud "no '## Queued work' items in $BACKLOG — nothing announced"; return 0; fi
  local out rc=0 numbers s
  out="$("$BUDGET" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] || [ "${out#ok }" = "$out" ]; then
    log "budget says no: ${out:-fleet-budget produced nothing}"
    return 0
  fi
  numbers="${out#ok }"
  for s in $(owners_sessions); do
    [ -n "$ONLY" ] && [ "$s" != "$ONLY" ] && continue
    run_session "$s" "$numbers"
  done
  return 0
}

main "$@"
exit 0
