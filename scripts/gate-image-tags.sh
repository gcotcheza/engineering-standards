#!/usr/bin/env bash
# T9's check: a gate must not build the image tag production runs. Given a
# project root it reads the compose files beside it, splits them into gate ones
# (*e2e*, *ci*) and production ones, resolves `${VAR:-default}`, and fails
# naming the file and line when one BUILT tag appears on both sides.
#
#   scripts/gate-image-tags.sh /var/www/<project>
#
# A pinned third-party image (postgres:18-alpine) is shared on purpose and is
# never a finding — only a tag something here builds can be overwritten. A
# project with no built image at all prints nothing and exits 0.
set -uo pipefail

usage() { printf 'usage: gate-image-tags.sh [project-root]\n' >&2; exit 2; }

case "${1:-}" in -h|--help) usage ;; esac
ROOT="${1:-.}"
[ -d "${ROOT}" ] || { printf 'gate-image-tags: not a directory: %s\n' "${ROOT}" >&2; exit 2; }
ROOT="$(cd -- "${ROOT}" && pwd)"

FILES=()
while IFS= read -r f; do FILES+=("${f}"); done < <(
    find "${ROOT}" -maxdepth 1 -type f \
        \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
        -o -name 'compose*.yml' -o -name 'compose*.yaml' \) | LC_ALL=C sort)
[ "${#FILES[@]}" -gt 0 ] || exit 0

RECORDS="$(mktemp)"
trap 'rm -f "${RECORDS}"' EXIT

# side, file, line, tag, built — one record per `image:` whose value resolves.
read_images() {
    awk -v side="$2" -v file="$3" '
        function ind(s) { match(s, /^ */); return RLENGTH }
        function skippable(s) { return (s ~ /^ *$/ || s ~ /^ *#/) }
        { L[NR] = $0 }
        END {
            q = sprintf("%c", 39)
            for (i = 1; i <= NR; i++) {
                if (L[i] !~ /^ *image *:/) continue
                v = L[i]
                sub(/^ *image *: */, "", v)
                sub(/ +#.*$/, "", v)
                sub(/ +$/, "", v)
                if (substr(v, 1, 1) == q || substr(v, 1, 1) == "\"") v = substr(v, 2)
                if (substr(v, length(v), 1) == q || substr(v, length(v), 1) == "\"") v = substr(v, 1, length(v) - 1)
                while (match(v, /\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*\}/)) {
                    d = substr(v, RSTART, RLENGTH)
                    sub(/^\$\{[A-Za-z_][A-Za-z0-9_]*:-/, "", d)
                    sub(/\}$/, "", d)
                    v = substr(v, 1, RSTART - 1) d substr(v, RSTART + RLENGTH)
                }
                if (v == "" || v ~ /\$/) continue
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
                for (j = st; j <= en; j++)
                    if (ind(L[j]) == I && L[j] ~ /^ *build *:/) built = 1
                printf "%s\t%s\t%d\t%s\t%d\n", side, file, i, v, built
            }
        }' "$1"
}

for f in "${FILES[@]}"; do
    rel="${f#"${ROOT}"/}"
    side=production
    case "${rel}" in *e2e*|*ci*) side=gate ;; esac
    read_images "${f}" "${side}" "${rel}" >>"${RECORDS}"
done

awk -F'\t' -v root="${ROOT}" '
    {
        tags[$4] = 1
        if ($5 == "1") built[$4] = 1
        if ($1 == "gate") { g[$4] = g[$4] sprintf("  gate:       %s:%s\n", $2, $3); gn[$4]++ }
        else              { p[$4] = p[$4] sprintf("  production: %s:%s\n", $2, $3); pn[$4]++ }
    }
    END {
        nbuilt = 0
        for (t in tags) if (built[t]) nbuilt++
        if (nbuilt == 0) exit 0
        n = 0
        for (t in tags) if (built[t] && gn[t] && pn[t]) bad[++n] = t
        if (n == 0) {
            printf "ok %s: %d built image tag(s), none shared between the gate and production\n", root, nbuilt
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
        printf "gate-image-tags: %d shared tag(s) — a gate run can overwrite what production is recreated from (T9)\n", n
        exit 1
    }' "${RECORDS}"
