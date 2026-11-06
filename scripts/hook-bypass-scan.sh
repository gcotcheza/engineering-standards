#!/usr/bin/env bash
# S1: no file git lists outside docs/ stands a commit up past the fleet hook. Exit 0 clean, 1 per finding, 2 if nothing was judged.
# hook-bypass-scan.sh <app-root> [<path> | <path>:<sha256 of the line>...], run from this checkout; HOOK_BYPASS_GIT is the git seam.
# decision: the-hook-bypass-scan-has-one-copy, the-hook-bypass-scan-skips-one-line-by-its-hash
set -uo pipefail

[ "$#" -ge 1 ] || { printf 'usage: hook-bypass-scan.sh <app-root> [<path> | <path>:<sha256 of the line>...]\n' >&2; exit 2; }
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/${BASH_SOURCE[0]##*/}"
cd -- "$1" || exit 2
shift
HERE=$(pwd -P)
declare -A skip=()
lines=$(mktemp) && list=$(mktemp) && skipped=$(mktemp) && stale=$(mktemp) && raw=$(mktemp) || exit 2
trap 'rm -f "${lines}" "${list}" "${skipped}" "${stale}" "${raw}"' EXIT
lpaths=()
nl=$'\n'
for p in "$@"; do
    [ -n "${p}" ] || { printf 'hook-bypass-scan: an empty skipped path, so nothing was judged.\n' >&2; exit 2; }
    # A line skip splits at its first colon; its path and its hash go to awk one line each.
    if [[ "${p}" == *:* ]]; then
        [[ -n "${p%%:*}" && "${p}" != *"${nl}"* ]] || { printf 'hook-bypass-scan: the line skip %s needs a path of one line before its colon, so nothing was judged.\n' "${p}" >&2; exit 2; }
        [[ "${p#*:}" =~ ^[0123456789abcdef]{64}$ ]] || { printf 'hook-bypass-scan: the line skip %s needs the sha256 of the line after its colon, 64 lowercase hex, so nothing was judged.\n' "${p}" >&2; exit 2; }
        printf '%s\n%s\n' "${p%%:*}" "${p#*:}" >>"${lines}"
        lpaths+=("${p%%:*}")
    else
        skip["${p}"]=1
    fi
done
read -ra GIT <<<"${HOOK_BYPASS_GIT:-git}"

if ! "${GIT[@]}" ls-files -z --cached --others --exclude-standard >"${list}"; then
    printf 'hook-bypass-scan: git ls-files failed, so nothing was judged.\n' >&2
    exit 2
fi
files=()
while IFS= read -r -d '' f; do
    # A listed path that is not here means git listed another tree.
    [ -e "${f}" ] || [ -L "${f}" ] || { printf 'hook-bypass-scan: git listed %s, which is not under %s, so nothing was judged.\n' "${f}" "${HERE}" >&2; exit 2; }
    case "${f}" in docs/*) continue ;; esac
    for lp in "${lpaths[@]}"; do
        [[ "${f}" != "${lp}:"* ]] || { printf 'hook-bypass-scan: %s holds a colon, so no line skip can name it and nothing was judged.\n' "${f}" >&2; exit 2; }
    done
    # The scanner never judges itself, since it names every route; a path the caller names is skipped whole.
    [ "${HERE}/${f}" != "${SELF}" ] || continue
    [ -z "${skip["${f}"]:-}" ] || continue
    # ./ so awk never reads a name like x=y.sh as an assignment.
    [ -f "${f}" ] && [ ! -L "${f}" ] && files+=("./${f}")
done <"${list}"
[ "${#files[@]}" -gt 0 ] || { printf 'hook-bypass-scan: git listed no file, so nothing was judged.\n' >&2; exit 2; }

# Lines joined across a trailing backslash with nothing put between, as bash joins them, judged lowercased: git keys and
# long flags take any case. A comment line is judged alone; `*` opens one only in a C-style file, so a shell `*)` arm is code.
findings=$(HBS_LINES="${lines}" HBS_RAW="${raw}" HBS_SKIPPED="${skipped}" HBS_STALE="${stale}" LC_ALL=C awk -v q="'" '
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
# The sha256 of a line as read, CR included and no newline added, which is how a caller hashes it.
function sha256(s,    h, cmd) {
    printf "%s", s > ENVIRON["HBS_RAW"]
    close(ENVIRON["HBS_RAW"])
    cmd = "sha256sum < \"$HBS_RAW\""
    cmd | getline h
    close(cmd)
    return substr(h, 1, 64)
}
function hit(label) { if (!(label in seen)) { seen[label] = 1; found = found " " label } }
# Every rule but -n, over t lowercased and s as written.
function rules(t, s,    h, e, rest) {
    # Each prefix git takes for --no-verify, whole: --no-ver is it for git am; --no-verb is --no-verbose, never it.
    if (t ~ /--no-v(e(r(i(fy?)?)?)?)?([^a-z-]|$)/) hit("--no-verify (or a prefix of it)")
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
function chr(v) { return v > 32 && v < 127 ? sprintf("%c", v) : "_" }
# Each ANSI-C string (dollar, quote) as bash decodes it, into a single-quoted one: hex and octal escapes become their character; a quote, blank, control or \c with its char, one _.
function ansic(x,    out, i, c, v, k, body) {
    out = ""
    while ((i = index(x, "$" q)) > 0) {
        out = out substr(x, 1, i - 1)
        x = substr(x, i + 2)
        body = ""
        for (i = 1; i <= length(x) && substr(x, i, 1) != q; i++) {
            c = substr(x, i, 1)
            if (c == "\\") {
                c = substr(x, ++i, 1)
                v = -1
                if (c == "c") i++
                if (c ~ /^[xuU]$/) for (v = k = 0; k < (c == "x" ? 2 : c == "u" ? 4 : 8) && substr(x, i + 1, 1) != "" && index(HEX, tolower(substr(x, i + 1, 1))); k++) v = v * 16 + index(HEX, tolower(substr(x, ++i, 1))) - 1
                if (c ~ /[0-7]/) for (v = c + 0; length(c) < 3 && substr(x, i + 1, 1) ~ /[0-7]/; c = c "o") v = v * 8 + substr(x, ++i, 1)
                c = v >= 0 ? chr(v) : c ~ /[a-z]/ ? "_" : c
            }
            body = body (c == q ? "_" : c)
        }
        x = substr(x, i + 1)
        out = out q body q
    }
    return out x
}
# The allow-lists of the mirror span, once MIRROR has read its words: each env name and PATH, then each argument for its
# subcommand. A variable argument comes after --end-of-options, so git never reads its value as an option.
function mirrorok(e,    a, w, n, i, x, k, v, sc, opt, eoo) {
    if (e ~ /(^|[ \t=:])~/) return 0
    a = e
    sub("^" MLEAD "env[ \t]+-i[ \t]+", "", a)
    while (match(a, "^" MASSIGN)) {
        x = substr(a, 1, RLENGTH)
        sub(/[ \t]+$/, "", x)
        a = substr(a, RLENGTH + 1)
        k = substr(x, 1, index(x, "=") - 1)
        v = substr(x, index(x, "=") + 1)
        if (k == "GIT_SSH_COMMAND" ? x !~ "^" SSHCMD "$" : k !~ ENVOK) return 0
        if (k == "PATH" && v !~ "^" MVAR "$" && !sysdirs(v)) return 0
    }
    sub(/[ \t]*(\)|;([ \t]*\})?)?[ \t]*$/, "", a)
    n = split(a, w, /[ \t]+/)
    i = w[4] == "-c" ? 6 : 4
    sc = w[i]
    for (k = i + 1; k <= n; k++) gsub(q, "", w[k])
    if (sc == "cat-file") {
        if (w[i + 2] == "--end-of-options") { eoo = 1; w[i + 2] = w[i + 3]; n-- }
        return n == i + 2 && w[i + 1] ~ CATTYPE && w[i + 2] !~ /^-/ && (eoo || w[i + 2] !~ "^" MVAR "$")
    }
    opt = sc == "fetch" ? FETCHOPT : sc == "rev-parse" ? REVOPT : sc == "log" ? LOGOPT : BASEOPT
    for (i++; i <= n; i++) {
        x = w[i]
        if (x ~ "^" MVAR "$" && !eoo) return 0
        if (sc == "log" && x == "-n" && w[i + 1] ~ /^[0-9]+$/) { i++; continue }
        if (x ~ /^-/ && x !~ opt) return 0
        if (x == "--end-of-options") eoo = 1
    }
    return 1
}
# A PATH of system directories only: an empty entry is the working directory.
function sysdirs(v,    d, n, i) {
    n = split(v, d, ":")
    for (i = 1; i <= n; i++) if (d[i] !~ "^" SYSDIR "$") return 0
    return n > 0
}
# Every rule but -n over a line and its de-quoted copy: bash drops a quote or backslash inside a word, so --no-"verify" is the long flag.
function both(p,    d) {
    rules(tolower(p), p)
    d = p
    gsub("\\$[\"" q "]", "", d)
    gsub("[\"" q "\\\\]", "", d)
    rules(tolower(d), d)
}
# The -n rule reads quotes as bash does, so a -m message is no flag: as written, and with the quotes in each word joined.
function nrule(s) { return tolower(s) ~ ARGV_N || shortn(tolower(s)) || shortn(shellwords(tolower(s), 1)) }
function judge(file, n, s, argvn,    p, e, k) {
    found = ""
    split("", seen)
    # The mirror pass: env -i, a HOME from one quoted variable, git -C <dir>, at most -c gpg.program="$X", then fetch,
    # rev-parse, log, cat-file or merge-base to the line end, each word bash-literal or one quoted variable (MWORD).
    p = s
    e = match(p, MIRROR) ? substr(p, RSTART, RLENGTH) : ""
    if (e != "" && mirrorok(e) && match(p, MIRROR)) { e = substr(p, RSTART, RLENGTH); sub("[ \t]" VARHOME "[ \t]", " ", e); sub(/env[ \t]+-i/, "env", e); p = substr(p, 1, RSTART - 1) e substr(p, RSTART + RLENGTH) }
    # The line is judged as written and with each ANSI-C string decoded, a union: a stray dollar-quote must not hide the rest.
    both(p)
    both(ansic(p))
    if (argvn || nrule(s) || nrule(ansic(s))) hit("commit or merge -n (a short --no-verify)")
    sub(/^\.\//, "", file)
    if (found == "") return
    k = (file in lpath) ? file SUBSEP sha256(first) : ""
    if ((k in allowed) && ++count[k] <= allowed[k]) { at[k] = at[k] " " n; text[k] = first; return }
    printf "%s:%d:%s\n", file, n, found
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
    NAME = "[A-Za-z_][A-Za-z0-9_]*"
    GITNAME = "([A-Za-z_][A-Za-z0-9_]*)?(GIT|git)[A-Za-z0-9_]*"
    COMMAND = "[^ \t;&|=]+([ \t;&|)`]|$)"
    # A mirror word is bash-literal (no glob, brace, expansion, escape or quote) or exactly one double-quoted variable.
    MLIT = "[A-Za-z0-9_./:@^~+=%-]+"
    MVAR = "\"\\$(" NAME "|\\{" NAME "\\})\""
    MWORD = "(" MLIT "|" MVAR ")"
    # An argument may also join single-quoted parts, inert to bash, with no blank: its options are read de-quoted.
    MQ = q "[^" q " \t]*" q
    MARG = "((" MLIT "|" MQ ")+|" MVAR ")"
    VARHOME = "HOME=" MVAR
    SYSDIR = "/(usr/(local/)?)?s?bin"
    # git, the git of a system directory, or one quoted variable named for git.
    MGIT = "(git|" SYSDIR "/git|\"\\$" GITNAME "\"|\"\\$\\{" GITNAME "\\}\")"
    # The one ssh command a mirror fetch may run: the key from one variable, expanded once by sh, quoted.
    SSHCMD = "GIT_SSH_COMMAND=" q "ssh -i \"\\$(SSH_KEY|\\{SSH_KEY\\})\" -o IdentitiesOnly=yes -o BatchMode=yes" q
    MASSIGN = "(" NAME "=" MWORD "?|" SSHCMD ")[ \t]+"
    # Before env, only blanks and one opening: no eval, ssh or quote can parse the values again, and no other command.
    MLEAD = "[ \t]*((local[ \t]+)?" NAME "=\\$\\(|" NAME "\\(\\)[ \t]*\\{|[{(])?[ \t]*"
    MPRE = "^" MLEAD "env[ \t]+-i[ \t]+(" MASSIGN ")*" VARHOME "[ \t]+(" MASSIGN ")*"
    # decision: the-mirror-pass-reads-its-own-arguments
    GPGC = "([ \t]+-c[ \t]+gpg\\.program=\"\\$(" NAME "|\\{" NAME "\\})\")?"
    MIRROR = MPRE MGIT "[ \t]+-C[ \t]+" MWORD GPGC "[ \t]+(fetch|rev-parse|log|cat-file|merge-base)([ \t]+" MARG ")*[ \t]*(\\)|;([ \t]*\\})?)?[ \t]*$"
    ENVOK = "^(PATH|GNUPGHOME|GIT_NO_REPLACE_OBJECTS|HOME|SSH_KEY)$"
    FETCHOPT = "^--(quiet|no-tags|prune|end-of-options)$"
    REVOPT = "^--(verify|quiet|end-of-options)$"
    LOGOPT = "^(-[0-9]+|--(format|pretty)=.*|--end-of-options)$"
    BASEOPT = "^--(is-ancestor|end-of-options)$"
    CATTYPE = "^(commit|tree|blob|tag|-t|-s|-e|-p)$"
    HEX = "0123456789abcdef"
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
    while ((getline lp < ENVIRON["HBS_LINES"]) > 0 && (getline lt < ENVIRON["HBS_LINES"]) > 0) { allowed[lp, lt]++; lpath[lp] = 1 }
}
FNR == 1 { if (held != "") judge(prev, start, held, 0); held = ""; incommit = 0; inrun = 0; prev = FILENAME }
{
    # An empty '' or "" splits a word for nothing (c''ommit is commit), so each pair is dropped first, even inside quotes.
    line = $0
    gsub(EMPTY, "", line)
    if (held == "") {
        first = $0
        if (comment(FILENAME, tolower(line))) { judge(FILENAME, FNR, line, 0); next }
        start = FNR
    }
    s = held line
    if (s ~ /\\$/) { held = substr(s, 1, length(s) - 1); next }
    held = ""
    judge(FILENAME, start, s, elements(FILENAME, tolower(s)))
}
END {
    if (held != "") judge(prev, start, held, 0)
    # One skip permits one line; each applied skip is printed with its text and how many finding lines hash to it, 0 is stale.
    for (k in allowed) {
        split(k, a, SUBSEP)
        if (!count[k]) { printf "hook-bypass-scan: stale line skip %s:%s, no finding line hashes to it; drop it.\n", a[1], a[2] > ENVIRON["HBS_STALE"]; continue }
        m = split(substr(at[k], 2), ns, " ")
        for (i = 1; i <= m; i++) printf "hook-bypass-scan: skipped %s:%d sha256 %s (%d finding line(s) hash to it): %s\n", a[1], ns[i], a[2], count[k], text[k] > ENVIRON["HBS_SKIPPED"]
    }
}
' "${files[@]}") || { printf 'hook-bypass-scan: awk could not read the tree, so nothing was judged.\n' >&2; exit 2; }

cat -- "${skipped}"
if [ -z "${findings}" ] && [ ! -s "${stale}" ]; then printf 'hook-bypass-scan: ok (%d files)\n' "${#files[@]}"; exit 0; fi
[ -z "${findings}" ] || while IFS= read -r f; do printf 'hook-bypass-scan: %s — a commit here would skip the fleet hook (S1); report a blocked commit, never route around it.\n' "${f}" >&2; done <<<"${findings}"
cat -- "${stale}" >&2
exit 1
