#!/usr/bin/env bash
# Guards ownership.sh with a chown that logs what it is handed. test.sh runs it as root; red proofs run it as
# nobody, whose uid stands in for root: DEPLOY_LIB_DIR=<copy> TMPDIR=<dir> ownership-test.sh
# shellcheck disable=SC2016
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${DEPLOY_LIB_DIR:-${SCRIPT_DIR}}"
fails=0
pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 — no [$3] in:"$'\n'"$2" ;; esac; }
absent() { case "$2" in *"$3"*) fail "$1 — [$3] is there and must not be:"$'\n'"$2" ;; *) pass "$1" ;; esac; }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
root_only_case() { [ "$(id -u)" = 0 ] || { printf 'skip %s (root only)\n' "$1"; return 1; }; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ownership-test.XXXXXXXX")" || { printf 'cannot make a work directory\n' >&2; exit 1; }
trap 'rm -rf "${WORK}"' EXIT
DEVNULL_BEFORE="$(stat -c '%a %u %g %F' /dev/null)"
ME="$(id -u)"
TO=nobody:nogroup

# A tree with a nested directory and a link to a file outside it; the stub chown can swap a
# directory for a link to the outside on its first call naming it, then logs and runs the real chown.
ofx() {
    OF="${WORK}/$1" O_SWAP=''
    OROOT="${OF}/root" OUTSIDE="${OF}/outside"
    mkdir -p "${OROOT}/a/sub" "${OUTSIDE}" "${OF}/bin"
    : >"${OROOT}/top"; : >"${OROOT}/a/sub/f"; : >"${OROOT}/a/sub/g"
    : >"${OUTSIDE}/f"; : >"${OUTSIDE}/g"; : >"${OUTSIDE}/secret"
    ln -s "${OUTSIDE}/secret" "${OROOT}/link"
    cat >"${OF}/bin/chown" <<'SH'
#!/bin/bash
for a in "$@"; do
    if [ -n "${O_SWAP}" ] && [ "${a##*/}" = "${O_SWAP##*/}" ] && [ ! -e "${O_SWAP}.real" ]; then
        mv "${O_SWAP}" "${O_SWAP}.real" && ln -s "${O_OUTSIDE}" "${O_SWAP}"
    fi
done
flags=''
for a in "$@"; do
    case $a in
        -*) flags="${flags}${a} " ;;
        *:*) ;;
        *) printf '%s|%s\n' "${flags}" "$(cd -P -- "$(dirname -- "$a")" && pwd -P)/${a##*/}" >>"${O_LOG}" ;;
    esac
done
printf '%s\n' "$*" >>"${O_LOG}.calls"
[ -z "${O_FAIL}" ] || exit 1
exec /bin/chown "$@"
SH
    chmod 0755 "${OF}/bin/chown"
}
orun() {
    OUT="$(env -i PATH="${O_PATH:-/usr/bin:/bin}" O_LOG="${OF}/log" O_SWAP="${O_SWAP}" O_OUTSIDE="${OUTSIDE}" O_FAIL="${O_FAIL:-}" \
        DEPLOY_ROOT_UID="${ME}" DEPLOY_EXEC_PATH="${OF}/bin:/usr/bin:/bin" \
        bash -c '. "$1"; shift; chown_root_owned "$@"; printf "RC=%s\n" "$?"' _ "${LIB_DIR}/ownership.sh" "$@" 2>&1)"
    LOG="$(cat "${OF}/log" 2>/dev/null)"
    CALLS="$(cat "${OF}/log.calls" 2>/dev/null)"
    O_PATH='' O_FAIL=''
}
owners() { find -P "$@" -printf '%u ' | sed 's/ $//'; }

ofx clean
orun "${OROOT}" "${TO}"
contains 'chown: a clean tree is handed over' "${OUT}" 'RC=0'
contains 'chown: a file in a subdirectory is named' "${LOG}" "|${OROOT}/a/sub/f"
contains 'chown: the planted link itself is named' "${LOG}" "|${OROOT}/link"
absent 'chown: nothing outside the tree is named' "${LOG}" "|${OUTSIDE}"
equals 'chown: every call carries -h' "$(grep -vc '^-h |' <<<"${LOG}")" 0
equals 'chown: -execdir batches one directory into one call' "$(grep -cE '^-h nobody:nogroup \./[fg] \./[fg]$' <<<"${CALLS}")" 1
if root_only_case 'chown: ownership as root'; then
    equals 'chown: every root-owned path in the tree is handed over' "$(find -P "${OROOT}" -user 0 | wc -l)" 0
    equals 'chown: the file the planted link names stays root'\''s' "$(owners "${OUTSIDE}/secret")" root
