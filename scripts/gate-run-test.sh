#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC1090,SC2317  # assertions are single-quoted strings ok() evals
# Planted attacks on scripts/gate-run.sh and scripts/lib/gate/ (card 719) against a throwaway repo, a local "GitHub" and
# gate-run-fake-docker.py. Knobs (GR_ENTRY, GR_*_SH, GR_CASES, GR_AS_NOBODY, GR_REAL_DOCKER, GR_CALLERS): README.md.
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
mkdir -m 755 "$P" "$RB" "$VT" "$S/deploy-src" "$S/gh" "$S/gate-env" "$S/gate-env/$APP" "$P/fake-etc" "$S/esp" "$S/redproof"
printf 'probe\n' >"$P/fake-etc/probe"
printf 'APP_KEY=gate-only\n' >"$S/gate-env/$APP/.env.e2e"
chmod 644 "$S/gate-env/$APP/.env.e2e"
[ "$ME" = 0 ] || chown -R nobody: "$P" "$RB" "$VT" "$S/gate-env" "$S/redproof"
mkdir -m 755 "$S/bin"
cp -- "$ENTRY" "$S/bin/gate-run.sh" && ENTRY=$S/bin/gate-run.sh || exit 2
cp -- "$REPO_ROOT/scripts/gate-run-fake-docker.py" "$P/docker.py"
[ "${GR_REAL_DOCKER:-0}" = 1 ] || printf '#!/bin/sh\nexec /usr/bin/python3 -I %s "$@"\n' "$P/docker.py" >"$S/bin/docker"
printf '#!/bin/sh\necho Avail; echo 1000\n' >"$S/bin/smalldf"
printf '#!/bin/sh\necho Avail; echo lots\n' >"$S/bin/baddf"
chmod 755 "$S/bin/smalldf" "$S/bin/baddf"; [ ! -e "$S/bin/docker" ] || chmod 755 "$S/bin/docker"
g() { git -c user.name=gate-run-test -c user.email=gate-run-test@invalid "$@"; }

# The box clone: this tree's lib (or a mutant copy) committed twice, with origin/main at HEAD; es-link also commits a link.
mk_es() { # dir [link]
    local es=$1
    mkdir -p "$es/scripts/lib"
    cp -r -- "$REPO_ROOT/scripts/lib/gate" "$REPO_ROOT/scripts/lib/deploy" "$es/scripts/lib/"
    [ -z "${GR_RUN_SH:-}" ] || cp -- "$GR_RUN_SH" "$es/scripts/lib/gate/run.sh"
    [ -z "${GR_EXPORT_SH:-}" ] || cp -- "$GR_EXPORT_SH" "$es/scripts/lib/gate/export.sh"
    [ -z "${GR_COMPOSE_SH:-}" ] || cp -- "$GR_COMPOSE_SH" "$es/scripts/lib/gate/compose.sh"
    chmod -R go-w "$es"
    g init -q -b main "$es" && g -C "$es" add scripts && g -C "$es" commit -qm lib && g -C "$es" commit -q --allow-empty -m second || return 1
    if [ -n "${2:-}" ]; then
        ln -s /etc/passwd "$es/scripts/lib/gate/evil.sh" && g -C "$es" add scripts && g -C "$es" commit -qm link || return 1
        g -C "$es" update-index --skip-worktree scripts/lib/gate/evil.sh && rm -f -- "$es/scripts/lib/gate/evil.sh" || return 1
    fi
    g -C "$es" update-ref refs/remotes/origin/main HEAD || return 1
    ES_FIRST=$(g -C "$es" rev-parse HEAD~1) ES_HEAD=$(g -C "$es" rev-parse HEAD)
    [ "$ME" = 0 ] || chown -R nobody: "$es"
}
ES=$S/esp/es
mk_es "$S/esp/es-link" link && mk_es "$ES" || exit 2

