# fleet-deploy-lib 2026-10-18 sha256:44115a68df9e542571d1aab0ea870eaecec7bdc048d013f61df98f48370992df
# shellcheck shell=bash
# A test's HOME, in the one form the hook-bypass scan lets through: HOME="$(guarded_home)". docs/DECISIONS.md (card 540)
# A refusal appends to GUARDED_HOME_REFUSALS (unset is itself a refusal); a suite ends red unless home_refusals_none returns 0.
# Overridden or unset for one call (env -i too), a refusal goes unrecorded; it still fails safe with the /proc HOME.

_guarded_home_refuse() {
    printf 'guarded_home refused: %s\n' "$1" >&2
    [ -z "${GUARDED_HOME_REFUSALS:-}" ] || printf '%s\n' "$1" >>"${GUARDED_HOME_REFUSALS}"
    printf '/proc/guarded-home-refused\n'
}

# Prints a fresh empty mktemp dir (permission bits 700, the caller's own) under GUARDED_HOME_PARENT, else TMPDIR, else /tmp.
# A refusal returns 1 and prints a HOME under /proc, where no git config can exist or be made.
guarded_home() {
    local d n u a t
    [ -n "${GUARDED_HOME_REFUSALS:-}" ] || { _guarded_home_refuse 'GUARDED_HOME_REFUSALS is not set, so a refusal could pass unseen'; return 1; }
    d="$(mktemp -d -p "${GUARDED_HOME_PARENT:-${TMPDIR:-/tmp}}" guarded-home.XXXXXXXX)" || { _guarded_home_refuse 'mktemp could not make a directory'; return 1; }
    read -r u a t <<<"$(stat -c '%u %a %F' -- "${d}" 2>/dev/null)"
    [ "${t}" = directory ] || { _guarded_home_refuse "${d} is not a plain directory"; return 1; }
    [ "${u}" = "$(id -u)" ] || { _guarded_home_refuse "${d} is not owned by uid $(id -u)"; return 1; }
    [ "$(( 8#${a:-0} & 8#777 ))" -eq 448 ] || { _guarded_home_refuse "${d} does not have permission bits 700"; return 1; }
    n="$(find "${d}" -mindepth 1 -print -quit)" || { _guarded_home_refuse "find could not list ${d}"; return 1; }
    [ -z "${n}" ] || { _guarded_home_refuse "${d} is not empty: it holds ${n}"; return 1; }
    printf '%s\n' "${d}"
}

# Returns 1, listing them, when GUARDED_HOME_REFUSALS is unset or holds a refusal.
home_refusals_none() {
    [ -n "${GUARDED_HOME_REFUSALS:-}" ] || { printf 'GUARDED_HOME_REFUSALS is not set\n' >&2; return 1; }
    [ -s "${GUARDED_HOME_REFUSALS}" ] || return 0
    printf 'guarded_home was refused during this suite:\n' >&2
    cat -- "${GUARDED_HOME_REFUSALS}" >&2
    return 1
}
