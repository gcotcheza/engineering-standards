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
equals  'case 10: exit code' "${RC}" 0

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

if [ "${fails}" -eq 0 ]; then
    printf 'gate-image-tags-test: all checks passed\n'
    exit 0
fi
printf 'gate-image-tags-test: %d check(s) failed\n' "${fails}" >&2
exit 1