# The app: a bare "GitHub" that serves reachable shas, and the app's own clone.
GH=$S/gh/$APP.git SRC=$S/src
g init -q --bare -b main "$GH" && g -C "$GH" config uploadpack.allowReachableSHA1InWant true || exit 2
g init -q -b main "$SRC" || exit 2
mkdir -p "$SRC/scripts/lib/deploy"
cp -- "$REPO_ROOT/scripts/lib/deploy/ledger.sh" "$SRC/scripts/lib/deploy/"
cat >"$SRC/scripts/check.sh" <<EOF
#!/usr/bin/env bash
set -u
P=$P mode=\${1:-}
. "\$GATE_RUN/tree/scripts/lib/deploy/ledger.sh"
gate_ledger_arm
other=1111111111111111111111111111111111111111
fin() {
    local rc=\$?
    [ "\$mode" != lie ] || { gate_ledger_record ci 0 -; exit 1; }
    gate_ledger_record ci "\$rc" -
    case \$mode in
        double) tail -1 "\$GATE_LEDGER" >>"\$GATE_LEDGER" ;;
        other) printf "%s ci t 0 - -\\n" "\$other" >"\$GATE_LEDGER" ;;
        norow) : >"\$GATE_LEDGER" ;;
    esac
}
trap fin EXIT
sha256sum <"\$0" | cut -d' ' -f1 >"\$P/selfhash"
env | sort >"\$P/env"
\$CI_GIT rev-parse refs/remotes/origin/main >"\$P/origin-main" 2>&1
alt=\$GATE_RUN/repo.git/objects/info/alternates
[ ! -f "\$alt" ] || { cat "\$alt"; stat -c %u "\$alt"; } >"\$P/alternates"
[ ! -f "\$P/hold" ] || sleep 2
case "\$mode" in
    badf) \$GATE_COMPOSE -f /etc/passwd config || exit \$? ;;
    stack) \$GATE_COMPOSE -f stack.yml up -d || exit \$? ;;
    preswap) mv "\$GATE_BUILD/artifacts" "\$GATE_BUILD/artifacts.old" && ln -s "\$P/fake-etc" "\$GATE_BUILD/artifacts"
        \$GATE_COMPOSE -f docker-compose.yml up -d || exit \$? ;;
    badenv) \$GATE_COMPOSE -f docker-compose.yml --env-file ../manifest up -d || exit \$? ;;
    compose) \$GATE_COMPOSE -f docker-compose.yml --env-file .env.e2e up || exit \$? ;;
    profiled) \$GATE_COMPOSE -f docker-compose.yml --profile assets up -d || exit \$? ;;
    passf) shift; \$GATE_COMPOSE -f docker-compose.yml "\$@" || exit \$? ;;
    build) \$GATE_COMPOSE --build -f docker-compose.yml run app true || exit \$?; \$GATE_COMPOSE -f docker-compose.yml up -d || exit \$? ;;
esac
GATE_SUITE_PASSED=1
EOF
printf 'services:\n  app:\n    image: alpine:3.20\n    command: [sh, -c, "echo report >/var/www/html/e2e/artifacts/report.txt"]\n    volumes:\n      - .:/var/www/html\n' >"$SRC/docker-compose.yml"
printf 'readme\n' >"$SRC/README.md"; printf 'ignored.log\n' >"$SRC/.gitignore"
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
commit stack 'printf "include:\n  - /var/www/x/compose.yml\nservices: {}\n" >stack.yml' && SHA_stack=$SHA || exit 2
commit named 'printf "services:\n  app:\n    image: alpine:3.20\n    volumes:\n      - .:/var/www/html\n      - data:/data\nvolumes:\n  data:\n    name: gt719_data\n" >docker-compose.yml' && SHA_named=$SHA || exit 2
commit profiled 'printf "  assets:\n    image: alpine:3.20\n    profiles: [assets]\n    volumes:\n      - .:/app\n" >>docker-compose.yml' && SHA_profiled=$SHA || exit 2
NOPUSH=1 commit unpushed 'printf local >>README.md' && SHA_unpushed=$SHA || exit 2
g -C "$SRC" checkout -q "$BASE" || exit 2
g clone -q --bare "$GH" "$S/mirror" || exit 2
[ "$ME" = 0 ] || chown -R nobody: "$GH"


