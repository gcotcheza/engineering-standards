#!/usr/bin/env bash
# T9's check: a gate must not build an image tag production runs. Given a
# project root it reads the compose files beside it, splits them into gate ones
# (*e2e*, *ci*) and production ones, resolves `${VAR:-default}`, and fails
# naming the file and line when one BUILT tag appears on both sides.
#
#   scripts/gate-image-tags.sh /var/www/<project>
#
# A pinned third-party image (postgres:18-alpine) is shared on purpose and is
# never a finding — only a tag something here builds can be overwritten. The
# check never stays silent: it always prints the files it read, the values it
# could not resolve and the built-tag count, because a silent pass made "nothing
# is built here" and "I could not tell" look identical.
#
# A service that builds and names no `image:` is not untagged: compose tags it
# `<project>-<service>`, so that tag is resolved and compared like a written one,
# with the project taken from the file's `name:` or the directory. Its file:line
# is the service's own line, the only line there is.
set -uo pipefail

usage() { printf 'usage: gate-image-tags.sh [project-root]\n' >&2; exit 2; }

case "${1:-}" in -h|--help) usage ;; esac
ROOT="${1:-.}"
[ -d "${ROOT}" ] || { printf 'gate-image-tags: not a directory: %s\n' "${ROOT}" >&2; exit 2; }
ROOT="$(cd -- "${ROOT}" && pwd)"

# -L so a symlinked compose file is read rather than skipped.
FILES=()
while IFS= read -r f; do FILES+=("${f}"); done < <(
    find -L "${ROOT}" -maxdepth 1 -type f \
        \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
        -o -name 'compose*.yml' -o -name 'compose*.yaml' \) | LC_ALL=C sort)

printf 'gate-image-tags: %s\n' "${ROOT}"
if [ "${#FILES[@]}" -eq 0 ]; then
    printf '  no compose file beside this root — nothing was examined\n'
    exit 0
fi

RECORDS="$(mktemp)"
trap 'rm -f "${RECORDS}"' EXIT

# img|unres, side, file, line, tag, built, inherited — one record per `image:`.
read_images() {
    awk -v side="$2" -v file="$3" -v dir="$4" '
        function ind(s) { match(s, /^ */); return RLENGTH }
        function skippable(s) { return (s ~ /^ *$/ || s ~ /^ *#/) }
        function unquote(v) {
            q = sprintf("%c", 39)
            if (substr(v, 1, 1) == q || substr(v, 1, 1) == "\"") v = substr(v, 2)
            if (substr(v, length(v), 1) == q || substr(v, length(v), 1) == "\"") v = substr(v, 1, length(v) - 1)
            return v
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
                    if (L[j] ~ /^ *image *:/) anchorimage[name] = 1
                }
            }
            proj = normproj(dir)
            for (i = 1; i <= NR; i++) {
                if (L[i] !~ /^name *:/ || ind(L[i]) != 0) continue
                v = L[i]
                sub(/^name *: */, "", v)
                sub(/ +#.*$/, "", v)
                sub(/ +$/, "", v)
                v = normproj(resolve(unquote(v)))
                if (v != "") proj = v
                break
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
                if (v == "" || v ~ /\$/) {
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
            svcs = 0
            for (i = 1; i <= NR; i++) {
                if (L[i] ~ /^services *:/ && ind(L[i]) == 0) { svcs = i; break }
            }
            SI = -1
            for (i = svcs + 1; svcs && i <= NR; i++) {
                if (skippable(L[i])) continue
                if (ind(L[i]) == 0) break
                if (SI < 0) SI = ind(L[i])
                if (ind(L[i]) != SI || L[i] !~ /^ *[A-Za-z0-9_.-]+ *:/) continue
                svc = L[i]
                sub(/^ */, "", svc)
                sub(/ *:.*$/, "", svc)
                hasimage = 0; hasbuild = 0; inherited = 0; unknown = ""
                DI = -1
                for (j = i + 1; j <= NR; j++) {
                    if (skippable(L[j])) continue
                    if (ind(L[j]) <= SI) break
                    if (DI < 0) DI = ind(L[j])
                    if (ind(L[j]) != DI) continue
                    if (L[j] ~ /^ *image *:/) { hasimage = 1; continue }
                    if (L[j] ~ /^ *build *:/) { hasbuild = 1; continue }
                    if (L[j] ~ /^ *extends *:/) { hasbuild = 1; inherited = 1; continue }
                    if (L[j] !~ /^ *<< *: *\*/) continue
                    a = L[j]
                    sub(/^[^*]*\*/, "", a)
                    sub(/[^A-Za-z0-9_.-].*$/, "", a)
                    if (anchorimage[a]) hasimage = 1
                    if (anchorbuild[a] || !anchor[a]) { hasbuild = 1; inherited = 1 }
                    if (!anchor[a]) unknown = a
                }
                if (hasimage || !hasbuild) continue
                if (unknown != "") {
                    printf "unres\t%s\t%s\t%d\tthe image of %s (merges *%s, not defined here)\t0\t0\n",
                        side, file, i, svc, unknown
                    continue
                }
                printf "img\t%s\t%s\t%d\t%s\t1\t%d\n", side, file, i, normtag(proj "-" svc), inherited
            }
        }' "$1"
}

GATE_FILES=()
PROD_FILES=()
ODD_FILES=()
for f in "${FILES[@]}"; do
    rel="${f#"${ROOT}"/}"
    side=production
    case "${rel}" in
        *e2e*|*ci*) side=gate; GATE_FILES+=("${rel}") ;;
        docker-compose.yml|docker-compose.yaml|compose.yml|compose.yaml|*prod*|*staging*)
            PROD_FILES+=("${rel}") ;;
        *) PROD_FILES+=("${rel}"); ODD_FILES+=("${rel}") ;;
    esac
    read_images "${f}" "${side}" "${rel}" "$(basename -- "${ROOT}")" >>"${RECORDS}"
