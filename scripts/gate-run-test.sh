#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC1090,SC2317  # assertions are single-quoted strings ok() evals
# Tests for scripts/gate-run.sh and scripts/lib/gate/: planted attacks A1-A5, A7-A18 of card 719 and the structural
# export-tree check, against a throwaway app repo, a local "GitHub" and a fake docker (gate-run-fake-docker.py).
#   GR_ENTRY / GR_RUN_SH / GR_EXPORT_SH / GR_COMPOSE_SH   a copy to test in place of this tree's file (T5 mutants)
#   GR_CASES="A3 A8a"   only these cases;  GR_CALLERS="<file>…"   also judge those export-tree callers
#   GR_AS_NOBODY=1   gate-run itself runs as nobody (T5 mutants, rule 26); fixtures are still committed by root, under the
#   secrets hook. As root the app uid is nobody; under GR_AS_NOBODY gate-run's uid is the app's too, and A10 is skipped.
set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd) || exit 2
ENTRY=${GR_ENTRY:-$REPO_ROOT/scripts/gate-run.sh}
[ "$(id -u)" = 0 ] || { printf 'gate-run-test: run as root: the fixtures are commits, which the secrets hook checks through root\n' >&2; exit 2; }
RUNAS=() ME=0 APPU=nobody
[ "${GR_AS_NOBODY:-0}" != 1 ] || { RUNAS=(runuser -u nobody --); ME=$(id -u nobody); }
APP=gt719
pass=0 fail=0 failed=()

S=$(mktemp -d -p "${GR_TMP:-/srv/worker-scratch}" gate-run-test.XXXXXXXX) || exit 2
chmod 755 "$S"
printf 'kind=lane\ncard=719\nowner=%s\n' "${FLEET_SCRATCH_OWNER:-pv}" >"$S/.fleet-scratch"
trap 'rm -rf -- "${S:?}"' EXIT
P=$S/probe RB=$S/run VT=$S/vartmp
mkdir -m 755 "$P" "$RB" "$VT" "$S/deploy-src" "$S/gh" "$S/gate-env" "$S/gate-env/$APP" "$P/fake-etc"
printf 'probe\n' >"$P/fake-etc/probe"
printf 'APP_KEY=gate-only\n' >"$S/gate-env/$APP/.env.e2e"
chmod 644 "$S/gate-env/$APP/.env.e2e"
[ "$ME" = 0 ] || chown -R nobody: "$P" "$RB" "$VT" "$S/gate-env"
mkdir -m 755 "$S/bin"
cp -- "$ENTRY" "$S/bin/gate-run.sh" && ENTRY=$S/bin/gate-run.sh || exit 2
cp -- "$REPO_ROOT/scripts/gate-run-fake-docker.py" "$P/docker.py"
printf '#!/bin/sh\nexec /usr/bin/python3 -I %s "$@"\n' "$P/docker.py" >"$S/bin/docker"
printf '#!/bin/sh\necho Avail; echo 1000\n' >"$S/bin/smalldf"
chmod 755 "$S/bin/docker" "$S/bin/smalldf"
g() { git -c user.name=gate-run-test -c user.email=gate-run-test@invalid "$@"; }

# The box clone: this tree's lib (or a mutant copy) committed, with origin/main at HEAD.
ES=$S/es
mkdir -p "$ES/scripts/lib"
cp -r -- "$REPO_ROOT/scripts/lib/gate" "$REPO_ROOT/scripts/lib/deploy" "$ES/scripts/lib/"
[ -z "${GR_RUN_SH:-}" ] || cp -- "$GR_RUN_SH" "$ES/scripts/lib/gate/run.sh"
[ -z "${GR_EXPORT_SH:-}" ] || cp -- "$GR_EXPORT_SH" "$ES/scripts/lib/gate/export.sh"
[ -z "${GR_COMPOSE_SH:-}" ] || cp -- "$GR_COMPOSE_SH" "$ES/scripts/lib/gate/compose.sh"
chmod -R go-w "$ES"
g init -q -b main "$ES" && g -C "$ES" add scripts && g -C "$ES" commit -qm lib && g -C "$ES" update-ref refs/remotes/origin/main HEAD || exit 2
[ "$ME" = 0 ] || chown -R nobody: "$ES"