gr() { # app sha script [args] -> OUT, RC; the ledger is $S/ledger
    rm -f -- "$P/docker.log" "$P/selfhash" "$P/env" "$P/alternates"
    OUT=$(env GATE_RUN_T_RUN_BASE="$RB" GATE_RUN_T_LIB_CLONE="${LIBC:-$ES}" GATE_RUN_T_UID="$ME" GATE_RUN_T_URL_PREFIX="$S/gh/" \
        GATE_RUN_T_SRC="$S/deploy-src" GATE_RUN_T_LEDGER="$P/ledger" GATE_RUN_T_BUILD_BASE="$VT" GATE_RUN_T_ENV_DIR="$S/gate-env" \
        GATE_RUN_T_PATH="$S/bin:/usr/bin:/bin" GATE_RUN_T_APP_USER="${GR_APPU:-$APPU}" GATE_RUN_T_DF="${DFBIN:-/usr/bin/df}" \
        "${PRE[@]}" "${RUNAS[@]}" bash "$ENTRY" "$@" 2>&1)
    RC=$?
}

PRE=()
ok() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); failed+=("$1"); printf 'FAIL %s: %s\n%s\n' "$1" "$2" "$OUT" | head -30; fi; }
want() { [ -z "${GR_CASES:-}" ] || [[ " $GR_CASES " == *" $1 "* ]]; }
no_run() { [ -z "$(ls -A "$RB/$APP-gate" 2>/dev/null)" ]; }
ledger_last() { tail -1 "$P/ledger" 2>/dev/null; }
ledger_n() { grep -c '' "$P/ledger" 2>/dev/null || true; }
fake_etc_clean() { [ "$(ls -A "$P/fake-etc")" = probe ]; }
# decision: grep-q-reads-a-here-string-not-a-pipe
stray_compose_file() { local f; f=$(grep "^FILE -f" "$1") || return 1; grep -vq -e "/tree/docker-compose.yml " -e "/override.yml " <<<"$f"; }
ran_bin_x() { local e; e=$(grep "^[0-9]* *execve(" "$1") || return 1; grep -q '/bin/x"' <<<"$e"; }

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
    ok A2 '[ "$RC" = 0 ] && grep -q "^FILE -f .*/tree/docker-compose.yml [0-9]* $blob$" "$P/docker.log" && ! stray_compose_file "$P/docker.log"'
    g -C "$SRC" checkout -q -f "$BASE"
    { printf 'FILE -f /etc/evil.yml 1 x\n'; printf 'FILE -f /run/t/tree/docker-compose.yml %s x\n' {1..30000}; } >"$S/big-docker.log"
    OUT="a stray -f file on line 1 of a 1.2 MB docker.log"; ok A2-big 'stray_compose_file "$S/big-docker.log"'
fi
if want A2; then
    gr "$APP" "$BASE" scripts/check.sh -- badf
    ok A2b '[ "$RC" = 2 ] && [[ $OUT == *"is not a compose file at the top of"* ]]'
