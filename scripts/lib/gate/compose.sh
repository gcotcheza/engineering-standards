# shellcheck shell=bash disable=SC2015  # every A && B || die here ends in an exit
# $GATE_COMPOSE [--build] [-f <file>]… [--env-file <name>] <compose args>: docker compose over <run>/tree only, through
# root's override; --build runs as the app uid with the build dirs writable. decision: gate-run-exports-one-sha
set -uo pipefail

LIB=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
RUN=${LIB%/lib/scripts/lib/gate}
TREE=$RUN/tree
die() { printf 'gate-compose: REFUSED: %s\n' "$*" >&2; exit 2; }
read -r APP ID BUILD OWNER RUN_PATH <"$RUN/compose-context" || die "$RUN/compose-context is unreadable"
[[ $ID =~ ^[A-Za-z0-9]{10}$ && $RUN == */"$APP"-gate/"$ID" ]] || die "$RUN is not a gate-run run directory"

PROJECT=$APP-gate-$(printf '%s' "$ID" | od -An -tx1 | tr -d ' \n')
build=0 files=() envf=/dev/null
[ "${1:-}" != --build ] || { build=1; shift; }
while [ $# -gt 0 ]; do
    case $1 in
        -f) [[ ${2:-} =~ ^[A-Za-z0-9._-]+\.ya?ml$ && -f $TREE/$2 && ! -L $TREE/$2 ]] || die "-f ${2:-} is not a compose file at the top of $TREE"
            files+=(-f "$TREE/$2"); shift 2 ;;
        --env-file) [[ ${2:-} =~ ^\.env[A-Za-z0-9._-]*$ && -f $RUN/env/$2 && ! -L $RUN/env/$2 ]] || die "--env-file ${2:-} is not a file root wrote to $RUN/env"
            envf=$RUN/env/$2; shift 2 ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || die "no compose command"
if [ ${#files[@]} -eq 0 ]; then
    [ -f "$RUN/compose-used" ] || die "no -f given and no earlier call named the compose files"
    mapfile -t files <"$RUN/compose-used"
    envf=$(cat "$RUN/compose-envfile")
else
    printf '%s\n' "${files[@]}" >"$RUN/compose-used" && printf '%s\n' "$envf" >"$RUN/compose-envfile" || die "cannot record the compose files"
fi

dc() { env -i PATH="$RUN_PATH" HOME=/root docker compose --project-directory "$TREE" "$@"; }
# shellcheck source=scripts/lib/deploy/compose.sh
. "$RUN/lib/scripts/lib/deploy/compose.sh" || die "the deploy compose policy could not be loaded"
json=$(dc -p "$APP" "${files[@]}" --env-file "$envf" config --format json) || die "compose config failed over the exported files"
deploy_compose_policy "$TREE" "$json" "$APP" "$envf" dc -p "$APP" "${files[@]}" --env-file "$envf" || die "$DEPLOY_COMPOSE_ERR"

override=$RUN/override.yml
[ "$build" = 0 ] || override=$RUN/override-build.yml
printf '%s' "$json" | env -i PATH=/usr/bin:/bin /usr/bin/python3 -I -c '
import json, sys
tree, build, rw = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
cfg, out = json.load(sys.stdin), {}
dirs = (("vendor", "vendor"), ("node_modules", "node_modules"), ("public-build", "public/build"), ("bootstrap-cache", "bootstrap/cache"))
for name, svc in (cfg.get("services") or {}).items():
    vols = []
    for v in svc.get("volumes") or []:
        if v.get("type") != "bind" or not (v["source"] + "/").startswith(tree + "/"): continue
        vols.append({"type": "bind", "source": v["source"], "target": v["target"], "read_only": True})
        if v["source"] == tree:
            t = v["target"].rstrip("/")
            vols += [{"type": "bind", "source": build + "/" + d, "target": t + "/" + m, "read_only": not rw} for d, m in dirs]
            vols.append({"type": "bind", "source": build + "/artifacts", "target": t + "/e2e/artifacts", "read_only": False})
    if vols: out[name] = {"volumes": vols}
json.dump({"services": out}, open(sys.argv[4], "w"))
' "$TREE" "$BUILD" "$build" "$override" || die "cannot write $override"

final=$(dc -p "$PROJECT" "${files[@]}" -f "$override" --env-file "$envf" config --format json) || die "compose config failed with $override"
printf '%s' "$final" | env -i PATH=/usr/bin:/bin /usr/bin/python3 -I -c '
import json, sys
run, build = sys.argv[1], sys.argv[2]
under = lambda p, d: (p.rstrip("/") + "/").startswith(d + "/")
for name, svc in (json.load(sys.stdin).get("services") or {}).items():
    ctx = (svc.get("build") or {}).get("context")
    if ctx and not under(ctx, run + "/tree"): sys.exit("compose %s: build.context %s is outside %s/tree" % (name, ctx, run))
    for v in svc.get("volumes") or []:
        if v.get("type") != "bind": continue
        src = v.get("source", "")
        if under(src, run):
            if not v.get("read_only"): sys.exit("compose %s: %s is mounted read-write" % (name, src))
        elif not under(src, build): sys.exit("compose %s: bind %s is outside %s and the build dir" % (name, src, run))
' "$RUN" "$BUILD" || die "the compose config failed root's bind check"

if [ "$build" = 1 ]; then
    [ "$1" = run ] || die "--build takes a compose run"
    shift
    set -- run --user "$OWNER" "$@"
fi
dc -p "$PROJECT" "${files[@]}" -f "$override" --env-file "$envf" "$@"
