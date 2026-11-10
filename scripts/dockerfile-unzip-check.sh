#!/bin/sh
# Fails each Dockerfile stage whose last apk add|del|upgrade|fix comes after its last `rm ... /usr/bin/unzip`.
# decision: vendor-is-never-world-writable
#   dockerfile-unzip-check.sh <Dockerfile>   exit 0: no stage leaves unzip; 1: one does, or nothing was judged; 2: usage
#   blind to: apk behind a variable (`${APK} add`), a RUN heredoc's body, `apk \` with its verb on the next line,
#   and a `#` comment later in a RUN line

usage() { printf 'usage: dockerfile-unzip-check.sh <Dockerfile>\n' >&2; exit 2; }
die() { printf 'dockerfile-unzip-check: FAILED %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 1 ] || usage
[ -n "$1" ] || usage
DOCKERFILE=$1
[ -f "${DOCKERFILE}" ] || die "${DOCKERFILE} is not a file, so nothing was judged."

OUT=$(awk '
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function last_at(s, re,   p, off, r) {
    off = 0; r = 0
    while ((p = match(s, re)) > 0) { r = off + p; off += p; s = substr(s, p + 1) }
    return r
}
function close_stage() {
    if (!change) return
    checked++
    if (removal < change) { left++; print "stage leaves /usr/bin/unzip after its last apk change: " stage }
}
BEGIN {
    APK = "(^|[^[:alnum:]_])apk([[:space:]]+-[^[:space:]]+)*[[:space:]]+(add|del|upgrade|fix)([^[:alnum:]_]|$)"
    RM = "(^|[^[:alnum:]_])rm([[:space:]]+[^[:space:];&|]+)*[[:space:]]+/usr/bin/unzip([[:space:];&|]|$)"
    stage = "(before the first FROM)"
}
/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]/ { close_stage(); froms++; stage = trim($0); change = 0; removal = 0; next }
/^[[:space:]]*#/ { next }
{
    a = last_at($0, APK); if (a) change = NR * 1000000 + a
    r = last_at($0, RM); if (r) removal = NR * 1000000 + r
}
END {
    close_stage()
    if (!froms) exit 3
    printf "stages that change apk packages: %d, leaving unzip: %d\n", checked, left
    exit left ? 1 : 0
}' "${DOCKERFILE}")
RC=$?
[ "${RC}" -ne 3 ] || die "${DOCKERFILE} has no FROM line, so nothing was judged."
case ${OUT} in *'stages that change apk packages: '*) ;; *) die "awk exited ${RC} without a verdict on ${DOCKERFILE}." ;; esac
printf '%s\n' "${OUT}"
[ "${RC}" -eq 0 ] || die "a stage of ${DOCKERFILE} can relink busybox unzip after removing it; remove /usr/bin/unzip again after its last apk change."
exit 0
