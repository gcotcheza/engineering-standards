#!/usr/bin/env bash
# Guards scripts/lib/deploy/compose.sh against a stub docker. test.sh runs it as root; the red proofs run it
# as nobody, with DEPLOY_ROOT_UID standing in for root and the root-only cases skipped by name.
#   DEPLOY_LIB_DIR=<copy> TMPDIR=<dir> compose-test.sh
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/compose-test.XXXXXXXX")" || { printf 'cannot make a work directory\n' >&2; exit 1; }
trap 'rm -rf "${WORK}"' EXIT
DEVNULL_BEFORE="$(stat -c '%a %u %g %F' /dev/null)"
C_UID=''
[ "$(id -u)" = 0 ] || C_UID="$(id -u)"

# A run directory shaped like fleet-deploy's export, a stub docker that records its argv and
# answers `config` with the case's JSON, and an app tree root never reads a compose file from.
COMPOSE_SHA=1111111111111111111111111111111111111111
cfx() {
    CF="${WORK}/compose-$1"
    CRUN="${CF}/${C_RUNDIR:-run}" CROOT="${CF}/www/demo" CENV="${CF}/app-env/demo.env" CBINDS="${CF}/app-binds/demo"
    mkdir -p "${CRUN}/scripts/lib/deploy" "${CRUN}/compose" "${CRUN}/buildcheck/docker/app" "${CROOT}/docker/app" "${CF}/app-env" "${CF}/app-binds" "${CF}/bin"
    chmod 755 "${CF}/app-binds"
    cp "${LIB_DIR}/compose.sh" "${CRUN}/scripts/lib/deploy/"
    printf 'services: {}\n' >"${CRUN}/compose/docker-compose.yml"
    printf 'FROM scratch\n' >"${CRUN}/buildcheck/docker/app/Dockerfile"
    cp "${CRUN}/buildcheck/docker/app/Dockerfile" "${CROOT}/docker/app/Dockerfile"
    printf 'services:\n  app:\n    volumes: ["/:/host"]\n' >"${CROOT}/docker-compose.yml"
    printf 'COMPOSE_FILE=docker-compose.yml\n' >"${CROOT}/.env"
    printf '%s\n' "${COMPOSE_SHA}" >"${CRUN}/export-sha"
    chmod 700 "${CF}/app-env"
    printf 'DB_PASSWORD=stub\n' >"${CENV}"
    chmod 600 "${CENV}"
    jq -n --arg r "${CROOT}" '{name: "demo", services: {app: {image: "x", build: {context: "\($r)/docker/app", dockerfile: "Dockerfile"},
        volumes: [{type: "bind", source: "\($r)/storage", target: "/s"}, {type: "volume", source: "data", target: "/d"}]}},
        volumes: {data: {}}}' >"${CF}/config.json"
    cat >"${CF}/bin/docker" <<'SH'
#!/bin/sh
d=$(dirname "$0")
printf '%s\n' "$*" >>"$d/argv"
env | grep '^COMPOSE_' >>"$d/env"
case " $* " in *' config '*) cat "$d/../config.json" ;; esac
exit 0
SH
    chmod 0755 "${CF}/bin/docker"
    # A git-as whose status lists bin/tracked and exits bin/git-rc (default 0); every call goes to bin/argv.
    cat >"${CF}/bin/git-as" <<'SH'
#!/bin/sh
d=$(dirname "$0")
printf 'git-as %s\n' "$*" >>"$d/argv"
cat "$d/tracked" 2>/dev/null
exit "$(cat "$d/git-rc" 2>/dev/null || echo 0)"
SH
    chmod 0755 "${CF}/bin/git-as"
    cat >"${CRUN}/scripts/deploy.sh" <<'SH'
#!/usr/bin/env bash
set -u
D="$(cd -- "$(dirname -- "$0")" && pwd)"
say() { printf '%s\n' "$*"; }
refuse() { say "REFUSED: $*"; exit 1; }
. "${D}/lib/deploy/compose.sh"
export DEPLOY_GIT_AS="$(dirname -- "$C_DOCKER")/git-as"
[ -z "${C_UID}" ] || export DEPLOY_ROOT_UID="${C_UID}"
ROOT=$C_ROOT DOCKER=$C_DOCKER DEPLOY_APP_ENV_DIR=$C_ENV_DIR
export DEPLOY_APP_BINDS_DIR=$C_BINDS_DIR
eval "$C_CALLS"
SH
}
cjson() { local t; t=$(jq --arg r "${CROOT}" "$1" "${CF}/config.json") && printf '%s\n' "$t" >"${CF}/config.json"; }
crun() {
    # shellcheck disable=SC2086
    OUT="$(env -i PATH=/usr/bin:/bin C_ROOT="${CROOT}" C_DOCKER="${CF}/bin/docker" C_ENV_DIR="${CF}/app-env" C_BINDS_DIR="${CF}/app-binds" C_UID="${C_UID}" \
        FLEET_DEPLOY_REPO=gcotcheza/demo ${C_EXTRA:-} C_CALLS="$1" bash "${CRUN}/scripts/deploy.sh" 2>&1)"
    RC=$?
    ARGV="$(cat "${CF}/bin/argv" 2>/dev/null)"
    C_EXTRA=''
}
INIT="deploy_compose_init ${COMPOSE_SHA}"

