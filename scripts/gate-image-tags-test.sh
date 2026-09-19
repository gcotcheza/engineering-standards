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

# --- 4. no app image at all (bind mounts) -> silent PASS -----------------------
mkdir -p "${WORK}/bindmount"
printf 'services:\n  postgres:\n    image: postgres:16-alpine\n' >"${WORK}/bindmount/docker-compose.yml"
run bindmount
equals 'case 4: a project with no built image says nothing' "${OUT}" ''
equals 'case 4: exit code' "${RC}" 0

# --- 5. ${VAR:?msg} has no default -> nothing to compare, silent PASS ----------
service required docker-compose.e2e.yml "'\${E2E_APP_IMAGE:?set by scripts/e2e.sh}'" build
run required
equals 'case 5: an image with no resolvable value says nothing' "${OUT}" ''
equals 'case 5: exit code' "${RC}" 0

# --- 6. the gate only RUNS the production tag, builds nothing -> FAIL ----------
service runsit docker-compose.e2e.yml 'demo/app:latest'
service runsit docker-compose.yml     'demo/app:latest' build
run runsit
matches 'case 6: running the production tag in the gate fails too' "${OUT}" 'FAIL .*: image tag demo/app:latest is built'
equals  'case 6: exit code' "${RC}" 1

# --- 7. a directory with no compose file at all -> silent PASS -----------------
mkdir -p "${WORK}/empty"
run empty
equals 'case 7: no compose file says nothing' "${OUT}" ''
equals 'case 7: exit code' "${RC}" 0

if [ "${fails}" -eq 0 ]; then
    printf 'gate-image-tags-test: all checks passed\n'
    exit 0
fi
printf 'gate-image-tags-test: %d check(s) failed\n' "${fails}" >&2
exit 1
