#!/usr/bin/env bash
# Fixtures only: compose files written into a temp dir drive the real
# scripts/gate-image-tags.sh. No docker, no network, no project repository.
# GATE_IMAGE_TAGS_SH points at a scratch copy for the red proofs.
#
#   scripts/gate-image-tags-test.sh
#   GATE_IMAGE_TAGS_SH=/tmp/mutant.sh scripts/gate-image-tags-test.sh   the red proofs
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${GATE_IMAGE_TAGS_SH:-${SCRIPT_DIR}/gate-image-tags.sh}"

fails=0
pass()  { printf 'ok   %s\n' "$*"; }
fail()  { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }
matches() { if printf '%s' "$2" | grep -qE "$3"; then pass "$1"; else fail "$1 — [$2] does not match /$3/"; fi; }
lacks()   { if printf '%s' "$2" | grep -qE "$3"; then fail "$1 — [$2] matches /$3/"; else pass "$1"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# $1 project, $2 compose file, $3 image value, $4 'build' adds a build: sibling
service() {
    mkdir -p "${WORK}/$1"
    { printf 'services:\n  app:\n'
      [ "${4:-}" = build ] && printf '    build:\n      context: ./docker/app\n'
      printf "    image: %s\n    volumes: ['./:/var/www/html']\n" "$3"
    } >>"${WORK}/$1/$2"
}

# The same service with its build inherited through a merge key instead.
merged() {
    mkdir -p "${WORK}/$1"
    { printf 'x-app: &app\n  build:\n    context: ./docker/app\n'
      printf 'services:\n  app:\n    <<: *app\n    image: %s\n' "$3"
    } >>"${WORK}/$1/$2"
}

# A service that builds and names no image: compose tags it <project>-<service>.
# $4 'extends' builds through extends: instead of build:.
builder() {
    mkdir -p "${WORK}/$1"
    { printf 'services:\n  %s:\n' "$3"
      if [ "${4:-}" = extends ]; then printf '    extends:\n      file: base.yml\n      service: app\n'
      else printf '    build:\n      context: ./docker/app\n'; fi
      printf "    volumes: ['./:/var/www/html']\n"
    } >>"${WORK}/$1/$2"
}

# Starts a compose file with a project name of its own, which compose prefers
# over the directory.
named() { mkdir -p "${WORK}/$1"; printf 'name: %s\n' "$3" >"${WORK}/$1/$2"; }

# An overlay service: an image: with no build: beside it, the shape a gate lays
# over a production base. $4 adds a build: of the file's own.
overlay() {
    mkdir -p "${WORK}/$1"
    [ -s "${WORK}/$1/$2" ] || printf 'services:\n' >>"${WORK}/$1/$2"
    { printf '  %s:\n' "$3"
      [ "${5:-}" = build ] && printf '    build:\n      context: ./docker/app\n'
      printf '    image: %s\n' "$4"
    } >>"${WORK}/$1/$2"
}

# A gate script the check reads for the compose files a gate run passes.
gate_script() { mkdir -p "${WORK}/$1/scripts"; printf '%s\n' "$3" >"${WORK}/$1/scripts/$2"; }

append() { printf '%s\n' "$3" >>"${WORK}/$1/$2"; }

run() { OUT="$("${CHECK}" "${WORK}/$1" 2>&1)"; RC=$?; }

# --- 1. one tag built by the gate and run in production -> FAIL ----------------
service shared docker-compose.e2e.yml 'demo/app:latest' build
service shared docker-compose.yml     'demo/app:latest' build
run shared
matches 'case 1: the shared tag is named' "${OUT}" 'FAIL .*: image tag demo/app:latest is built for the gate and run in production'
matches 'case 1: the gate file and line'  "${OUT}" 'gate: +docker-compose\.e2e\.yml:5$'
matches 'case 1: the production file and line' "${OUT}" 'production: +docker-compose\.yml:5$'
equals  'case 1: exit code' "${RC}" 1

# --- 2. separate tags, and a pinned image on both sides -> PASS ----------------
service separate docker-compose.e2e.yml 'demo/app:ci' build
service separate docker-compose.yml     'demo/app:latest' build
append  separate docker-compose.e2e.yml '  postgres:
    image: postgres:18-alpine'
append  separate docker-compose.yml '  postgres:
    image: postgres:18-alpine'
run separate
matches 'case 2: separate tags pass' "${OUT}" '^ok .*: 2 built image tag\(s\), none shared'
equals  'case 2: exit code' "${RC}" 0
matches 'case 2: a pinned image shared on both sides is not a finding' "${OUT}" '^ok '
matches 'case 2: the files it read are named' "${OUT}" 'gate files: +docker-compose\.e2e\.yml$'
matches 'case 2: every value resolved' "${OUT}" 'images: +4 resolved, 0 unresolved$'

# --- 3. ${CI_APP_IMAGE:-x/app:ci} resolves to its default -> PASS --------------
service defaulted docker-compose.e2e.yml "'\${CI_APP_IMAGE:-x/app:ci}'" build
service defaulted docker-compose.yml     'x/app:latest' build
run defaulted
matches 'case 3: a resolved default that differs passes' "${OUT}" '^ok .*: 2 built image tag\(s\), none shared'
equals  'case 3: exit code' "${RC}" 0

# --- 3b. the default IS the production tag -> FAIL (the resolver really runs) --
service resolved docker-compose.ci.yml "'\${CI_APP_IMAGE:-x/app:latest}'" build
service resolved docker-compose.yml    'x/app:latest' build
run resolved
matches 'case 3b: a default equal to the production tag fails' "${OUT}" 'FAIL .*: image tag x/app:latest is built'
equals  'case 3b: exit code' "${RC}" 1

# --- 4. no app image at all (bind mounts) -> PASS, and never silently ----------
mkdir -p "${WORK}/bindmount"
printf 'services:\n  postgres:\n    image: postgres:16-alpine\n' >"${WORK}/bindmount/docker-compose.yml"
run bindmount
matches 'case 4: a project with no built image says so' "${OUT}" '^ok .*: no built image tag resolved here'
matches 'case 4: and names the file it read' "${OUT}" 'production files: +docker-compose\.yml$'
equals  'case 4: exit code' "${RC}" 0

# --- 5. ${VAR:?msg} has no default -> counted and named, never dropped ---------
service required docker-compose.e2e.yml "'\${E2E_APP_IMAGE:?set by scripts/e2e.sh}'" build
run required
matches 'case 5: an unresolvable value is counted and named' "${OUT}" 'images: +0 resolved, 1 unresolved — \$\{E2E_APP_IMAGE:\?set by scripts/e2e\.sh\} in docker-compose\.e2e\.yml:5$'
matches 'case 5: and the verdict does not claim a clean sweep' "${OUT}" '^ok .*: no built image tag resolved here'
equals  'case 5: exit code' "${RC}" 0

# --- 6. the gate only RUNS the production tag, builds nothing -> FAIL ----------
service runsit docker-compose.e2e.yml 'demo/app:latest'
service runsit docker-compose.yml     'demo/app:latest' build
run runsit
matches 'case 6: running the production tag in the gate fails too' "${OUT}" 'FAIL .*: image tag demo/app:latest is built'
equals  'case 6: exit code' "${RC}" 1

# --- 7. a directory with no compose file at all -> REFUSED, never a pass ------
mkdir -p "${WORK}/empty"
run empty
matches 'case 7: a root with nothing to read is refused in one line' "${OUT}" \
    '^gate-image-tags: no compose file beside this root — nothing was examined, so .*/empty is refused, not passed \(T9\)$'
equals  'case 7: exit code' "${RC}" 2

# --- 7b. a compose file renamed out of the pattern -> read, and judged --------
mkdir -p "${WORK}/renamed"
printf 'services:\n  app:\n    build: ./docker/app\n    image: demo/app:latest\n' >"${WORK}/renamed/stack.yml"
run renamed
matches 'case 7b: a yml carrying services: is read whatever its name' "${OUT}" 'production files: +stack\.yml$'
matches 'case 7b: and a tag it builds is refused, not hidden' "${OUT}" 'FAIL .*: stack\.yml builds an image tag and is named neither for the gate nor for production'
equals  'case 7b: exit code' "${RC}" 1

# --- 7c. a yml that is not a compose file at all -> not read, root refused ----
mkdir -p "${WORK}/notcompose"
printf 'paths:\n  only_dir_groups:\n    app: ["src/App"]\n' >"${WORK}/notcompose/deptrac.yaml"
run notcompose
matches 'case 7c: a yml with no top-level services: is not read as compose' "${OUT}" \
    '^gate-image-tags: no compose file beside this root — nothing was examined, so .*/notcompose is refused, not passed \(T9\)$'
equals  'case 7c: exit code' "${RC}" 2

# --- 8. the build is inherited through a merge key on both sides -> FAIL ------
merged anchored docker-compose.e2e.yml 'demo/app:latest'
merged anchored docker-compose.yml     'demo/app:latest'
run anchored
matches 'case 8: a build inherited through <<: *anchor still counts as built' "${OUT}" 'FAIL .*: image tag demo/app:latest is built'
matches 'case 8: the inheritance is reported' "${OUT}" 'built tags: +1 \(2 value\(s\) inherit a build through <<: or extends\)$'
equals  'case 8: exit code' "${RC}" 1

# --- 9. a missing tag is the same image as :latest -> FAIL --------------------
service untagged docker-compose.e2e.yml 'demo/app:latest' build
service untagged docker-compose.yml     "'demo/app'" build
run untagged
matches 'case 9: an untagged production image normalises to :latest' "${OUT}" 'FAIL .*: image tag demo/app:latest is built'
equals  'case 9: exit code' "${RC}" 1

# --- 10. a compose file the classifier does not recognise -> named, not hidden -
service oddname docker-compose.test.yml 'demo/app:latest' build
service oddname docker-compose.yml      'demo/app:latest' build
run oddname
matches 'case 10: an unrecognised compose filename is named' "${OUT}" 'unrecognised: +docker-compose\.test\.yml — read as production, on filename alone$'
matches 'case 10: and a tag built there is refused, not guessed at' "${OUT}" 'FAIL .*: docker-compose\.test\.yml builds an image tag and is named neither for the gate nor for production — rename it \*ci\* or \*e2e\* if a gate run builds it, \*prod\* if production runs it$'
matches 'case 10: the trailer says which half failed' "${OUT}" '^gate-image-tags: 1 unrecognised compose file\(s\) build a tag — which side builds it is a guess \(T9\)$'
equals  'case 10: exit code' "${RC}" 1

# --- 11. a double-quoted value is the same tag as a bare one -> FAIL ----------
service quoted docker-compose.e2e.yml '"demo/app:ci"' build
service quoted docker-compose.yml     'demo/app:ci' build
run quoted
matches 'case 11: a double-quoted image value is unquoted like a bare one' "${OUT}" 'FAIL .*: image tag demo/app:ci is built'
equals  'case 11: exit code' "${RC}" 1

# --- 12. compose.yaml is a compose file too -> FAIL ---------------------------
service modern docker-compose.e2e.yml 'demo/app:latest' build
service modern compose.yaml           'demo/app:latest' build
run modern
matches 'case 12: compose.yaml is read' "${OUT}" 'production files: +compose\.yaml$'
matches 'case 12: and its tag is compared' "${OUT}" 'FAIL .*: image tag demo/app:latest is built'
equals  'case 12: exit code' "${RC}" 1

# --- 13. a symlinked compose file is followed, not skipped -> FAIL ------------
mkdir -p "${WORK}/symlinked" "${WORK}/elsewhere"
printf 'services:\n  app:\n    build:\n      context: .\n    image: demo/app:latest\n' >"${WORK}/elsewhere/prod.yml"
ln -s "${WORK}/elsewhere/prod.yml" "${WORK}/symlinked/docker-compose.yml"
service symlinked docker-compose.e2e.yml 'demo/app:latest' build
run symlinked
matches 'case 13: a symlinked compose file is read' "${OUT}" 'FAIL .*: image tag demo/app:latest is built'
equals  'case 13: exit code' "${RC}" 1

# --- 14. a CRLF file matches an LF one -> FAIL -------------------------------
mkdir -p "${WORK}/crlf"
printf 'services:\r\n  app:\r\n    build:\r\n      context: .\r\n    image: demo/app:latest\r\n' >"${WORK}/crlf/docker-compose.e2e.yml"
service crlf docker-compose.yml 'demo/app:latest' build
run crlf
matches 'case 14: a trailing carriage return does not hide a shared tag' "${OUT}" 'FAIL .*: image tag demo/app:latest is built'
equals  'case 14: exit code' "${RC}" 1

# --- 15. production builds with no image: -> its implicit tag is compared -> FAIL
service implicit docker-compose.ci.yml 'implicit-symfony' build
builder implicit docker-compose.yml     symfony
run implicit
matches 'case 15: a production build with no image: still has a tag' "${OUT}" 'FAIL .*: image tag implicit-symfony:latest is built for the gate and run in production'
matches 'case 15: located at the service line, the only line there is' "${OUT}" 'production: +docker-compose\.yml:2$'
equals  'case 15: exit code' "${RC}" 1

# --- 16. a gate service that builds through extends: -> unresolved, not invented
builder extended docker-compose.ci.yml app extends
service extended docker-compose.yml    'extended-app' build
run extended
matches 'case 16: an extends: build carries no tag this check can resolve' "${OUT}" 'images: +1 resolved, 1 unresolved — the image of app \(extends a service, whose image: is not read here\) in docker-compose\.ci\.yml:2$'
matches 'case 16: and no tag is invented from the project name' "${OUT}" '^ok .*: 1 built image tag\(s\), none shared between the gate and production — 1 value\(s\) unresolved and not judged$'
equals  'case 16: exit code' "${RC}" 0

# --- 17. a file's own name: beats the directory -> FAIL on the chosen project ---
named   named-proj docker-compose.yml chosen
builder named-proj docker-compose.yml app
service named-proj docker-compose.ci.yml 'chosen-app' build
run named-proj
matches 'case 17: name: decides the project, not the directory' "${OUT}" 'FAIL .*: image tag chosen-app:latest is built for the gate and run in production'
equals  'case 17: exit code' "${RC}" 1

# --- 17b. the directory is lower-cased and stripped the way compose does it ----
builder 'My.Proj_1' docker-compose.yml app
service 'My.Proj_1' docker-compose.ci.yml 'myproj_1-app:latest' build
run 'My.Proj_1'
matches 'case 17b: the directory becomes a compose project name' "${OUT}" 'FAIL .*: image tag myproj_1-app:latest is built for the gate and run in production'
equals  'case 17b: exit code' "${RC}" 1

# --- 18. both sides build the same service and name nothing -> FAIL -----------
builder bothways docker-compose.ci.yml app
builder bothways docker-compose.yml    app
run bothways
matches 'case 18: two implicit tags of the same service are one tag' "${OUT}" 'FAIL .*: image tag bothways-app:latest is built for the gate and run in production'
matches 'case 18: the gate side is located too' "${OUT}" 'gate: +docker-compose\.ci\.yml:2$'
equals  'case 18: exit code' "${RC}" 1

# --- 19. an unrecognised file that builds nothing -> named, and still passes ---
service oddquiet docker-compose.test.yml 'postgres:18-alpine'
service oddquiet docker-compose.yml      'demo/app:latest' build
run oddquiet
matches 'case 19: an unrecognised file that builds nothing is named' "${OUT}" 'unrecognised: +docker-compose\.test\.yml — read as production, on filename alone$'
matches 'case 19: and the verdict still passes' "${OUT}" '^ok .*: 1 built image tag\(s\), none shared'
equals  'case 19: exit code' "${RC}" 0

# --- 20. implicit tags that differ -> PASS, and an inert override is not one ---
builder distinct docker-compose.ci.yml app-ci
builder distinct docker-compose.yml    app
append  distinct docker-compose.yml "  web:
    ports: ['8080:8080']"
run distinct
matches 'case 20: two implicit tags that differ are not a finding' "${OUT}" '^ok .*: 2 built image tag\(s\), none shared'
matches 'case 20: a service that neither builds nor names an image is not tagged' "${OUT}" 'images: +2 resolved, 0 unresolved$'
equals  'case 20: exit code' "${RC}" 0

# --- 21. a merge key this file does not define -> unresolved, never guessed ----
mkdir -p "${WORK}/foreign"
printf 'services:\n  app:\n    <<: *elsewhere\n' >"${WORK}/foreign/docker-compose.yml"
run foreign
matches 'case 21: an unknown anchor leaves the tag unresolved, and says so' "${OUT}" 'images: +0 resolved, 1 unresolved — the image of app \(merges \*elsewhere, not defined here\) in docker-compose\.yml:2$'
equals  'case 21: exit code' "${RC}" 0

# --- 22. a flow-style service body -> unresolved, never a silent pass ----------
builder flowbody docker-compose.yml symfony
printf 'services:\n  symfony: {build: ./docker/app, image: flowbody-symfony}\n' >"${WORK}/flowbody/docker-compose.ci.yml"
run flowbody
matches 'case 22: a service written as a flow map is read as unresolved, not as nothing' "${OUT}" 'images: +1 resolved, 1 unresolved — the body of symfony \(written in a form this check cannot read\) in docker-compose\.ci\.yml:2$'
equals  'case 22: exit code' "${RC}" 0

# --- 23. quoted mapping keys -> unresolved, not read as a service with no image -
service quotedkeys docker-compose.yml 'demo/app:ci' build
printf 'services:\n  app:\n    "build": ./d\n    "image": "demo/app:ci"\n' >"${WORK}/quotedkeys/docker-compose.ci.yml"
run quotedkeys
matches 'case 23: a quoted image: key leaves the service unresolved' "${OUT}" 'images: +1 resolved, 1 unresolved — the body of app \(written in a form this check cannot read\) in docker-compose\.ci\.yml:2$'
equals  'case 23: exit code' "${RC}" 0

# --- 24. extends: a service in this root -> unresolved, not an invented tag -----
service extfile docker-compose.yml 'myapp/api:prod' build
printf 'services:\n  worker:\n    extends:\n      file: docker-compose.yml\n      service: app\n' >"${WORK}/extfile/docker-compose.ci.yml"
run extfile
matches 'case 24: an extends: with no image: of its own is named, not guessed at' "${OUT}" 'images: +1 resolved, 1 unresolved — the image of worker \(extends a service, whose image: is not read here\) in docker-compose\.ci\.yml:2$'
matches 'case 24: and the verdict says what it could not judge' "${OUT}" '^ok .*: 1 built image tag\(s\), none shared between the gate and production — 1 value\(s\) unresolved and not judged$'
equals  'case 24: exit code' "${RC}" 0

# --- 25. a build.tags entry is a tag the build writes -> FAIL ------------------
builder tagsonly docker-compose.yml symfony
printf 'services:\n  symfony:\n    build:\n      context: ./docker/app\n      tags:\n        - tagsonly-symfony\n    image: throwaway:ci\n' >"${WORK}/tagsonly/docker-compose.ci.yml"
run tagsonly
matches 'case 25: a build.tags entry is compared like an image: value' "${OUT}" 'FAIL .*: image tag tagsonly-symfony:latest is built for the gate and run in production'
matches 'case 25: located at the entry line' "${OUT}" 'gate: +docker-compose\.ci\.yml:6$'
equals  'case 25: exit code' "${RC}" 1

# --- 26. a file with no name: beside one that has it -> FAIL on that project ----
named   overlay docker-compose.yml chosen
builder overlay docker-compose.yml    app
builder overlay docker-compose.ci.yml app
run overlay
matches 'case 26: a file declaring no name: is compared under the name declared beside it' "${OUT}" 'FAIL .*: image tag chosen-app:latest is built for the gate and run in production'
matches 'case 26: and its own directory stays a candidate project' "${OUT}" 'built tags: +2$'
equals  'case 26: exit code' "${RC}" 1

# --- 27. a flow map on a key that is not the image: -> the service is still read
builder flowsibling docker-compose.ci.yml app
builder flowsibling docker-compose.yml    app
append  flowsibling docker-compose.yml "    healthcheck: {test: ['CMD','true'], interval: 10s}"
run flowsibling
matches 'case 27: a flow map on healthcheck: does not hide the image' "${OUT}" 'FAIL .*: image tag flowsibling-app:latest is built for the gate and run in production'
matches 'case 27: and nothing is left unresolved' "${OUT}" 'images: +2 resolved, 0 unresolved$'
equals  'case 27: exit code' "${RC}" 1

# --- 28. a quoted top-level "services": key -> dequoted and read --------------
builder quotedsvcs docker-compose.yml app
printf '"services":\n  app:\n    build: ./docker/app\n' >"${WORK}/quotedsvcs/docker-compose.ci.yml"
run quotedsvcs
matches 'case 28: a quoted services: key is read like a bare one' "${OUT}" 'FAIL .*: image tag quotedsvcs-app:latest is built for the gate and run in production'
matches 'case 28: located at the service line' "${OUT}" 'gate: +docker-compose\.ci\.yml:2$'
equals  'case 28: exit code' "${RC}" 1

# --- 28b. no top-level services: this check can read -> unresolved, not empty --
mkdir -p "${WORK}/nosvcs"
printf '{"services": {"app": {"build": "./d"}}}\n' >"${WORK}/nosvcs/docker-compose.yml"
run nosvcs
matches 'case 28b: a file whose services: was never found is unresolved' "${OUT}" 'images: +0 resolved, 1 unresolved — the services of this file \(no top-level services: line this check can read\) in docker-compose\.yml:1$'
equals  'case 28b: exit code' "${RC}" 0

# --- 29. a name: only a gate file declares -> not production's project --------
named   gatename docker-compose.ci.yml gatename-ci
builder gatename docker-compose.ci.yml app
builder gatename docker-compose.yml    app
run gatename
matches 'case 29: a gate-only project name is not a candidate for production' "${OUT}" '^ok .*: 2 built image tag\(s\), none shared'
equals  'case 29: exit code' "${RC}" 0

# --- 30. a value carried out of a flow map -> unresolved, never a tag ---------
service flowvalue docker-compose.yml 'flowvalue-app' build
printf 'services:\n  app: {\n    build: ./d,\n    image: flowvalue-app }\n' >"${WORK}/flowvalue/docker-compose.ci.yml"
run flowvalue
matches 'case 30: a value left holding flow punctuation is not resolved' "${OUT}" 'images: +1 resolved, 2 unresolved'
matches 'case 30: and no mangled tag is counted' "${OUT}" 'built tags: +1$'
equals  'case 30: exit code' "${RC}" 0

# --- 31. an overlay that only retags, merged over the base that builds -> PASS -
service overlaid docker-compose.yml 'x/app:latest' build
overlay overlaid docker-compose.ci.yml app 'x/app:ci'
gate_script overlaid check.sh 'docker compose -f docker-compose.yml -f docker-compose.ci.yml up -d'
run overlaid
matches 'case 31: the two files a gate passes are read as one run' "${OUT}" \
    'gate runs: +docker-compose\.yml \+ docker-compose\.ci\.yml \(scripts/check\.sh:1, -f\) builds x/app:ci$'
matches 'case 31: an image: with no build: beside it is not a tag nothing builds' "${OUT}" '^ok '
equals  'case 31: exit code' "${RC}" 0

# --- 32. the overlay retags one service and leaves its sibling -> FAIL ---------
service halfway docker-compose.yml 'x/app:latest' build
append  halfway docker-compose.yml '  queue:
    build:
      context: ./docker/app
    image: x/app:latest'
overlay halfway docker-compose.ci.yml app 'x/app:ci'
gate_script halfway check.sh 'docker compose -f docker-compose.yml -f docker-compose.ci.yml up -d'
run halfway
matches 'case 32: the service the overlay forgot still builds production tag' "${OUT}" \
    'FAIL .*: the gate run at scripts/check\.sh:1 builds image tag x/app:latest, which production is recreated from'
matches 'case 32: and the service is named' "${OUT}" 'services: +queue \(build at docker-compose\.yml:[0-9]+\)$'
equals  'case 32: exit code' "${RC}" 1

# --- 33. a gate that passes no -f at all runs the production file -> FAIL ------
service bare docker-compose.yml     'orb/app:latest' build
service bare docker-compose.e2e.yml 'orb/app:e2e' build
gate_script bare check.sh 'docker compose run --rm --no-deps app php artisan test'
run bare
matches 'case 33: a bare compose call is read as compose reads it' "${OUT}" \
    'gate runs: +docker-compose\.yml \(scripts/check\.sh:1, default\) builds orb/app:latest'
matches 'case 33: and building production tag in the gate fails' "${OUT}" \
    'FAIL .*: the gate run at scripts/check\.sh:1 builds image tag orb/app:latest'
matches 'case 33: the call is quoted back' "${OUT}" 'gate run: +docker compose run over docker-compose\.yml \(default\)$'
equals  'case 33: exit code' "${RC}" 1

# --- 34. the same gate with an exported COMPOSE_FILE pair -> PASS, and credited -
service fixed docker-compose.yml 'orb/app:latest' build
overlay fixed docker-compose.ci.yml app 'orb/app:ci'
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script fixed check.sh 'here=$(dirname "$0")
export COMPOSE_FILE="$here/docker-compose.yml:$here/docker-compose.ci.yml"
docker compose run --rm --no-deps app php artisan test'
run fixed
matches 'case 34: an exported COMPOSE_FILE is the file set of a bare call' "${OUT}" \
    'gate runs: +docker-compose\.yml \+ docker-compose\.ci\.yml \(scripts/check\.sh:3, COMPOSE_FILE\) builds orb/app:ci$'
matches 'case 34: and the gate tag of its own passes' "${OUT}" '^ok '
equals  'case 34: exit code' "${RC}" 0

# --- 34b. COMPOSE_FILE assigned but never exported -> compose reads its default -
service unexported docker-compose.yml 'orb/app:latest' build
overlay unexported docker-compose.ci.yml app 'orb/app:ci'
gate_script unexported check.sh 'COMPOSE_FILE="docker-compose.yml:docker-compose.ci.yml"
docker compose up -d'
run unexported
matches 'case 34b: a variable compose never sees does not decide the file set' "${OUT}" \
    'gate runs: +docker-compose\.yml \(scripts/check\.sh:2, default\) builds orb/app:latest'
equals  'case 34b: exit code' "${RC}" 1

# --- 35. the overlay carries its own build:, passed as a pair -> PASS ----------
service withbuild docker-compose.yml 'mem/app:latest' build
overlay withbuild docker-compose.ci.yml app 'mem/app:ci' build
gate_script withbuild check.sh 'compose() { docker compose -f docker-compose.yml -f docker-compose.ci.yml "$@"; }
compose up -d'
run withbuild
matches 'case 35: a -f pair inside a wrapper is read at the line that runs it' "${OUT}" \
    'gate runs: +docker-compose\.yml \+ docker-compose\.ci\.yml \(scripts/check\.sh:2, -f\) builds mem/app:ci$'
equals  'case 35: exit code' "${RC}" 0

# --- 36. a bare call that only tears down -> named, not judged, and passes -----
service teardown docker-compose.yml 'x/app:latest' build
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script teardown e2e.sh 'DOWN=(docker compose -p "$PROJECT")
"${DOWN[@]}" down -v --remove-orphans'
run teardown
matches 'case 36: the wrapper is judged where it is used, by the subcommand there' "${OUT}" \
    'gate runs: +docker-compose\.yml \(scripts/e2e\.sh:2, default\) down builds nothing$'
lacks   'case 36: and the line that only defined it says nothing' "${OUT}" 'scripts/e2e\.sh:1'
equals  'case 36: exit code' "${RC}" 0

# --- 37. an overlay naming production's own built tag -> FAIL, as it always did -
service takesprod docker-compose.yml 'x/app:latest' build
overlay takesprod docker-compose.ci.yml app 'x/app:latest'
run takesprod
matches 'case 37: an overlay on production tag is a shared tag with no gate script' "${OUT}" \
    'FAIL .*: image tag x/app:latest is built for the gate and run in production'
equals  'case 37: exit code' "${RC}" 1

# --- 38. an overlay in no gate run this check can read -> named, and passes ----
service unpaired docker-compose.yml 'x/app:latest' build
overlay unpaired docker-compose.ci.yml app 'x/app:ci'
run unpaired
matches 'case 38: an overlay no gate run here pairs is named, not assumed' "${OUT}" \
    'overlay tags: +docker-compose\.ci\.yml:2 tags app x/app:ci, over the build at docker-compose\.yml:2 — in no gate run read here$'
matches 'case 38: and the root still passes' "${OUT}" '^ok '
equals  'case 38: exit code' "${RC}" 0

# --- 39. a -f value naming a file that is not here -> printed, never dropped ---
service missingf docker-compose.yml 'x/app:latest' build
gate_script missingf check.sh 'docker compose -f docker-compose.gone.yml up -d'
run missingf
matches 'case 39: a -f value this root has no file for is named' "${OUT}" \
    'unread -f values: +docker-compose\.gone\.yml in scripts/check\.sh:1$'
matches 'case 39: and a call this reader could not read is refused, not passed' "${OUT}" \
    '^gate-image-tags: 1 unread compose call\(s\) — a set this check cannot read is a set it cannot clear \(T9\)$'
equals  'case 39: exit code' "${RC}" 1

# --- 40. a compose call inside a quoted help string is not a gate run ----------
service helptext docker-compose.yml 'x/app:latest' build
gate_script helptext check.sh "printf '  docker compose up -d app\n'
printf \"  or: docker compose run --rm app sh\n\"
echo 'nothing here runs compose'"
run helptext
matches 'case 40: a compose line inside a string is not read as a run' "${OUT}" 'gate runs: +none read beside this root$'
equals  'case 40: exit code' "${RC}" 0

# --- 40b. a service in a gate run that extends: -> no tag invented for it -----
builder extset docker-compose.ci.yml app extends
service extset docker-compose.yml 'extset-app' build
gate_script extset check.sh 'docker compose -f docker-compose.ci.yml up -d'
run extset
matches 'case 40b: a gate run invents no tag the file alone would not carry' "${OUT}" \
    'images: +1 resolved, 1 unresolved — the image of app \(extends a service, whose image: is not read here\) in docker-compose\.ci\.yml:2$'
matches 'case 40b: so the gate run claims no built tag' "${OUT}" \
    'gate runs: +docker-compose\.ci\.yml \(scripts/check\.sh:1, -f\) builds nothing$'
equals  'case 40b: exit code' "${RC}" 0

# --- 41. the gate scripts read are named, even when there are none ------------
service noscripts docker-compose.yml 'x/app:latest' build
run noscripts
matches 'case 41: a root with no gate script says which names it looked for' "${OUT}" \
    'gate scripts: +none — scripts/\{check,ci,e2e,gate\}\.sh$'
equals  'case 41: exit code' "${RC}" 0

# --- 42. a call continued over lines keeps every -f it names -> PASS -----------
service contpair docker-compose.yml 'x/app:latest' build
overlay contpair docker-compose.ci.yml app 'x/app:ci'
gate_script contpair check.sh 'docker compose \
  -f docker-compose.yml \
  -f docker-compose.ci.yml \
  up -d'
run contpair
matches 'case 42: a call continued over lines keeps its -f flags' "${OUT}" \
    'gate runs: +docker-compose\.yml \+ docker-compose\.ci\.yml \(scripts/check\.sh:1, -f\) builds x/app:ci$'
equals  'case 42: exit code' "${RC}" 0

# --- 43. the same, with production named last -> FAIL (the hole a \ was hiding) -
service contlast docker-compose.yml 'x/app:latest' build
overlay contlast docker-compose.ci.yml app 'x/app:ci'
gate_script contlast check.sh 'docker compose -f docker-compose.ci.yml \
  -f docker-compose.yml \
  up -d'
run contlast
matches 'case 43: the later file of a continued call still wins the tag' "${OUT}" \
    'FAIL .*: the gate run at scripts/check\.sh:1 builds image tag x/app:latest'
equals  'case 43: exit code' "${RC}" 1

# --- 44. COMPOSE_FILE re-exported -> each call reads what was set above it -----
service cfseq docker-compose.yml 'x/app:latest' build
overlay cfseq docker-compose.ci.yml app 'x/app:ci'
gate_script cfseq check.sh 'export COMPOSE_FILE="docker-compose.yml"
docker compose up -d
export COMPOSE_FILE="docker-compose.yml:docker-compose.ci.yml"
docker compose run --rm app phpunit'
run cfseq
matches 'case 44: a call reads the COMPOSE_FILE set above it, not the last in the file' "${OUT}" \
    'FAIL .*: the gate run at scripts/check\.sh:2 builds image tag x/app:latest'
matches 'case 44: and the later pair is judged on its own' "${OUT}" \
    'docker-compose\.yml \+ docker-compose\.ci\.yml \(scripts/check\.sh:4, COMPOSE_FILE\) builds x/app:ci'
equals  'case 44: exit code' "${RC}" 1

# --- 45. a -f variable reassigned between two calls -> both read in order ------
service fseq docker-compose.yml 'x/app:latest' build
overlay fseq docker-compose.ci.yml app 'x/app:ci'
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script fseq check.sh 'F=docker-compose.yml
docker compose -f "$F" up -d
F=docker-compose.ci.yml
docker compose -f "$F" run --rm app phpunit'
run fseq
matches 'case 45: the first call reads the first value, not the last' "${OUT}" \
    'FAIL .*: the gate run at scripts/check\.sh:2 builds image tag x/app:latest'
equals  'case 45: exit code' "${RC}" 1

# --- 46. a -f variable set twice in an order this cannot read -> not resolved --
service fbranch docker-compose.yml 'x/app:latest' build
overlay fbranch docker-compose.ci.yml app 'x/app:ci'
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script fbranch check.sh 'F=docker-compose.ci.yml
if [ -n "${CI:-}" ]; then F=docker-compose.yml; fi
docker compose -f "$F" up -d'
run fbranch
# shellcheck disable=SC2016  # the expected text quotes the fixture's own $F
matches 'case 46: a variable given two values this cannot order is printed, not picked' "${OUT}" \
    'unread -f values: +"\$F" \(F takes more than one value above this line\) in scripts/check\.sh:3$'
equals  'case 46: exit code' "${RC}" 1

# --- 47. COMPOSE_FILE set in a sourced file -> followed one level -------------
service srcset docker-compose.yml 'x/app:latest' build
overlay srcset docker-compose.ci.yml app 'x/app:ci'
gate_script srcset lib.sh 'export COMPOSE_FILE="docker-compose.yml:docker-compose.ci.yml"'
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script srcset check.sh 'here="$(cd "$(dirname "$0")/.." && pwd)"
. "$here/scripts/lib.sh"
docker compose up -d'
run srcset
matches 'case 47: a COMPOSE_FILE set in a sourced file decides the file set' "${OUT}" \
    'gate runs: +docker-compose\.yml \+ docker-compose\.ci\.yml \(scripts/check\.sh:3, COMPOSE_FILE\) builds x/app:ci$'
equals  'case 47: exit code' "${RC}" 0

# --- 48. a sourced file this check cannot read -> unjudged, not the default set -
service srcgone docker-compose.yml 'x/app:latest' build
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script srcgone check.sh '. "$here/scripts/missing-lib.sh"
docker compose up -d'
run srcgone
# shellcheck disable=SC2016  # the expected text quotes the fixture's own $here
matches 'case 48: a bare call under an unreadable sourced file is named' "${OUT}" \
    'unread -f values: +COMPOSE_FILE, which \$here/scripts/missing-lib\.sh \(sourced at line 1\) may set in scripts/check\.sh:2$'
matches 'case 48: and no default file set is invented for it' "${OUT}" 'gate runs: +none read beside this root$'
equals  'case 48: exit code' "${RC}" 1

# --- 49. a -f wrapper carrying no subcommand -> not judged, whatever it names --
service teardownf docker-compose.yml 'x/app:latest' build
overlay teardownf docker-compose.ci.yml app 'x/app:ci'
gate_script teardownf e2e.sh 'DOWN=(docker compose -f docker-compose.yml -p acme)
docker compose -f docker-compose.yml -f docker-compose.ci.yml up -d'
run teardownf
matches 'case 49: a -f wrapper with no subcommand of its own is not judged' "${OUT}" \
    'docker-compose\.yml \(scripts/e2e\.sh:1, -f\) not judged — no subcommand read'
matches 'case 49: and the run that names one carries the verdict' "${OUT}" '^ok '
equals  'case 49: exit code' "${RC}" 0

# --- 49b. the same wrapper used with up -> judged where it is used -------------
service wrapup docker-compose.yml 'x/app:latest' build
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script wrapup check.sh 'DC=(docker compose -f docker-compose.yml)
"${DC[@]}" up -d app'
run wrapup
matches 'case 49b: a wrapper is judged by the subcommand it is used with' "${OUT}" \
    'FAIL .*: the gate run at scripts/check\.sh:2 builds image tag x/app:latest'
equals  'case 49b: exit code' "${RC}" 1

# --- 50. services: indented under a CI job -> not a compose file --------------
service gitlabci docker-compose.yml 'x/app:latest' build
printf 'stages: [test]\ntest:\n  image: x/app:latest\n  services:\n    - name: postgres:18-alpine\n' \
    >"${WORK}/gitlabci/.gitlab-ci.yml"
run gitlabci
matches 'case 50: a services: key under a job is not a top-level one' "${OUT}" 'production files: +docker-compose\.yml$'
matches 'case 50: so the image: beside it is not read as a tag' "${OUT}" 'images: +1 resolved, 0 unresolved$'
equals  'case 50: exit code' "${RC}" 0

# --- 51. the default set pairs a base and an override across extensions -------
service overpair compose.yaml 'x/app:latest' build
overlay overpair docker-compose.override.yml app 'x/app:over'
gate_script overpair check.sh 'docker compose up -d'
run overpair
matches 'case 51: compose.yaml pairs with docker-compose.override.yml' "${OUT}" \
    'gate runs: +compose\.yaml \+ docker-compose\.override\.yml \(scripts/check\.sh:1, default\) builds x/app:over$'
matches 'case 51: and an override is production, not an unrecognised name' "${OUT}" \
    'production files: +compose\.yaml, docker-compose\.override\.yml$'
equals  'case 51: exit code' "${RC}" 0

# --- 52. a call this reader cannot read -> printed, never silent --------------
service invisible docker-compose.yml 'x/app:latest' build
gate_script invisible check.sh 'eval "docker compose -f docker-compose.yml up -d"
sh -c "docker compose -f docker-compose.yml up -d"'
run invisible
matches 'case 52: an eval and an sh -c naming compose are printed as unjudged' "${OUT}" \
    'unjudged calls: +scripts/check\.sh:1; scripts/check\.sh:2 — a line naming docker compose that this reader could not read as a call$'
matches 'case 52: and neither is read as a gate run' "${OUT}" 'gate runs: +none read beside this root$'
equals  'case 52: exit code' "${RC}" 0

# --- 52b. a commented-out call is not an unjudged one ------------------------
service commentedout docker-compose.yml 'x/app:latest' build
gate_script commentedout check.sh '# docker compose -f docker-compose.yml up -d
true'
run commentedout
lacks   'case 52b: a line the shell never runs is not printed as unjudged' "${OUT}" 'unjudged calls:'
equals  'case 52b: exit code' "${RC}" 0

# --- 53. a build: contributed by a later file in the set still builds ---------
service laterbuild docker-compose.yml 'x/app:latest' build
overlay laterbuild docker-compose.e2e.yml app 'x/app:latest'
printf 'services:\n  app:\n    build:\n      context: ./docker/app\n' \
    >"${WORK}/laterbuild/docker-compose.ci.yml"
gate_script laterbuild check.sh 'docker compose -f docker-compose.e2e.yml -f docker-compose.ci.yml up -d'
run laterbuild
matches 'case 53: a build: from the later file of a set is credited to the set' "${OUT}" \
    'docker-compose\.e2e\.yml \+ docker-compose\.ci\.yml \(scripts/check\.sh:1, -f\) builds x/app:latest'
matches 'case 53: so the run builds the tag rather than merely running it' "${OUT}" \
    'FAIL .*: the gate run at scripts/check\.sh:1 builds image tag x/app:latest, which production is recreated from'
equals  'case 53: exit code' "${RC}" 1

# --- 54. two calls over one set -> the finding names the one that can build ----
service whichcall docker-compose.yml 'x/app:latest' build
gate_script whichcall check.sh 'docker compose -f docker-compose.yml exec -T app php artisan test
docker compose -f docker-compose.yml up -d app'
run whichcall
matches 'case 54: the finding names the call that can build the set' "${OUT}" \
    'FAIL .*: the gate run at scripts/check\.sh:2 builds image tag x/app:latest'
matches 'case 54: and quotes that call, not the one beside it' "${OUT}" \
    'gate run: +docker compose up over docker-compose\.yml \(-f\)$'
equals  'case 54: exit code' "${RC}" 1

# --- 55. -f=value names a file the way -f value does -> FAIL ------------------
service feqval docker-compose.yml 'x/app:latest' build
gate_script feqval check.sh 'docker compose -f=docker-compose.yml up -d'
run feqval
matches 'case 55: -f=value is read as a file name' "${OUT}" \
    'FAIL .*: the gate run at scripts/check\.sh:1 builds image tag x/app:latest'
equals  'case 55: exit code' "${RC}" 1

# --- 56. -f in another directory is not the file of the same name here --------
service subdirf docker-compose.yml 'x/app:latest' build
gate_script subdirf check.sh 'docker compose -f infra/docker-compose.yml up -d'
run subdirf
matches 'case 56: a -f under another directory is named, not resolved here' "${OUT}" \
    'unread -f values: +infra/docker-compose\.yml \(not beside this root\) in scripts/check\.sh:1$'
matches 'case 56: and the root is not passed on it either' "${OUT}" \
    '^FAIL .*: 1 compose call\(s\) here name files this check could not read, so what they build is not judged$'
equals  'case 56: exit code' "${RC}" 1

# --- 57. a -f wrapper defined differently in two branches -> not one file set --
service wrapbranch docker-compose.yml 'x/app:latest' build
overlay wrapbranch docker-compose.ci.yml app 'x/app:ci'
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script wrapbranch check.sh 'if [ -n "${FAST:-}" ]; then
  DC=(docker compose -f docker-compose.yml)
else
  DC=(docker compose -f docker-compose.yml -f docker-compose.ci.yml)
fi
"${DC[@]}" up -d app'
run wrapbranch
matches 'case 57: a wrapper with two possible file sets is not read as the last one' "${OUT}" \
    'unread -f values: +DC \(more than one file set is possible above this line\) in scripts/check\.sh:6$'
lacks   'case 57: so the safe branch does not clear the root' "${OUT}" '^ok '
equals  'case 57: exit code' "${RC}" 1

# --- 58. -f under a directory only the environment names -> not a name match ---
service vardirf docker-compose.yml 'x/app:latest' build
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script vardirf check.sh 'docker compose -f "$SHARED/docker-compose.yml" up -d'
run vardirf
# shellcheck disable=SC2016  # the expected text quotes the fixture's own $SHARED
matches 'case 58: a -f under an unknown directory is named, not matched by basename' "${OUT}" \
    'unread -f values: +"\$SHARED/docker-compose\.yml" \(under a directory only the environment names\) in scripts/check\.sh:1$'
lacks   'case 58: and the file of that name here is not judged in its place' "${OUT}" 'builds x/app:latest'
equals  'case 58: exit code' "${RC}" 1

# --- 59. a source written as $(dirname "$0")/lib.sh is followed ---------------
service srcdyn docker-compose.yml 'x/app:latest' build
gate_script srcdyn lib.sh 'export COMPOSE_FILE=docker-compose.yml'
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script srcdyn check.sh '. "$(dirname "$0")/lib.sh"
docker compose up -d'
run srcdyn
matches 'case 59: a source naming the script own directory is resolved' "${OUT}" \
    'gate runs: +docker-compose\.yml \(scripts/check\.sh:2, COMPOSE_FILE\) builds x/app:latest$'
equals  'case 59: exit code' "${RC}" 1

# --- 59b. the same source, unreadable -> the whole argument is named ----------
service srcdyngone docker-compose.yml 'x/app:latest' build
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script srcdyngone check.sh '. "$(dirname "$0")/missing-lib.sh"
docker compose up -d'
run srcdyngone
# shellcheck disable=SC2016  # the expected text quotes the fixture's own $(dirname "$0")
matches 'case 59b: the message carries the whole source argument' "${OUT}" \
    'COMPOSE_FILE, which \$\(dirname \$0\)/missing-lib\.sh \(sourced at line 1\) may set in scripts/check\.sh:2$'
equals  'case 59b: exit code' "${RC}" 1

# --- 60. COMPOSE_FILE set two sources deep -> still the file set --------------
service srcnest docker-compose.yml 'x/app:latest' build
gate_script srcnest inner.sh 'export COMPOSE_FILE=docker-compose.yml'
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script srcnest outer.sh '. "$(dirname "$0")/inner.sh"'
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script srcnest check.sh '. "$(dirname "$0")/outer.sh"
docker compose up -d'
run srcnest
matches 'case 60: a chain of sources is followed, not read as compose default' "${OUT}" \
    'gate runs: +docker-compose\.yml \(scripts/check\.sh:2, COMPOSE_FILE\) builds x/app:latest$'
equals  'case 60: exit code' "${RC}" 1

# --- 61. a call that cannot build -> the finding says it runs the tag ---------
service execonly docker-compose.yml 'x/app:latest' build
gate_script execonly check.sh 'docker compose exec -T app php artisan test'
run execonly
matches 'case 61: a call with no build in it runs the tag' "${OUT}" \
    'FAIL .*: the gate run at scripts/check\.sh:1 runs image tag x/app:latest, which production is recreated from$'
lacks   'case 61: and is never reported as building it' "${OUT}" 'scripts/check\.sh:1 builds image tag'
equals  'case 61: exit code' "${RC}" 1

# --- 62. a call continued over nine lines -> its subcommand is still read -----
service longcall docker-compose.yml 'x/app:latest' build
gate_script longcall check.sh 'docker compose \
  -f docker-compose.yml \
  --ansi never \
  --progress plain \
  -p acme \
  --project-directory . \
  --env-file .env \
  --parallel 2 \
  --profile ci \
  up -d app'
run longcall
matches 'case 62: the subcommand past the eighth continuation is read' "${OUT}" \
    'gate run: +docker compose up over docker-compose\.yml \(-f\)$'
lacks   'case 62: and the \ that joined the lines is not the subcommand' "${OUT}" 'docker compose \\ over'
equals  'case 62: exit code' "${RC}" 1

# --- 62b. the same call ending in an idle subcommand -> named, and passes -----
service longidle docker-compose.yml 'x/app:latest' build
gate_script longidle check.sh 'docker compose \
  -f docker-compose.yml \
  --ansi never \
  --progress plain \
  -p acme \
  --project-directory . \
  --env-file .env \
  --parallel 2 \
  --profile ci \
  config --services'
run longidle
matches 'case 62b: the subcommand it really runs is the one reported' "${OUT}" \
    'gate runs: +docker-compose\.yml \(scripts/check\.sh:1, -f\) config builds nothing$'
equals  'case 62b: exit code' "${RC}" 0

# --- 63. a compose line inside a heredoc body is not a call -------------------
service hdoc docker-compose.yml 'x/app:latest' build
gate_script hdoc check.sh 'cat <<EOF
docker compose -f docker-compose.yml up -d app
EOF'
run hdoc
lacks   'case 63: a heredoc body is not a line naming a call' "${OUT}" 'unjudged calls'
matches 'case 63: and the root passes on what is really run' "${OUT}" '^ok '
equals  'case 63: exit code' "${RC}" 0

# --- 64. a wrapper consumed by a later call -> judged once, where it is used --
service arrwrap docker-compose.yml 'x/app:latest' build
overlay arrwrap docker-compose.ci.yml app 'x/app:ci'
# shellcheck disable=SC2016  # the fixture is a script, not this one's expansion
gate_script arrwrap check.sh 'DC=(docker compose -f docker-compose.yml)
"${DC[@]}" -f docker-compose.ci.yml up -d app'
run arrwrap
matches 'case 64: the set is judged at the line that uses the wrapper' "${OUT}" \
    'gate runs: +docker-compose\.yml \+ docker-compose\.ci\.yml \(scripts/check\.sh:2, -f\) builds x/app:ci$'
lacks   'case 64: and the line that only defines it is not a run of its own' "${OUT}" 'scripts/check\.sh:1'
equals  'case 64: exit code' "${RC}" 0

if [ "${fails}" -eq 0 ]; then
    printf 'gate-image-tags-test: all checks passed\n'
    exit 0
fi
printf 'gate-image-tags-test: %d check(s) failed\n' "${fails}" >&2
exit 1