fi
if want A3; then
    gr "$APP" "$SHA_host" scripts/check.sh -- compose
    ok A3a '[ "$RC" = 2 ] && [[ $OUT == *"reaches outside"* ]] && [ -f "$P/docker.log" ] && ! grep -q "ARGV.* up" "$P/docker.log"'
    touch "$P/ignore-override"; gr "$APP" "$BASE" scripts/check.sh -- compose; rm -f "$P/ignore-override"
    ok A3b '[ "$RC" = 2 ] && [[ $OUT == *"mounted read-write"* ]] && [ -f "$P/docker.log" ] && ! grep -q "ARGV.* up" "$P/docker.log"'
    touch "$P/deep-bind"; gr "$APP" "$BASE" scripts/check.sh -- compose; rm -f "$P/deep-bind"
    ok A3c '[ "$RC" = 2 ] && [[ $OUT == *"is not the tree or a build dir"* ]] && [ -f "$P/docker.log" ] && ! grep -q "ARGV.* up" "$P/docker.log"'
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
    touch "$P/hold"; gr "$APP" "$BASE" scripts/check.sh; rm -f "$P/hold"; wait
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
    ok A9 '[ ! -e "$P/pwn" ] && [ -s "$P/strace" ] && ! ran_bin_x "$P/strace"'
    { printf '9 execve("/bin/x", ["/bin/x"], 0x0) = 0\n'; printf '%s execve("/usr/bin/true", ["true"], 0x0) = 0\n' {10000..40000}; } >"$S/big-strace"
    OUT="a /bin/x execve on line 1 of a 1.4 MB strace"; ok A9-big 'ran_bin_x "$S/big-strace"'
    ok A9-user 'grep -q "^ARGV compose .* run --user $(id -u nobody):$(id -g nobody) app true$" "$P/docker.log"'
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
    gr "$APP" "$BASE" scripts/check.sh -- badenv
    ok A12c '[ "$RC" = 2 ] && [[ $OUT == *"is not a file root wrote to"* ]] && [ ! -e "$P/docker.log" ]'
    chmod 777 "$S/gate-env/$APP"; gr "$APP" "$BASE" scripts/check.sh; chmod 755 "$S/gate-env/$APP"
    ok A12d '[ "$RC" = 2 ] && [[ $OUT == *"not a root-owned directory only root can write"* ]]'
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
    mv "$RB/$APP-gate" "$RB/gates.real"; ln -s "$P/fake-etc" "$RB/$APP-gate"
    gr "$APP" "$BASE" scripts/check.sh
    ok A16c '[ "$RC" = 2 ] && [[ $OUT == *"-gate is a symlink"* ]] && [ "$(ls "$P/fake-etc")" = probe ]'
    rm -f -- "$RB/$APP-gate"; mv "$RB/gates.real" "$RB/$APP-gate"
    GR_APPU=root gr "$APP" "$BASE" scripts/check.sh
    ok A16d '[ "$RC" = 2 ] && [[ $OUT == *"is root: the build would not be confined"* ]] && no_run'
fi
if want A17; then
    DFBIN=$S/bin/smalldf gr "$APP" "$BASE" scripts/check.sh
    ok A17 '[ "$RC" = 2 ] && [[ $OUT == *"under twice"* ]] && no_run'
    DFBIN=$S/bin/baddf gr "$APP" "$BASE" scripts/check.sh
    ok A17b '[ "$RC" = 2 ] && [[ $OUT == *"free space"*"could not be read"* ]] && no_run'
fi
if want A18; then
    gr "$APP" "$SHA_unpushed" scripts/check.sh
    ok A18 '[ "$RC" = 2 ] && [[ $OUT == *"only a sha on GitHub is gated"* ]] && no_run'
fi
if want B1 && [ "$ME" = 0 ]; then
    printf '%s:%s\n' "$(id -u nobody)" "$(id -g nobody)" >"$P/swap-build"
    gr "$APP" "$BASE" scripts/check.sh -- compose; rm -f "$P/swap-build"
    ok B1a '[ "$RC" = 0 ] && grep -q "^SWAP refused" "$P/docker.log" && fake_etc_clean'
fi
if want B1; then
    gr "$APP" "$BASE" scripts/check.sh -- preswap
    ok B1b '[ "$RC" = 2 ] && [[ $OUT == *"a build dir in"*"is a link"* ]] && [ -f "$P/docker.log" ] && ! grep -q "ARGV.* up" "$P/docker.log" && fake_etc_clean'
    find "$VT/$APP-gate-build" -mindepth 1 -delete
