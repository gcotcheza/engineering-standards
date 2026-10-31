#!/usr/bin/env bash
# Fleet-level standards check — ROLLOUT.md step 5, the piece no project gate can do.
#
# Each project's drift test compares docs/STANDARDS.md against ITS OWN header, so
# a project that never updates passes its own test forever. This compares every
# project against the CANONICAL clone, which is the only comparison that can
# notice staleness. Checking zero projects is an error, never a pass, or "the
# registry is gone" would be indistinguishable from "clean".
#
#   fleet-versions.sh              report; exit 1 if anything needs attention
#   fleet-versions.sh --quiet|-q   exit code only (usage/canonical errors still go to stderr)
#
# Exit: 0 all projects on the canonical version · 1 one or more need attention,
#       including a repository under ROOT that is not listed ·
#       2 usage error, canonical clone or registry unreadable/invalid, or no projects to check.
#
# The projects are the first column of the app-owners registry. A checkout with no
# STANDARDS.md copy and no link reads `retired`, not a failure; one that kept the
# link reads HALFRETIRED. A deploy lib that is not vendored reads `shared` when the
# app's gate pins the canonical clone's. decision: fleet-versions-reads-app-owners
#
# Env: STANDARDS_CANONICAL (default /srv/engineering-standards), STANDARDS_ROOT
# (default /var/www), STANDARDS_APP_OWNERS (default /etc/fleet/app-owners),
# STANDARDS_PROJECTS (space-separated; default = the registry; set but empty is an
# error, not the default).

set -uo pipefail
set -f   # defence in depth: nothing here is pathname-expanded

CANON=${STANDARDS_CANONICAL:-/srv/engineering-standards}
ROOT=${STANDARDS_ROOT:-/var/www}
APP_OWNERS=${STANDARDS_APP_OWNERS:-/etc/fleet/app-owners}
LINK_TARGET='../../docs/STANDARDS.md'   # what every project commits, byte-for-byte (#56)
LIB_FILES="ledger resolve preflight summary"   # scripts/lib/deploy/*.sh, the vendored deploy library
LIB_MARKER=scripts/lib/deploy/VERSION

QUIET=0
case "${1:-}" in
    "")            ;;
    --quiet|-q)    QUIET=1 ;;
    *) echo "usage: fleet-versions.sh [--quiet|-q]" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "usage: fleet-versions.sh [--quiet|-q]" >&2; exit 2; }

say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
die()  { echo "fleet-versions: $*" >&2; exit 2; }

# A deployed checkout or a worktree pool mirrors a project's files; it is not one.
is_fleet_project_name() { case "$1" in *-staging|*-worktrees) return 1 ;; esac; }

