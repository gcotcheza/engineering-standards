#!/usr/bin/env bash
# S1: no file git lists outside docs/ stands a commit up past the fleet hook. Exit 0 clean, 1 per finding, 2 if nothing was judged.
# hook-bypass-scan.sh <app-root> [<skipped path>...], run from this checkout; HOOK_BYPASS_GIT is the git seam.
# decision: the-hook-bypass-scan-has-one-copy
set -uo pipefail

[ "$#" -ge 1 ] || { printf 'usage: hook-bypass-scan.sh <app-root> [<skipped path>...]\n' >&2; exit 2; }
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/${BASH_SOURCE[0]##*/}"
cd -- "$1" || exit 2
shift
HERE=$(pwd -P)
declare -A skip=()
for p in "$@"; do
    [ -n "${p}" ] || { printf 'hook-bypass-scan: an empty skipped path, so nothing was judged.\n' >&2; exit 2; }
    skip["${p}"]=1
done
read -ra GIT <<<"${HOOK_BYPASS_GIT:-git}"

list=$(mktemp) || exit 2
trap 'rm -f "${list}"' EXIT
if ! "${GIT[@]}" ls-files -z --cached --others --exclude-standard >"${list}"; then
    printf 'hook-bypass-scan: git ls-files failed, so nothing was judged.\n' >&2
    exit 2
fi
files=()
while IFS= read -r -d '' f; do
    case "${f}" in docs/*) continue ;; esac
    # The scanner never judges itself, since it names every route; a path the caller names is skipped whole.
    [ "${HERE}/${f}" != "${SELF}" ] || continue
    [ -z "${skip["${f}"]:-}" ] || continue
    # ./ so awk never reads a name like x=y.sh as an assignment.
    [ -f "${f}" ] && [ ! -L "${f}" ] && files+=("./${f}")
done <"${list}"
[ "${#files[@]}" -gt 0 ] || { printf 'hook-bypass-scan: git listed no file, so nothing was judged.\n' >&2; exit 2; }

# Lines joined across a trailing backslash with nothing put between, as bash joins them, judged lowercased: git keys and
# long flags take any case. A comment line is judged alone; `*` opens one only in a C-style file, so a shell `*)` arm is code.
findings=$(LC_ALL=C awk -v q="'" '
function comment(file, s) {
    if (s ~ /^[ \t]*#/) return 1
    return file ~ /\.(php|js|mjs|cjs|ts|vue|css|scss)$/ && s ~ /^[ \t]*(\/\/|\/\*|\*)/
}
# A quoted word that is a whole flag cluster is the flag, unless the word before it is a short cluster
# ending in m, f, c or t, or a long option in VALUEOPT: then it is the value of that option.
function flagword(out, w, before, after,    p) {
    p = out
    sub(/[ \t]+$/, "", p)
    sub(/.*[ \t]/, "", p)
    return w ~ /^-[a-z]+$/ && before ~ /^([ \t]|)$/ && after ~ AFTER && p !~ VALUEOPT
}
# The words after commit, each other quoted string left as a _ word, up to a ;, & or | outside them that ends a command:
# the & of >&, <& or &> and the | of >| are redirections, so the words after them still belong to commit.
function unquoted(s,    i, c, qc, st, w, out) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\"" || c == q) {
            qc = c
            st = i
            for (i++; i <= length(s) && substr(s, i, 1) != qc; i++) if (qc == "\"" && substr(s, i, 1) == "\\") i++
            w = substr(s, st + 1, i - st - 1)
            out = out (flagword(out, w, st > 1 ? substr(s, st - 1, 1) : "", substr(s, i + 1, 1)) ? w : " _ ")
            continue
        }
        if (c == ";" || (c == "&" && out !~ /[<>]$/ && substr(s, i + 1, 1) != ">") || (c == "|" && out !~ />$/)) break
        out = out c
    }
    return out
}
# One argv element per line, in a code file: element lines read as one run, fresh after an unclosed ( or [.
# A blank line, or a balanced one ending in a comma, is skipped; a ) or ] outside quotes ends the run.
function elements(file, t,    u, m, b, fresh, opens, closes, closed, w, hit) {
    if (file !~ CODE || t ~ /^[ \t]*$/) return 0
    u = t
    gsub(QUOTED, "", u)
    opens = gsub(/[[(]/, "", u)
    closes = gsub(/[])]/, "", u)
    fresh = opens > closes && match(t, OPEN)
    if (fresh) { incommit = 0; inrun = 1; t = substr(t, RLENGTH + 1) }
    if (t !~ ELEMS) {
        if (opens > closes) { incommit = 0; inrun = 1; return 0 }
        if (opens != closes || t !~ /,[ \t]*$/) { incommit = 0; inrun = 0 }
        return 0
    }
    hit = 0
    m = t
    while (match(m, QUOTED)) { b = substr(m, RSTART, RLENGTH); gsub(/./, " ", b); m = substr(m, 1, RSTART - 1) b substr(m, RSTART + RLENGTH) }
    closed = match(m, /[])]/)
    if (closed) t = substr(t, 1, RSTART - 1)
    while (match(t, ELEM)) {
        w = substr(t, RSTART, RLENGTH)
        t = substr(t, RSTART + RLENGTH)
        if (w ~ "^" Q) w = substr(w, 2, length(w) - 2)
        if (w == "commit" || w == "merge") incommit = inrun
        else if (incommit && w ~ /^-[a-z]*n[a-z]*$/) hit = 1
    }
    if (closed) { incommit = 0; inrun = 0 }
    return hit
}
function judge(file, n, s, argvn,    t, h, r, cut, found, short, e, rest) {
    t = tolower(s)
    found = ""
    if (index(t, "--no-ver") || t ~ /--no-ve?([^a-z-]|$)/) found = found " --no-verify (or a prefix of it)"
    if (index(t, "husky=0")) found = found " HUSKY=0"
    # Only a --get read of the key with nothing after it but a command end passes, --get its own word (--no-get unsets).
    h = t
    gsub(HOOKSREAD, " ", h)
    if (index(h, "core.hookspath")) found = found " core.hooksPath"
    if (t ~ /git_config_[a-z0-9_]+/) found = found " a GIT_CONFIG_ shim"
    if (index(t, "commit-tree")) found = found " commit-tree"
    if (index(t, "fast-import")) found = found " fast-import"
    if (t ~ /hash-object[^;|&]*[ \t]-[a-z]*w/) found = found " hash-object -w"
    # Env names keep their case. A -e HOME= in a docker run, before its command ends, hands a container its env.
    h = s
    if (match(h, DOCKER_RUN)) {
        e = substr(h, RSTART)
        h = substr(h, 1, RSTART - 1)
        rest = match(e, /[;&|]/) ? substr(e, RSTART) : ""
        if (rest != "") e = substr(e, 1, RSTART - 1)
        gsub(CONTAINER_ENV, " ", e)
        h = h e rest
    }
    if (h ~ /(^|[^A-Za-z0-9_])HOME=/) found = found " HOME= (another home drops a hook set in ~/.gitconfig)"
    if (index(h, "XDG_CONFIG_HOME=")) found = found " XDG_CONFIG_HOME="
    # A short cluster carrying n after the word commit or merge (quoted or not), up to a command end; or in an argv array.
    short = t ~ ARGV_N || argvn
    r = t
    while (!short && match(r, VERB)) {
        r = substr(r, RSTART + RLENGTH)
        cut = unquoted(r)
        short = cut ~ /(^|[ \t)`])-[a-z]*n[a-z]*([ \t)`]|$)/
    }
    if (short) found = found " commit or merge -n (a short --no-verify)"
    sub(/^\.\//, "", file)
    if (found != "") printf "%s:%d:%s\n", file, n, found
}
BEGIN {
    Q = "[\"" q "]"
    HOOKSREAD = "(^|[ \t])--get[ \t]+" Q "?core\\.hookspath" Q "?[ \t]*([;&|)`,]|$)"
    VERB = "(^|[^a-z0-9_-])(commit|merge)" Q "?[ \t]"
    DOCKER_RUN = "docker[ \t]+(compose[ \t]+)?run[ \t]"
    ARGV_N = Q "(commit|merge)" Q "[ \t]*,([ \t]*" Q "[^\"" q "]*" Q "[ \t]*,)*[ \t]*" Q "-[a-z]*n[a-z]*" Q
    CONTAINER_ENV = "(^|[ \t])(-e|--env)[ \t=]+[\"" q "]?HOME="
    VALUEOPT = "^(-[a-z]*[mfct]|--(message|file|author|date|template|trailer|cleanup|fixup|squash|reuse-message|reedit-message))$"
    ELEM = "(" Q "[^\"" q "]*" Q "|[^][ \t,\"" q "()]+)"
    CLOSER = "[])].*$"
    # The repeated group opens with ELEM: mawk 1.3.4 20200120 never matches one that opens with [ \t]*.
    ELEMS = "^[ \t]*(" ELEM "[ \t]*,[ \t]*)*" ELEM "[ \t]*,?[ \t]*(" CLOSER ")?$"
    QUOTED = Q "[^\"" q "]*" Q
    EMPTY = q q "|\"\""
    AFTER = "^([ \t;&|)`\"" q "]|)$"
    CODE = "(^|/)[^./]+$|\\.(php|js|mjs|cjs|ts|tsx|jsx|vue|sh|bash|zsh|py|rb|pl|json|ya?ml|mts|cts)$"
    OPEN = "^[^\"" q "]*[[(]"
    if ((q "x" q ",") !~ ELEMS || "x" !~ ELEMS) { print "hook-bypass-scan: this awk misreads the argv-element pattern." > "/dev/stderr"; exit 2 }
    if ((q "x" q ", " q "x" q ",") !~ ELEMS) { print "hook-bypass-scan: this awk misreads repeated argv elements." > "/dev/stderr"; exit 2 }
}
FNR == 1 { if (held != "") judge(prev, start, held, 0); held = ""; incommit = 0; inrun = 0; prev = FILENAME }
{
    # An empty '' or "" splits a word for nothing (c''ommit is commit), so each pair is dropped first, even inside quotes.
    line = $0
    gsub(EMPTY, "", line)
    if (held == "") {
        if (comment(FILENAME, tolower(line))) { judge(FILENAME, FNR, line, 0); next }
        start = FNR
    }
    s = held line
    if (s ~ /\\$/) { held = substr(s, 1, length(s) - 1); next }
    held = ""
    judge(FILENAME, start, s, elements(FILENAME, tolower(s)))
}
END { if (held != "") judge(prev, start, held, 0) }
' "${files[@]}") || { printf 'hook-bypass-scan: awk could not read the tree, so nothing was judged.\n' >&2; exit 2; }

[ -n "${findings}" ] || { printf 'hook-bypass-scan: ok (%d files)\n' "${#files[@]}"; exit 0; }
while IFS= read -r f; do printf 'hook-bypass-scan: %s — a commit here would skip the fleet hook (S1); report a blocked commit, never route around it.\n' "${f}" >&2; done <<<"${findings}"
exit 1