# The app: a bare "GitHub" that serves reachable shas, and the app's own clone.
GH=$S/gh/$APP.git SRC=$S/src
g init -q --bare -b main "$GH" && g -C "$GH" config uploadpack.allowReachableSHA1InWant true || exit 2
g init -q -b main "$SRC" || exit 2
mkdir -p "$SRC/scripts/lib/deploy"
cp -- "$REPO_ROOT/scripts/lib/deploy/ledger.sh" "$SRC/scripts/lib/deploy/"
cat >"$SRC/scripts/check.sh" <<EOF
#!/usr/bin/env bash
set -u
P=$P
. "\$GATE_RUN/tree/scripts/lib/deploy/ledger.sh"
gate_ledger_arm
trap 'gate_ledger_record ci \$? -; [ "\${1:-}" != foreign ] || printf "%s ci t 0 - -\\n" 1111111111111111111111111111111111111111 >>"\$GATE_LEDGER"' EXIT
sha256sum <"\$0" | cut -d' ' -f1 >"\$P/selfhash"
env | sort >"\$P/env"
\$CI_GIT rev-parse refs/remotes/origin/main >"\$P/origin-main" 2>&1
[ ! -f "\$P/hold" ] || sleep 2
case "\${1:-}" in
    compose) \$GATE_COMPOSE -f docker-compose.yml --env-file .env.e2e up -d || exit \$? ;;
    build) \$GATE_COMPOSE --build -f docker-compose.yml run app true || exit \$?; \$GATE_COMPOSE -f docker-compose.yml up -d || exit \$? ;;
esac
GATE_SUITE_PASSED=1
EOF
printf 'services:\n  app:\n    image: busybox\n    volumes:\n      - .:/var/www/html\n' >"$SRC/docker-compose.yml"
printf 'readme\n' >"$SRC/README.md"
g -C "$SRC" add -A && g -C "$SRC" commit -qm base && g -C "$SRC" remote add origin "$GH" && g -C "$SRC" push -q origin main || exit 2
BASE=$(g -C "$SRC" rev-parse HEAD)

commit() { # message, then shell run in the app clone -> SHA, pushed to a branch unless NOPUSH=1
    local msg=$1; shift
    (cd "$SRC" && git checkout -q -B "t-$RANDOM" "$BASE" && eval "$*" && g add -A . && g commit -qm "$msg") || return 1
    SHA=$(g -C "$SRC" rev-parse HEAD)
    [ "${NOPUSH:-0}" = 1 ] || g -C "$SRC" push -q origin "HEAD:refs/heads/b-$SHA"
}

commit host "printf \"services:\n  app:\n    image: busybox\n    volumes: ['/:/host']\n\" >docker-compose.yml" && SHA_host=$SHA || exit 2
commit link 'ln -sf /etc/shadow scripts/e2e.sh' && SHA_link=$SHA || exit 2
commit odd 'printf x >"x y.txt"' && SHA_odd=$SHA || exit 2
commit include 'printf "include:\n  - /var/www/x/compose.yml\nservices: {}\n" >compose.e2e.yml' && SHA_include=$SHA || exit 2
commit extends 'printf "services:\n  app:\n    extends: {file: /var/www/x/c.yml, service: a}\n" >compose.e2e.yml' && SHA_extends=$SHA || exit 2
commit ahead 'printf more >>README.md' && SHA_ahead=$SHA || exit 2
commit dotenv 'printf "X=1\n" >.env' && SHA_dotenv=$SHA || exit 2
NOPUSH=1 commit unpushed 'printf local >>README.md' && SHA_unpushed=$SHA || exit 2
g -C "$SRC" checkout -q "$BASE" || exit 2
[ "$ME" = 0 ] || chown -R nobody: "$GH"


gr() { # app sha script [args] -> OUT, RC; the ledger is $S/ledger
    rm -f -- "$P/docker.log" "$P/selfhash" "$P/env"
    OUT=$(env GATE_RUN_T_RUN_BASE="$RB" GATE_RUN_T_LIB_CLONE="$ES" GATE_RUN_T_UID="$ME" GATE_RUN_T_URL_PREFIX="$S/gh/" \
        GATE_RUN_T_SRC="$S/deploy-src" GATE_RUN_T_LEDGER="$P/ledger" GATE_RUN_T_BUILD_BASE="$VT" GATE_RUN_T_ENV_DIR="$S/gate-env" \
        GATE_RUN_T_PATH="$S/bin:/usr/bin:/bin" GATE_RUN_T_APP_USER="$APPU" GATE_RUN_T_DF="${DFBIN:-/usr/bin/df}" \
        "${PRE[@]}" "${RUNAS[@]}" bash "$ENTRY" "$@" 2>&1)
    RC=$?
}