# --- canonical ---------------------------------------------------------------
canon_file=$CANON/ENGINEERING-STANDARDS.md
canon_vfile=$CANON/VERSION
[ -r "$canon_file"  ] || die "canonical file unreadable: $canon_file"
[ -r "$canon_vfile" ] || die "canonical VERSION unreadable: $canon_vfile"
canon_version=""   # `read` leaves it unset on a zero-byte file, which set -u would then trip on
read -r canon_version < "$canon_vfile" || true
canon_version=${canon_version#"${canon_version%%[![:space:]]*}"}   # trim leading
canon_version=${canon_version%"${canon_version##*[![:space:]]}"}   # trim trailing
# A date, plus .N from the second change of a day onward (see the canonical docs/DECISIONS.md).
[[ $canon_version =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(\.[0-9]+)?$ ]] || die "canonical VERSION is not a date: '$canon_version'"
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

# --- canonical deploy library --------------------------------------------------
# Same idea as the docs comparison above, for scripts/lib/deploy/: the vendored
# header is read first. Which of the three words a row gets: docs/DECISIONS.md.
canon_lib=$CANON/scripts/lib/deploy
canon_lib_vfile=$canon_lib/VERSION
[ -d "$canon_lib"      ] || die "canonical deploy-lib dir unreadable: $canon_lib"
[ -r "$canon_lib_vfile" ] || die "canonical deploy-lib VERSION unreadable: $canon_lib_vfile"
canon_lib_version=""
read -r canon_lib_version < "$canon_lib_vfile" || true
canon_lib_version=${canon_lib_version#"${canon_lib_version%%[![:space:]]*}"}
canon_lib_version=${canon_lib_version%"${canon_lib_version##*[![:space:]]}"}

# --- projects ----------------------------------------------------------------
# Row order is the C collation of the names, never the caller's locale's.
registry_names_c_ordered() {
    local n _
    while read -r n _ || [ -n "$n" ]; do
        case "$n" in ''|'#'*) continue ;; esac
        printf '%s\n' "$n"
    done < "$APP_OWNERS" | LC_ALL=C sort -u
}

projects=()
listed_in=STANDARDS_PROJECTS
if [ "${STANDARDS_PROJECTS+x}" = x ]; then
    # `read -r -a` splits on whitespace and never pathname-expands: an entry is a name.
    read -r -a projects <<<"$STANDARDS_PROJECTS"
    [ "${#projects[@]}" -gt 0 ] || die "no projects to check (STANDARDS_PROJECTS is empty) — refusing to report a clean fleet"
else
    listed_in=$APP_OWNERS
    if [ ! -f "$APP_OWNERS" ] || [ ! -r "$APP_OWNERS" ]; then die "app-owners registry unreadable: $APP_OWNERS — refusing to report a clean fleet"; fi
    while IFS= read -r p; do projects+=("$p"); done < <(registry_names_c_ordered)
    [ "${#projects[@]}" -gt 0 ] || die "no app listed in $APP_OWNERS — refusing to report a clean fleet"
fi

# --- per project -------------------------------------------------------------
bad=0; checked=0; retired=0
for p in "${projects[@]}"; do
    checked=$((checked+1))
    # A project is one unit of attention however many of its rows fail.
    pbad=0
    f=$ROOT/$p/docs/STANDARDS.md
    link=$ROOT/$p/.claude/rules/standards.md
    lmark=$ROOT/$p/$LIB_MARKER
    content=ok; cwhy=""; linkst=ok; lwhy=""

    if [ "$p" = . ] || [ "$p" = .. ] || [[ $p == */* ]]; then
        content=MISSING; cwhy="'$p' is not an app name — a name is never . or .. and has no /"
    elif [ ! -d "$ROOT/$p" ]; then
        content=MISSING; cwhy="no $ROOT/$p directory — listed but not checked out"
    elif [ ! -e "$f" ] && [ ! -e "$link" ] && [ ! -L "$link" ]; then
        if [ -e "$ROOT/$p/.git" ]; then
            content=retired; cwhy="no docs/STANDARDS.md copy — retired (609); the standard loads from the canonical clone"
        else
            content=MISSING; cwhy="$ROOT/$p is not a checkout — no .git, so nothing there could be checked"
        fi
    elif [ ! -e "$f" ]; then
        content=HALFRETIRED; cwhy="no docs/STANDARDS.md copy but .claude/rules/standards.md is still there — remove the link or re-vendor"
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

    if [ "$content" = MISSING ]; then
        say "  MISSING    $p  ($cwhy)"
        pbad=1
    elif [ "$content" = retired ]; then
        say "  retired    $p  ($cwhy)"
        retired=$((retired+1))
    elif [ "$content" = ok ] && [ "$linkst" = ok ]; then
        say "  ok         $p  ($declared_version)"
    else
        st=$content; why=$cwhy
        if [ "$content" = ok ]; then st=$linkst; why=$lwhy
        elif [ "$linkst" != ok ]; then why="$cwhy; also: $lwhy"; fi
        say "  $(printf '%-10s' "$st") $p  ($why)"
        pbad=1
    fi

    if [ "$content" = MISSING ]; then bad=$((bad+pbad)); continue; fi   # no checkout: no deploy-lib row

    # --- deploy-library line ---------------------------------------------------
    # dstatus prints lowercase (none/ok/shared) or uppercase (MISSING/STALE/DRIFTED/
    # DIVERGED/BADHEADER) on purpose: the watchdog's line parser only captures a leading
    # ALL-CAPS word (see check_standards() in vps-health-check.sh), so lowercase
    # is how "nothing to see here" stays invisible to it, exactly like the
    # existing "ok" line above — a capitalised OK/NONE here would misreport as
    # an attention line on every healthy or not-yet-adopted project.
    dsh=$ROOT/$p/scripts/deploy.sh
    ldir=$ROOT/$p/scripts/lib/deploy
    dstatus=none; dwhy="no scripts/deploy.sh — deploy-lib not adopted yet"
    [ -e "$lmark" ] && dwhy="$LIB_MARKER present but no scripts/deploy.sh — the lib is not compared"
    if [ -e "$dsh" ]; then
        if [ ! -d "$ldir" ] && grep -qxF -- "DEPLOY_LIB=$canon_lib" "$ROOT/$p/scripts/lib/gate/deploy-lib.sh" 2>/dev/null; then
            dstatus=shared; dwhy="not vendored; the gate pins $canon_lib, deploy-lib $canon_lib_version"
        elif [ ! -d "$ldir" ]; then
            dstatus=MISSING; dwhy="scripts/deploy.sh present but no scripts/lib/deploy, and scripts/lib/gate/deploy-lib.sh does not pin $canon_lib"
        else
            dstatus=ok
            for lf in $LIB_FILES; do
                lfile=$ldir/$lf.sh
                if [ ! -r "$lfile" ]; then
                    dstatus=MISSING; dwhy="$lf.sh is missing or unreadable"; break
                fi
                dheader=$(head -n1 "$lfile" 2>/dev/null)
                if [[ ! $dheader =~ ^#\ fleet-deploy-lib\ ([0-9]{4}-[0-9]{2}-[0-9]{2}(\.[0-9]+)?)\ sha256:([0-9a-f]{64})$ ]]; then
                    dstatus=BADHEADER; dwhy="$lf.sh header is not the fleet-deploy-lib stamp"; break
                fi
                dver_h=${BASH_REMATCH[1]}
                dbody_hash=$(tail -n +2 "$lfile" | sha256sum | cut -d' ' -f1)
                if [ "$dbody_hash" != "${BASH_REMATCH[3]}" ]; then
                    dstatus=DRIFTED
                    dwhy="$lf.sh differs from canonical byte-for-byte (local edit — body does not match its own header)"
                    break
                fi
                cmp -s "$lfile" "$canon_lib/$lf.sh" 2>/dev/null && continue
                if [[ $dver_h < $canon_lib_version ]]; then
                    dstatus=STALE; dwhy="deploy-lib $dver_h, canonical $canon_lib_version"
                elif [[ $dver_h > $canon_lib_version ]]; then
                    # Ahead of canonical: the clone we measured against is the behind one.
                    dstatus=DIVERGED
                    dwhy="$lf.sh differs from canonical (deploy-lib $dver_h, canonical $canon_lib_version) — canonical clone unpulled?"
                else
                    dstatus=DIVERGED
                    dwhy="claims $dver_h but $lf.sh differs from canonical — local edit re-stamped? re-vendor from the canonical repo"
                fi
                break
            done
            if [ "$dstatus" = ok ]; then
                dver=""
                if [ -r "$ldir/VERSION" ]; then read -r dver < "$ldir/VERSION" || true; fi
                if [ "$dver" != "$canon_lib_version" ]; then
                    dstatus=STALE; dwhy="VERSION is '$dver', canonical is '$canon_lib_version'"
                else
                    dwhy="deploy-lib $canon_lib_version"
                fi
            fi
        fi
    fi
    case "$dstatus" in
        none|ok|shared) ;;
        *) pbad=1 ;;
    esac
    say "  $(printf '%-10s' "$dstatus") $p  ($dwhy)"
    bad=$((bad+pbad))
done

# --- unlisted projects --------------------------------------------------------
# A repository under ROOT that is not listed has joined the fleet without
# joining the check. Row shape and the two exclusions: docs/DECISIONS.md.
unlisted=()
while IFS= read -r d; do
    n=${d##*/}
    is_fleet_project_name "$n" || continue
    [ -d "$d" ] || continue                 # -type l above: a project dir may be a symlink
    [ -e "$d/.git" ] || continue
    for q in "${projects[@]}"; do [ "$q" = "$n" ] && continue 2; done
    unlisted+=("$n")
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) 2>/dev/null | sort)
if [ "${#unlisted[@]}" -gt 0 ]; then
    say ""
    for n in "${unlisted[@]}"; do
        say "  $(printf '%-10s' UNLISTED) $n  (has a .git under $ROOT but is not listed in $listed_in)"
    done
    bad=$((bad+${#unlisted[@]})); checked=$((checked+${#unlisted[@]}))
fi

retired_note=""
[ "$retired" -gt 0 ] && retired_note=" ($retired retired)"
say ""
if [ "$bad" -eq 0 ]; then say "fleet: all $checked project(s) on $canon_version$retired_note"; exit 0; fi
say "fleet: $bad of $checked project(s) need attention$retired_note"; exit 1
