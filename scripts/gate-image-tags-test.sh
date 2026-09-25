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

# --- 7. a directory with no compose file at all -> PASS, and says so ----------
mkdir -p "${WORK}/empty"
run empty
matches 'case 7: no compose file is reported, not passed over' "${OUT}" 'no compose file beside this root — nothing was examined$'
equals  'case 7: exit code' "${RC}" 0

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

if [ "${fails}" -eq 0 ]; then
    printf 'gate-image-tags-test: all checks passed\n'
    exit 0
fi
printf 'gate-image-tags-test: %d check(s) failed\n' "${fails}" >&2
exit 1
