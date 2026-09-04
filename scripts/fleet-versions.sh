#!/usr/bin/env bash
# Fleet-level standards check — ROLLOUT.md step 5, the piece no project gate can do.
#
# Each project's drift test compares docs/STANDARDS.md against ITS OWN header, so
# a project that never updates passes its own test forever. This compares every
# project against the CANONICAL clone, which is the only comparison that can
# notice staleness. A project with no vendored copy is a FAILURE, not a skip —
# otherwise "never adopted" is indistinguishable from "clean". For the same
# reason, checking zero projects is an error, never a pass.
#
#   fleet-versions.sh              report; exit 1 if anything needs attention
#   fleet-versions.sh --quiet|-q   exit code only (usage/canonical errors still go to stderr)
#
# Exit: 0 all projects on the canonical version · 1 one or more need attention ·
#       2 usage error, canonical clone unreadable/invalid, or no projects to check.
#
# The defaults below describe one host's layout; every one of them is overridable
# by environment variable, so the script is not tied to that machine.
#
# Env: STANDARDS_CANONICAL (default /srv/engineering-standards), STANDARDS_ROOT
# (default /var/www), STANDARDS_PROJECTS (space-separated; default = the projects
# listed below; set but empty is an error, not the default).

set -uo pipefail
set -f   # the project list is split on whitespace, never glob-expanded

CANON=${STANDARDS_CANONICAL:-/srv/engineering-standards}
ROOT=${STANDARDS_ROOT:-/var/www}
DEFAULT_PROJECTS="memento orbit health-tracker kidsquest ghiecode ghie-writes reflection scribly pig-dice-game"
LINK_TARGET='../../docs/STANDARDS.md'   # what every project commits, byte-for-byte (#56)

QUIET=0
case "${1:-}" in
    "")            ;;
    --quiet|-q)    QUIET=1 ;;
    *) echo "usage: fleet-versions.sh [--quiet|-q]" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "usage: fleet-versions.sh [--quiet|-q]" >&2; exit 2; }

say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
die()  { echo "fleet-versions: $*" >&2; exit 2; }