PRE=()
ok() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); failed+=("$1"); printf 'FAIL %s: %s\n%s\n' "$1" "$2" "$OUT" | head -30; fi; }
want() { [ -z "${GR_CASES:-}" ] || [[ " $GR_CASES " == *" $1 "* ]]; }
no_run() { [ -z "$(ls -A "$RB/$APP-gate" 2>/dev/null)" ]; }
ledger_last() { tail -1 "$P/ledger" 2>/dev/null; }

if want A0; then
    gr "$APP" "$BASE" scripts/check.sh
    ok A0 '[ "$RC" = 0 ] && [[ $(ledger_last) == "$BASE ci "*" 0 - "* ]] && no_run && [ -z "$(ls -A "$VT/$APP-gate-build")" ]'
fi
if want A0; then
    install -d -o nobody -m 755 "$P/artifacts"
    gr "$APP" "$BASE" scripts/check.sh --artifacts-to "$P/artifacts" -- compose
    ok A0-artifacts '[ "$RC" = 0 ] && [ "$(stat -c %U "$P/artifacts/report.txt" 2>/dev/null)" = nobody ]'
    gr "$APP" "$BASE" scripts/check.sh --artifacts-to "$P/../x"
    ok A0-artifacts-path '[ "$RC" = 2 ] && [[ $OUT == *"--artifacts-to is not an absolute path"* ]] && no_run'
fi
if want A1; then
    (for _ in 1 2 3 4 5 6; do printf 'touch %s/pwn\n' "$P" >"$SRC/scripts/check.sh"; sleep 0.5; done) &
    touch "$P/hold"; gr "$APP" "$BASE" scripts/check.sh; rm -f "$P/hold"; wait
    blob=$(g -C "$SRC" cat-file blob "$BASE:scripts/check.sh" | sha256sum | cut -d' ' -f1)
    ok A1 '[ ! -e "$P/pwn" ] && [ "$(cat "$P/selfhash" 2>/dev/null)" = "$blob" ]'
    g -C "$SRC" checkout -q -f "$BASE"
fi
if want A2; then
    (for _ in 1 2 3 4 5 6; do printf "services:\n  app:\n    image: busybox\n    volumes: ['/:/host']\n" >"$SRC/docker-compose.yml"; sleep 0.5; done) &
    touch "$P/hold"; gr "$APP" "$BASE" scripts/check.sh -- compose; rm -f "$P/hold"; wait
    blob=$(g -C "$SRC" cat-file blob "$BASE:docker-compose.yml" | sha256sum | cut -d' ' -f1)
    ok A2 '[ "$RC" = 0 ] && grep -q "^FILE -f .*/tree/docker-compose.yml [0-9]* $blob$" "$P/docker.log" && ! grep "^FILE -f" "$P/docker.log" | grep -vq -e "/tree/docker-compose.yml " -e "/override.yml "'
    g -C "$SRC" checkout -q -f "$BASE"
fi
if want A3; then
    gr "$APP" "$SHA_host" scripts/check.sh -- compose
    ok A3a '[ "$RC" = 2 ] && [[ $OUT == *"reaches outside"* ]] && ! grep -q "ARGV.* up" "$P/docker.log"'
    touch "$P/ignore-override"; gr "$APP" "$BASE" scripts/check.sh -- compose; rm -f "$P/ignore-override"
    ok A3b '[ "$RC" = 2 ] && [[ $OUT == *"mounted read-write"* ]] && ! grep -q "ARGV.* up" "$P/docker.log"'
fi
if want A4; then
    gr "$APP" "$SHA_link" scripts/check.sh
    ok A4a '[ "$RC" = 2 ] && [[ $OUT == *"not a plain file"* ]] && no_run'
    gr "$APP" "$SHA_odd" scripts/check.sh
    ok A4b '[ "$RC" = 2 ] && [[ $OUT == *"path outside"* ]] && no_run'
    # A gitlink cannot be committed past the secrets hook (S1), so export_judge reads one from a stub mirror_git.
    OUT=$(. "${GR_EXPORT_SH:-$REPO_ROOT/scripts/lib/gate/export.sh}"; mirror_git() { printf '160000 commit %s\tvendored\0' "$BASE"; }; export_judge "$BASE" all; printf 'rc=%s %s' "$?" "$EXPORT_ERR")
    ok A4c '[[ $OUT == "rc=1 vendored at $BASE is commit mode 160000, not a plain file" ]]'
