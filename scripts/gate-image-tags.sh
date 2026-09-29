#!/usr/bin/env bash
# T9's check: a gate must not build an image tag production runs. Given a
# project root it reads the compose files beside it, splits them into gate ones
# (*e2e*, *ci*) and production ones, resolves `${VAR:-default}`, and fails
# naming the file and line when one BUILT tag appears on both sides.
#
#   scripts/gate-image-tags.sh /var/www/<project>
#
# A compose file judged alone is not what a gate runs: `-f base -f ci` merges
# them, so the tag the gate builds is the overlay's on the base's `build:`. The
# check reads scripts/{check,ci,e2e,gate}.sh for the file sets their compose
# calls pass (-f, an exported COMPOSE_FILE — including one set in a file they
# source — or compose's own default base-and-override pair) and judges each
# merged set. A variable is read from the assignments above the call, never
# from the file's last one. Everything it cannot read is printed, never
# assumed: an unresolved -f value, a call whose subcommand was never reached,
# and any line naming `docker compose` that yielded no call at all.
#
# A pinned third-party image (postgres:18-alpine) is shared on purpose and is
# never a finding — only a tag something here builds can be overwritten. The
# check never stays silent and never passes on nothing: it prints the files it
# read, the unresolved values and the built-tag count, and refuses (exit 2) a
# root where no `.yml` beside it carries a `services:` key — a wrong root.
#
# A service that builds and names no `image:` is not untagged: compose tags it
# `<project>-<service>`, so that tag is resolved and compared like a written one,
# with the project taken from the file's `name:`, or — when it declares none —
# from the names the production files beside it declare and the directory,
# because one invocation carries one project name; a name only a gate file
# declares is that gate invocation's own and is never offered to production.
# Its file:line is the service's own line, the only line there is. `build.tags`
# entries are built tags too; a service body these line-regexes cannot read is
# reported unresolved rather than skipped.
set -uo pipefail

usage() { printf 'usage: gate-image-tags.sh [project-root]\n' >&2; exit 2; }

case "${1:-}" in -h|--help) usage ;; esac
ROOT="${1:-.}"
[ -d "${ROOT}" ] || { printf 'gate-image-tags: not a directory: %s\n' "${ROOT}" >&2; exit 2; }
ROOT="$(cd -- "${ROOT}" && pwd)"

# -L so a symlinked compose file is read rather than skipped. A name outside the
# compose conventions is read when it carries a top-level `services:`, because a
# file compose can be pointed at is a file a gate can build from.
FILES=()
while IFS= read -r f; do
    case "$(basename -- "${f}")" in
        docker-compose*.yml|docker-compose*.yaml|compose*.yml|compose*.yaml) ;;
        *) grep -qE '^"?services"? *:' "${f}" || continue ;;
    esac
    FILES+=("${f}")
done < <(
    find -L "${ROOT}" -maxdepth 1 -type f \
        \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C sort)

printf 'gate-image-tags: %s\n' "${ROOT}"
if [ "${#FILES[@]}" -eq 0 ]; then
    printf 'gate-image-tags: no compose file beside this root — nothing was examined, so %s is refused, not passed (T9)\n' "${ROOT}" >&2
    exit 2
fi

RECORDS="$(mktemp)"
trap 'rm -f "${RECORDS}"' EXIT

