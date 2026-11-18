#!/usr/bin/env bash
# Every bash run on a script file under scripts/ names that file after --, so an operand that
# starts with - is read as a file and never as an option (card 1138). decision: bash-names-a-script-after-dashdash
#
#   scripts/bash-dashdash-scan.sh <repo-root>
#
# Judges every *.sh under <repo-root>/scripts: a bash word in code (not inside a quoted string, a
# comment or a here-doc body), its options (lines joined at a trailing \), then a script operand that
# starts with an expansion. bash -c, -s and -- are left alone. Exit 0 clean, 1 with one file:line per
# finding, 2 on usage.
set -uo pipefail

[ -n "${1:-}" ] || { printf 'usage: bash-dashdash-scan.sh <repo-root>\n' >&2; exit 2; }
[ -d "$1/scripts" ] || { printf 'bash-dashdash-scan: no scripts/ under %s\n' "$1" >&2; exit 2; }
cd -- "$1" || exit 2

found=0
while IFS= read -r -d '' f; do
    awk -v file="${f#./}" '
    function finding(at) { printf "%s:%d: bash runs a script operand without -- before it\n", file, at; hit = 1 }
    BEGIN {
        opts = "([[:space:]]+([-+][abd-np-rt-zA-NP-Z]+|[-+][oO][[:space:]]+[^[:space:]]+|--[a-z][a-z-]*))*"
        runs = "^" opts "[[:space:]]+\"?[$]"; goes_on = "^" opts "[[:space:]]+[\\\\]$"
    }
    doc != "" { t = $0; sub(/^\t+/, "", t); if (t == doc) doc = ""; next }
    held != "" { rest = held $0; held = ""; if (rest ~ runs) finding(heldat); else if (rest ~ goes_on) held = substr(rest, 1, length(rest) - 1) }
    {
        line = $0; n = length(line); prev = ""; i = 1
        while (i <= n) {
            ch = substr(line, i, 1); k = ctx[top]
            if (k == "s") { if (ch == "\047") top--; prev = ch; i++; continue }
            if (ch == "\\") { prev = "x"; i += 2; continue }
            if (k == "d") {
                if (ch == "\"") top--
                else if (substr(line, i, 2) == "$(") { ctx[++top] = "c"; depth[top] = 0; i++; ch = "(" }
                prev = ch; i++; continue
            }
            if (ch == "#" && (prev == "" || prev ~ /[[:space:];&|(]/)) break
            if (ch == "\047") { ctx[++top] = "s" }
            else if (ch == "\"") { ctx[++top] = "d" }
            else if (substr(line, i, 3) == "<<<") { i += 3; prev = "x"; continue }
            else if (ch == "(") { depth[top]++ }
            else if (ch == ")") { if (depth[top] > 0) depth[top]--; else if (top > 0) top-- }
            else if (substr(line, i, 2) == "<<" && match(substr(line, i), /^<<-?[[:space:]]*[\\\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
                d = substr(line, i, RLENGTH); sub(/^<<-?[[:space:]]*[\\\047"]?/, "", d); sub(/[\047"]$/, "", d); pend = d
                i += RLENGTH; prev = "x"; continue
            }
            else if (substr(line, i, 4) == "bash" && (prev == "" || prev ~ /[[:space:];&|(!\/`]/)) {
                rest = substr(line, i + 4)
                if (rest ~ runs) finding(FNR)
                else if (rest ~ goes_on) { held = substr(rest, 1, length(rest) - 1); heldat = FNR }
            }
            prev = ch; i++
        }
        if (pend != "") { doc = pend; pend = "" }
    }
    END { exit hit }' "$f" || found=1
done < <(find ./scripts -type f -name '*.sh' -print0 | LC_ALL=C sort -z)
exit "${found}"