fi
if want A5; then
    gr "$APP" "$SHA_include" scripts/check.sh
    ok A5a '[ "$RC" = 2 ] && [[ $OUT == *"top-level include:"* ]] && no_run'
    gr "$APP" "$SHA_extends" scripts/check.sh
    ok A5b '[ "$RC" = 2 ] && [[ $OUT == *"extends: with file:"* ]] && no_run'
fi
if want A7; then
    (sleep 1; g -C "$SRC" commit -q --allow-empty -m mid-run) &
    touch "$P/hold"; gr "$APP" "$BASE" scripts/check.sh -- foreign; rm -f "$P/hold"; wait
    ok A7 '[ "$RC" = 0 ] && [[ $(ledger_last) == "$BASE ci "* ]]'
    g -C "$SRC" checkout -q -f "$BASE"
fi
if want A8; then
    touch "$P/write-tree"; gr "$APP" "$BASE" scripts/check.sh -- compose; rm -f "$P/write-tree"
    ok A8a '[ "$RC" = 1 ] && [[ $(ledger_last) == "$BASE ci "*" 1 - -" ]]'
    touch "$P/add-tree"; gr "$APP" "$BASE" scripts/check.sh -- compose; rm -f "$P/add-tree"
    ok A8b '[ "$RC" = 1 ] && [[ $(ledger_last) == "$BASE ci "*" 1 - -" ]]'
fi
if want A9; then
    touch "$P/plant-build"
    PRE=(strace -f -qq -e trace=execve -o "$P/strace"); gr "$APP" "$BASE" scripts/check.sh -- build; PRE=()
    rm -f "$P/plant-build"
    ok A9 '[ ! -e "$P/pwn" ] && [ -s "$P/strace" ] && ! grep "^[0-9]* *execve(" "$P/strace" | grep -q "/bin/x\""'
fi
if want A10 && [ "$ME" = 0 ]; then
    touch "$P/plant-build"; gr "$APP" "$BASE" scripts/check.sh -- build; rm -f "$P/plant-build"
    ok A10 '[ -e "$P/fake-etc/probe" ] && [ -n "$(find "$VT/$APP-gate-build" -name keep)" ] && [[ $OUT == *"was not emptied by nobody"* ]]'
    find "$VT/$APP-gate-build" -mindepth 1 -delete
fi
if want A11; then
    printf 'case $0 in *gate-run.sh) ;; *) touch %s/bashenv-ran ;; esac\n' "$P" >"$S/bashenv"
    PRE=(env "BASH_ENV=$S/bashenv" "BASH_FUNC_x%%=() { :; }" GIT_DIR=/nonexistent); gr "$APP" "$BASE" scripts/check.sh; PRE=()
    ok A11 '[ "$RC" = 0 ] && [ ! -e "$P/bashenv-ran" ] && ! grep -qE "^(BASH_ENV|BASH_FUNC|GIT_DIR|GATE_RUN_T_|GATE_RUN_DIR)" "$P/env"'
fi
if want A12; then
    gr "$APP" "$BASE" scripts/check.sh -- compose
    envsum=$(sha256sum <"$S/gate-env/$APP/.env.e2e" | cut -d' ' -f1)
    ok A12a '[ "$RC" = 0 ] && grep -q "^FILE --env-file $RB/$APP-gate/[A-Za-z0-9]*/env/.env.e2e $ME $envsum$" "$P/docker.log"'
    mv "$S/gate-env/$APP/.env.e2e" "$S/real-env"; ln -s "$S/real-env" "$S/gate-env/$APP/.env.e2e"
    gr "$APP" "$BASE" scripts/check.sh -- compose
    ok A12b '[ "$RC" = 2 ] && [[ $OUT == *"not a root-owned regular file"* ]]'
    rm -f "$S/gate-env/$APP/.env.e2e"; mv "$S/real-env" "$S/gate-env/$APP/.env.e2e"
