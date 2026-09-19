#!/usr/bin/env bash
# fleet-budget — one line on stdout: `ok <numbers>` (exit 0) or `hold <reason>`
# (exit 1). Anything unreadable is a hold: a budget gate that cannot measure
# must never say go.
#
# Meters come from the same endpoint the CLI's /usage reads, with root's OAuth
# token. The token is read inside python, never echoed, never logged, never
# written anywhere but the request header; the cache holds the response only.
#
# Seams (tests only): FLEET_BUDGET_CONF CACHE CACHE_TTL CREDS METER_FILE
#   LOADAVG PRESSURE MEMINFO CORES.
set -uo pipefail

CONF="${FLEET_BUDGET_CONF:-/root/fleet-budget.conf}"
CREDS="${FLEET_BUDGET_CREDS:-/root/.claude/.credentials.json}"
CACHE="${FLEET_BUDGET_CACHE:-/var/lib/fleet/fleet-budget.cache}"
CACHE_TTL="${FLEET_BUDGET_CACHE_TTL:-600}"
METER_FILE="${FLEET_BUDGET_METER_FILE:-}"
LOADAVG="${FLEET_BUDGET_LOADAVG:-/proc/loadavg}"
PRESSURE="${FLEET_BUDGET_PRESSURE:-/proc/pressure/memory}"
MEMINFO="${FLEET_BUDGET_MEMINFO:-/proc/meminfo}"
CORES="${FLEET_BUDGET_CORES:-$(nproc 2>/dev/null || echo 0)}"
ENDPOINT="${FLEET_BUDGET_ENDPOINT:-https://api.anthropic.com/api/oauth/usage}"
MIN_AVAIL_MB=1500
PSI_CEIL=10

TMPJS="$(mktemp)" || exit 1
trap 'rm -f "$TMPJS"' EXIT

