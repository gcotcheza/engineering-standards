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
    # A listed path that is not here means git listed another tree.
    [ -e "${f}" ] || [ -L "${f}" ] || { printf 'hook-bypass-scan: git listed %s, which is not under %s, so nothing was judged.\n' "${f}" "${HERE}" >&2; exit 2; }
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
# Quotes as bash reads them: a quoted string with no blank or operator joins its word, unless it opens the value of a
# VALUEOPT option; any other is one _ word. With bs a backslash keeps the next char; a $ before a quote is dropped.
function shellwords(s, bs,    i, c, b, qc, st, esc, w, p, out) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (bs && c == "\\") { c = substr(s, ++i, 1); out = out (c ~ /[ \t;&|<>()`$]/ ? "_" : c); continue }
        b = i > 1 ? substr(s, i - 1, 1) : ""
        esc = 0
        if (c == "$" && (substr(s, i + 1, 1) == "\"" || substr(s, i + 1, 1) == q)) { i++; esc = substr(s, i, 1) == q; c = substr(s, i, 1) }
        if (c == "\"" || c == q) {
            qc = c
            st = i
            for (i++; i <= length(s) && substr(s, i, 1) != qc; i++) if ((qc == "\"" || esc) && substr(s, i, 1) == "\\") i++
            w = substr(s, st + 1, i - st - 1)
            p = out
            sub(/[ \t]+$/, "", p)
            sub(/.*[ \t]/, "", p)
            out = out (w ~ /^[^ \t;&|<>()`$\\]*$/ && !(b ~ /^[ \t]?$/ && p ~ VALUEOPT) ? w : " _ ")
            continue
        }
        out = out c
    }
    return out
}
# The words up to a ;, & or | that ends a command: the & of >&, <& or &> and the | of >| are redirections.
function cutcmd(s,    i, c, out) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == ";" || (c == "&" && out !~ /[<>]$/ && substr(s, i + 1, 1) != ">") || (c == "|" && out !~ />$/)) break
        out = out c
    }
    return out
}
# A short cluster carrying n after the word commit or merge (quoted or not, or ended by a redirection), up to a command end.
# r may start inside a quoted string, so a backslash is read both ways.
function shortn(r) {
    while (match(r, VERB)) {
        r = substr(r, RSTART + RLENGTH)
        if (cutcmd(shellwords(r, 0)) ~ SHORT || cutcmd(shellwords(r, 1)) ~ SHORT) return 1
    }
    return 0
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
function hit(label) { if (!(label in seen)) { seen[label] = 1; found = found " " label } }
# Every rule but -n, over t lowercased and s as written.
function rules(t, s,    h, e, rest) {
    if (index(t, "--no-ver") || t ~ /--no-ve?([^a-z-]|$)/) hit("--no-verify (or a prefix of it)")
    if (index(t, "husky=0")) hit("HUSKY=0")
    # Only a --get read of the key with nothing after it but a command end passes, --get its own word (--no-get unsets).
    h = t
    gsub(HOOKSREAD, " ", h)
    if (index(h, "core.hookspath")) hit("core.hooksPath")
    if (t ~ /git_config_[a-z0-9_]+/) hit("a GIT_CONFIG_ shim")
    if (index(t, "commit-tree")) hit("commit-tree")
    if (index(t, "fast-import")) hit("fast-import")
    if (index(t, "include.path") || t ~ /includeif\.[^=;&|]*\.path/) hit("include.path (a config file can set core.hooksPath)")
    if (t ~ /hash-object[^;|&]*[ \t]-[a-z]*w/) hit("hash-object -w")
    # Env names keep their case. A -e HOME= in a docker run, before a command end, $( or backtick, hands a container its env.
    h = s
    if (match(h, DOCKER_RUN)) {
        e = substr(h, RSTART)
        h = substr(h, 1, RSTART - 1)
        rest = match(e, /[;&|`]|\$\(/) ? substr(e, RSTART) : ""
        if (rest != "") e = substr(e, 1, RSTART - 1)
        gsub(CONTAINER_ENV, " ", e)
        h = h e rest
    }
    # One pass: env -i, assignments, HOME=/root, assignments, then a command word, all one command: root keeps its own home.
    if (match(h, ROOTHOME)) { e = substr(h, RSTART, RLENGTH); sub("[ \t]" ROOT "[ \t]", " ", e); sub(/env[ \t]+-i/, "env", e); h = substr(h, 1, RSTART - 1) e substr(h, RSTART + RLENGTH) }
    if (h ~ /(^|[^A-Za-z0-9_])HOME\+?=/) hit("HOME= (another home drops a hook set in ~/.gitconfig)")
    if (h ~ /XDG_CONFIG_HOME\+?=/) hit("XDG_CONFIG_HOME=")
    # A home taken away is another home: env -i past the pass above with git next, or env -u or unset of either home.
    if (h ~ ENV_CMD "(-[0iv]*i[^ \t;&|]*([ \t]+[^- \t;&|][^ \t;&|]*)?|--ignore-e[a-z]*|-)" ENV_OPTS "[ \t]+(" ASSIGN ")*" GITWORD) hit("env -i (git with no HOME at all)")
    if (h ~ ENV_CMD "(-[0iv]*u[ \t]*|--u[a-z]*([ \t]+|=))" HOMES WORDEND || h ~ WORD "unset" ARGS "[ \t]+" HOMES WORDEND) hit("env -u or unset of a home")
    # A home set without the text HOME=: an index, read, printf -v, declare or local, getopts, wait -p, a loop or coproc name,
    # or let or (( )).
    if (h ~ "(^|[^A-Za-z0-9_])" HOMES "\\[[^]]*\\]\\+?=" || h ~ SETS HOMES WORDEND || h ~ ARITH) hit("a home set by read, declare, printf -v, for, let or an index")
    # A nameref to a home sets it through the other name: declare, local or typeset -n r=HOME.
    if (h ~ NAMEREF) hit("a nameref to a home")
}
function judge(file, n, s, argvn,    d) {
    found = ""
    split("", seen)
    rules(tolower(s), s)
    # Bash drops a quote or backslash inside a word, so a de-quoted copy is judged too: --no-"verify" is the long flag.
    d = s
    gsub("\\$[\"" q "]", "", d)
    gsub("[\"" q "\\\\]", "", d)
    rules(tolower(d), d)
    # The -n rule reads quotes as bash does, so a -m message is no flag: as written, and with the quotes in each word joined.
    if (tolower(s) ~ ARGV_N || argvn || shortn(tolower(s)) || shortn(shellwords(tolower(s), 1))) hit("commit or merge -n (a short --no-verify)")
    sub(/^\.\//, "", file)
    if (found != "") printf "%s:%d:%s\n", file, n, found
}
BEGIN {
    Q = "[\"" q "]"
    HOOKSREAD = "(^|[ \t])--get[ \t]+" Q "?core\\.hookspath" Q "?[ \t]*([;&|)`,]|$)"
    VERB = "(^|[^a-z0-9_-])(commit|merge)([ \t<>]|&>)"
    SHORT = "(^|[ \t)`])-[a-z]*n[a-z]*([ \t)`]|$)"
    DOCKER_RUN = "(^|[^A-Za-z0-9_.-])docker[ \t]+(compose[ \t]+)?run[ \t]"
    ARGV_N = Q "(commit|merge)" Q "[ \t]*,([ \t]*" Q "[^\"" q "]*" Q "[ \t]*,)*[ \t]*" Q "-[a-z]*n[a-z]*" Q
    ASSIGN = "[A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|[^ \t\"" q ";&|]*)[ \t]+"
    ROOT = "HOME=/root"
    COMMAND = "[^ \t;&|=]+([ \t;&|)`]|$)"
    ROOTHOME = "(^|[ \t;&|({`])env[ \t]+-i[ \t]+(" ASSIGN ")*" ROOT "[ \t]+(" ASSIGN ")*" COMMAND
    HOMES = "(XDG_CONFIG_)?HOME"
    WORDEND = "([^A-Za-z0-9_]|$)"
    WORD = "(^|[^A-Za-z0-9_.-])"
    ARGS = "([ \t]+[^ \t;&|]+)*"
    # The options of env, each with at most one argument, so a -i or -u after -v or -C dir is still read.
    ENV_OPTS = "([ \t]+-[^ \t;&|]*([ \t]+[^- \t;&|][^ \t;&|]*)?)*"
    ENV_CMD = WORD "env" ENV_OPTS "[ \t]+"
    GITWORD = "[^ \t;&|=]*(git|GIT)[^ \t;&|=]*([ \t;&|)`]|$)"
    SETS = WORD "((read|readarray|mapfile|local|declare|typeset)" ARGS "[ \t]+|export" ARGS "[ \t]+-[a-z]*n" ARGS "[ \t]+|printf" ARGS "[ \t]+-v[ \t]*|getopts[ \t]+[^ \t;&|]+[ \t]+|wait" ARGS "[ \t]+-[a-z]*p[ \t]*|(for|select|coproc)[ \t]+)"
    ARITH = "(" WORD "let" ARGS "[ \t]+|\\(\\(([^)]*[^A-Za-z0-9_])?)" HOMES "[ \t]*(\\+\\+|--|([-+*/%&|^]|<<|>>)?=([^=]|$))"
    NAMEREF = WORD "(declare|local|typeset)" ARGS "[ \t]+-[a-z]*n[a-z]*" ARGS "[ \t]+[A-Za-z_][A-Za-z0-9_]*=" HOMES WORDEND
    CONTAINER_ENV = "(^|[ \t])(-e|--env)[ \t=]+[\"" q "]?HOME="
    VALUEOPT = "^(-[a-z]*[mfct]|--(message|file|author|date|template|trailer|cleanup|fixup|squash|reuse-message|reedit-message))$"
    ELEM = "(" Q "[^\"" q "]*" Q "|[^][ \t,\"" q "()]+)"
    CLOSER = "[])].*$"
    # The repeated group opens with ELEM: mawk 1.3.4 20200120 never matches one that opens with [ \t]*.
    ELEMS = "^[ \t]*(" ELEM "[ \t]*,[ \t]*)*" ELEM "[ \t]*,?[ \t]*(" CLOSER ")?$"
    QUOTED = Q "[^\"" q "]*" Q
    EMPTY = q q "|\"\""
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
