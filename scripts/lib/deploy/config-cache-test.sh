#!/usr/bin/env bash
# Guards config-cache.sh on throwaway app trees. test.sh runs it as root; it runs as nobody too, where the
# root-only cases skip: DEPLOY_LIB_DIR=<copy> TMPDIR=<dir> config-cache-test.sh
# shellcheck disable=SC2016
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${DEPLOY_LIB_DIR:-${SCRIPT_DIR}}"
fails=0
pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 — no [$3] in:"$'\n'"$2" ;; esac; }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
root_only_case() { [ "$(id -u)" = 0 ] || { printf 'skip %s (root only)\n' "$1"; return 1; }; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/config-cache-test.XXXXXXXX")" || { printf 'cannot make a work directory\n' >&2; exit 1; }
trap 'rm -rf "${WORK}"' EXIT
WORK="$(cd -P -- "${WORK}" && pwd)" && chmod 755 "${WORK}" || exit 1

# app NAME MODE: a tree whose cached config has MODE ("" for no cache), owned by nobody when root builds it.
app() {
    APP="${WORK}/$1"
    mkdir -p "${APP}/bootstrap/cache" "${APP}/bin"
    [ -z "$2" ] || { printf '<?php return [];\n' >"${APP}/bootstrap/cache/config.php"; chmod "$2" "${APP}/bootstrap/cache/config.php"; }
    [ "$(id -u)" != 0 ] || chown -R nobody:nogroup "${APP}"
}
mode() { stat -c %a -- "$1"; }
run() {  # run FUNCTION ARGS…: OUT holds its output and RC= line
    OUT="$(env -i PATH=/usr/bin:/bin DEPLOY_EXEC_PATH="${EXEC_PATH:-}" \
        bash -c '. "$1"; shift; "$@"; printf "RC=%s\n" "$?"' _ "${LIB_DIR}/config-cache.sh" "$@" 2>&1)"
    EXEC_PATH=''
}
stub_chmod() {  # stub_chmod BODY: a chmod in ${APP}/bin that runs BODY
    printf '#!/bin/bash\n%s\n' "$1" >"${APP}/bin/chmod"
    /bin/chmod 0755 "${APP}/bin/chmod"
    EXEC_PATH="${APP}/bin:/usr/bin:/bin"
}

# --- the VERIFY -----------------------------------------------------------------
app none ''
run config_cache_check "${APP}"
contains 'check: no cached config passes, said so' "${OUT}" "no cached config under ${APP}"$'\nRC=0'
for m in 600 400; do
    app "ok$m" "$m"
    run config_cache_check "${APP}"
    contains "check: a $m cache passes" "${OUT}" "cached config ${APP}/bootstrap/cache/config.php is $m, owner-only"$'\nRC=0'
done
for m in 644 640 604 755 620 602; do
    app "bad$m" "$m"
    run config_cache_check "${APP}/"
    contains "check: a $m cache is refused, its mode named" "${OUT}" "REFUSED: config_cache_check: ${APP}/bootstrap/cache/config.php is $m: group or others"
    contains "check: a $m cache exits 1" "${OUT}" 'RC=1'
done
app linkfile ''
app linktarget 644
ln -s "${WORK}/linktarget/bootstrap/cache/config.php" "${WORK}/linkfile/bootstrap/cache/config.php"
run config_cache_check "${WORK}/linkfile"
contains 'check: a cache that is a link is refused' "${OUT}" "REFUSED: config_cache_check: ${WORK}/linkfile/bootstrap/cache/config.php is not a plain file"
contains 'check: a cache that is a link exits 1' "${OUT}" 'RC=1'
app linkdir ''
rm -r "${WORK}/linkdir/bootstrap/cache"
ln -s "${WORK}/linktarget/bootstrap/cache" "${WORK}/linkdir/bootstrap/cache"
run config_cache_check "${WORK}/linkdir"
contains 'check: a cache reached through a linked directory is refused' "${OUT}" "REFUSED: config_cache_check: ${WORK}/linkdir/bootstrap/cache/config.php is not a plain file"
app dirnamed ''
mkdir "${APP}/bootstrap/cache/config.php"
run config_cache_check "${APP}"
contains 'check: a directory named config.php is refused' "${OUT}" "REFUSED: config_cache_check: ${APP}/bootstrap/cache/config.php is not a plain file"
ln -s "${WORK}/ok600" "${WORK}/treelink"
run config_cache_check "${WORK}/treelink"
contains 'check: an app tree given through a link is refused' "${OUT}" 'REFUSED: config_cache_check:'
contains 'check: an app tree given through a link exits 1' "${OUT}" 'RC=1'
run config_cache_check ''
contains 'check: no app tree is refused' "${OUT}" 'RC=1'
OUT="$(bash -- "${LIB_DIR}/config-cache.sh" "${WORK}/bad644" 2>&1; printf 'RC=%s\n' "$?")"
contains 'check: run as a script, it refuses a 644 cache' "${OUT}" 'is 644: group or others'
contains 'check: run as a script, it exits 1' "${OUT}" 'RC=1'

# --- the repair -----------------------------------------------------------------
app fix 644
run config_cache_private "${APP}"
contains 'private: a 644 cache is made owner-only' "${OUT}" 'RC=0'
equals 'private: the cache mode afterwards' "$(mode "${APP}/bootstrap/cache/config.php")" 600
app fixtrail 664
run config_cache_private "${APP}///"
equals 'private: a trailing slash still repairs the cache' "$(mode "${APP}/bootstrap/cache/config.php")" 600
app missing ''
run config_cache_private "${APP}"
contains 'private: no cache is refused, naming config:cache' "${OUT}" "REFUSED: config_cache_private: no ${APP}/bootstrap/cache/config.php: run it after config:cache"
contains 'private: no cache exits 1' "${OUT}" 'RC=1'
run config_cache_private "${WORK}/linkfile"
contains 'private: a cache that is a link is refused' "${OUT}" 'is not a plain file'
equals 'private: the link target keeps its mode' "$(mode "${WORK}/linktarget/bootstrap/cache/config.php")" 644
app noop 644
stub_chmod 'exit 0'
run config_cache_private "${APP}"
contains 'private: a chmod that changed nothing is caught by the check' "${OUT}" 'is 644: group or others'
contains 'private: a chmod that changed nothing exits 1' "${OUT}" 'RC=1'
app chmodfails 644
stub_chmod 'exit 1'
run config_cache_private "${APP}"
contains 'private: a failing chmod is refused' "${OUT}" "REFUSED: config_cache_private: chmod 600 failed on ${APP}/bootstrap/cache/config.php"
contains 'private: a failing chmod exits 1' "${OUT}" 'RC=1'
if root_only_case 'private: chmod runs as the owner, never root'; then
    app asowner 644
    stub_chmod "id -u >\"${APP}/bin/who\"; exec /bin/chmod \"\$@\""
    run config_cache_private "${APP}"
    equals 'private: the uid chmod ran as' "$(cat "${APP}/bin/who" 2>&1)" "$(id -u nobody)"
    equals 'private: as root, the cache mode afterwards' "$(mode "${APP}/bootstrap/cache/config.php")" 600
fi
if root_only_case 'private: an owner uid with no host name'; then
    app unnamed 644
    getent passwd 54321 >/dev/null && fail 'uid 54321 has a host name, so it cannot stand in for a container uid'
    chown -R 54321:54321 "${APP}"
    run config_cache_private "${APP}"
    contains 'private: an unnamed owner uid is handled' "${OUT}" 'RC=0'
    equals 'private: the unnamed owner cache mode afterwards' "$(mode "${APP}/bootstrap/cache/config.php")" 600
fi
if root_only_case 'private: a root-owned cache is refused'; then
    app rootowned 644
    chown root:root "${APP}/bootstrap/cache/config.php"
    run config_cache_private "${APP}"
    contains 'private: a root-owned cache is refused, naming the writer' "${OUT}" 'root owns'
    equals 'private: the root-owned cache keeps its mode' "$(mode "${APP}/bootstrap/cache/config.php")" 644
fi

[ "${fails}" = 0 ] || { printf 'config-cache-test: %s check(s) failed\n' "${fails}" >&2; exit 1; }
printf 'config-cache-test: all checks passed\n'