cfx clean
crun "${INIT}; deploy_compose up -d; deploy_compose exec -T app true"
contains 'compose: a clean export passes the policy' "${OUT}" "COMPOSE root's files: docker-compose.yml at ${COMPOSE_SHA:0:12}, env ${CENV}, policy clean"
equals 'compose: and exits 0' "${RC}" 0
contains 'compose: every call names the exported file, the project directory and root'"'"'s env file' "${ARGV}" \
    "compose --project-directory ${CROOT} -p demo -f ${CRUN}/compose/docker-compose.yml --env-file ${CENV} up -d"
equals 'compose: the policy, the first call, reads every profile'"'"'s services, without resolving env files' "$(head -1 "${CF}/bin/argv")" \
    "compose --project-directory ${CROOT} -p demo -f ${CRUN}/compose/docker-compose.yml --env-file ${CENV} --profile * config --no-env-resolution --format json"
absent 'compose: never the tree'"'"'s docker-compose.yml' "${ARGV}" "${CROOT}/docker-compose.yml"
absent 'compose: never the tree'"'"'s .env' "${ARGV}" "${CROOT}/.env"
equals 'compose: up checks the build context, exec does not (config runs twice)' "$(grep -c ' config ' "${CF}/bin/argv")" 2
equals 'compose: and the build check reads every profile too' "$(grep -c -- "--profile \* config" "${CF}/bin/argv")" 2

cfx env-dropped
C_EXTRA='COMPOSE_FILE=/tmp/evil.yml COMPOSE_PROFILES=evil'
crun "${INIT}; deploy_compose ps"
equals 'compose: no COMPOSE_* from the caller reaches docker' "$(cat "${CF}/bin/env" 2>/dev/null)" ''

cfx caller-file
crun "${INIT}; deploy_compose -f ${CROOT}/docker-compose.yml up -d"
contains 'compose: a caller'"'"'s own -f is refused' "${OUT}" 'REFUSED: a caller names no compose file, env file, project directory or name'
absent 'compose: and that file is never handed to docker' "${ARGV}" "${CROOT}/docker-compose.yml"
# Card 372: every spelling compose parses for its file, name, env file and directory, joined or not.
for a in -f/tmp/evil.yml -f=/tmp/evil.yml --file=/tmp/evil.yml '-pevil' '-p=evil' '--project-name=evil' \
    --env-file=/tmp/x.env --project-directory=/tmp '-p evil' '--file /tmp/evil.yml' '--profile x -f/tmp/evil.yml' \
    '--profile -x -pevil'; do
    n=$((${n:-0} + 1)); cfx "caller-joined-${n}"
    crun "${INIT}; deploy_compose ${a} up -d"
    contains "compose: a caller's own ${a} is refused" "${OUT}" 'REFUSED: a caller names no compose file, env file, project directory or name'
    absent "compose: and docker never runs up (${a})" "${ARGV}" ' up -d'
done
cfx caller-sub-flags
crun "${INIT}; deploy_compose --profile web logs -f app; deploy_compose rm -f -s app; deploy_compose --progress=plain up -d"
equals 'compose: -f after the command is the command'"'"'s own (logs, rm), and --x=y before it is no short option' "${RC}" 0
contains 'compose: so docker runs them' "${ARGV}" "--profile web logs -f app"

cfx no-init
crun 'deploy_compose ps'
contains 'compose: deploy_compose before init refuses' "${OUT}" 'REFUSED: deploy_compose_init has not run.'

# B1: a missing piece refuses and names fleet-deploy (an export from the 317 fleet-deploy has none).
cfx no-compose-dir; rm -rf "${CRUN}/compose"
crun "${INIT}"
contains 'pieces: no compose/ beside scripts/ refuses' "${OUT}" "REFUSED: ${CRUN}/compose is missing: this deploy.sh was not exported by a fleet-deploy that carries the compose files (packet 320). Deploy with: fleet-deploy <app> <PR#>"
equals 'pieces: and no docker call is made' "${ARGV}" ''
cfx no-export-sha; rm -f "${CRUN}/export-sha"
crun "${INIT}"
contains 'pieces: no export-sha refuses' "${OUT}" "REFUSED: ${CRUN}/export-sha is missing"
cfx no-named-file
crun 'DEPLOY_COMPOSE_FILES=docker-compose.prod.yml; '"${INIT}"
contains 'pieces: a named file not exported refuses' "${OUT}" "REFUSED: ${CRUN}/compose/docker-compose.prod.yml is missing"
cfx odd-name
crun 'DEPLOY_COMPOSE_FILES=../x.yml; '"${INIT}"
contains 'pieces: a file name with a path refuses' "${OUT}" "REFUSED: '../x.yml' is not a compose file name"
cfx no-env; rm -f "${CENV}"
crun "${INIT}"
contains 'pieces: no root env file refuses' "${OUT}" "REFUSED: ${CENV} is not a root 600 file in a root 700 directory"
cfx env-644; chmod 644 "${CENV}"
crun "${INIT}"
contains 'pieces: a 644 env file refuses' "${OUT}" "REFUSED: ${CENV} is not a root 600 file in a root 700 directory"
cfx env-link; mv "${CENV}" "${CF}/real.env"; ln -s "${CF}/real.env" "${CENV}"
crun "${INIT}"
contains 'pieces: an env file that is a symlink refuses' "${OUT}" "REFUSED: ${CENV} is not a root 600 file in a root 700 directory"
cfx env-dir-755; chmod 755 "${CF}/app-env"
crun "${INIT}"
contains 'pieces: an env dir others can enter refuses' "${OUT}" "REFUSED: ${CENV} is not a root 600 file in a root 700 directory"
if root_only_case 'pieces: an env file the app user owns refuses'; then
    cfx env-nobody; chown nobody "${CENV}"
    crun "${INIT}"
    contains 'pieces: an env file the app user owns refuses' "${OUT}" "REFUSED: ${CENV} is not a root 600 file in a root 700 directory"
