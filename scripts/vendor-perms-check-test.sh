#!/usr/bin/env bash
# Fixtures only: throwaway vendor/ trees in a temp dir drive the real scripts/vendor-perms-check.sh, every case
# under bash and again under busybox sh with only busybox applets on PATH, as an Alpine image runs it (dash for case 6).
#
#   scripts/vendor-perms-check-test.sh
#   VENDOR_PERMS_CHECK_SH=/path/mutant.sh scripts/vendor-perms-check-test.sh   the red proofs
#   VP_TEST=$PWD/scripts/vendor-perms-check-test.sh scripts/guard-mutants.sh scripts/vendor-perms-check.sh scripts/vendor-perms-check-mutants.txt
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${VENDOR_PERMS_CHECK_SH:-${SCRIPT_DIR}/vendor-perms-check.sh}"

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
# decision: grep-q-reads-a-here-string-not-a-pipe
contains() { if grep -qF -- "$3" <<<"$2"; then pass "$1"; else fail "$1 — [$2] does not contain [$3]"; fi; }

BUSYBOX=$(command -v busybox) || { printf 'busybox is not on PATH, so the Alpine half of this test cannot run (C9).\n' >&2; exit 1; }
umask 022
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The unreadable-subdir case runs as nobody, who must reach the fixtures and the script under test.
chmod 755 "${WORK}"
cp -- "${CHECK}" "${WORK}/check.sh"
mkdir "${WORK}/bb" "${WORK}/fake"
for applet in sh find grep head wc; do ln -s "${BUSYBOX}" "${WORK}/bb/${applet}"; done
# A find that fails only when asked to judge modes. Busybox sh runs its own find applet whatever PATH says, so dash stands in.
printf '#!/bin/sh\ncase "$*" in *-perm*) exit 1 ;; esac\nexec /usr/bin/find "$@"\n' >"${WORK}/fake/find"
chmod 755 "${WORK}/fake/find"
n=0

# A clean vendor/: autoload.php, one package dir, one file, and a 0777-looking symlink that must be skipped.
fresh() {
    n=$((n + 1)); D="${WORK}/t${n}"
    mkdir -p "${D}/vendor/acme/pkg" "${D}/vendor/bin"
    printf '<?php\n' >"${D}/vendor/autoload.php"
    printf '<?php\n' >"${D}/vendor/acme/pkg/src.php"
    ln -s ../acme/pkg/src.php "${D}/vendor/bin/tool"
}
# run [--as-nobody] [--fake-find] <args...>: OUT/RC from bash, then busybox sh (dash with the fake find) must agree,
# find's own error lines aside, whose wording differs between GNU and busybox.
run() {
    local as=() second=("${BUSYBOX}" sh) second_path=${WORK}/bb path=${PATH}
    [ "${1-}" != --as-nobody ] || { shift; [ "$(id -u)" -ne 0 ] || as=(runuser -u nobody --); }
    [ "${1-}" != --fake-find ] || { shift; second=(dash); path=${WORK}/fake:${PATH}; second_path=${path}; }
    RAN_AS=$("${as[@]}" id -u)
    OUT="$("${as[@]}" env PATH="${path}" bash "${WORK}/check.sh" "$@" 2>&1)"; RC=$?
    SECOND_OUT="$("${as[@]}" env PATH="${second_path}" "${second[@]}" "${WORK}/check.sh" "$@" 2>&1)"; SECOND_RC=$?
    equals "case ${n}: ${second[*]##*/} exit code" "${SECOND_RC}" "${RC}"
    equals "case ${n}: ${second[*]##*/} output" "$(grep -v '^find: ' <<<"${SECOND_OUT}")" "$(grep -v '^find: ' <<<"${OUT}")"
}

# --- 1. a clean vendor/ passes, with or without a trailing slash -------------------------
fresh; run "${D}/vendor"
equals   'case 1: the verdict line' "${OUT}" 'world-writable paths under vendor/: 0 of 6'
equals   'case 1: exit code' "${RC}" 0
run "${D}/vendor//"
equals   'case 1: trailing slashes, exit code' "${RC}" 0