# img|unres, side, file, line, tag, built, inherited — one record per `image:`.
read_images() {
    awk -v side="$2" -v file="$3" -v dir="$4" -v cands="$5" '
        function ind(s) { match(s, /^ */); return RLENGTH }
        function skippable(s) { return (s ~ /^ *$/ || s ~ /^ *#/) }
        function unquote(v) {
            q = sprintf("%c", 39)
            if (substr(v, 1, 1) == q || substr(v, 1, 1) == "\"") v = substr(v, 2)
            if (substr(v, length(v), 1) == q || substr(v, length(v), 1) == "\"") v = substr(v, 1, length(v) - 1)
            return v
        }
        function brace(s) { gsub(/\$\{[^}]*\}/, "", s); return index(s, "{") }
        # No tag carries flow-map punctuation: a value holding it was read in part.
        function flowish(v,   s) { s = v; gsub(/\$\{[^}]*\}/, "", s); return (s ~ /[][{},]/) }
        # The key of a mapping line, dequoted: "image" and image come back alike.
        function keyword(s,   k) {
            k = s
            sub(/^ */, "", k)
            if (k !~ /:/) return ""
            sub(/ *:.*$/, "", k)
            return unquote(k)
        }
        function resolve(v,   d) {
            while (match(v, /\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*\}/)) {
                d = substr(v, RSTART, RLENGTH)
                sub(/^\$\{[A-Za-z_][A-Za-z0-9_]*:-/, "", d)
                sub(/\}$/, "", d)
                v = substr(v, 1, RSTART - 1) d substr(v, RSTART + RLENGTH)
            }
            return v
        }
        # Compose lower-cases a project name and drops what is not [a-z0-9_-].
        function normproj(s,   out, i, c) {
            s = tolower(s)
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c ~ /[a-z0-9_-]/) out = out c
            }
            sub(/^[_-]+/, "", out)
            return out
        }
        # A registry may carry a port and a digest has no tag, so only a last
        # path segment without a colon is missing one.
        function normtag(v,   last) {
            if (v ~ /@/) return v
            last = v
            sub(/^.*\//, "", last)
            if (last !~ /:/) v = v ":latest"
            return v
        }
        # An `image:` line as a tag, or "?" where the value cannot be read.
        function imgvalue(s,   v, raw) {
            v = s
            sub(/^ *image *: */, "", v)
            sub(/ +#.*$/, "", v)
            sub(/ +$/, "", v)
            v = unquote(v)
            raw = v
            v = resolve(v)
            if (v == "" || v ~ /\$/ || flowish(raw)) return "?"
            return normtag(v)
        }
        { sub(/\r$/, ""); L[NR] = $0 }
        END {
            q = sprintf("%c", 39)
            for (i = 1; i <= NR; i++) {
                if (L[i] !~ /^ *[^ #]+ *: *&[A-Za-z0-9_.-]+/) continue
                name = L[i]
                sub(/^[^&]*&/, "", name)
                sub(/[^A-Za-z0-9_.-].*$/, "", name)
                anchor[name] = 1
                I = ind(L[i])
                for (j = i + 1; j <= NR; j++) {
                    if (skippable(L[j])) continue
                    if (ind(L[j]) <= I) break
                    if (L[j] ~ /^ *build *:/) anchorbuild[name] = 1
                    if (L[j] ~ /^ *image *:/) { anchorimage[name] = 1; anchorimgv[name] = imgvalue(L[j]) }
                }
            }
            np = 0
            for (i = 1; i <= NR; i++) {
                if (L[i] !~ /^name *:/ || ind(L[i]) != 0) continue
                v = L[i]
                sub(/^name *: */, "", v)
                sub(/ +#.*$/, "", v)
                sub(/ +$/, "", v)
                v = normproj(resolve(unquote(v)))
                if (v != "") { np = 1; PROJ[1] = v }
                break
            }
            # One invocation carries one project name, so a file with no `name:`
            # of its own can be built under any name declared beside it.
            if (np == 0) {
                nc = split(cands, CA, "\t")
                for (i = 1; i <= nc; i++) {
                    v = normproj(resolve(unquote(CA[i])))
                    if (v == "" || projseen[v]++) continue
                    PROJ[++np] = v
                }
                if (np == 0) { np = 1; PROJ[1] = normproj(dir) }
            }
            for (i = 1; i <= NR; i++) {
                if (L[i] !~ /^ *image *:/) continue
                v = L[i]
                sub(/^ *image *: */, "", v)
                sub(/ +#.*$/, "", v)
                sub(/ +$/, "", v)
                v = unquote(v)
                raw = v
                v = resolve(v)
                if (v == "" || v ~ /\$/ || flowish(raw)) {
                    printf "unres\t%s\t%s\t%d\t%s\t0\t0\n", side, file, i, raw
                    continue
                }
                I = ind(L[i])
                st = 1
                for (j = i - 1; j >= 1; j--) {
                    if (skippable(L[j])) continue
                    if (ind(L[j]) < I) { st = j + 1; break }
                }
                en = NR
                for (j = i + 1; j <= NR; j++) {
                    if (skippable(L[j])) continue
                    if (ind(L[j]) < I) { en = j - 1; break }
                }
                built = 0
                inherited = 0
                for (j = st; j <= en; j++) {
                    if (ind(L[j]) != I) continue
                    if (L[j] ~ /^ *build *:/) { built = 1; continue }
                    if (L[j] ~ /^ *extends *:/) { built = 1; inherited = 1; continue }
                    if (L[j] !~ /^ *<< *: *\*/) continue
                    a = L[j]
                    sub(/^[^*]*\*/, "", a)
                    sub(/[^A-Za-z0-9_.-].*$/, "", a)
                    if (anchorbuild[a] || !anchor[a]) { built = 1; inherited = 1 }
                }
                printf "img\t%s\t%s\t%d\t%s\t%d\t%d\n", side, file, i, normtag(v), built, inherited
            }
            # build.tags names tags the build writes, beside or instead of image:.
            for (i = 1; i <= NR; i++) {
                if (L[i] !~ /^ *build *:/) continue
                BI = ind(L[i])
                for (j = i + 1; j <= NR; j++) {
                    if (skippable(L[j])) continue
                    if (ind(L[j]) <= BI) break
                    if (L[j] !~ /^ *tags *:/) continue
                    TI = ind(L[j])
                    v = L[j]
                    sub(/^ *tags *: */, "", v)
                    sub(/ +#.*$/, "", v)
                    sub(/ +$/, "", v)
                    if (v != "") {
                        printf "unres\t%s\t%s\t%d\ta build tags: list written in a form this check cannot read\t0\t0\n",
                            side, file, j
                        break
                    }
                    for (k = j + 1; k <= NR; k++) {
                        if (skippable(L[k])) continue
                        if (L[k] !~ /^ *- */) { if (ind(L[k]) <= TI) break; continue }
                        if (ind(L[k]) < TI) break
                        v = L[k]
                        sub(/^ *- */, "", v)
                        sub(/ +#.*$/, "", v)
                        sub(/ +$/, "", v)
                        v = unquote(v)
                        raw = v
                        v = resolve(v)
                        if (v == "" || v ~ /\$/ || flowish(raw)) {
                            printf "unres\t%s\t%s\t%d\t%s\t0\t0\n", side, file, k, raw
                            continue
                        }
                        printf "img\t%s\t%s\t%d\t%s\t1\t0\n", side, file, k, normtag(v)
                    }
                    break
                }
            }
            svcs = 0
            for (i = 1; i <= NR; i++) {
                if (ind(L[i]) == 0 && keyword(L[i]) == "services") { svcs = i; break }
            }
            if (svcs) {
                v = L[svcs]
                sub(/^[^:]*: */, "", v)
                sub(/ +#.*$/, "", v)
                if (v !~ /^ *$/)
                    printf "unres\t%s\t%s\t%d\tthe services of this file (written in a form this check cannot read)\t0\t0\n",
                        side, file, svcs
            }
            # A file whose services: this check never found still builds things.
            bre = "(^|[^A-Za-z0-9_.-])[\"" q "]?(image|build)[\"" q "]? *:"
            for (i = 1; !svcs && i <= NR; i++) {
                if (L[i] !~ bre) continue
                printf "unres\t%s\t%s\t%d\tthe services of this file (no top-level services: line this check can read)\t0\t0\n",
                    side, file, i
                break
            }
            SI = -1
            for (i = svcs + 1; svcs && i <= NR; i++) {
                if (skippable(L[i])) continue
                if (ind(L[i]) == 0) break
                if (SI < 0) SI = ind(L[i])
                if (ind(L[i]) != SI || L[i] !~ /^ *[^ #]+ *:/) continue
                svc = L[i]
                sub(/^ */, "", svc)
                sub(/ *:.*$/, "", svc)
                svc = unquote(svc)
                hasimage = 0; hasbuild = 0; inherited = 0; extended = 0; unknown = ""
                own = ""; viaanchor = ""
                murk = (L[i] !~ /^ *[A-Za-z0-9_.-]+ *:/ || brace(L[i]))
                DI = -1
                for (j = i + 1; j <= NR; j++) {
                    if (skippable(L[j])) continue
                    if (ind(L[j]) <= SI) break
                    if (DI < 0) DI = ind(L[j])
                    if (ind(L[j]) != DI) continue
                    kw = keyword(L[j])
                    if ((kw == "image" || kw == "build" || kw == "extends") &&
                        (brace(L[j]) || L[j] !~ /^ *(image|build|extends) *:/)) murk = 1
                    if (L[j] ~ /^ *image *:/) { hasimage = 1; own = imgvalue(L[j]); continue }
                    if (L[j] ~ /^ *build *:/) { hasbuild = 1; continue }
                    if (L[j] ~ /^ *extends *:/) { hasbuild = 1; inherited = 1; extended = 1; continue }
                    if (L[j] !~ /^ *<< *: *\*/) continue
                    a = L[j]
                    sub(/^[^*]*\*/, "", a)
                    sub(/[^A-Za-z0-9_.-].*$/, "", a)
                    if (anchorimage[a]) { hasimage = 1; viaanchor = anchorimgv[a] }
                    if (anchorbuild[a] || !anchor[a]) { hasbuild = 1; inherited = 1 }
                    if (!anchor[a]) unknown = a
                }
                # One record per service for the merged-set reader: what this file
                # alone says, before any overlay is laid over it.
                tg = (own != "" ? own : viaanchor)
                flag = "ok"
                if (murk) flag = "murk"
                else if (unknown != "" || (extended && tg == "")) flag = "unres"
                if (tg == "?") { tg = ""; flag = "unres" }
                printf "svc\t%s\t%s\t%d\t%s\t%s\t%d\t%s\n", side, file, i, svc, tg, hasbuild, flag
                # Fail closed: a body these line-regexes cannot read is not a pass.
                if (murk) {
                    printf "unres\t%s\t%s\t%d\tthe body of %s (written in a form this check cannot read)\t0\t0\n",
                        side, file, i, svc
                    continue
                }
                if (hasimage || !hasbuild) continue
                if (unknown != "") {
                    printf "unres\t%s\t%s\t%d\tthe image of %s (merges *%s, not defined here)\t0\t0\n",
                        side, file, i, svc, unknown
                    continue
                }
                if (extended) {
                    printf "unres\t%s\t%s\t%d\tthe image of %s (extends a service, whose image: is not read here)\t0\t0\n",
                        side, file, i, svc
                    continue
                }
                for (k = 1; k <= np; k++)
                    printf "img\t%s\t%s\t%d\t%s\t1\t%d\n", side, file, i, normtag(PROJ[k] "-" svc), inherited
            }
        }' "$1"
}

# One `set` record per compose call a gate script makes: the files it passes and
# whether they can be judged. A shell read by regex is read in part, so what this
# cannot resolve becomes a `setbad` record and is printed, never assumed away.
read_gate_sets() {
    awk -v script="$2" -v known="$3" -v defset="$4" -v root="$5" \
        -v prefile="$6" -v srcbad="$7" -v emit="$8" '
        function pad(c, n,   s, i) { s = ""; for (i = 0; i < n; i++) s = s c; return s }
        # C code, S single-quoted, D double-quoted, N comment, H heredoc body.
        function lex(   i, line, n, m, j, c, st, hd, nhd, tok, hre) {
            st = 0; hd = ""
            hre = "^<<[-~]?[ \t]*[\\\\\"" q "]?[A-Za-z_][A-Za-z0-9_]*[\"" q "]?"
            for (i = 1; i <= NR; i++) {
                line = L[i]; n = length(line); m = ""
                if (hd != "") {
                    tok = line; sub(/^[ \t]*/, "", tok); sub(/[ \t]*$/, "", tok)
                    if (tok == hd) hd = ""
                    M[i] = pad("H", n)
                    continue
                }
                j = 1; nhd = ""
                while (j <= n) {
                    c = substr(line, j, 1)
                    if (st == 1) { m = m "S"; if (c == q) st = 0; j++; continue }
                    if (st == 2) {
                        if (c == "\\" && j < n) { m = m "DD"; j += 2; continue }
                        m = m "D"; if (c == "\"") st = 0; j++; continue
                    }
                    if (c == "\\") { if (j < n) { m = m "CC"; j += 2 } else { m = m "C"; j++ } continue }
                    if (c == q) { st = 1; m = m "S"; j++; continue }
                    if (c == "\"") { st = 2; m = m "D"; j++; continue }
                    if (c == "#" && (j == 1 || substr(line, j - 1, 1) ~ /[ \t;&|(]/)) {
                        m = m pad("N", n - j + 1); j = n + 1; continue
                    }
                    if (substr(line, j, 2) == "<<" && substr(line, j, 3) != "<<<" && match(substr(line, j), hre)) {
                        tok = substr(line, j + RSTART - 1, RLENGTH)
                        sub(/^<<[-~]?[ \t]*/, "", tok)
                        gsub("[\"" q "\\\\]", "", tok)
                        nhd = tok
                        m = m pad("C", RLENGTH); j += RLENGTH; continue
                    }
                    m = m "C"; j++
                }
                M[i] = m
                if (nhd != "") hd = nhd
            }
        }
        # A command can run past its line: a trailing \ or an unclosed ( continues it.
        function needjoin(s, mk,   j, c, mc, depth) {
            depth = 0
            for (j = 1; j <= length(s); j++) {
                mc = substr(mk, j, 1); c = substr(s, j, 1)
                if (mc != "C") continue
                if (c == "(") depth++
                else if (c == ")" && depth > 0) depth--
            }
            if (depth > 0) return 1
            return (substr(s, length(s), 1) == "\\" && substr(mk, length(mk), 1) == "C")
        }
        function tokenize(s, mk,   j, n, c, mc, tok, cnt) {
            split("", T)
            cnt = 0; tok = ""; n = length(s)
            for (j = 1; j <= n; j++) {
                c = substr(s, j, 1); mc = substr(mk, j, 1)
                if (mc == "N" || mc == "H") break
                if (mc == "C" && c ~ /[ \t]/) { if (tok != "") { T[++cnt] = tok; tok = "" } continue }
                if (mc == "C" && c ~ /[;()&|{}<>]/) {
                    if (tok != "") { T[++cnt] = tok; tok = "" }
                    T[++cnt] = c; continue
                }
                tok = tok c
            }
            if (tok != "") T[++cnt] = tok
            return cnt
        }
        # Every assignment in file order, so a call reads what was set above it
        # rather than whatever the file happened to set last.
        function note(nm, val, ex, cond, ln) {
            nasg++; AN[nasg] = nm; AV[nasg] = val; AE[nasg] = ex; AC[nasg] = cond; AL[nasg] = ln
        }
        # The value a call reads: the assignments above it, in order. An
        # unconditional one replaces what is possible, one inside a branch adds
        # to it, and two possible values are not a value (VARSPLIT).
        function varval(nm, ln,   z, poss, np, S) {
            S = sprintf("%c", 1)
            poss = ""; np = 0; VARHAVE = 0; VARSPLIT = 0; VARIDX = 0
            for (z = 1; z <= nasg; z++) {
                if (AL[z] > ln || AN[z] != nm) continue
                VARHAVE = 1; VARIDX = z
                if (!AC[z]) { poss = AV[z]; np = 1; continue }
                if (index(S poss S, S AV[z] S) == 0) { poss = poss (np ? S : "") AV[z]; np++ }
            }
            VARSPLIT = (np > 1)
            return (VARSPLIT ? "" : poss)
        }
        function varexp(nm, ln,   z, e) {
            e = 0
            for (z = 1; z <= nasg; z++) if (AL[z] <= ln && AN[z] == nm && AE[z]) e = 1
            return e
        }
        function expand(v,   r, nm, val) {
            for (r = 0; r < 4; r++) {
                if (!match(v, /\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) break
                nm = substr(v, RSTART, RLENGTH)
                gsub(/[${}]/, "", nm)
                val = varval(nm, CURLN)
                if (VARSPLIT) { SPLITVAR = nm; return "" }
                if (!VARHAVE) break
                v = substr(v, 1, RSTART - 1) val substr(v, RSTART + RLENGTH)
            }
            EXPUNSET = match(v, /\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/) ? 1 : 0
            return v
        }
        function bad(t) { BAD = BAD (BAD ? "; " : "") t }
        # A record is held back until the end: a file set defined for a wrapper
        # is judged where the wrapper is used, so its own line says nothing.
        function out(t, d) { nout++; OUTT[nout] = t; OUTD[nout] = d }
        # A wrapper is read the way a variable is: the definitions above the use,
        # an unconditional one replacing what is possible and one inside a branch
        # adding to it. Two possible file sets are not a file set.
        function wrapval(nm, ln,   z, np, S, key, poss) {
            S = sprintf("%c", 1)
            poss = ""; np = 0
            WRAPHAVE = 0; WRAPSPLIT = 0; WFSET = ""; WBAD = ""; WNAMED = 0; WLINES = ""
            for (z = 1; z <= nwrap; z++) {
                if (WDL[z] >= ln || WDN[z] != nm) continue
                WRAPHAVE = 1
                WLINES = WLINES (WLINES ? "," : "") WDL[z]
                key = WDF[z] S WDB[z] S WDNM[z]
                if (!WDC[z]) { poss = key; np = 1 }
                else if (index(S poss S, S key S) == 0) { poss = poss (np ? S : "") key; np++ }
                WFSET = WDF[z]; WBAD = WDB[z]; WNAMED = WDNM[z]
            }
            WRAPSPLIT = (np > 1)
            return WRAPHAVE
        }
        # A compose file is named by its basename here, but a directory written
        # out must be this root: `-f infra/x.yml` is not the x.yml beside it.
        # A directory the script computes from its own path is this root; one
        # only the environment names is not a directory this check can resolve.
        function addfile(v,   b, d) {
            SPLITVAR = ""
            b = expand(v)
            gsub("[\"" q "]", "", b)
            if (SPLITVAR != "") {
                bad(v " (" SPLITVAR " takes more than one value above this line)"); return
            }
            if (index(b, "/")) {
                d = b; sub(/\/[^\/]*$/, "", d)
                if (d ~ /\$/) {
                    if (EXPUNSET) { bad(v " (under a directory only the environment names)"); return }
                } else if (d != "." && d != root) { bad(b " (not beside this root)"); return }
            }
            sub(/.*\//, "", b)
            if (b == "" || b ~ /\$/) { bad(v); return }
            if (index(known, "\t" b "\t") == 0) { bad(b); return }
            if (index("," FSET, "," b ",") == 0) FSET = FSET b ","
        }
        # `docker compose` as a command word, outside a comment. A line holding
        # one and yielding no call is printed, not read as no call at all.
        function mentions(s, mk,   p, seg) {
            seg = ""
            for (p = 1; p <= length(s); p++)
                seg = seg (substr(mk, p, 1) ~ /^[NH]$/ ? " " : substr(s, p, 1))
            return (seg ~ /docker[ \t]+compose([ \t]|$)/ || seg ~ /docker-compose([ \t;&|)]|$)/)
        }
        BEGIN {
            q = sprintf("%c", 39)
            while (prefile != "" && (getline pl < prefile) > 0)
                if (split(pl, PF, "\t") >= 5) note(PF[2], PF[3], PF[4], PF[5], PF[1])
            srcln = srcbad; sub(/:.*$/, "", srcln); srcln += 0
            srcpath = srcbad; sub(/^[0-9]*:/, "", srcpath)
        }
        { sub(/\r$/, ""); L[NR] = $0 }
        END {
            lex()
            for (i = 1; i <= NR; i++) {
                s = L[i]; mk = M[i]; j = i
                while (j < NR && needjoin(s, mk)) {
                    # The \ that joined the lines is not a token of the command.
                    if (substr(s, length(s), 1) == "\\" && substr(mk, length(mk), 1) == "C") {
                        s = substr(s, 1, length(s) - 1); mk = substr(mk, 1, length(mk) - 1)
                    }
                    j++; s = s " " L[j]; mk = mk "C" M[j]
                }
                if (substr(s, length(s), 1) == "\\" && substr(mk, length(mk), 1) == "C") {
                    s = substr(s, 1, length(s) - 1); mk = substr(mk, 1, length(mk) - 1)
                }
                LS[i] = s; LM[i] = mk; LE[i] = j
            }
            dep = 0
            for (i = 1; i <= NR; i++) {
                cnt = tokenize(LS[i], LM[i])
                head = 1; ex = 0; dmax = dep
                for (k = 1; k <= cnt; k++) {
                    t = T[k]
                    if (t ~ /^(if|case|for|while|until|\{)$/) { dep++; if (dep > dmax) dmax = dep }
                    else if (t ~ /^(fi|esac|done|\})$/) { if (dep) dep-- }
                    if (head && t == "export") { ex = 1; head = 0; continue }
                    if ((head || ex) && t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
                        nm = t; sub(/=.*$/, "", nm)
                        vv = t; sub(/^[^=]*=/, "", vv); gsub("[\"" q "]", "", vv)
                        note(nm, vv, (ex || (k < cnt && T[k + 1] !~ /^[;()&|{}<>]$/)) ? 1 : 0, \
                            (dep > 0) ? 1 : 0, i)
                        head = 0; continue
                    }
                    ex = 0
                    head = (t ~ /^[;()&|{}<>]$/ || t ~ /^(then|else|elif|do)$/) ? 1 : 0
                }
                LDEP[i] = dmax
            }
            if (emit == "assign") {
                for (z = 1; z <= nasg; z++)
                    printf "asg\t%s\t%s\t%d\t%d\n", AN[z], AV[z], AE[z], AC[z]
                exit
            }
            for (i = 1; i <= NR; i++) {
                CURLN = i
                cnt = tokenize(LS[i], LM[i])
                for (k = 1; k <= cnt; k++) {
                    start = 0; wrap = ""
                    if (T[k] == "docker" && T[k + 1] == "compose") start = k + 2
                    else if (T[k] == "docker-compose") start = k + 1
                    else {
                        nm = T[k]
                        gsub("[\"" q "]", "", nm)
                        sub(/^\$\{?/, "", nm); sub(/\[[@*]\]\}?$/, "", nm); sub(/\}$/, "", nm)
                        if (nm != T[k] && nm ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
                            vv = varval(nm, i)
                            if (VARHAVE && (vv ~ /^docker[ \t]+compose$/ || vv == "docker-compose")) {
                                start = k + 1; SEEN[AL[VARIDX]] = 1
                            } else if (wrapval(nm, i)) { start = k + 1; wrap = nm }
                        } else if (wrapval(nm, i) && (k == 1 || T[k - 1] ~ /^[;()&|{}<>]$/ ||
                                   T[k - 1] ~ /^(then|else|elif|do)$/)) { start = k + 1; wrap = nm }
                    }
                    if (!start) continue
                    FSET = ""; BAD = ""; subc = ""; named = 0; defline = 0
                    if (wrap != "") {
                        if (WRAPSPLIT) { bad(wrap " (more than one file set is possible above this line)"); named = 1 }
                        else { FSET = WFSET; BAD = WBAD; named = WNAMED }
                        nwl = split(WLINES, WL, ",")
                        for (z = 1; z <= nwl; z++) { SEEN[WL[z]] = 1; USEDDEF[WL[z]] = 1 }
                    }
                    for (p = start; p <= cnt; p++) {
                        t = T[p]
                        if (t ~ /^[;()}|&<>]$/) break
                        if (t == "-f" || t == "--file") { named = 1; addfile(T[++p]); continue }
                        if (t ~ /^--file=/) { named = 1; addfile(substr(t, 8)); continue }
                        if (t ~ /^-f./) {
                            vv = substr(t, 3); sub(/^=/, "", vv)
                            named = 1; addfile(vv); continue
                        }
                        if (t == "-p" || t == "--project-name" || t == "--env-file" || t == "--profile" ||
                            t == "--project-directory" || t == "--progress" || t == "--ansi" ||
                            t == "--parallel" || t == "-c" || t == "--context") { p++; continue }
                        if (t ~ /^-/) continue
                        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
                        subc = t; break
                    }
                    if (subc == "" || subc ~ /\$[@*]/) subc = "-"
                    # An array or function holding a file set but no subcommand
                    # of its own is judged where it is used, not where it is set.
                    if (wrap == "" && subc == "-") {
                        nm = ""
                        if (T[1] ~ /^[A-Za-z_][A-Za-z0-9_]*=$/ && T[2] == "(") { nm = T[1]; sub(/=$/, "", nm) }
                        else if (T[1] ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && T[2] == "(" && T[3] == ")") nm = T[1]
                        else if (T[1] == "function" && T[2] ~ /^[A-Za-z_][A-Za-z0-9_]*$/) nm = T[2]
                        if (nm != "") {
                            nwrap++; WDN[nwrap] = nm; WDL[nwrap] = i; WDC[nwrap] = (LDEP[i] > 0) ? 1 : 0
                            WDF[nwrap] = FSET; WDB[nwrap] = BAD; WDNM[nwrap] = named
                            defline = i
                        }
                    }
                    origin = (named ? "-f" : "")
                    if (!named) {
                        vv = varval("COMPOSE_FILE", i)
                        if (VARHAVE && varexp("COMPOSE_FILE", i)) {
                            origin = "COMPOSE_FILE"
                            if (VARSPLIT)
                                bad("COMPOSE_FILE (more than one value is set above this line)")
                            else {
                                nsep = split(vv, SEP, ":")
                                for (z = 1; z <= nsep; z++) addfile(SEP[z])
                            }
                        } else if (srcln && srcln < i) {
                            origin = "sourced"
                            bad("COMPOSE_FILE, which " srcpath " (sourced at line " srcln ") may set")
                        } else {
                            origin = "default"
                            nsep = split(defset, SEP, ",")
                            for (z = 1; z <= nsep; z++) if (SEP[z] != "") addfile(SEP[z])
                        }
                    }
                    # A call that inspects or tears down builds nothing, whatever
                    # named its files; a subcommand never read is not judged either.
                    idle = (subc ~ "^(down|ps|logs|config|version|ls|images|top|port|kill|stop|rm|" \
                                    "pause|unpause|events|wait|cp|convert|push|pull|-)$")
                    judged = idle ? 0 : 1
                    # A file this reader could not resolve is a file missing from
                    # the merge, so the rest of the set is not judged either.
                    if (BAD != "") judged = 0
                    builds = (subc ~ /^(build|up|run|create)$/) ? 1 : 0
                    if (FSET != "")
                        out(sprintf("set\t%s\t%d\t%d\t%s\t%s\t%s\t%d\t%d\n", \
                            script, i, judged, origin, subc, FSET, builds, (BAD != "") ? 1 : 0), defline)
                    if (BAD != "") out(sprintf("setbad\t%s\t%d\t%s\n", script, i, BAD), defline)
                    if (FSET != "" || BAD != "") for (z = i; z <= LE[i]; z++) SEEN[z] = 1
                }
            }
            for (z = 1; z <= nout; z++)
                if (!OUTD[z] || !USEDDEF[OUTD[z]]) printf "%s", OUTT[z]
            for (i = 1; i <= NR; i++)
                if (!SEEN[i] && mentions(L[i], M[i])) printf "mention\t%s\t%d\n", script, i
        }' "$1"
}

GATE_FILES=()
PROD_FILES=()
ODD_FILES=()
SIDES=()
for f in "${FILES[@]}"; do
    rel="${f#"${ROOT}"/}"
    side=production
    case "${rel}" in
        *e2e*|*ci*) side=gate; GATE_FILES+=("${rel}") ;;
        docker-compose.yml|docker-compose.yaml|compose.yml|compose.yaml|*prod*|*staging*)
            PROD_FILES+=("${rel}") ;;
        *) PROD_FILES+=("${rel}"); ODD_FILES+=("${rel}") ;;
    esac
    SIDES+=("${side}")
done

# The names a file that declares none of its own can be built under: what the
# production files declare, plus the directory. A gate file may also be run
# under its own side's names; production is never run under a gate-only one.
TAB="$(printf '\t')"
BASE="$(basename -- "${ROOT}")"
CANDS_PROD=''
CANDS_GATE=''
NAMES=()
for i in "${!FILES[@]}"; do
    n="$(awk '{ sub(/\r$/, "") }
        /^name *:/ { sub(/^name *: */, ""); sub(/ +#.*$/, ""); sub(/ +$/, ""); print; exit }' "${FILES[${i}]}")"
    NAMES+=("${n}")
    [ -n "${n}" ] || continue
    if [ "${SIDES[${i}]}" = gate ]; then CANDS_GATE="${CANDS_GATE}${n}${TAB}"
    else CANDS_PROD="${CANDS_PROD}${n}${TAB}"; fi
done
CANDS_GATE="${CANDS_PROD}${CANDS_GATE}${BASE}"
CANDS_PROD="${CANDS_PROD}${BASE}"

for i in "${!FILES[@]}"; do
    cands="${CANDS_PROD}"
    [ "${SIDES[${i}]}" != gate ] || cands="${CANDS_GATE}"
    read_images "${FILES[${i}]}" "${SIDES[${i}]}" "${FILES[${i}]#"${ROOT}"/}" "${BASE}" "${cands}" >>"${RECORDS}"
    printf 'fname\t%s\t%s\t%s\n' "${FILES[${i}]#"${ROOT}"/}" "${SIDES[${i}]}" "${NAMES[${i}]}" >>"${RECORDS}"
done

KNOWN="${TAB}"
for f in "${FILES[@]}"; do KNOWN="${KNOWN}${f#"${ROOT}"/}${TAB}"; done

# Compose's two searches when a call names no file: a base, then an override.
# Each runs its own extension order and neither depends on the other, so
# compose.yaml pairs with docker-compose.override.yml — see docs/DECISIONS.md.
DEFSET=''
for c in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    [ ! -f "${ROOT}/${c}" ] || { DEFSET="${c}"; break; }
done
for o in compose.override.yaml compose.override.yml \
         docker-compose.override.yaml docker-compose.override.yml; do
    [ -n "${DEFSET}" ] || break
    [ ! -f "${ROOT}/${o}" ] || { DEFSET="${DEFSET},${o}"; break; }
done

# A gate script may set COMPOSE_FILE in a file it sources, which may source
# another. The idioms naming the sourcing script's own directory are resolved
# against it; otherwise the leading variable of the path is dropped and the rest
# resolved under this root. A path that resolves to nothing readable makes that
# script's bare calls unjudged rather than falling through to compose's default.
resolve_sourced() {
    local v="$1" dir="$2" rest c pre
    # shellcheck disable=SC2016  # these are the sourcing script's own text, not ours
    for pre in '$(dirname $0)' '$(dirname $BASH_SOURCE)' '$(dirname ${BASH_SOURCE[0]})' \
               '${BASH_SOURCE%/*}' '${BASH_SOURCE[0]%/*}' '${0%/*}'; do
        case "${v}" in "${pre}/"*) v="${dir}/${v#"${pre}/"}"; break ;; esac
    done
    rest="${v}"
    case "${v}" in *'$'*) rest="${v#*/}" ;; esac
    case "${rest}" in *'$'*|'') return 1 ;; esac
    for c in "${rest}" "${ROOT}/${rest}" "${ROOT}/scripts/${rest}"; do
        [ -f "${c}" ] || continue
        c="$(cd -- "$(dirname -- "${c}")" && pwd)/$(basename -- "${c}")"
        case "${c}" in "${ROOT}"/*) printf '%s' "${c}"; return 0 ;; esac
    done
    return 1
}

PRE="$(mktemp)"
ASG="$(mktemp)"
trap 'rm -f "${RECORDS}" "${PRE}" "${ASG}"' EXIT

# Every assignment a gate script reaches through source, credited to the line
# that sourced it. A chain deeper than this, or a link that resolves to nothing
# readable, leaves that script's bare calls unjudged.
SRCDEPTH=4
scan_sources() {
    local g="$1" att="$2" depth="$3" dir ln raw sp use
    dir="$(dirname -- "${g}")"
    while IFS="${TAB}" read -r ln raw; do
        [ -n "${ln}" ] || continue
        use="${att:-${ln}}"
        if [ "${depth}" -ge "${SRCDEPTH}" ]; then
            [ -n "${SRCBAD}" ] || SRCBAD="${use}:${raw}"
            continue
        fi
        if sp="$(resolve_sourced "${raw}" "${dir}")"; then
            read_gate_sets "${sp}" "${sp#"${ROOT}"/}" '' '' "${ROOT}" '' '' assign >"${ASG}"
            awk -F'\t' -v ln="${use}" 'BEGIN { OFS = "\t" }
                $1 == "asg" { print ln, $2, $3, $4, $5 }' "${ASG}" >>"${PRE}"
            scan_sources "${sp}" "${use}" "$((depth + 1))"
        elif [ -z "${SRCBAD}" ]; then
            SRCBAD="${use}:${raw}"
        fi
    done < <(awk '{ sub(/\r$/, "") }
        /^[ \t]*(\.|source)[ \t]+[^ \t]/ {
            v = $0
            sub(/^[ \t]*(\.|source)[ \t]+/, "", v)
            if (v !~ /\$\(/) sub(/[ \t].*$/, "", v)
            sub(/[ \t]*$/, "", v)
            gsub(/["'"'"']/, "", v)
            printf "%d\t%s\n", NR, v
        }' "${g}")
}

# The gate entry points T1 and T6 name. A gate that lives under another name is
# not guessed at: the output says which scripts were read and which were not.
GATE_SCRIPTS=()
for s in check ci e2e gate; do
    g="${ROOT}/scripts/${s}.sh"
    [ -f "${g}" ] || continue
    GATE_SCRIPTS+=("scripts/${s}.sh")
    : >"${PRE}"
    SRCBAD=''
    scan_sources "${g}" '' 0
    read_gate_sets "${g}" "scripts/${s}.sh" "${KNOWN}" "${DEFSET}" "${ROOT}" \
        "${PRE}" "${SRCBAD}" '' >>"${RECORDS}"
done

ODD_LIST='|'
for rel in ${ODD_FILES[@]+"${ODD_FILES[@]}"}; do ODD_LIST="${ODD_LIST}${rel}|"; done

list() { local out='' s; for s in "$@"; do out="${out:+${out}, }${s}"; done; printf '%s' "${out:-none}"; }
printf '  gate files:       %s\n' "$(list "${GATE_FILES[@]}")"
printf '  production files: %s\n' "$(list "${PROD_FILES[@]}")"
[ "${#ODD_FILES[@]}" -eq 0 ] ||
    printf '  unrecognised:     %s — read as production, on filename alone\n' "$(list "${ODD_FILES[@]}")"
if [ "${#GATE_SCRIPTS[@]}" -eq 0 ]; then
    printf '  gate scripts:     none — scripts/{check,ci,e2e,gate}.sh\n'
else
    printf '  gate scripts:     %s\n' "$(list "${GATE_SCRIPTS[@]}")"
fi

awk -F'\t' -v root="${ROOT}" -v odd="${ODD_LIST}" -v base="${BASE}" '
    function normproj(s,   out, i, c) {
        s = tolower(s); out = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c ~ /[a-z0-9_-]/) out = out c
        }
        sub(/^[_-]+/, "", out)
        return out
    }
    function normtag(v,   last) {
        if (v ~ /@/) return v
        last = v
        sub(/^.*\//, "", last)
        if (last !~ /:/) v = v ":latest"
        return v
    }
    function pretty(k,   nf, FL, i, out) {
        nf = split(k, FL, ",")
        out = ""
        for (i = 1; i <= nf; i++) if (FL[i] != "") out = out (out ? " + " : "") FL[i]
        return out
    }
    # One gate run: the services of its files merged in order, the way compose
    # merges them — a later image: wins, a build: anywhere in the set builds.
    function evalset(k,   nf, FL, i, f, ns, SN, j, s, proj, tag, nord, MORD,
                     MSEEN, MTAG, MBUILT, MTSRC, MBSRC, MFLAG, ntag, TSEEN, TORD, TBUILT, TSVC) {
        nf = split(k, FL, ",")
        proj = ""; nord = 0
        for (i = 1; i <= nf; i++) {
            f = FL[i]
            if (f == "") continue
            if (PROJOF[f] != "") proj = PROJOF[f]
            ns = split(FSVCS[f], SN, " ")
            for (j = 1; j <= ns; j++) {
                s = SN[j]
                if (!MSEEN[s]) { MSEEN[s] = 1; MORD[++nord] = s }
                if (SVCTAG[f, s] != "") { MTAG[s] = SVCTAG[f, s]; MTSRC[s] = f ":" SVCLINE[f, s] }
                if (SVCBUILT[f, s] == 1) { MBUILT[s] = 1; MBSRC[s] = f ":" SVCLINE[f, s] }
                if (SVCFLAG[f, s] != "ok") MFLAG[s] = 1
            }
        }
        proj = normproj(proj != "" ? proj : base)
        ntag = 0
        for (i = 1; i <= nord; i++) {
            s = MORD[i]
            tag = MTAG[s]
            # The implicit tag is invented only where the service was read whole:
            # a body or an image this check could not read is already unresolved.
            if (tag == "" && MBUILT[s] && !MFLAG[s]) tag = normtag(proj "-" s)
            if (tag == "") continue
            if (MBUILT[s] && index("," SETBUILT[k] ",", "," tag ",") == 0)
                SETBUILT[k] = SETBUILT[k] (SETBUILT[k] ? "," : "") tag
            if (!pbuilt[tag]) continue
            if (!TSEEN[tag]) { TSEEN[tag] = 1; TORD[++ntag] = tag }
            if (MBUILT[s]) TBUILT[tag] = 1
            TSVC[tag] = TSVC[tag] (TSVC[tag] ? ", " : "") \
                sprintf("%s (%s)", s, (MBUILT[s] ? "build at " MBSRC[s] : "image at " MTSRC[s]))
        }
        for (i = 1; i <= ntag; i++) {
            tag = TORD[i]
            nrun++
            runs[nrun] = sprintf("FAIL %s: the gate run at %s %s image tag %s, which production is recreated from\n", \
                root, SETSRC[k], ((SETBUILDS[k] == 1 && TBUILT[tag]) ? "builds" : "runs"), tag)
            runs[nrun] = runs[nrun] sprintf("  gate run:   %s over %s (%s)\n", \
                (SETSUB[k] == "-" ? "docker compose" : "docker compose " SETSUB[k]), pretty(k), SETORIGIN[k])
            runs[nrun] = runs[nrun] sprintf("  services:   %s\n", TSVC[tag])
            runs[nrun] = runs[nrun] p[tag]
        }
    }
    $1 == "svc" {
        if (!seensvc[$3, $5]) {
            seensvc[$3, $5] = 1
            if (FSVCS[$3] == "") FORDER[++nfiles] = $3
            FSVCS[$3] = FSVCS[$3] (FSVCS[$3] ? " " : "") $5
        }
        if ($2 != "gate" && $7 == "1") PRODBUILDS[$5] = $3 ":" $4
        SVCLINE[$3, $5] = $4; SVCTAG[$3, $5] = $6; SVCBUILT[$3, $5] = $7; SVCFLAG[$3, $5] = $8
        SVCSIDE[$3] = $2
        next
    }
    $1 == "fname" { PROJOF[$2] = $4; next }
    # Several calls can pass the same set. The one named in a finding is the one
    # that can build it (build, up, run, create), and a judged call before an
    # unjudged one — otherwise the report points at a call that rebuilds nothing.
    $1 == "set" {
        k = $7
        r = $4 * 2 + $8
        if (!(k in setseen)) { setseen[k] = 1; SETKEY[++nsets] = k; SETRANK[k] = -1 }
        if (r > SETRANK[k]) {
            SETRANK[k] = r; SETJUDGE[k] = $4; SETSRC[k] = $2 ":" $3
            SETORIGIN[k] = $5; SETSUB[k] = $6; SETBUILDS[k] = $8; SETUNREAD[k] = $9
        }
        nf = split(k, FL, ",")
        for (i = 1; i <= nf; i++) if (FL[i] != "") INSET[FL[i]] = 1
        next
    }
    $1 == "mention" {
        nment++
        mlist = mlist (mlist ? "; " : "") sprintf("%s:%d", $2, $3)
        next
    }
    $1 == "setbad" {
        nsetbad++
        sblist = sblist (sblist ? "; " : "") sprintf("%s in %s:%d", $4, $2, $3)
        next
    }
    $1 == "unres" {
        nunres++
        ulist = ulist (ulist ? "; " : "") sprintf("%s in %s:%d", $5, $3, $4)
        next
    }
    $1 == "img" {
        nres++
        tags[$5] = 1
        if ($6 == "1") built[$5] = 1
        if ($6 == "1" && $2 != "gate") pbuilt[$5] = 1
        if ($7 == "1") ninherited++
        if ($6 == "1" && index(odd, "|" $3 "|") && !oddseen[$3]) {
            oddseen[$3] = 1
            noddfiles++
            oddlist = oddlist (oddlist ? ", " : "") $3
        }
        if ($2 == "gate") { g[$5] = g[$5] sprintf("  gate:       %s:%s\n", $3, $4); gn[$5]++ }
        else              { p[$5] = p[$5] sprintf("  production: %s:%s\n", $3, $4); pn[$5]++ }
        next
    }
    END {
        for (i = 1; i <= nsets; i++) if (SETJUDGE[SETKEY[i]]) evalset(SETKEY[i])
        printf "  images:           %d resolved, %d unresolved", nres, nunres
        if (nunres) printf " — %s", ulist
        printf "\n"
        nbuilt = 0
        for (t in tags) if (built[t]) nbuilt++
        printf "  built tags:       %d", nbuilt
        if (ninherited) printf " (%d value(s) inherit a build through <<: or extends)", ninherited
        printf "\n"
        runsline = ""
        for (i = 1; i <= nsets; i++) {
            k = SETKEY[i]
            runsline = runsline (runsline ? "; " : "") sprintf("%s (%s, %s) %s", pretty(k), SETSRC[k], SETORIGIN[k], \
                (SETJUDGE[k] ? (SETBUILT[k] ? ((SETBUILDS[k] == 1 ? "builds " : "runs ") SETBUILT[k]) : "builds nothing") \
                 : (SETUNREAD[k] == 1 ? "not judged — a file it names was not read" \
                    : (SETSUB[k] == "-" ? "not judged — no subcommand read" : SETSUB[k] " builds nothing"))))
        }
        printf "  gate runs:        %s\n", (runsline ? runsline : "none read beside this root")
        if (nsetbad) printf "  unread -f values: %s\n", sblist
        # A line naming docker compose that yielded no call — an eval, a wrapper
        # this reader cannot follow, or plain help text. Printed, never counted.
        if (nment)
            printf "  unjudged calls:   %s — a line naming docker compose that this reader could not read as a call\n", \
                mlist
        # An overlay tagging a service it does not build takes that build from the
        # file beside it. Naming production`s own tag there is already a shared
        # tag below; naming another is only as safe as the pairing, so say so.
        for (i = 1; i <= nfiles; i++) {
            f = FORDER[i]
            if (SVCSIDE[f] != "gate" || INSET[f]) continue
            ns = split(FSVCS[f], SN, " ")
            for (j = 1; j <= ns; j++) {
                s = SN[j]
                if (SVCTAG[f, s] == "" || SVCBUILT[f, s] == "1" || PRODBUILDS[s] == "") continue
                loose = loose (loose ? "; " : "") sprintf("%s:%s tags %s %s, over the build at %s", \
                    f, SVCLINE[f, s], s, SVCTAG[f, s], PRODBUILDS[s])
            }
        }
        if (loose) printf "  overlay tags:     %s — in no gate run read here\n", loose
        n = 0
        for (t in tags) if (built[t] && gn[t] && pn[t]) bad[++n] = t
        if (n == 0 && noddfiles == 0 && nrun == 0 && nsetbad == 0) {
            if (nbuilt == 0) {
                printf "ok %s: no built image tag resolved here — nothing a gate run could overwrite\n", root
                exit 0
            }
            printf "ok %s: %d built image tag(s), none shared between the gate and production", root, nbuilt
            if (nunres) printf " — %d value(s) unresolved and not judged", nunres
            printf "\n"
            exit 0
        }
        for (i = 2; i <= n; i++) {
            v = bad[i]; j = i - 1
            while (j >= 1 && bad[j] > v) { bad[j + 1] = bad[j]; j-- }
            bad[j + 1] = v
        }
        for (i = 1; i <= n; i++) {
            t = bad[i]
            printf "FAIL %s: image tag %s is built for the gate and run in production\n", root, t
            printf "%s%s", g[t], p[t]
        }
        for (i = 1; i <= nrun; i++) printf "%s", runs[i]
        if (nsetbad)
            printf "FAIL %s: %d compose call(s) here name files this check could not read, so what they build is not judged\n", \
                root, nsetbad
        if (noddfiles) {
            printf "FAIL %s: %s builds an image tag and is named neither for the gate nor for production", root, oddlist
            printf " — rename it *ci* or *e2e* if a gate run builds it, *prod* if production runs it\n"
        }
        if (n) printf "gate-image-tags: %d shared tag(s) — a gate run can overwrite what production is recreated from (T9)\n", n
        if (nrun) printf "gate-image-tags: %d gate run(s) reach a tag production is recreated from (T9)\n", nrun
        if (noddfiles) printf "gate-image-tags: %d unrecognised compose file(s) build a tag — which side builds it is a guess (T9)\n", noddfiles
        if (nsetbad) printf "gate-image-tags: %d unread compose call(s) — a set this check cannot read is a set it cannot clear (T9)\n", nsetbad
        exit 1
    }' "${RECORDS}"
