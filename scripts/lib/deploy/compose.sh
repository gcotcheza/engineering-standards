# fleet-deploy-lib 2026-10-05.4 sha256:1930132c8377dbe93eea31c6f27fbd264774f7eac335d69f890ad8d6455efe24
# shellcheck shell=bash
# Root's compose reads no file the app user can edit: compose files exported beside this lib by
# fleet-deploy, and root's /etc/fleet/app-env/<app>.env. docs/DECISIONS.md (backlog 320)

FLEET_COMPOSE_LIB="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/compose.sh"
FLEET_COMPOSE_WORD='^/?[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$'
# External networks an app may join, by exact name: scribly and reflection share whisper (docs/DECISIONS.md).
FLEET_COMPOSE_SHARED_NETWORKS="whisper-net"

# One rule a line, F|A <service> <key> or P <service> <key> <path>; values never leave jq.
# A lines come last, so a key both lists refuse is named by its F rule (docs/DECISIONS.md, backlog 320).
# shellcheck disable=SC2016
FLEET_COMPOSE_POLICY='
def fleet_off($ok): select(IN($ok[]) | not);
(.services // {} | to_entries[] | .key as $s | .value as $v | (
  (select($v.privileged == true) | "F\t\($s)\tprivileged"),
  (select($v.pid == "host") | "F\t\($s)\tpid"),
  (select($v.ipc == "host") | "F\t\($s)\tipc"),
  (select($v.network_mode == "host") | "F\t\($s)\tnetwork_mode"),
  (select($v.uts == "host") | "F\t\($s)\tuts"),
  (select($v.userns_mode == "host") | "F\t\($s)\tuserns_mode"),
  (select($v.cgroup == "host") | "F\t\($s)\tcgroup"),
  (select(($v.cap_add // []) | length > 0) | "F\t\($s)\tcap_add"),
  (select(($v.devices // []) | length > 0) | "F\t\($s)\tdevices"),
  (select(($v.device_cgroup_rules // []) | length > 0) | "F\t\($s)\tdevice_cgroup_rules"),
  ($v | to_entries[] | select(.key == "network_mode" or .key == "pid" or .key == "ipc") | select(.value | type == "string" and startswith("container:")) | "F\t\($s)\t\(.key) (container:)"),
  (select(any($v.volumes_from[]?; startswith("container:"))) | "F\t\($s)\tvolumes_from (container:)"),
  (select($v.provider != null) | "F\t\($s)\tprovider"),
  (select(($v.security_opt // [])
    - ["no-new-privileges:true", "no-new-privileges=true", "no-new-privileges"]
    | length > 0) | "F\t\($s)\tsecurity_opt"),
  (select(any($v.volumes[]?; (.source // "") | test("docker[.]sock$"))) | "F\t\($s)\tvolumes (docker.sock)"),
  (select(($v.build.secrets // []) | length > 0) | "F\t\($s)\tbuild.secrets"),
  (select(($v.build.ssh // []) | length > 0) | "F\t\($s)\tbuild.ssh"),
  (select(($v.build.additional_contexts // {}) | length > 0) | "F\t\($s)\tbuild.additional_contexts"),
  (select($v.build.privileged == true) | "F\t\($s)\tbuild.privileged"),
  (select(($v.build.entitlements // []) | length > 0) | "F\t\($s)\tbuild.entitlements"),
  (select($v.build.network == "host") | "F\t\($s)\tbuild.network"),
  ($v.volumes[]? | select(.type == "bind") | "P\t\($s)\tvolumes\t\(.source // "")"),
  ($v.env_file[]? | "P\t\($s)\tenv_file\t\(if type == "object" then .path else . end)"),
  ($v.build? // empty | "P\t\($s)\tbuild.context\t\(.context // "")"),
  empty)),
(.volumes // {} | to_entries[] | select((.value.driver_opts // {}) | length > 0) | "F\tvolume \(.key)\tdriver_opts"),
(.volumes // {} | to_entries[] | select(.value.external == true) | "F\tvolume \(.key)\texternal"),
(.networks // {} | to_entries[] | select(.value.driver == "host") | "F\tnetwork \(.key)\tdriver host"),
(.networks // {} | to_entries[] | select(.value.external == true and (.value.name // .key) == "host") | "F\tnetwork \(.key)\texternal host"),
(.volumes // {} | to_entries[] | select(.value.driver != null and .value.driver != "local") | "F\tvolume \(.key)\tdriver"),
(.networks // {} | to_entries[] | select(.value.driver != null and .value.driver != "bridge") | "F\tnetwork \(.key)\tdriver"),
(.networks // {} | to_entries[] | select((.value.ipam // {}) | length > 0) | "F\tnetwork \(.key)\tipam"),
(select(.name != $app) | "F\ttop level\tname"),
(.volumes // {} | to_entries[] | select(.value.external != true and ((.value.name // "\($app)_\(.key)") | startswith("\($app)_") | not)) | "F\tvolume \(.key)\tname"),
(.networks // {} | to_entries[] | select(.value.external != true and ((.value.name // "\($app)_\(.key)") | startswith("\($app)_") | not)) | "F\tnetwork \(.key)\tname"),
(.networks // {} | to_entries[] | select((.value.external == true) and (IN(.value.name // .key; $shared | splits(" +")) | not)) | "F\tnetwork \(.key)\texternal (not on the shared list)"),
(.secrets // {} | to_entries[] | select(.value.file) | "P\tsecret \(.key)\tfile\t\(.value.file)"),
(.configs // {} | to_entries[] | select(.value.file) | "P\tconfig \(.key)\tfile\t\(.value.file)"),
(keys[] | select(startswith("x-") | not) | fleet_off(["name", "networks", "services", "volumes"]) | "A\ttop level\t\(.)"),
(.services // {} | to_entries[] | .key as $s | .value | (
  (keys[] | fleet_off(["build", "cap_drop", "command", "depends_on", "entrypoint", "environment", "healthcheck", "image", "mem_limit", "memswap_limit", "networks", "ports", "profiles", "read_only", "restart", "security_opt", "stop_grace_period", "tmpfs", "user", "volumes", "working_dir"]) | "A\t\($s)\t\(.)"),
  (.build? // empty | keys[] | fleet_off(["args", "context", "dockerfile"]) | "A\t\($s)\tbuild.\(.)"),
  (.volumes[]? | keys[] | fleet_off(["bind", "read_only", "source", "target", "type", "volume"]) | "A\t\($s)\tvolumes.\(.)"),
  (.volumes[]? | .type | fleet_off(["bind", "volume"]) | "A\t\($s)\tvolumes.type \(.)"),
  empty)),
(.volumes // {} | to_entries[] | .key as $n | .value // {} | keys[] | fleet_off(["driver", "name"]) | "A\tvolume \($n)\t\(.)"),
(.networks // {} | to_entries[] | .key as $n | .value // {} | keys[] | fleet_off(["driver", "external", "ipam", "name"]) | "A\tnetwork \($n)\t\(.)"),
empty
'

deploy_compose_root_only() { [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = "${DEPLOY_ROOT_UID:-0}" ] && (( (8#$(stat -c %a "$1") & 8#022) == 0 )); }

# Root's list of extra bind sources outside ROOT, /etc/fleet/app-binds/<app>: exact paths, no prefixes.
deploy_compose_binds() { # root -> DEPLOY_COMPOSE_BINDS, or 1 with DEPLOY_COMPOSE_ERR
    local f line
    f="${DEPLOY_APP_BINDS_DIR:-/etc/fleet/app-binds}/$(basename -- "$1")"
    DEPLOY_COMPOSE_BINDS=()
    [ -e "$f" ] || [ -L "$f" ] || return 0
    { [ -f "$f" ] && deploy_compose_root_only "$f" && deploy_compose_root_only "$(dirname -- "$f")"; } || { DEPLOY_COMPOSE_ERR="$f is not a root-owned file in a root-owned directory that only root can write"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in ''|'#'*) continue ;; /*) ;; *) DEPLOY_COMPOSE_ERR="$f has a line that is not an absolute path"; return 1 ;; esac
        DEPLOY_COMPOSE_BINDS+=("$(realpath -m -- "$line")")
    done <"$f"
}

deploy_compose_bind_listed() { # path -> 0 when it is exactly a listed path and none the host needs kept
    local real b
    real=$(realpath -m -- "$1")
    case $real in /|/etc*|/root*|/proc*|/sys*|/dev*|/boot*|/usr*|/var/run*|/run*|/var/lib/docker*|/var/lib/fleet*|/home*|*docker.sock) return 1 ;; esac
    for b in "${DEPLOY_COMPOSE_BINDS[@]}"; do [ "$b" != "$real" ] || return 0; done
    return 1
}

deploy_compose_policy() { # root, config json, app -> 0, or 1 with DEPLOY_COMPOSE_ERR naming service and key
    local root=$1 app=${3:-} rules kind svc key path
    [[ $app =~ ^[a-z0-9-]+$ ]] || { DEPLOY_COMPOSE_ERR="the policy was given no app name"; return 1; }
    deploy_compose_binds "$root" || return 1
    rules=$(printf '%s' "$2" | jq -r --arg app "$app" --arg shared "$FLEET_COMPOSE_SHARED_NETWORKS" "$FLEET_COMPOSE_POLICY") || { DEPLOY_COMPOSE_ERR="jq could not read the compose config, so no compose call runs"; return 1; }
    while IFS=$'\t' read -r kind svc key path; do
        [ "$kind" != F ] || { DEPLOY_COMPOSE_ERR="compose $svc sets $key, which root's compose does not run (policy, backlog 320)"; return 1; }
        [ "$kind" != A ] || { DEPLOY_COMPOSE_ERR="compose $svc sets $key, which is not on root's compose list (policy, backlog 320)"; return 1; }
        [ "$kind" != P ] || [[ $path == /* && "$(realpath -m -- "$path")/" == "$root"/* ]] || { [ "$key" = volumes ] && deploy_compose_bind_listed "$path"; } || { DEPLOY_COMPOSE_ERR="compose $svc: $key reaches outside $root (policy, backlog 320)"; return 1; }
    done <<<"$rules"
}

deploy_compose_buildcheck() { # root, run dir, config json -> 0, or 1 with DEPLOY_COMPOSE_ERR
    local root=$1 bc=$2/buildcheck f rel ctx df
    { [ -d "$bc" ] && [ ! -L "$bc" ]; } || { DEPLOY_COMPOSE_ERR="$bc is missing: this deploy.sh was not exported by a fleet-deploy that checks the build context (packet 320). Deploy with: fleet-deploy <app> <PR#>"; return 1; }
    while IFS= read -r -d '' f; do
        rel=${f#"$bc"/}
        { [ -f "$root/$rel" ] && [ "$(realpath -e -- "$root/$rel" 2>/dev/null)" = "$root/$rel" ]; } || { DEPLOY_COMPOSE_ERR="$root/$rel is missing, not a plain file, or reached through a symlink, so the build context is not the merged one"; return 1; }
        cmp -s -- "$f" "$root/$rel" || { DEPLOY_COMPOSE_ERR="$root/$rel differs from the merged commit, so nothing is built"; return 1; }
    done < <(find -P "$bc" -type f -print0)
    while IFS= read -r -d '' f; do
        rel=${f#"$root"/}
        [ -f "$bc/$rel" ] || { DEPLOY_COMPOSE_ERR="$f is not in the merged commit (untracked, or a link), so nothing is built"; return 1; }
    done < <(find -P "$root/docker" ! -type d -print0 2>/dev/null)
    while IFS=$'\t' read -r ctx df; do
        [ -n "$ctx" ] || continue
        [[ $df == /* ]] || df=$ctx/$df
        [[ "$(realpath -m -- "$df")" == "$(realpath -m -- "$ctx")"/* ]] || { DEPLOY_COMPOSE_ERR="build.dockerfile $df is outside its context $ctx, so nothing is built"; return 1; }
        for f in "$df" "$df.dockerignore" "$ctx/.dockerignore"; do
            [ "$f" = "$df" ] || [ -e "$f" ] || [ -L "$f" ] || continue
            [ -f "$bc/${f#"$root"/}" ] || { DEPLOY_COMPOSE_ERR="$f is not in the merged commit, so nothing is built"; return 1; }
        done
    done < <(printf '%s' "$3" | jq -r '.services // {} | .[] | .build? // empty | select(.dockerfile_inline == null) | "\(.context)\t\(.dockerfile // "Dockerfile")"')
}

# The one root compose argv: run <root> <docker> <env file> <file>… -- <compose args>.
deploy_compose_exec() {
    local root docker env run f sub json files=() argv=()
    [ "${1:-}" = run ] || { printf 'REFUSED: compose.sh runs only as: compose.sh run <root> <docker> <env file> <file>… -- <args>\n' >&2; return 1; }
    root=${2:-} docker=${3:-} env=${4:-}
    shift 4 || return 1
    while [ $# -gt 0 ] && [ "$1" != -- ]; do files+=("$1"); shift; done
    [ "${1:-}" = -- ] || { printf 'REFUSED: compose.sh run has no -- before the compose arguments\n' >&2; return 1; }
    shift
    run=$(cd -P -- "$(dirname -- "$FLEET_COMPOSE_LIB")/../../.." && pwd -P)
    deploy_compose_pieces "$root" "$env" "$run" "${files[@]}" || { printf 'REFUSED: %s\n' "$DEPLOY_COMPOSE_ERR" >&2; return 1; }
    [[ $docker =~ $FLEET_COMPOSE_WORD ]] || { printf 'REFUSED: the docker command is not one plain word\n' >&2; return 1; }
    argv=(compose --project-directory "$root")
    argv+=(-p "$DEPLOY_COMPOSE_APP")
    for f in "${files[@]}"; do argv+=(-f "$run/compose/$f"); done
    argv+=(--env-file "$env")
    sub='' build=''
    for f in "$@"; do
        [ "$sub" != next ] || { sub=''; continue; }
        case $f in
            -[!-]*|--file|--file=*|--env-file|--env-file=*|--project-directory|--project-directory=*|--project-name|--project-name=*)
                [ -n "$sub" ] || { printf 'REFUSED: a caller names no compose file, env file, project directory or name: deploy_compose fixes them\n' >&2; return 1; } ;;
            --profile|--progress|--ansi|--parallel) [ -n "$sub" ] || sub=next ;;
            --build|--build=*) build=y ;;
            -*) ;;
            *) [ -n "$sub" ] || sub=$f ;;
        esac
    done
    case $sub/$build in
        build/*|up/*|create/*|run/y) deploy_compose_tracked "$root" || { printf 'REFUSED: %s\n' "$DEPLOY_COMPOSE_ERR" >&2; return 1; } ;;
    esac
    case $sub in
        watch) printf 'REFUSED: compose watch copies the app tree into running containers, so root does not run it\n' >&2; return 1 ;;
        build|up|run|create)
            json=$("$docker" "${argv[@]}" --profile '*' config --no-env-resolution --format json) || { printf 'REFUSED: compose config failed, so the policy and the build context were not checked\n' >&2; return 1; }
            deploy_compose_policy "$root" "$json" "$DEPLOY_COMPOSE_APP" || { printf 'REFUSED: %s\n' "$DEPLOY_COMPOSE_ERR" >&2; return 1; }
            deploy_compose_buildcheck "$root" "$run" "$json" || { printf 'REFUSED: %s\n' "$DEPLOY_COMPOSE_ERR" >&2; return 1; } ;;
    esac
    for f in "${!COMPOSE_@}"; do unset "$f"; done
    "$docker" "${argv[@]}" "$@"
}

# Before a build, an up, a create or a run --build, the tracked files as the app user sees them: an
# edit made after the fast-forward is not built (cards 363, 371). root -> 0, or 1 with DEPLOY_COMPOSE_ERR
deploy_compose_tracked() {
    local out rc=0
    out=$("${DEPLOY_GIT_AS:-git-as}" "$(deploy_compose_user "$1")" -C "$1" --no-optional-locks status --porcelain --untracked-files=no) || rc=$?
    [ "$rc" = 0 ] || { DEPLOY_COMPOSE_ERR="git status exited $rc in $1, so the tracked files are not known to be the merge and nothing is built over them"; return 1; }
    [ -z "$out" ] || { DEPLOY_COMPOSE_ERR="tracked files in $1 are modified since the fast-forward, so nothing is built over them: ${out//$'\n'/; }"; return 1; }
}

deploy_compose_user() { printf '%s' "${DEPLOY_APP_USER:-$(basename -- "$1")}"; }

deploy_compose_pieces() { # root, env file, run dir, file… -> 0, or 1 with DEPLOY_COMPOSE_ERR
    local root=$1 env=$2 run=$3 f d
    shift 3
    DEPLOY_COMPOSE_ERR=''
    [[ $root =~ $FLEET_COMPOSE_WORD && $root == /* && -d $root && ! -L $root ]] || { DEPLOY_COMPOSE_ERR="ROOT '$root' is not a plain absolute directory"; return 1; }
    [[ $env =~ $FLEET_COMPOSE_WORD ]] || { DEPLOY_COMPOSE_ERR="the env file path '$env' is not one plain word"; return 1; }
    { [ -d "$run/compose" ] && [ ! -L "$run/compose" ]; } || { DEPLOY_COMPOSE_ERR="$run/compose is missing: this deploy.sh was not exported by a fleet-deploy that carries the compose files (packet 320). Deploy with: fleet-deploy <app> <PR#>"; return 1; }
    { [ -f "$run/export-sha" ] && [ ! -L "$run/export-sha" ]; } || { DEPLOY_COMPOSE_ERR="$run/export-sha is missing: this deploy.sh was not exported by fleet-deploy (packet 320). Deploy with: fleet-deploy <app> <PR#>"; return 1; }
    [ $# -gt 0 ] || { DEPLOY_COMPOSE_ERR="no compose file is named"; return 1; }
    for f in "$@"; do
        [[ $f =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[.]ya?ml$ ]] || { DEPLOY_COMPOSE_ERR="'$f' is not a compose file name"; return 1; }
        { [ -f "$run/compose/$f" ] && [ ! -L "$run/compose/$f" ]; } || { DEPLOY_COMPOSE_ERR="$run/compose/$f is missing: fleet-deploy exported no $f at the merge commit"; return 1; }
    done
    d=$(dirname -- "$env")
    [ "$(basename -- "$env")" = "$(basename -- "$root").env" ] || { DEPLOY_COMPOSE_ERR="$env is not named after $root"; return 1; }
    { [ -d "$d" ] && [ ! -L "$d" ] && [ "$(stat -c %u:%a "$d")" = "${DEPLOY_ROOT_UID:-0}:700" ] && [ -f "$env" ] && [ ! -L "$env" ] && [ "$(stat -c %u:%a "$env")" = "${DEPLOY_ROOT_UID:-0}:600" ]; } || { DEPLOY_COMPOSE_ERR="$env is not a root 600 file in a root 700 directory: fleet-app-env-seed writes it, then deploy with: fleet-deploy <app> <PR#>"; return 1; }
    DEPLOY_COMPOSE_APP=${FLEET_DEPLOY_REPO:-}
    [[ $DEPLOY_COMPOSE_APP =~ ^[A-Za-z0-9-]+/[a-z0-9-]+$ ]] || { DEPLOY_COMPOSE_ERR="FLEET_DEPLOY_REPO '${FLEET_DEPLOY_REPO:-}' names no app: root names it. Deploy with: fleet-deploy <app> <PR#>"; return 1; }
    DEPLOY_COMPOSE_APP=${DEPLOY_COMPOSE_APP#*/}
    [ "$DEPLOY_COMPOSE_APP" = "$(basename -- "$root")" ] || { DEPLOY_COMPOSE_ERR="FLEET_DEPLOY_REPO names $DEPLOY_COMPOSE_APP, not $(basename -- "$root")"; return 1; }
}

# deploy_compose_init <merge sha>, before the first compose call; ROOT set, DEPLOY_COMPOSE_FILES optional.
deploy_compose_init() {
    local root env run json exported
    root=$(cd -P -- "${ROOT:-}" 2>/dev/null && pwd -P) || refuse "ROOT '${ROOT:-}' is not a directory."
    env="${DEPLOY_APP_ENV_DIR:-/etc/fleet/app-env}/$(basename -- "$root").env"
    run=$(cd -P -- "$(dirname -- "$FLEET_COMPOSE_LIB")/../../.." && pwd -P)
    read -ra DEPLOY_COMPOSE_FILE_LIST <<<"${DEPLOY_COMPOSE_FILES:-docker-compose.yml}"
    deploy_compose_pieces "$root" "$env" "$run" "${DEPLOY_COMPOSE_FILE_LIST[@]}" || refuse "$DEPLOY_COMPOSE_ERR"
    exported=$(head -c 41 "$run/export-sha" | tr -d '\n')
    [ "$exported" = "${1:-}" ] || refuse "the compose files were exported at ${exported:-nothing}, not the merge ${1:-(none)} this deploy lands."
    [[ ${DOCKER:-docker} =~ $FLEET_COMPOSE_WORD ]] || refuse "DOCKER '${DOCKER:-}' is not one plain word."
    DEPLOY_COMPOSE="bash $FLEET_COMPOSE_LIB run $root ${DOCKER:-docker} $env ${DEPLOY_COMPOSE_FILE_LIST[*]} --"
    json=$($DEPLOY_COMPOSE --profile '*' config --no-env-resolution --format json) || refuse "compose config failed, so the policy could not be checked."
    deploy_compose_policy "$root" "$json" "$DEPLOY_COMPOSE_APP" || refuse "$DEPLOY_COMPOSE_ERR"
    say "COMPOSE root's files: ${DEPLOY_COMPOSE_FILE_LIST[*]} at ${exported:0:12}, env $env, policy clean"
}

deploy_compose() { [ -n "${DEPLOY_COMPOSE:-}" ] || refuse "deploy_compose_init has not run."; $DEPLOY_COMPOSE "$@"; }

# A value from the app's .env, read as the app user (root never follows the app user's link);
# a failed sudo returns 1 on stderr, never an empty value.
deploy_app_env_value() {
    local user dotenv
    user=$(deploy_compose_user "$ROOT")
    [[ ${1:-} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || refuse "'${1:-}' is not an env key."
    dotenv=$(sudo -n -u "$user" -- cat -- "$ROOT/.env" 2>/dev/null) || { printf 'REFUSED: %s/.env could not be read as %s (sudo), so no value is guessed\n' "$ROOT" "$user" >&2; return 1; }
    printf '%s\n' "$dotenv" | grep -m1 "^$1=" | cut -d= -f2-
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then deploy_compose_exec "$@"; exit; fi
