# fleet-deploy-lib 2026-10-18 sha256:90d9fc4546e7b5d45ee0f4184ed51d988cec8571b794012740bcb42b713ab566
# shellcheck shell=bash
# A test's HOME, in the one form the hook-bypass scan lets through: HOME="$(guarded_home)". docs/DECISIONS.md (card 540)

_guarded_home_refuse() {
    printf 'guarded_home refused: %s\n' "$1" >&2
    printf '/proc/guarded-home-refused\n'
}

# Prints a fresh empty mktemp dir (mode 700, the caller's own) under GUARDED_HOME_PARENT, else TMPDIR, else /tmp.
# A refusal returns 1 and prints a HOME under /proc, where no git config can exist or be made.
guarded_home() {
    local d n
    d="$(mktemp -d -p "${GUARDED_HOME_PARENT:-${TMPDIR:-/tmp}}" guarded-home.XXXXXXXX)" || { _guarded_home_refuse 'mktemp could not make a directory'; return 1; }
    [ "$(stat -c '%F %u %a' -- "${d}" 2>/dev/null)" = "directory $(id -u) 700" ] || { _guarded_home_refuse "${d} is not a plain directory of mode 700 owned by uid $(id -u)"; return 1; }
    n="$(find "${d}" -mindepth 1 -print -quit)" || { _guarded_home_refuse "find could not list ${d}"; return 1; }
    [ -z "${n}" ] || { _guarded_home_refuse "${d} is not empty: it holds ${n}"; return 1; }
    printf '%s\n' "${d}"
}