done

ODD_LIST='|'
for rel in ${ODD_FILES[@]+"${ODD_FILES[@]}"}; do ODD_LIST="${ODD_LIST}${rel}|"; done

list() { local out='' s; for s in "$@"; do out="${out:+${out}, }${s}"; done; printf '%s' "${out:-none}"; }
printf '  gate files:       %s\n' "$(list "${GATE_FILES[@]}")"
printf '  production files: %s\n' "$(list "${PROD_FILES[@]}")"
[ "${#ODD_FILES[@]}" -eq 0 ] ||
    printf '  unrecognised:     %s — read as production, on filename alone\n' "$(list "${ODD_FILES[@]}")"

awk -F'\t' -v root="${ROOT}" -v odd="${ODD_LIST}" '
    $1 == "unres" {
        nunres++
        ulist = ulist (ulist ? "; " : "") sprintf("%s in %s:%d", $5, $3, $4)
        next
    }
    {
        nres++
        tags[$5] = 1
        if ($6 == "1") built[$5] = 1
        if ($7 == "1") ninherited++
        if ($6 == "1" && index(odd, "|" $3 "|") && !oddseen[$3]) {
            oddseen[$3] = 1
            noddfiles++
            oddlist = oddlist (oddlist ? ", " : "") $3
        }
        if ($2 == "gate") { g[$5] = g[$5] sprintf("  gate:       %s:%s\n", $3, $4); gn[$5]++ }
        else              { p[$5] = p[$5] sprintf("  production: %s:%s\n", $3, $4); pn[$5]++ }
    }
    END {
        printf "  images:           %d resolved, %d unresolved", nres, nunres
        if (nunres) printf " — %s", ulist
        printf "\n"
        nbuilt = 0
        for (t in tags) if (built[t]) nbuilt++
        printf "  built tags:       %d", nbuilt
        if (ninherited) printf " (%d value(s) inherit a build through <<: or extends)", ninherited
        printf "\n"
        n = 0
        for (t in tags) if (built[t] && gn[t] && pn[t]) bad[++n] = t
        if (n == 0 && noddfiles == 0) {
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
        if (noddfiles) {
            printf "FAIL %s: %s builds an image tag and is named neither for the gate nor for production", root, oddlist
            printf " — rename it *ci* or *e2e* if a gate run builds it, *prod* if production runs it\n"
        }
        if (n) printf "gate-image-tags: %d shared tag(s) — a gate run can overwrite what production is recreated from (T9)\n", n
        else   printf "gate-image-tags: %d unrecognised compose file(s) build a tag — which side builds it is a guess (T9)\n", noddfiles
        exit 1
    }' "${RECORDS}"