fi
if want L; then
    chmod 777 "$S/esp"; gr "$APP" "$BASE" scripts/check.sh; chmod 755 "$S/esp"
    ok L1 '[ "$RC" = 2 ] && [[ $OUT == *"esp is a symlink, not root'"'"'s, or writable by others"* ]] && no_run'
    lib=$ES/scripts/lib/gate/export.sh; cp -- "$lib" "$S/lib.save"; printf '# dirty\n' >>"$lib"
    gr "$APP" "$BASE" scripts/check.sh; cp -- "$S/lib.save" "$lib"
    ok L2 '[ "$RC" = 2 ] && [[ $OUT == *"modified, untracked or ignored files under the lib"* ]] && no_run'
    printf '%s\n' "$ES_FIRST" >"$ES/.git/refs/remotes/origin/main"; gr "$APP" "$BASE" scripts/check.sh
    printf '%s\n' "$ES_HEAD" >"$ES/.git/refs/remotes/origin/main"
    ok L3 '[ "$RC" = 2 ] && [[ $OUT == *"HEAD is not its origin/main"* ]] && no_run'
    LIBC=$S/esp/es-link gr "$APP" "$BASE" scripts/check.sh
    ok L4 '[ "$RC" = 2 ] && [[ $OUT == *"evil.sh at "*"mode 120000, not a plain file in scripts/lib/gate"* ]] && no_run'
fi
if want A19; then
    mv -- "$S/mirror" "$S/deploy-src/$APP.git" || exit 2
    gr "$APP" "$BASE" scripts/check.sh
    ok A19a '[ "$RC" = 0 ] && [ "$(cat "$P/alternates" 2>/dev/null)" = "$S/deploy-src/$APP.git/objects"$'"'"'\n'"'"'"$ME" ]'
    chmod 777 "$S/deploy-src"; gr "$APP" "$BASE" scripts/check.sh
    ok A19b '[ "$RC" = 0 ] && [ ! -e "$P/alternates" ] && [[ $OUT == *"is not root'"'"'s alone, so it is not borrowed"* ]]'
    chmod 755 "$S/deploy-src"
    for bad in 'chmod 777 objects/info' 'ln -s /etc objects/info/evil'; do
        (cd "$S/deploy-src/$APP.git" && eval "$bad"); gr "$APP" "$BASE" scripts/check.sh
        ok "A19c:$bad" '[ "$RC" = 0 ] && [ ! -e "$P/alternates" ] && [[ $OUT == *"something in its objects is not root'"'"'s alone"* ]]'
        chmod 755 "$S/deploy-src/$APP.git/objects/info"; rm -f -- "$S/deploy-src/$APP.git/objects/info/evil"
    done
    mv -- "$S/deploy-src/$APP.git" "$S/mirror"
fi
if want A20; then
    gr "$APP" "$SHA_stack" scripts/check.sh -- stack
    ok A20 '[ "$RC" = 2 ] && [[ $OUT == *"stack.yml has an include:"* ]] && [ ! -e "$P/docker.log" ]'
fi
if want N1; then
    gr "$APP" "$SHA_named" scripts/check.sh -- compose
    ok N1 '[ "$RC" = 2 ] && [[ $OUT == *"name gt719_data is outside this gate project"* ]] && [ -f "$P/docker.log" ] && ! grep -q "ARGV.* up" "$P/docker.log"'
fi
if want PF; then
    gr "$APP" "$SHA_profiled" scripts/check.sh -- profiled
    ok PFa '[ "$RC" = 0 ] && grep -q "^MOUNT assets /app ro$" "$P/docker.log" && grep -q "^MOUNT assets /app/vendor ro$" "$P/docker.log" && ! grep -q "^MOUNT assets /app rw" "$P/docker.log"'
    printf 'assets\n' >"$P/ignore-override"; gr "$APP" "$SHA_profiled" scripts/check.sh -- profiled; rm -f "$P/ignore-override"
    ok PFb '[ "$RC" = 2 ] && [[ $OUT == *"compose assets: "*"mounted read-write"* ]] && ! grep -q "ARGV.* up" "$P/docker.log"'