# --- 2. usage --------------------------------------------------------------------------------
run
contains 'case 2a: no argument is usage' "${OUT}" 'usage: vendor-perms-check.sh <vendor-dir>'
equals   'case 2a: exit code' "${RC}" 2
fresh; run "${D}/vendor" "${D}/vendor"
equals   'case 2b: two arguments, exit code' "${RC}" 2
run ''
equals   'case 2c: an empty argument, exit code' "${RC}" 2
run '//'
equals   'case 2d: only slashes, exit code' "${RC}" 2

# --- 3. a symlinked vendor/, named with and without a trailing slash -------------------------
fresh; mv "${D}/vendor" "${D}/real"; ln -s real "${D}/vendor"; run "${D}/vendor"
contains 'case 3a: a symlink is refused' "${OUT}" "${D}/vendor is a symlink"
equals   'case 3a: exit code' "${RC}" 1
run "${D}/vendor/"
contains 'case 3b: vendor/ with a slash is still the symlink' "${OUT}" "${D}/vendor is a symlink"
equals   'case 3b: exit code' "${RC}" 1

# --- 4. no autoload.php -------------------------------------------------------------------------
fresh; rm "${D}/vendor/autoload.php"; run "${D}/vendor"
contains 'case 4: no autoload.php is refused' "${OUT}" "no ${D}/vendor/autoload.php, so there is no installed vendor/ to judge."
equals   'case 4: exit code' "${RC}" 1

# --- 5. a subdir the caller cannot read (as nobody: root reads a mode-000 dir) ----------------
fresh; mkdir "${D}/vendor/acme/pkg/locked"; chmod 000 "${D}/vendor/acme/pkg/locked"; run --as-nobody "${D}/vendor"
printf '   case 5 ran as uid %s (nobody is %s): %s\n' "${RAN_AS}" "$(id -u nobody)" "${OUT}"
equals   'case 5: not run as root' "$([ "${RAN_AS}" -ne 0 ] && echo non-root)" non-root
contains 'case 5: an unreadable subdir is refused' "${OUT}" "find could not list every path under ${D}/vendor/"
equals   'case 5: exit code' "${RC}" 1
chmod 755 "${D}/vendor/acme/pkg/locked"

# --- 6. the mode-judging find fails ----------------------------------------------------------------
fresh; run --fake-find "${D}/vendor"
contains 'case 6: a failing mode find is refused' "${OUT}" "find could not judge every mode under ${D}/vendor/"
equals   'case 6: exit code' "${RC}" 1

# --- 7. nothing but vendor/ itself to judge (autoload.php a symlink) ---------------------------------
n=$((n + 1)); D="${WORK}/t${n}"; mkdir -p "${D}/vendor"; printf '<?php\n' >"${D}/autoload.php"
ln -s ../autoload.php "${D}/vendor/autoload.php"; run "${D}/vendor"
contains 'case 7: a total of 1 is refused' "${OUT}" "find saw no path under ${D}/vendor/ but vendor/ itself"
equals   'case 7: exit code' "${RC}" 1

# --- 8. vendor/ itself is 0777 ------------------------------------------------------------------------
fresh; chmod 0777 "${D}/vendor"; run "${D}/vendor"
contains 'case 8: vendor/ itself is counted' "${OUT}" 'world-writable paths under vendor/: 1 of 6'
contains 'case 8: and named' "${OUT}" "$(printf 'first five:\n%s/vendor/\n' "${D}")"
equals   'case 8: exit code' "${RC}" 1

# --- 9. one 0666 file, and a 0777 package dir as busybox unzip leaves them --------------------------------
fresh; chmod 0666 "${D}/vendor/acme/pkg/src.php"; run "${D}/vendor"
contains 'case 9a: a 0666 file is counted' "${OUT}" 'world-writable paths under vendor/: 1 of 6'
contains 'case 9a: and named' "${OUT}" "${D}/vendor/acme/pkg/src.php"
equals   'case 9a: exit code' "${RC}" 1
fresh; chmod 0777 "${D}/vendor/acme" "${D}/vendor/acme/pkg"; run "${D}/vendor"
contains 'case 9b: two 0777 dirs are counted' "${OUT}" 'world-writable paths under vendor/: 2 of 6'
equals   'case 9b: exit code' "${RC}" 1

if [ "${fails}" -gt 0 ]; then printf '%s failure(s)\n' "${fails}" >&2; exit 1; fi
printf 'vendor-perms-check-test: all cases passed\n'