fi
if want A13; then
    g -C "$SRC" update-ref refs/remotes/origin/main "$SHA_ahead"
    gr "$APP" "$SHA_ahead" scripts/check.sh
    ok A13 '[ "$RC" = 0 ] && [ "$(cat "$P/origin-main")" = "$BASE" ]'
fi
if want A14; then
    line=$(grep -F 'rm -rf -- "${RUN_BASE_DIR' "${GR_RUN_SH:-$REPO_ROOT/scripts/lib/gate/run.sh}")
    mkdir -p "$S/a14/-gate/x"; chown -R nobody: "$S/a14"
    runuser -u nobody -- env RUN_BASE_DIR="$S/a14" APP='' ID='' LINE="$line" bash -c 'eval "$LINE"' 2>/dev/null
    ok A14 '[ -n "$line" ] && [ -d "$S/a14/-gate/x" ]'
fi
if want A15; then
    gr "$APP" HEAD scripts/check.sh
    ok A15a '[ "$RC" = 2 ] && [[ $OUT == *"not 40 lowercase hex"* ]] && no_run'
    gr "$APP" "${BASE:0:39}" scripts/check.sh
    ok A15b '[ "$RC" = 2 ] && [[ $OUT == *"not 40 lowercase hex"* ]] && no_run'
    gr "$APP" "$BASE" ../x.sh
    ok A15c '[ "$RC" = 2 ] && [[ $OUT == *"not a path under scripts/"* ]] && no_run'
    gr "$APP" "$BASE" scripts/../x.sh
    ok A15d '[ "$RC" = 2 ] && [[ $OUT == *"not a path under scripts/"* ]] && no_run'
    gr "$APP" "$BASE" scripts/nope.sh
    ok A15e '[ "$RC" = 2 ] && [[ $OUT == *"scripts/nope.sh is not a file at"* ]] && no_run'
    gr "$APP" "$SHA_dotenv" scripts/check.sh
    ok A15f '[ "$RC" = 2 ] && [[ $OUT == *".env is committed"* ]] && no_run'
fi
if want A16; then
    rm -rf -- "${VT:?}/$APP-gate-build"; ln -s "$P/fake-etc" "$VT/$APP-gate-build"
    gr "$APP" "$BASE" scripts/check.sh
    ok A16a '[ "$RC" = 2 ] && [[ $OUT == *"gate-build is a symlink"* ]] && [ "$(ls "$P/fake-etc")" = probe ]'
    rm -f -- "$VT/$APP-gate-build"; mkdir "$VT/$APP-gate-build"
    if [ "$ME" = 0 ]; then chown nobody "$VT/$APP-gate-build"; else chmod 777 "$VT/$APP-gate-build"; fi
    gr "$APP" "$BASE" scripts/check.sh
    ok A16b '[ "$RC" = 2 ] && [[ $OUT == *"gate-build is a symlink"* ]] && [ -z "$(ls -A "$VT/$APP-gate-build")" ]'
    rmdir -- "$VT/$APP-gate-build"
fi
if want A17; then
    DFBIN=$S/bin/smalldf gr "$APP" "$BASE" scripts/check.sh
    ok A17 '[ "$RC" = 2 ] && [[ $OUT == *"under twice"* ]] && no_run'
fi
if want A18; then
    gr "$APP" "$SHA_unpushed" scripts/check.sh
    ok A18 '[ "$RC" = 2 ] && [[ $OUT == *"only a sha on GitHub is gated"* ]] && no_run'
fi
if want S1; then
    judge_caller() { grep -q '^\. .*scripts/lib/gate/export\.sh' "$1" && ! grep -qE '^(EXPORT_YAML_CHECK=|export_judge\(\)|export_write\(\))' "$1"; }
    printf '. "$LIB/scripts/lib/gate/export.sh"\n' >"$S/good-caller"
    sed -n '/^EXPORT_YAML_CHECK=/,/^}/p' "$REPO_ROOT/scripts/lib/gate/export.sh" >"$S/copy-caller"
    ok S1 'judge_caller "$S/good-caller" && ! judge_caller "$S/copy-caller"'
    for c in ${GR_CALLERS:-}; do OUT="$c carries its own export-tree block"; ok "S1:$c" 'judge_caller "$c"'; done
fi

printf '%s passed, %s failed%s\n' "$pass" "$fail" "${failed[*]:+ (${failed[*]})}"
[ "$fail" = 0 ] && [ "$pass" -gt 0 ]