hold(){ printf 'hold %s\n' "$*"; exit 1; }
num(){ [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
gt(){ awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
gte(){ awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

# A key that is present but unparseable returns 1: the caller holds rather than
# quietly falling back to the looser default.
conf_get(){
    local raw v
    [ -r "$CONF" ] || { printf '%s' "$2"; return 0; }
    raw="$(grep -aE "^[[:space:]]*$1[[:space:]]*=" "$CONF" 2>/dev/null | tail -1)"
    [ -n "$raw" ] || { printf '%s' "$2"; return 0; }
    v="$(printf '%s' "$raw" | sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//; s/[[:space:]]+\$//")"
    [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -le 100 ] || return 1
    printf '%s' "$v"
}

# An unreadable capacity reading is a hold, never a zero (heavy-work's rule).
capacity(){
    local l15 avail psi
    l15="$(cut -d' ' -f3 "$LOADAVG" 2>/dev/null)"
    num "$l15" || hold "capacity unreadable: $LOADAVG"
    avail="$(awk '/^MemAvailable:/{print int($2/1024); exit}' "$MEMINFO" 2>/dev/null)"
    num "$avail" || hold "capacity unreadable: $MEMINFO"
    psi="$(awk '/^full /{for(i=1;i<=NF;i++) if($i ~ /^avg300=/){sub(/avg300=/,"",$i); print $i; exit}}' "$PRESSURE" 2>/dev/null)"
    num "$psi" || hold "capacity unreadable: $PRESSURE"
    if ! num "$CORES" || [ "${CORES%%.*}" -lt 1 ]; then hold "capacity unreadable: core count"; fi
    gt "$l15" "$CORES" && hold "capacity: load15 $l15 over $CORES cores"
    [ "$avail" -lt "$MIN_AVAIL_MB" ] && hold "capacity: ${avail}MB available, under ${MIN_AVAIL_MB}MB"
    gt "$psi" "$PSI_CEIL" && hold "capacity: memory pressure full avg300 $psi over $PSI_CEIL"
    return 0
}

fetch_meter(){
    local out rc=0
    mkdir -p "$(dirname "$CACHE")" 2>/dev/null
    out="$(FB_CREDS="$CREDS" FB_CACHE="$CACHE" FB_ENDPOINT="$ENDPOINT" python3 - <<'PY'
import json, os, sys, time, urllib.request, urllib.error
try:
    c = json.load(open(os.environ['FB_CREDS']))['claudeAiOauth']
except Exception:
    print('token missing'); sys.exit(2)
if not c.get('accessToken') or float(c.get('expiresAt', 0)) / 1000 <= time.time():
    print('token missing or expired'); sys.exit(2)
r = urllib.request.Request(os.environ['FB_ENDPOINT'], method='GET')
r.add_header('Authorization', 'Bearer ' + c['accessToken'])
r.add_header('anthropic-beta', 'oauth-2025-04-20')
r.add_header('User-Agent', 'claude-cli/2.1.274 (external, cli)')
r.add_header('Accept', 'application/json')
try:
    body = urllib.request.urlopen(r, timeout=20).read().decode()
    json.loads(body)
except urllib.error.HTTPError as e:
    print('HTTP %d' % e.code); sys.exit(2)
except Exception as e:
    print(type(e).__name__); sys.exit(2)
cache = os.environ['FB_CACHE']
tmp = cache + '.new'
old = os.umask(0o177)
try:
    with open(tmp, 'w') as f:
        f.write(body)
    os.chmod(tmp, 0o600)
    os.replace(tmp, cache)
finally:
    os.umask(old)
print(body)
PY
    )" || rc=$?
    [ "$rc" -eq 0 ] || hold "meter unreadable (${out:-fetch failed})"
    printf '%s' "$out" >"$TMPJS"
}

meter_to_file(){
    local age now stamp
    if [ -n "$METER_FILE" ]; then
        [ -r "$METER_FILE" ] || hold "meter unreadable (meter file $METER_FILE)"
        cat "$METER_FILE" >"$TMPJS"; return 0
    fi
    if [ -r "$CACHE" ]; then
        now="$(date +%s)"; stamp="$(stat -c %Y "$CACHE" 2>/dev/null || echo 0)"
        age=$(( now - stamp ))
        if [ "$age" -lt "$CACHE_TTL" ]; then cat "$CACHE" >"$TMPJS"; return 0; fi
    fi
    fetch_meter
}

meter_pcts(){
    python3 -c '
import json, sys
d = json.load(sys.stdin)
def pct(x):
    v = (x or {}).get("utilization")
    return None if v is None else float(v)
fh, wa, wf = pct(d.get("five_hour")), pct(d.get("seven_day")), None
for l in d.get("limits") or []:
    m = ((l.get("scope") or {}).get("model") or {})
    if m.get("display_name") == "Fable" and l.get("percent") is not None:
        wf = float(l["percent"])
if None in (fh, wa, wf):
    sys.exit(3)
print("%g %g %g" % (fh, wa, wf))
' <"$TMPJS"
}

main(){
    local five_max week_max fable_max fh wa wf pcts numbers
    five_max="$(conf_get FIVE_HOUR_MAX 50)" || hold "conf unreadable: FIVE_HOUR_MAX"
    week_max="$(conf_get WEEK_ALL_MAX 60)" || hold "conf unreadable: WEEK_ALL_MAX"
    fable_max="$(conf_get WEEK_FABLE_MAX 60)" || hold "conf unreadable: WEEK_FABLE_MAX"
    capacity
    meter_to_file
    pcts="$(meter_pcts)" || hold "meter unreadable (no utilization numbers in the response)"
    read -r fh wa wf <<<"$pcts"
    if ! num "$fh" || ! num "$wa" || ! num "$wf"; then hold "meter unreadable (no utilization numbers in the response)"; fi
    numbers="5h ${fh}%/${five_max} week-all ${wa}%/${week_max} week-fable ${wf}%/${fable_max}"
    gte "$fh" "$five_max" && hold "5h meter ${fh}% is at or above its cap ${five_max} — $numbers"
    gte "$wa" "$week_max" && hold "week-all meter ${wa}% is at or above its cap ${week_max} — $numbers"
    gte "$wf" "$fable_max" && hold "week-fable meter ${wf}% is at or above its cap ${fable_max} — $numbers"
    printf 'ok %s\n' "$numbers"
    return 0
}

main "$@"