fi

ofx swap; O_SWAP="${OROOT}/a/sub"
orun "${OROOT}" "${TO}"
contains 'swap: a directory swapped for a link mid-walk still hands over' "${OUT}" 'RC=0'
contains 'swap: the swap happened' "${LOG}" "|${OROOT}/a/sub.real/f"
absent 'swap: and no chown reached the link'\''s target' "${LOG}" "|${OUTSIDE}"
if root_only_case 'swap: ownership as root'; then
    equals 'swap: the files outside stay root'\''s' "$(owners "${OUTSIDE}/f" "${OUTSIDE}/g")" 'root root'
fi

ofx relative-path; O_PATH=".:/usr/bin:/bin"
orun "${OROOT}" "${TO}"
contains 'path: a caller PATH with . in it still hands over (find refuses -execdir under it)' "${OUT}" 'RC=0'
contains 'path: and the files are named' "${LOG}" "|${OROOT}/a/sub/f"

ofx skip
orun "${OROOT}" "${TO}" "${OROOT}/a/*"
contains 'skip: a skipped pattern leaves its paths alone' "${OUT}" 'RC=0'
absent 'skip: nothing under it is named' "${LOG}" "|${OROOT}/a/"
contains 'skip: the rest still is' "${LOG}" "|${OROOT}/top"

if root_only_case 'other owner: a path another uid owns is left alone'; then
    ofx other-owner; chown -h daemon "${OROOT}/top"
    orun "${OROOT}" "${TO}"
    absent 'other owner: a path another uid owns is not named' "${LOG}" "|${OROOT}/top"
    equals 'other owner: and keeps its owner' "$(owners "${OROOT}/top")" daemon
fi

ofx refusals
ln -s "${OROOT}" "${OF}/root-link"
for d in root "${OF}/root-link" "${OF}/missing" ''; do
    orun "${d}" "${TO}"
    contains "dir: [${d}] refuses" "${OUT}" "REFUSED: chown_root_owned: ${d} is not a plain absolute directory"
    contains "dir: [${d}] returns 1" "${OUT}" 'RC=1'
done
for o in nobody 'nobody:nogroup;id' ':nogroup' 'Nobody:nogroup'; do
    orun "${OROOT}" "${o}"
    contains "owner: [${o}] refuses" "${OUT}" "REFUSED: chown_root_owned: '${o}' is not user:group"
    contains "owner: [${o}] returns 1" "${OUT}" 'RC=1'
done
# A trailing slash makes -L false and find -P follow the link; a . or .. part does the same (card 678).
for d in "${OF}/root-link/" "${OF}/root-link//"; do
    orun "${d}" "${TO}"
    contains "dir: [${d}] refuses as the link it is" "${OUT}" "REFUSED: chown_root_owned: ${OF}/root-link is not a plain absolute directory"
done
for d in "${OF}/root-link/." "${OF}/root-link/a/.." "${OF}/root-link/./"; do
    orun "${d}" "${TO}"
    contains "dir: [${d}] refuses its . or .. part" "${OUT}" "REFUSED: chown_root_owned: ${d%/} has a . or .. part"
done
equals 'refusals: no chown ran' "${LOG}" ''
for d in / //; do
    orun "${d}" nobody
    contains "dir: [${d}] is still a plain directory (the owner check is what refuses)" "${OUT}" "REFUSED: chown_root_owned: 'nobody' is not user:group"
done
ofx trailing-slash
orun "${OROOT}//" "${TO}"
contains 'trailing: a plain directory with slashes is still walked: its files are named' "${LOG}" "|${OROOT}/a/sub/f"

ofx chown-fails; O_FAIL=1
orun "${OROOT}" "${TO}"
contains 'fail: a chown that fails refuses' "${OUT}" "REFUSED: chown_root_owned: find or chown failed under ${OROOT}, so root-owned paths may remain"
contains 'fail: and returns 1' "${OUT}" 'RC=1'

