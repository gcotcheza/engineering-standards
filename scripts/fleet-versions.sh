#!/usr/bin/env bash
# Fleet-level standards check — ROLLOUT.md step 5, the piece no project gate can do.
#
# Each project's drift test compares docs/STANDARDS.md against ITS OWN header, so
# a project that never updates passes its own test forever. This compares every
# project against the CANONICAL clone, which is the only comparison that can
# notice staleness. A project with no vendored copy is a FAILURE, not a skip —
# otherwise "never adopted" is indistinguishable from "clean".
#
#   fleet-versions.sh            report; exit 1 if anything is stale/missing/drifted
#   fleet-versions.sh --quiet    exit code only
#
# Env: STANDARDS_CANONICAL (default /srv/engineering-standards), STANDARDS_ROOT
# (default /var/www), STANDARDS_PROJECTS (space list; default = the nine in
# ROLLOUT.md).

set -uo pipefail

CANON=${STANDARDS_CANONICAL:-/srv/engineering-standards}
ROOT=${STANDARDS_ROOT:-/var/www}
PROJECTS=${STANDARDS_PROJECTS:-"memento orbit health-tracker kidsquest ghiecode ghie-writes reflection scribly pig-dice-game"}
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

canon_file=$CANON/ENGINEERING-STANDARDS.md
[ -r "$canon_file" ] || { echo "fleet-versions: canonical file unreadable: $canon_file" >&2; exit 2; }
canon_version=$(tr -d '[:space:]' < "$CANON/VERSION" 2>/dev/null)
canon_hash=$(sha256sum "$canon_file" | cut -d' ' -f1)
[ -n "$canon_version" ] || { echo "fleet-versions: $CANON/VERSION is empty or missing" >&2; exit 2; }

say "canonical: version=$canon_version sha256=${canon_hash:0:16}…"
say ""

bad=0
for p in $PROJECTS; do
    f=$ROOT/$p/docs/STANDARDS.md
    link=$ROOT/$p/.claude/rules/standards.md

    if [ ! -f "$f" ]; then
        say "  MISSING   $p  (no docs/STANDARDS.md — not adopted)"; bad=$((bad+1)); continue
    fi

    header=$(head -n1 "$f")
    if [[ ! $header =~ ^\<!--\ standards-version:\ ([^[:space:]]+)\ ·\ sha256:\ ([0-9a-f]{64})\ --\>$ ]]; then
        say "  BADHEADER $p  (first line is not the standards header)"; bad=$((bad+1)); continue
    fi
    declared_version=${BASH_REMATCH[1]}
    declared_hash=${BASH_REMATCH[2]}

    # The header declares the hash of the BODY (everything after line 1), and the
    # body must be byte-identical to the canonical file.
    body_hash=$(tail -n +2 "$f" | sha256sum | cut -d' ' -f1)

    status=ok; why=""
    if [ "$body_hash" != "$declared_hash" ]; then
        status=DRIFTED; why="body does not match its own header (local edit)"
    elif [ "$body_hash" != "$canon_hash" ]; then
        status=STALE;   why="declared $declared_version, canonical $canon_version"
    elif [ "$declared_version" != "$canon_version" ]; then
        status=VERSION; why="body current but header says $declared_version, canonical $canon_version"
    fi

    if [ "$status" = ok ]; then
        if [ ! -L "$link" ]; then
            status=NOLINK; why=".claude/rules/standards.md is not a symlink"
        elif [ "$(readlink -f "$link")" != "$(readlink -f "$f")" ]; then
            status=BADLINK; why="symlink resolves to $(readlink "$link"), not docs/STANDARDS.md"
        fi
    fi

    if [ "$status" = ok ]; then
        say "  ok        $p  ($declared_version)"
    else
        say "  $(printf '%-9s' "$status") $p  ($why)"; bad=$((bad+1))
    fi
done

say ""
if [ "$bad" -eq 0 ]; then say "fleet: all projects on $canon_version"; exit 0; fi
say "fleet: $bad project(s) need attention"; exit 1
