#!/bin/sh
# Fails a composer vendor/ that any uid could write to: vendor-perms-check.sh <vendor-dir>. POSIX sh, for bash and busybox ash.
# decision: vendor-is-never-world-writable
#   exit 0: `0 of N` world-writable paths with N > 1; 1: a finding, or nothing could be judged; 2: usage

usage() { printf 'usage: vendor-perms-check.sh <vendor-dir>\n' >&2; exit 2; }
die() { printf 'vendor-perms-check: FAILED %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 1 ] || usage
VENDOR=$1
while :; do case ${VENDOR} in */) VENDOR=${VENDOR%/} ;; *) break ;; esac; done
[ -n "${VENDOR}" ] || usage

[ -L "${VENDOR}" ] && die "${VENDOR} is a symlink, so what it points at is not the vendor/ composer installed here."
[ -f "${VENDOR}/autoload.php" ] || die "no ${VENDOR}/autoload.php, so there is no installed vendor/ to judge."
ALL_PATHS=$(find "${VENDOR}/" ! -type l) || die "find could not list every path under ${VENDOR}/, so a world-writable one could hide there."
ALL=$(printf '%s\n' "${ALL_PATHS}" | grep -c .)
[ "${ALL}" -gt 1 ] || die "find saw no path under ${VENDOR}/ but vendor/ itself, so there is nothing to judge."
WRITABLE=$(find "${VENDOR}/" ! -type l -perm -0002) || die "find could not judge every mode under ${VENDOR}/, so a world-writable path could hide there."
W=$(printf '%s\n' "${WRITABLE}" | grep -c .)

printf 'world-writable paths under vendor/: %s of %s\n' "${W}" "${ALL}"
[ "${W}" -eq 0 ] || die "${W} of ${ALL} paths under vendor/ are world-writable, first five:
$(printf '%s\n' "${WRITABLE}" | head -n 5)
An unzip that keeps a zip's 0777 modes extracted them; delete vendor/ and install again with no unzip on PATH."
exit 0