fi
if want PT; then
    for a in '-f /etc/x.yml' '--file=/etc/x.yml' '-fx.yml' '-dp other' '--project-name other' '--project-directory=/' '--env-file=.env.e2e'; do
        read -ra extra <<<"$a"; gr "$APP" "$BASE" scripts/check.sh -- passf up "${extra[@]}"
        ok "PT:$a" '[ "$RC" = 2 ] && [[ $OUT == *"after the compose options could name another file"* ]] && [ ! -e "$P/docker.log" ]'
    done
fi
if want D2; then
    for m in norow double other; do
        n=$(ledger_n); gr "$APP" "$BASE" scripts/check.sh -- "$m"
        ok "D2-$m" '[ "$RC" = 1 ] && [[ $OUT == *"so no row is written"* ]] && [ "$(ledger_n)" = "$n" ]'
    done
    gr "$APP" "$BASE" scripts/check.sh -- lie
    ok D2-lie '[ "$RC" = 1 ] && [[ $OUT == *"the row says rc 0 but scripts/check.sh exited 1"* ]] && [[ $(ledger_last) == "$BASE ci "*" 1 - "* ]]'
fi
if want LG; then
    n=$(ledger_n); gr "$APP" "$BASE" scripts/check.sh --ledger "$S/redproof/ledger"
    ok LGa '[ "$RC" = 0 ] && [[ $(tail -1 "$S/redproof/ledger" 2>/dev/null) == "$BASE ci "* ]] && [ "$(ledger_n)" = "$n" ]'
    install -d -m 777 "$P/open"; gr "$APP" "$BASE" scripts/check.sh --ledger "$P/open/ledger"
    ok LGb '[ "$RC" = 2 ] && [[ $OUT == *"is not a root-only file"* ]] && no_run && [ ! -e "$P/open/ledger" ]'
    gr "$APP" "$BASE" scripts/check.sh --ledger ledger
    ok LGc '[ "$RC" = 2 ] && [[ $OUT == *"--ledger is not an absolute path"* ]] && no_run'
    gr "$APP" "$BASE" scripts/check.sh --ledger "$S/redproof/out"
    ok LGd '[ "$RC" = 2 ] && [[ $OUT == *"is not named *ledger*"* ]] && no_run && [ ! -e "$S/redproof/out" ]'
    n=$(ledger_n); PRE=(env "GATE_LEDGER=$S/redproof/ledger-env"); gr "$APP" "$BASE" scripts/check.sh; PRE=()
    ok LGe '[ "$RC" = 2 ] && [[ $OUT == *"GATE_LEDGER is set but gate-run never reads it"* ]] && no_run && [ "$(ledger_n)" = "$n" ]'
fi
if want C1; then
    if [ -f "${GR_FLEET_DEPLOY:-/usr/local/sbin/fleet-deploy}" ]; then
        block() { sed -n '/^# >>> clone-lib/,/^# <<< clone-lib/p' "$1" | sed -e 's/^[[:space:]]*//' -e '/^#/d' -e '/^$/d'; }
        block "$ENTRY" | grep -vE 'LIB_SUB|\$sub|run\.sh|gate lib|HEAD\^\{commit\}|local d=|chmod 644|is not a git clone"|under the lib:|^done$' >"$S/c1-gate"
        block "${GR_FLEET_DEPLOY:-/usr/local/sbin/fleet-deploy}" | grep -vE 'LIB_SUB|summary\.sh|deploy lib|origin/main\^\{commit\}|scripts/lib/deploy/|100755|local d=|symbolic-ref|^done$' >"$S/c1-deploy"
        OUT=$(diff "$S/c1-gate" "$S/c1-deploy")
        ok C1 '[ -z "$OUT" ] && [ "$(wc -l <"$S/c1-gate")" -ge 15 ]'
    else
        printf 'SKIP C1: no %s to compare the clone-lib block with\n' "${GR_FLEET_DEPLOY:-/usr/local/sbin/fleet-deploy}"
    fi
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
