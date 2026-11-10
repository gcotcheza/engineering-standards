#!/bin/sh
# Fails each Dockerfile stage whose last apk add|del|upgrade|fix comes after its last `rm ... /usr/bin/unzip`.
# decision: vendor-is-never-world-writable
#   dockerfile-unzip-check.sh [--stages N] <Dockerfile>   exit 0: no stage leaves unzip, and N stages change apk when given;
#   1: a stage leaves unzip, no stage changes apk, the count is not N, or nothing was judged; 2: usage
#   `\` continuations are joined first. An rm (-f or -rf) of exactly /usr/bin/unzip counts only where it starts a RUN or follows
#   && or ;, before any ` #`. Blind to apk behind a variable (`${APK} add`) and to an rm that sits there but never runs:
#   `&& rm … || true`, one inside `if false`, inside quotes with more text after, or in a heredoc body (COPY or RUN).

usage() { printf 'usage: dockerfile-unzip-check.sh [--stages N] <Dockerfile>\n' >&2; exit 2; }
die() { printf 'dockerfile-unzip-check: FAILED %s\n' "$*" >&2; exit 1; }

STAGES=0
if [ "${1-}" = --stages ]; then
    case ${2-} in '' | 0* | *[!0-9]*) usage ;; esac
    STAGES=$2
    shift 2
fi
[ "$#" -eq 1 ] || usage
[ -n "$1" ] || usage
DOCKERFILE=$1
[ -f "${DOCKERFILE}" ] || die "${DOCKERFILE} is not a file, so nothing was judged."

OUT=$(awk -v want="${STAGES}" '
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
function judge(s,   c, a, r) {
    if (s ~ /^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]/) { close_stage(); froms++; stage = trim(s); change = 0; removal = 0; return }
    sub(/^[[:space:]]*[Rr][Uu][Nn][[:space:]]+/, "; ", s)
    c = s
    sub(/(^|[[:space:]])#.*/, "", c)
    lines++
    a = last_at(s, APK); if (a) change = lines * 1000000 + a
    r = last_at(c, RM); if (r) removal = lines * 1000000 + r
}
BEGIN {
    APK = "(^|[^[:alnum:]_])apk([[:space:]]+-[^[:space:]]+)*[[:space:]]+(add|del|upgrade|fix)([^[:alnum:]_]|$)"
    RM = "(&&|;)[[:space:]]*rm([[:space:]]+-r?f)?[[:space:]]+/usr/bin/unzip([[:space:];&|]|$)"
    stage = "(before the first FROM)"
}
{ sub(/\r$/, "") }
/^[[:space:]]*#/ { next }
/\\$/ { held = held substr($0, 1, length($0) - 1) " "; next }
{ judge(held $0); held = "" }
END {
    if (held != "") judge(held)
    close_stage()
    if (!froms) exit 3
    printf "stages that change apk packages: %d, leaving unzip: %d\n", checked, left
    if (left) exit 1
    if (!checked) exit 4
    if (want + 0 && checked != want + 0) exit 5
    exit 0
}' "${DOCKERFILE}")
RC=$?
[ "${RC}" -ne 3 ] || die "${DOCKERFILE} has no FROM line, so nothing was judged."
case ${OUT} in *'stages that change apk packages: '*) ;; *) die "awk exited ${RC} without a verdict on ${DOCKERFILE}." ;; esac
printf '%s\n' "${OUT}"
[ "${RC}" -ne 4 ] || die "no stage of ${DOCKERFILE} changes apk packages, so nothing was judged."
[ "${RC}" -ne 5 ] || die "--stages ${STAGES} was given, but that is not how many stages of ${DOCKERFILE} change apk packages."
[ "${RC}" -eq 0 ] || die "a stage of ${DOCKERFILE} can relink busybox unzip after removing it; remove /usr/bin/unzip again after its last apk change."
exit 0