# --- canonical ---------------------------------------------------------------
canon_file=$CANON/ENGINEERING-STANDARDS.md
canon_vfile=$CANON/VERSION
[ -r "$canon_file"  ] || die "canonical file unreadable: $canon_file"
[ -r "$canon_vfile" ] || die "canonical VERSION unreadable: $canon_vfile"
canon_version=""   # `read` leaves it unset on a zero-byte file, which set -u would then trip on
read -r canon_version < "$canon_vfile" || true
canon_version=${canon_version#"${canon_version%%[![:space:]]*}"}   # trim leading
canon_version=${canon_version%"${canon_version##*[![:space:]]}"}   # trim trailing
[[ $canon_version =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "canonical VERSION is not a date: '$canon_version'"
canon_hash=$(sha256sum "$canon_file" | cut -d' ' -f1)

# Say what the report was measured against: a forgotten `git pull` in the canonical
# clone would otherwise make a superseded fleet read as clean. Read-only git only:
# plain `git status` refreshes .git/index as a side effect, and this clone is
# what every session on the box loads — --no-optional-locks keeps it untouched.
canon_head=$(git -C "$CANON" rev-parse --short HEAD 2>/dev/null || echo '?')
canon_dirty=$(git -C "$CANON" --no-optional-locks status --porcelain --untracked-files=no 2>/dev/null | grep -c . || true)

dirty_note=""
[ "${canon_dirty:-0}" -gt 0 ] && dirty_note=" ($canon_dirty uncommitted change(s) in the canonical clone — report may not reflect origin)"
say "canonical: version=$canon_version sha256=${canon_hash:0:16}… head=$canon_head$dirty_note"
say ""

# --- project list ------------------------------------------------------------
if [ "${STANDARDS_PROJECTS+x}" = x ]; then list=$STANDARDS_PROJECTS; else list=$DEFAULT_PROJECTS; fi
read -r -a projects <<<"$list"
[ "${#projects[@]}" -gt 0 ] || die "no projects to check (STANDARDS_PROJECTS is empty) — refusing to report a clean fleet"

# --- per project -------------------------------------------------------------
bad=0; checked=0
for p in "${projects[@]}"; do
    checked=$((checked+1))
    f=$ROOT/$p/docs/STANDARDS.md
    link=$ROOT/$p/.claude/rules/standards.md
    content=ok; cwhy=""; linkst=ok; lwhy=""

    if [ ! -e "$f" ]; then
        content=MISSING; cwhy="no docs/STANDARDS.md — not adopted"
    elif [ ! -r "$f" ]; then
        content=UNREADABLE; cwhy="docs/STANDARDS.md exists but is not readable by $(id -un)"
    else
        header=$(head -n1 "$f" 2>/dev/null)
        if [[ ! $header =~ ^\<!--\ standards-version:\ ([^[:space:]]+)\ ·\ sha256:\ ([0-9a-f]{64})\ --\>$ ]]; then
            content=BADHEADER; cwhy="first line is not the standards header"
        else
            declared_version=${BASH_REMATCH[1]}
            declared_hash=${BASH_REMATCH[2]}
            # The header declares the hash of the BODY (everything after line 1),
            # and the body must be byte-identical to the canonical file.
            body_hash=$(tail -n +2 "$f" | sha256sum | cut -d' ' -f1)
            if [ "$body_hash" != "$declared_hash" ]; then
                content=DRIFTED;  cwhy="body does not match its own header (local edit; the project's own drift test fails too)"
            elif [ "$body_hash" != "$canon_hash" ]; then
                if [ "$declared_version" = "$canon_version" ]; then
                    # Self-consistent, claims the current version, yet differs from
                    # canonical: a local edit re-stamped to pass its own gate. Only
                    # this check can see it; do not call it stale.
                    content=DIVERGED; cwhy="claims $declared_version but body differs from canonical — local edit re-stamped? re-vendor from the canonical repo"
                else
                    content=STALE;    cwhy="declared $declared_version, canonical $canon_version"
                fi
            elif [ "$declared_version" != "$canon_version" ]; then
                content=VERSION;  cwhy="body current but header says $declared_version, canonical $canon_version"
            fi
        fi
    fi

    # Symlink is checked independently of content, so both problems show in one pass.
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
        linkst=NOLINK;  lwhy=".claude/rules/standards.md is absent"
    elif [ ! -L "$link" ]; then
        linkst=NOLINK;  lwhy=".claude/rules/standards.md is a regular file, not a symlink"
    else
        target=$(readlink "$link")
        if [ "$target" != "$LINK_TARGET" ]; then
            # #56's drift test asserts the literal relative target; an absolute or
            # chained link passes here only if we are looser than the project gate.
            linkst=BADLINK; lwhy="symlink target is '$target', must be '$LINK_TARGET'"
        elif [ "$(readlink -f "$link")" != "$(readlink -f "$f")" ]; then
            linkst=BADLINK; lwhy="symlink does not resolve to docs/STANDARDS.md"
        fi
    fi

    if [ "$content" = ok ] && [ "$linkst" = ok ]; then
        say "  ok         $p  ($declared_version)"
    else
        st=$content; why=$cwhy
        if [ "$content" = ok ]; then st=$linkst; why=$lwhy
        elif [ "$linkst" != ok ]; then why="$cwhy; also: $lwhy"; fi
        say "  $(printf '%-10s' "$st") $p  ($why)"
        bad=$((bad+1))
    fi
done

say ""
if [ "$bad" -eq 0 ]; then say "fleet: all $checked project(s) on $canon_version"; exit 0; fi
say "fleet: $bad of $checked project(s) need attention"; exit 1