fi
cfx sha-moved
crun "deploy_compose_init 2222222222222222222222222222222222222222"
contains 'pieces: compose files exported at another sha refuse' "${OUT}" "REFUSED: the compose files were exported at ${COMPOSE_SHA}, not the merge 2222222222222222222222222222222222222222 this deploy lands."
cfx run-mode-direct; rm -rf "${CRUN}/compose"
OUT="$(bash "${CRUN}/scripts/lib/deploy/compose.sh" run "${CROOT}" "${CF}/bin/docker" "${CENV}" docker-compose.yml -- up -d 2>&1)"
contains 'pieces: run mode checks the pieces itself' "${OUT}" "REFUSED: ${CRUN}/compose is missing"
equals 'pieces: and calls no docker' "$(cat "${CF}/bin/argv" 2>/dev/null)" ''

# B2: one case per refusal; the message names service and key, never a value.
policy_case() { # key, jq edit, expected sentence; "sets <key>," means its F rule, not the allow-list
    local want=$3
    [[ $want != *, ]] || want="$want which root's compose does not run"
    cfx "policy-$1"
    cjson "$2"
    crun "${INIT}; deploy_compose up -d"
    contains "policy $1: refused" "${OUT}" "REFUSED: ${want}"
    absent "policy $1: nothing runs" "${ARGV}" ' up -d'
}
policy_case privileged '.services.app.privileged = true' 'compose app sets privileged, which root'"'"'s compose does not run (policy, backlog 320)'
policy_case pid '.services.app.pid = "host"' 'compose app sets pid,'
policy_case ipc '.services.app.ipc = "host"' 'compose app sets ipc,'
policy_case network_mode '.services.app.network_mode = "host"' 'compose app sets network_mode,'
policy_case cap_add '.services.app.cap_add = ["SYS_ADMIN"]' 'compose app sets cap_add,'
policy_case devices '.services.app.devices = [{source: "/dev/kmsg", target: "/dev/kmsg"}]' 'compose app sets devices,'
policy_case security_opt '.services.app.security_opt = ["label:disable"]' 'compose app sets security_opt,'
policy_case docker_sock '.services.app.volumes += [{type: "bind", source: "/var/run/docker.sock", target: "/var/run/docker.sock"}]' 'compose app sets volumes (docker.sock),'
policy_case build_secrets '.services.app.build.secrets = [{source: "s"}]' 'compose app sets build.secrets,'
policy_case build_ssh '.services.app.build.ssh = ["default"]' 'compose app sets build.ssh,'
policy_case build_contexts '.services.app.build.additional_contexts = {extra: "/etc"}' 'compose app sets build.additional_contexts,'
policy_case bind_outside '.services.app.volumes[0].source = "/etc"' 'compose app: volumes reaches outside'
policy_case env_file_outside '.services.app.env_file = [{path: "/etc/shadow"}]' 'compose app: env_file reaches outside'
policy_case context_outside '.services.app.build.context = "/"' 'compose app: build.context reaches outside'
policy_case driver_opts '.volumes.data.driver_opts = {type: "none", o: "bind", device: "/etc"}' 'compose volume data sets driver_opts,'
policy_case secret_file '.secrets = {s: {file: "/etc/hostname"}}' 'compose secret s: file reaches outside'
policy_case config_file '.configs = {c: {file: "/etc/hostname"}}' 'compose config c: file reaches outside'
cfx policy-bind-link; ln -s /etc "${CROOT}/storage"
crun "${INIT}"
contains 'policy bind_link: a bind inside ROOT that is a symlink out is refused' "${OUT}" 'REFUSED: compose app: volumes reaches outside'
cfx policy-relative; cjson '.services.app.volumes[0].source = "storage"'
crun "${INIT}"
contains 'policy relative: a path that is not absolute is refused' "${OUT}" 'REFUSED: compose app: volumes reaches outside'
cfx policy-jq; printf 'not json\n' >"${CF}/config.json"
crun "${INIT}"
contains 'policy jq: config jq cannot read refuses' "${OUT}" 'REFUSED: jq could not read the compose config'

