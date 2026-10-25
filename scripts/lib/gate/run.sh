# shellcheck shell=bash disable=SC2015  # every A && B || die here ends in an exit
# Exec'd by scripts/gate-run.sh only, from its root-owned copy in <run>/lib, with a scrubbed env.
# decision: gate-run-exports-one-sha
set -uo pipefail

LIB=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
APP=$1 SHA=$2 SCRIPT=$3
shift 3
RUN=${GATE_RUN_DIR:?}
ID=${RUN##*/}
URL_PREFIX=${GATE_RUN_T_URL_PREFIX:-https://github.com/gcotcheza/}
SRC=${GATE_RUN_T_SRC:-/var/lib/fleet/deploy-src}
LEDGER=${GATE_RUN_T_LEDGER:-/var/lib/fleet/gate-ledger}
BUILD_BASE=${GATE_RUN_T_BUILD_BASE:-/var/tmp}
ENV_DIR=${GATE_RUN_T_ENV_DIR:-/etc/fleet/gate-env}
RUN_PATH=${GATE_RUN_T_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
APP_USER=${GATE_RUN_T_APP_USER:-$APP}
ROOT_UID=${GATE_RUN_T_UID:-0}
DF=${GATE_RUN_T_DF:-/usr/bin/df}
GIT_BIN=/usr/bin/git
TREE=$RUN/tree REPO=$RUN/repo.git BUILD=''
KIND=ci
case $SCRIPT in *e2e*) KIND=e2e ;; esac

# shellcheck source=scripts/lib/gate/export.sh
. "$LIB/export.sh" || exit 2
die() { printf 'gate-run: REFUSED: %s\n' "$*" >&2; exit 2; }
[[ $ID =~ ^[A-Za-z0-9]{10}$ && $RUN == */"$APP"-gate/"$ID" ]] || die "GATE_RUN_DIR $RUN is not a gate-run run directory"

root_git() {
    env -i PATH=/usr/bin:/bin HOME=/root GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0 \
        "$GIT_BIN" -c credential.helper= -c "credential.helper=!/usr/local/bin/gh auth git-credential" "$@"
}
mirror_git() { root_git --git-dir="$REPO" "$@"; }
tree_git() { root_git --git-dir="$REPO" --work-tree="$TREE" "$@"; }
run_as() { if [ "$(id -u)" = "$APP_UID" ]; then env -i PATH=/usr/bin:/bin "$@"; else runuser -u "$APP_USER" -- env -i PATH=/usr/bin:/bin "$@"; fi; }
owned_dir() { [ ! -L "$1" ] && [ -d "$1" ] && [ "$(stat -c %u "$1")" = "$ROOT_UID" ] && (( (8#$(stat -c %a "$1") & 8#022) == 0 )); }

# shellcheck disable=SC2317
cleanup() {
    local code=$?
    if [ "${GATE_RUN_KEEP:-0}" = 1 ]; then
        printf 'gate-run: --keep: left %s and %s\n' "$RUN" "${BUILD:-no build dir}" >&2
        exit "$code"
    fi
    [ ! -e "$RUN/compose-used" ] || bash "$LIB/compose.sh" down -v --remove-orphans >/dev/null 2>&1 || printf 'gate-run: compose down for %s-gate-%s failed\n' "$APP" "$ID" >&2
    if [ -n "$BUILD" ]; then
        [ -z "${GATE_RUN_ARTIFACTS:-}" ] || run_as cp -r -- "$BUILD/artifacts/." "$GATE_RUN_ARTIFACTS/" || printf 'gate-run: %s could not copy the artifacts to %s\n' "$APP_USER" "$GATE_RUN_ARTIFACTS" >&2
        run_as rm -rf -- "${BUILD:?}" 2>/dev/null
        rmdir -- "${BUILD:?}" 2>/dev/null || [ ! -e "$BUILD" ] || printf 'gate-run: the build dir %s was not emptied by %s, left in place\n' "$BUILD" "$APP_USER" >&2
    fi
    rm -rf -- "${RUN_BASE_DIR:?}/${APP:?}-gate/${ID:?}"
    exit "$code"
}
RUN_BASE_DIR=${RUN%/"$APP"-gate/"$ID"}
trap cleanup EXIT
umask 022

APP_UID=$(id -u -- "$APP_USER" 2>/dev/null) && APP_GID=$(id -g -- "$APP_USER") || die "there is no user $APP_USER for $APP"
[ "$APP_UID" != 0 ] || die "$APP_USER is root: the build would not be confined"

root_git init -q --bare "$REPO" || die "cannot create $REPO"
mirror="$SRC/$APP.git"
if [ -d "$mirror/objects" ] && owned_dir "$mirror"; then printf '%s\n' "$mirror/objects" >"$REPO/objects/info/alternates"; fi
mirror_git fetch --quiet --no-tags "${URL_PREFIX}$APP.git" '+refs/heads/main:refs/remotes/origin/main' "$SHA" 2>/dev/null || die "${SHA:0:12} could not be fetched from ${URL_PREFIX}$APP.git: push it first, only a sha on GitHub is gated"
mirror_git cat-file -e "$SHA^{commit}" 2>/dev/null || die "${SHA:0:12} is not a commit after the fetch from GitHub"

export_judge "$SHA" all || die "$EXPORT_ERR"
for e in "${EXPORT_ENTRIES[@]}"; do
    read -r _ _ _ path <<<"$e"
    case /$path in */.env) die "$path is committed at ${SHA:0:12}: an env file is root's, never the commit's" ;; esac
done
printf '%s\n' "${EXPORT_ENTRIES[@]}" | awk -v p="$SCRIPT" '$4 == p { f = 1 } END { exit !f }' || die "$SCRIPT is not a file at ${SHA:0:12}"
size=$(printf '%s\n' "${EXPORT_ENTRIES[@]}" | awk '{print $3}' | mirror_git cat-file --batch-check='%(objectsize)' | awk '{s+=$1} END {print s+0}') || die "the size of the tree at ${SHA:0:12} could not be read"
free=$("$DF" -B1 --output=avail "$RUN_BASE_DIR" | tail -1 | tr -d ' ')
[[ $free =~ ^[0-9]+$ ]] || die "the free space of $RUN_BASE_DIR could not be read"
(( free >= 2 * size )) || die "$RUN_BASE_DIR has $free bytes free, under twice the $size bytes the tree needs"

export_write "$SHA" "$RUN" || die "$EXPORT_ERR"
printf '%s\n' "${EXPORT_ENTRIES[@]}" | awk '{print $3, $4}' >"$RUN/manifest" || die "cannot write the manifest"
{ tree_git read-tree "$SHA" && mirror_git update-ref --no-deref HEAD "$SHA" && tree_git update-index -q --refresh >/dev/null; } || die "cannot set up $REPO at ${SHA:0:12}"

mkdir -m 750 "$RUN/env" && chown "$ROOT_UID:$APP_GID" "$RUN/env" || die "cannot create $RUN/env"
if [ -d "$ENV_DIR/$APP" ]; then
    owned_dir "$ENV_DIR" && owned_dir "$ENV_DIR/$APP" || die "$ENV_DIR/$APP is not a root-owned directory only root can write"
    for f in "$ENV_DIR/$APP"/.env*; do
        [ -e "$f" ] || continue
        [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %u "$f")" = "$ROOT_UID" ] || die "$f is not a root-owned regular file"
        install -m 640 -g "$APP_GID" -- "$f" "$RUN/env/${f##*/}" || die "cannot copy $f into $RUN/env"
    done
fi

bparent="$BUILD_BASE/$APP-gate-build"
[ -e "$bparent" ] || [ -L "$bparent" ] || mkdir -m 755 "$bparent" || die "cannot create $bparent"
owned_dir "$bparent" || die "$bparent is a symlink, not a directory, not root's, or writable by others"
BUILD=$(mktemp -d "$bparent/XXXXXXXXXX") || die "no build directory under $bparent"
chown -h "$APP_UID:$APP_GID" "$BUILD" || die "cannot hand $BUILD to $APP_USER"
run_as mkdir -p "$BUILD/vendor" "$BUILD/node_modules" "$BUILD/public-build" "$BUILD/bootstrap-cache" "$BUILD/artifacts" || die "$APP_USER could not create the build dirs"

printf 'gate-run: %s %s -> %s\n' "$APP" "${SHA:0:7}" "$RUN"
printf '%s %s %s %s %s\n' "$APP" "$ID" "$BUILD" "$APP_UID:$APP_GID" "$RUN_PATH" >"$RUN/compose-context"
cd / || die "cannot cd to /"
tgit="$GIT_BIN --git-dir=$REPO --work-tree=$TREE"
env -i PATH="$RUN_PATH" HOME=/root LANG=C.UTF-8 TERM=dumb \
    GATE_RUN="$RUN" GATE_EXPORT_SHA="$SHA" GATE_BUILD="$BUILD" GATE_COMPOSE="bash $LIB/compose.sh" \
    CI_GIT="$tgit" CHECK_GIT="$tgit" E2E_GIT="$tgit" GATE_LEDGER_GIT="$tgit" GATE_LEDGER="$RUN/status" \
    bash "$TREE/$SCRIPT" "$@"
rc=$?

intact=1
while read -r obj path; do
    [ -f "$TREE/$path" ] && [ ! -L "$TREE/$path" ] && [ "$(root_git hash-object --no-filters -- "$TREE/$path")" = "$obj" ] || { intact=0; printf 'gate-run: %s changed during the run\n' "$path" >&2; break; }
done <"$RUN/manifest"
[ "$(find "$TREE" ! -type d | wc -l)" = "$(wc -l <"$RUN/manifest")" ] || { intact=0; printf 'gate-run: files appeared in %s during the run\n' "$TREE" >&2; }

row=$(awk -v s="$SHA" '$1 == s' "$RUN/status" 2>/dev/null | tail -1)
if [ "$intact" = 0 ]; then
    row="$SHA $KIND $(date -u +%FT%TZ) 1 - -"
fi
if [ -n "$row" ]; then
    printf '%s\n' "$row" >>"$LEDGER" || die "cannot append to $LEDGER"
    printf 'gate-run: ledger %s\n' "$row"
else
    printf 'gate-run: the gate recorded no row for %s, so none is written\n' "${SHA:0:7}" >&2
fi
[ "$intact" = 1 ] || exit 1
exit "$rc"