# root_owned_count: the uid standing in for root owns every fixture path; .claude/** is not counted.
crun() {
    OUT="$(env -i PATH=/usr/bin:/bin DEPLOY_ROOT_UID="${C_UID:-${ME}}" \
        bash -c '. "$1"; shift; root_owned_count "$@"; printf "RC=%s\n" "$?"' _ "${LIB_DIR}/ownership.sh" "$@" 2>&1)"
    C_UID=''
}
CROOT="${WORK}/count/root"
mkdir -p "${CROOT}/.claude/skills" "${CROOT}/app"
ln -s "${CROOT}" "${WORK}/count/root-link"
: >"${CROOT}/.claude/settings.json"; : >"${CROOT}/.claude/skills/s.md"; : >"${CROOT}/app/a.php"
crun "${CROOT}"
equals 'count: root, .claude and app/ and its file count; nothing under .claude does' "${OUT}" $'4\nRC=0'
crun "${CROOT}/"
equals 'count: a trailing slash still leaves .claude/** out' "${OUT}" $'4\nRC=0'
crun "${CROOT}//"
equals 'count: two trailing slashes still leave .claude/** out' "${OUT}" $'4\nRC=0'
NROOT="${WORK}/count-nested/root"
mkdir -p "${NROOT}/app/x/.claude"; : >"${NROOT}/app/x/.claude/f"
crun "${NROOT}"
equals 'count: a .claude below the top (app/x/.claude/f) is counted, only <dir>/.claude/** is skipped' "${OUT}" $'5\nRC=0'
for g in 'star*' 'what?' '[set' 'back\slash'; do
    mkdir -p "${WORK}/count-glob/${g}"
    crun "${WORK}/count-glob/${g}"
    contains "count: a dir holding a glob character [${g}] refuses" "${OUT}" "REFUSED: root_owned_count: ${WORK}/count-glob/${g} holds a glob character"
    contains "count: [${g}] returns 1" "${OUT}" 'RC=1'
done
if root_only_case 'count: one root-owned .claude file and one root-owned app file'; then
    chown -h nobody "${CROOT}" "${CROOT}/.claude" "${CROOT}/.claude/skills" "${CROOT}/.claude/skills/s.md" "${CROOT}/app"
    crun "${CROOT}"
    equals 'count: one root-owned .claude file and one root-owned app file count 1' "${OUT}" $'1\nRC=0'
fi
C_UID='no-such-user-c527'
crun "${CROOT}"
contains 'count: a find that fails refuses' "${OUT}" "REFUSED: root_owned_count: find failed under ${CROOT}, so the count of root-owned paths is unknown"
equals 'count: and prints no count, only RC=1' "$(grep -cx '[0-9]*' <<<"${OUT}")" 0
contains 'count: and returns 1' "${OUT}" 'RC=1'
for d in root "${WORK}/count/root-link" "${WORK}/count/missing" ''; do
    crun "${d}"
    contains "count: [${d}] refuses" "${OUT}" "REFUSED: root_owned_count: ${d} is not a plain absolute directory"
    contains "count: [${d}] returns 1" "${OUT}" 'RC=1'
done
for d in "${WORK}/count/root-link/" "${WORK}/count/root-link//"; do
    crun "${d}"
    equals "count: [${d}] refuses as the link it is, and counts nothing" "${OUT}" \
        "REFUSED: root_owned_count: ${WORK}/count/root-link is not a plain absolute directory"$'\nRC=1'
done
for d in "${WORK}/count/root-link/." "${WORK}/count/root-link/app/.."; do
    crun "${d}"
    equals "count: [${d}] refuses its . or .. part, and counts nothing" "${OUT}" \
        "REFUSED: root_owned_count: ${d} has a . or .. part, which can reach the tree through a link"$'\nRC=1'
done

equals '/dev/null keeps its mode and owner across the suite (rule 26)' "$(stat -c '%a %u %g %F' /dev/null)" "${DEVNULL_BEFORE}"
if [ "${fails}" -eq 0 ]; then printf '\nownership-test: all checks passed\n'; exit 0; fi
printf '\nownership-test: %s check(s) failed\n' "${fails}" >&2
exit 1