# B3: the build context is the merged one, checked right before anything that can build.
build_case() { # name, setup, expected sentence
    cfx "build-$1"
    eval "$2"
    crun "${INIT}; deploy_compose build app"
    local want=${3//@ROOT@/${CROOT}}
    contains "build $1: refused" "${OUT}" "REFUSED: ${want//@RUN@/${CRUN}}"
    absent "build $1: nothing is built" "${ARGV}" ' build app'
}
cfx build-clean
crun "${INIT}; deploy_compose build app"
contains 'build clean: a clean context builds' "${ARGV}" "--env-file ${CENV} build app"
build_case differs 'printf "RUN id\n" >>"${CROOT}/docker/app/Dockerfile"' "@ROOT@/docker/app/Dockerfile differs from the merged commit, so nothing is built"
build_case missing 'printf x >"${CRUN}/buildcheck/docker/app/entry.sh"' "@ROOT@/docker/app/entry.sh is missing, not a plain file, or reached through a symlink"
build_case link 'mv "${CROOT}/docker/app/Dockerfile" "${CF}/Df"; ln -s "${CF}/Df" "${CROOT}/docker/app/Dockerfile"' "@ROOT@/docker/app/Dockerfile is missing, not a plain file, or reached through a symlink"
build_case untracked 'printf x >"${CROOT}/docker/app/extra"' "@ROOT@/docker/app/extra is not in the merged commit (untracked, or a link), so nothing is built"
build_case ctx_dockerfile 'mkdir -p "${CROOT}/api"; printf "FROM x\n" >"${CROOT}/api/Dockerfile"; cjson ".services.app.build.context = \"\(\$r)/api\""' "@ROOT@/api/Dockerfile is not in the merged commit, so nothing is built"
build_case ctx_dockerignore 'mkdir -p "${CROOT}/api" "${CRUN}/buildcheck/api"; printf "FROM x\n" | tee "${CROOT}/api/Dockerfile" >"${CRUN}/buildcheck/api/Dockerfile"; printf "*\n" >"${CROOT}/api/.dockerignore"; cjson ".services.app.build.context = \"\(\$r)/api\""' "@ROOT@/api/.dockerignore is not in the merged commit, so nothing is built"
build_case no_buildcheck 'rm -rf "${CRUN}/buildcheck"' "@RUN@/buildcheck is missing"
cfx build-up-dirty; printf 'RUN id\n' >>"${CROOT}/docker/app/Dockerfile"
crun "${INIT}; deploy_compose --profile build up -d"
contains 'build up: up (after a --profile) checks the context too' "${OUT}" "REFUSED: ${CROOT}/docker/app/Dockerfile differs"

# Card 363: a build or an up re-reads the tracked files as the app user inside compose.sh run, so
# every route to it does: deploy_compose, and $DEPLOY_COMPOSE in a job's own bash -c.
cfx tracked-clean
STATUS="-C ${CROOT} --no-optional-locks status --porcelain --untracked-files=no"
crun "${INIT}; deploy_compose build app; deploy_compose up -d; deploy_compose create; deploy_compose ps; deploy_compose exec -T app true"
equals 'tracked: build, up and create each re-read the tracked files as the app user, ps and exec do not' \
    "$(grep -cxF -- "git-as demo ${STATUS}" <<<"${ARGV}")" 3
contains 'tracked: the check comes before the build' "${ARGV}" "git-as demo ${STATUS}"$'\ncompose --project-directory '"${CROOT}"
cfx tracked-edited
crun "${INIT}; printf ' M app/Models/User.php\n' >${CF}/bin/tracked; deploy_compose --profile web up -d"
contains 'tracked: a tracked file edited between the merge and the up is refused' "${OUT}" \
    "REFUSED: tracked files in ${CROOT} are modified since the fast-forward, so nothing is built over them:  M app/Models/User.php"
absent 'tracked: and compose never runs up' "${ARGV}" ' up -d'
cfx tracked-job
crun "${INIT}; printf ' M app/Models/User.php\n' >${CF}/bin/tracked; COMPOSE=\$DEPLOY_COMPOSE; job=\"\$COMPOSE build app; \$COMPOSE up -d\"; bash -c \"\$job\""
equals 'tracked: $DEPLOY_COMPOSE in a bash -c job refuses the build and the up' \
    "$(grep -c "^REFUSED: tracked files in ${CROOT} are modified since the fast-forward" <<<"${OUT}")" 2
absent 'tracked: and compose never builds (job)' "${ARGV}" ' build app'
absent 'tracked: and compose never runs up (job)' "${ARGV}" ' up -d'
cfx tracked-git-fails
crun "${INIT}; echo 128 >${CF}/bin/git-rc; deploy_compose up -d"
contains 'tracked: a git status that fails is refused, never read as clean' "${OUT}" \
    "REFUSED: git status exited 128 in ${CROOT}, so the tracked files are not known to be the merge and nothing is built over them"
absent 'tracked: and compose never runs up (git failed)' "${ARGV}" ' up -d'
# Card 371: run --build builds, so it re-reads the tracked files like build and up; a plain run does not.
cfx tracked-run-build
crun "${INIT}; printf ' M app/Models/User.php\n' >${CF}/bin/tracked; deploy_compose run --build --rm app true"
contains 'tracked: run --build over a tracked file edited after the merge is refused' "${OUT}" \
    "REFUSED: tracked files in ${CROOT} are modified since the fast-forward, so nothing is built over them:  M app/Models/User.php"
absent 'tracked: and compose never runs run --build' "${ARGV}" ' run --build'
cfx tracked-run-plain
crun "${INIT}; printf ' M app/Models/User.php\n' >${CF}/bin/tracked; deploy_compose run --rm app true; deploy_compose --profile web run --rm app true"
equals 'tracked: a plain run is not re-read, and runs over an edited tree' "$(grep -c '^git-as ' <<<"${ARGV}")" 0
equals 'tracked: and both run' "$(grep -c ' run --rm app true$' <<<"${ARGV}")" 2
cfx tracked-run-clean
crun "${INIT}; deploy_compose run --build --rm app true"
equals 'tracked: a clean run --build passes after one re-read' "$(grep -cxF -- "git-as demo -C ${CROOT} --no-optional-locks status --porcelain --untracked-files=no" <<<"${ARGV}")" 1
contains 'tracked: and it runs' "${ARGV}" ' run --build --rm app true'

# B4: a value from the app's .env is read as the app user, never through root's eyes.
if root_only_case 'env value: read as the app user (sudo)'; then
    cfx env-value; chown -R nobody "${CF}/www"; chmod 711 "${WORK}" "${CF}"
    printf 'APP_URL=https://demo.invalid\n' >"${CROOT}/.env"; chown nobody "${CROOT}/.env"
    crun 'printf "VAL=%s\n" "$(DEPLOY_APP_USER=nobody deploy_app_env_value APP_URL)"'
    contains 'env value: read as the app user' "${OUT}" 'VAL=https://demo.invalid'
    rm -f "${CROOT}/.env"; printf 'APP_URL=root-only\n' >"${CF}/root-only"; chmod 600 "${CF}/root-only"; ln -s "${CF}/root-only" "${CROOT}/.env"
    crun 'printf "VAL=%s\n" "$(DEPLOY_APP_USER=nobody deploy_app_env_value APP_URL)"'
    contains 'env value: a link to a root-only file refuses' "${OUT}" "REFUSED: ${CROOT}/.env could not be read as nobody (sudo)"
    absent 'env value: and never its content' "${OUT}" 'root-only'
fi

# Fix round 1: security_opt allows only no-new-privileges; host uts/userns/cgroup; root's bind list.
for form in 'no-new-privileges:true' 'no-new-privileges=true' 'no-new-privileges'; do
    cfx "secopt-ok-${form//[:=]/-}"; cjson ".services.app.security_opt = [\"${form}\"]"
    crun "${INIT}"
    contains "policy security_opt allows ${form}" "${OUT}" 'policy clean'
done
policy_case secopt_seccomp '.services.app.security_opt = ["seccomp:unconfined"]' 'compose app sets security_opt,'
policy_case secopt_apparmor '.services.app.security_opt = ["apparmor=unconfined"]' 'compose app sets security_opt,'
policy_case secopt_mixed '.services.app.security_opt = ["no-new-privileges:true", "label:disable"]' 'compose app sets security_opt,'
policy_case uts '.services.app.uts = "host"' 'compose app sets uts,'
policy_case userns_mode '.services.app.userns_mode = "host"' 'compose app sets userns_mode,'
policy_case cgroup '.services.app.cgroup = "host"' 'compose app sets cgroup,'

bind_case() { # name, list content, bind source, expect: clean or a refusal sentence
    cfx "binds-$1"
    mkdir -p "${CF}/audio/sub"
    printf '%s' "${2//@CF@/${CF}}" >"${CBINDS}"
    cjson ".services.app.volumes += [{type: \"bind\", source: \"${3//@CF@/${CF}}\", target: \"/a\"}]"
    crun "${INIT}"
    if [ "$4" = clean ]; then contains "binds $1: passes" "${OUT}" 'policy clean'
    else contains "binds $1: refused" "${OUT}" "REFUSED: ${4//@CF@/${CF}}"; fi
}
bind_case listed $'# audio\n\n@CF@/audio\n' '@CF@/audio' clean
bind_case unlisted $'@CF@/audio\n' '@CF@/other' 'compose app: volumes reaches outside'
bind_case prefix $'@CF@/audio\n' '@CF@/audio/sub' 'compose app: volumes reaches outside'
bind_case hard $'/var/lib/fleet/x\n' '/var/lib/fleet/x' 'compose app: volumes reaches outside'
bind_case relative $'audio\n' '@CF@/audio' '@CF@/app-binds/demo has a line that is not an absolute path'
cfx binds-link; mkdir -p "${CF}/audio"; ln -s "${CF}/audio" "${CF}/audio-link"; printf '%s\n' "${CF}/audio-link" >"${CBINDS}"
cjson ".services.app.volumes += [{type: \"bind\", source: \"${CF}/audio\", target: \"/a\"}]"
crun "${INIT}"
contains 'binds link: a listed symlink is compared by its real path' "${OUT}" 'policy clean'
cfx binds-writable; printf '%s\n' "${CF}/audio" >"${CBINDS}"; chmod 664 "${CBINDS}"
cjson ".services.app.volumes += [{type: \"bind\", source: \"${CF}/audio\", target: \"/a\"}]"
crun "${INIT}"
contains 'binds writable: a group-writable list refuses' "${OUT}" "REFUSED: ${CBINDS} is not a root-owned file in a root-owned directory that only root can write"
cfx binds-dir-writable; printf '%s\n' "${CF}/audio" >"${CBINDS}"; chmod 775 "${CF}/app-binds"
crun "${INIT}"
contains 'binds dir writable: a group-writable list directory refuses' "${OUT}" "REFUSED: ${CBINDS} is not a root-owned file"
cfx binds-not-volumes; printf '%s\n' "${CF}/audio" >"${CBINDS}"; cjson ".services.app.env_file = [{path: \"${CF}/audio\"}]"
crun "${INIT}"
contains 'binds not-volumes: the list frees binds only, not env_file' "${OUT}" 'REFUSED: compose app: env_file reaches outside'

# Fix round 2: more host escapes, watch, the dockerfile's place, the policy again at exec, the seven argv guards.
policy_case device_cgroup_rules '.services.app.device_cgroup_rules = ["c 1:3 mr"]' 'compose app sets device_cgroup_rules,'
policy_case net_container '.services.app.network_mode = "container:abc"' 'compose app sets network_mode (container:),'
policy_case pid_container '.services.app.pid = "container:abc"' 'compose app sets pid (container:),'
policy_case ipc_container '.services.app.ipc = "container:abc"' 'compose app sets ipc (container:),'
policy_case volumes_from '.services.app.volumes_from = ["container:abc"]' 'compose app sets volumes_from (container:),'
policy_case provider '.services.app.provider = {type: "model"}' 'compose app sets provider,'
policy_case build_privileged '.services.app.build.privileged = true' 'compose app sets build.privileged,'
policy_case build_entitlements '.services.app.build.entitlements = ["network.host"]' 'compose app sets build.entitlements,'
policy_case build_network '.services.app.build.network = "host"' 'compose app sets build.network,'
policy_case volume_external '.volumes.data.external = true' 'compose volume data sets external,'
policy_case network_driver_host '.networks = {n: {driver: "host"}}' 'compose network n sets driver host,'
policy_case network_external_host '.networks = {n: {external: true, name: "host"}}' 'compose network n sets external host,'
cfx policy-listed-forms; cjson '.networks = {"whisper-net": {external: true, name: "whisper-net"}, m: {driver: "bridge", ipam: {}}} | .volumes.data.driver = "local" | ."x-common" = {a: 1}'
crun "${INIT}"
contains 'policy listed forms: the shared external whisper-net, bridge, an empty ipam, a local volume and an x- key pass' "${OUT}" 'policy clean'
cfx watch
crun "${INIT}; deploy_compose watch"
contains 'compose: watch is refused' "${OUT}" 'REFUSED: compose watch copies the app tree into running containers, so root does not run it'
absent 'compose: and never reaches docker' "${ARGV}" ' watch'
build_case dockerfile_outside 'printf "FROM x\n" | tee "${CROOT}/Dockerfile" >"${CRUN}/buildcheck/Dockerfile"; cjson ".services.app.build.dockerfile = \"../../Dockerfile\""' "build.dockerfile @ROOT@/docker/app/../../Dockerfile is outside its context @ROOT@/docker/app, so nothing is built"
cfx policy-swap
crun "${INIT}; ln -s /etc ${CROOT}/storage; deploy_compose up -d"
contains 'policy swap: init passed before the swap' "${OUT}" 'policy clean'
contains 'policy swap: a bind swapped to a symlink out after init is refused at up' "${OUT}" 'REFUSED: compose app: volumes reaches outside'
absent 'policy swap: and nothing runs' "${ARGV}" ' up -d'
cfx binds-up; mkdir -p "${CF}/audio"; printf '%s\n' "${CF}/audio" >"${CBINDS}"
cjson ".services.app.volumes += [{type: \"bind\", source: \"${CF}/audio\", target: \"/a\"}]"
crun "${INIT}; deploy_compose up -d"
contains 'binds up: the policy at up reads the same list' "${ARGV}" "--env-file ${CENV} up -d"

drun() { # direct run mode, as a job's text calls it
    OUT="$(env -i PATH=/usr/bin:/bin FLEET_DEPLOY_REPO=gcotcheza/demo ${C_UID:+DEPLOY_ROOT_UID=${C_UID}} bash "${CRUN}/scripts/lib/deploy/compose.sh" "$@" 2>&1)"
    ARGV="$(cat "${CF}/bin/argv" 2>/dev/null)"
}
cfx direct-ok
drun run "${CROOT}" "${CF}/bin/docker" "${CENV}" docker-compose.yml -- ps
contains 'direct: a well-formed run reaches docker' "${ARGV}" "--env-file ${CENV} ps"
cfx direct-argnum
drun walk "${CROOT}" "${CF}/bin/docker" "${CENV}" docker-compose.yml -- ps
contains 'direct: a first word other than run is refused' "${OUT}" 'REFUSED: compose.sh runs only as:'
equals 'direct: and calls no docker (run word)' "${ARGV}" ''
cfx direct-dashdash
drun run "${CROOT}" "${CF}/bin/docker" "${CENV}" docker-compose.yml ps
contains 'direct: no -- before the compose arguments is refused' "${OUT}" 'REFUSED: compose.sh run has no -- before the compose arguments'
cfx direct-docker-word; cp "${CF}/bin/docker" "${CF}/bin/dock er"
drun run "${CROOT}" "${CF}/bin/dock er" "${CENV}" docker-compose.yml -- ps
contains 'direct: a docker command that is not one word is refused' "${OUT}" 'REFUSED: the docker command is not one plain word'
equals 'direct: and calls no docker (docker word)' "${ARGV}" ''
cfx direct-root-link; mkdir -p "${CF}/alt"; ln -s "${CROOT}" "${CF}/alt/demo"
drun run "${CF}/alt/demo" "${CF}/bin/docker" "${CENV}" docker-compose.yml -- ps
contains 'direct: a ROOT reached through a symlink is refused' "${OUT}" "REFUSED: ROOT '${CF}/alt/demo' is not a plain absolute directory"
equals 'direct: and calls no docker (ROOT)' "${ARGV}" ''
cfx direct-env-word; mkdir -m 700 "${CF}/app env"; cp -p "${CENV}" "${CF}/app env/demo.env"
drun run "${CROOT}" "${CF}/bin/docker" "${CF}/app env/demo.env" docker-compose.yml -- ps
contains 'direct: an env file path that is not one word is refused' "${OUT}" "REFUSED: the env file path '${CF}/app env/demo.env' is not one plain word"
equals 'direct: and calls no docker (env word)' "${ARGV}" ''
cfx direct-env-name; cp -p "${CENV}" "${CF}/app-env/other.env"
drun run "${CROOT}" "${CF}/bin/docker" "${CF}/app-env/other.env" docker-compose.yml -- ps
contains 'direct: an env file not named after ROOT is refused' "${OUT}" "REFUSED: ${CF}/app-env/other.env is not named after ${CROOT}"
equals 'direct: and calls no docker (env name)' "${ARGV}" ''
cfx init-docker-glob
crun "DOCKER='${CF}/bin/docke?'; ${INIT}; deploy_compose ps"
contains 'init: a DOCKER that is not one word (a glob) is refused' "${OUT}" "REFUSED: DOCKER '${CF}/bin/docke?' is not one plain word."
equals 'init: and calls no docker (DOCKER)' "${ARGV}" ''
cfx env-value-sudo-fails; printf '#!/bin/sh\nexit 1\n' >"${CF}/bin/sudo"; chmod 755 "${CF}/bin/sudo"
C_EXTRA="PATH=${CF}/bin:/usr/bin:/bin"
crun 'v=$(DEPLOY_APP_USER=nobody deploy_app_env_value APP_URL) || printf "RC=%s\n" "$?"; printf "VAL=[%s]\n" "${v:-}"'
contains 'env value: a failed sudo refuses on stderr' "${OUT}" "REFUSED: ${CROOT}/.env could not be read as nobody (sudo), so no value is guessed"
contains 'env value: and returns 1 with no value' "${OUT}" $'RC=1\nVAL=[]'

# Last round: an allow-list per level; anything not on it is refused by name, and a listed key is still judged by value.
allow_case() { # name, jq edit, "<service> sets <key>"
    cfx "allow-$1"
    cjson "$2"
    crun "${INIT}; deploy_compose up -d"
    contains "allow $1: refused" "${OUT}" "REFUSED: compose $3, which is not on root's compose list (policy, backlog 320)"
    absent "allow $1: nothing runs" "${ARGV}" ' up -d'
}
allow_case top '.secrets = {s: {environment: "S"}}' 'top level sets secrets'
allow_case service '.services.app.sysctls = {"net.core.somaxconn": "1024"}' 'app sets sysctls'
allow_case service_runtime '.services.app.runtime = "runsc"' 'app sets runtime'
allow_case service_cgroup_parent '.services.app.cgroup_parent = "/x"' 'app sets cgroup_parent'
allow_case service_group_add '.services.app.group_add = ["docker"]' 'app sets group_add'
allow_case service_env_file '.services.app.env_file = [{path: "\($r)/.env"}]' 'app sets env_file'
allow_case service_volumes_from '.services.app.volumes_from = ["db"]' 'app sets volumes_from'
allow_case build '.services.app.build.network = "container:abc"' 'app sets build.network'
allow_case volume_key '.services.app.volumes += [{type: "volume", source: "data", target: "/e", consistency: "cached"}]' 'app sets volumes.consistency'
allow_case volume_type '.services.app.volumes += [{type: "tmpfs", target: "/t"}]' 'app sets volumes.type tmpfs'
allow_case top_volume '.volumes.data.labels = {a: "b"}' 'volume data sets labels'
allow_case top_network '.networks = {n: {driver_opts: {"com.docker.network.bridge.name": "docker0"}}}' 'network n sets driver_opts'
policy_case volume_driver '.volumes.data.driver = "plugin"' 'compose volume data sets driver,'
policy_case network_driver '.networks = {n: {driver: "macvlan"}}' 'compose network n sets driver,'
policy_case network_ipam '.networks = {n: {ipam: {config: [{subnet: "10.0.0.0/8"}]}}}' 'compose network n sets ipam,'
policy_case allow_value '.services.app.security_opt = ["apparmor:unconfined"]' 'compose app sets security_opt,'

# The project is the app root names (FLEET_DEPLOY_REPO), forced with -p; volume and network names carry its prefix.
C_RUNDIR=run.Ab12Cd34 cfx export-dir
crun "${INIT}; deploy_compose up -d"
contains 'export dir: the project is the app, not the run.* directory the files sit in' "${ARGV}" "compose --project-directory ${CROOT} -p demo -f ${CF}/run.Ab12Cd34/compose/docker-compose.yml --env-file ${CENV} up -d"
cfx repo-other
C_EXTRA='FLEET_DEPLOY_REPO=gcotcheza/other'
crun "${INIT}"
contains 'repo: a FLEET_DEPLOY_REPO naming another app is refused' "${OUT}" "REFUSED: FLEET_DEPLOY_REPO names other, not demo"
equals 'repo: and no docker call is made (other)' "${ARGV}" ''
cfx repo-unset
C_EXTRA='FLEET_DEPLOY_REPO='
crun "${INIT}"
contains 'repo: an unset FLEET_DEPLOY_REPO is refused' "${OUT}" "REFUSED: FLEET_DEPLOY_REPO '' names no app: root names it. Deploy with: fleet-deploy <app> <PR#>"
cfx policy-no-app
crun 'deploy_compose_policy "$ROOT" "{}" || printf "ERR=%s\n" "$DEPLOY_COMPOSE_ERR"'
contains 'policy no_app: the policy refuses without an app name' "${OUT}" 'ERR=the policy was given no app name'
policy_case top_name '.name = "memento"' 'compose top level sets name,'
policy_case volume_name '.volumes.data.name = "memento_pgdata"' 'compose volume data sets name,'
policy_case network_name '.networks = {n: {name: "memento_default"}}' 'compose network n sets name,'
policy_case network_external_unlisted '.networks = {n: {external: true, name: "proxy"}}' "compose network n sets external (not on the shared list),"
cfx names-own
cjson '.volumes.data.name = "demo_data" | .networks = {n: {name: "demo_n"}, "whisper-net": {external: true, name: "whisper-net"}}'
crun "${INIT}; deploy_compose up -d"
contains 'shared: own-prefixed names and the shared whisper-net pass' "${ARGV}" "--env-file ${CENV} up -d"
equals "shared: root's list is exactly whisper-net" "$(bash -c '. "$1"; printf %s "$FLEET_COMPOSE_SHARED_NETWORKS"' _ "${LIB_DIR}/compose.sh")" whisper-net

cfx no-file-named
crun "DEPLOY_COMPOSE_FILES=' '; ${INIT}"
contains 'pieces: no compose file named refuses' "${OUT}" 'REFUSED: no compose file is named'
cfx init-root-missing
crun "ROOT='${CF}/nowhere'; ${INIT}"
contains 'init: a ROOT that is not a directory refuses' "${OUT}" "REFUSED: ROOT '${CF}/nowhere' is not a directory."
cfx init-policy; cjson '.services.app.privileged = true'
crun "${INIT}"
contains 'init: the policy refuses at init, before any other call' "${OUT}" 'REFUSED: compose app sets privileged'
absent 'init: and says nothing clean' "${OUT}" 'policy clean'
cfx env-key
crun 'deploy_app_env_value "bad key"'
contains 'env value: a key that is not a name refuses' "${OUT}" "REFUSED: 'bad key' is not an env key."
equals '/dev/null keeps its mode and owner across the suite (rule 26)' "$(stat -c '%a %u %g %F' /dev/null)" "${DEVNULL_BEFORE}"
if [ "${fails}" -eq 0 ]; then printf '\ncompose-test: all checks passed\n'; exit 0; fi
printf '\ncompose-test: %s check(s) failed\n' "${fails}" >&2
exit 1
