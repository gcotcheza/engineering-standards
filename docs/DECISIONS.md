# Decisions

Why this repository is shaped the way it is, where the reason is too long for a
comment (C5) and too easy to lose (W7). One entry per decision, newest last; the
code carries a one-line pointer here, never the argument itself.

## What the fleet check calls a deploy-lib copy, and what it calls a project (2026-09-20)

**Three words for a vendored deploy library, not one.** The row used to compare bytes and say
DRIFTED for every difference, so the day the canonical library moved on, ten projects were told
they carried a local edit nobody had made and each one went looking for it. The vendored
`# fleet-deploy-lib <ver> sha256:<h>` header is now read before the bytes are compared, and the
three answers are genuinely different repairs. **DRIFTED** — the body disagrees with its own
header — is a local edit, and the project's own gate fails too. **STALE** — the header version
sorts *before* the canonical — is not a fault at all: re-vendor on the next deploy-lib bump and
it clears. **DIVERGED** is everything else that differs: the same version with different bytes
(a local edit re-stamped to pass its own gate, which only this fleet-wide comparison can see),
or a version sorting *after* the canonical, which is not the project's problem at all — it means
the clone the report was measured against is unpulled, and the row says so rather than blaming
the project for being behind something that is itself behind. A file that is simply absent is
**MISSING** and says so; it is not byte-compared, so it must not claim it was.

**An unlisted repository is attention, and its row shouts.** `DEFAULT_PROJECTS` is the contract —
the list is what "the fleet" means — but a hardcoded list cannot notice a project that joins the
box and never joins the check, which is exactly how a project goes unchecked for months. The
check now names any directory under `$ROOT` that holds a `.git` and is not on the list. It gets a
full ALL-CAPS row of its own, in the shape every other row has, rather than a tidy lowercase
summary line: the watchdog reads this output only through `^\s+[A-Z]+\s` (`vps-health-check.sh`
:806), and on exit 1 with no such line it reports *"exit 1 but no parsable project lines — output
format changed?"* (:814). A lowercase line would therefore have converted the one real finding
into a complaint about the format. Lowercase is for rows that are *not* attention (`ok`, `none`);
this one is. Each unlisted project is added to both sides of the `N of M` summary, so the
numerator can never exceed its denominator — the defect this same change fixed.

**`*-staging` and `*-worktrees` are excluded by name, on purpose.** `ghie-writes-staging` and
`health-tracker-staging` are real repositories on this box and they are deliberately not fleet
projects: staging is where a project's own change is tried, it is not a thing the standard is
vendored into, and a worktree is a second checkout of a repository already on the list. Counting
either would put a permanent two-line complaint on a clean report, which is how a check stops
being read. The exclusion is by suffix rather than by a second list because the suffix is the
convention the box already follows; if that ever stops being true, the fix is a named exclusion
list, not a looser pattern.

## The ledger is asked about the merge commit, not the branch head (2026-09-20)
A merge commit that is not a fast-forward has a tree of its own, and that tree is what a deploy
puts live; the branch head's green gate says nothing about it. The old `resolve()` refused that
case outright, which made every PR merged after `main` had moved undeployable. `resolve()` now
names the commit that deploys in `GATE_SHA` and `gated()` asks the ledger about that one, so the
gate covers what ships. `ledger.sh` keeps a `${GATE_SHA-$HEAD_SHA}` default on purpose: a
project vendors these files one at a time, and a half-vendored pair must degrade to the old
behaviour rather than die on `set -u`. The colon is deliberately absent, and putting it back
would be a fail-open: a caller that initialises `GATE_SHA=''` for `set -u` and then skips or
abandons `resolve` would silently be gated on the branch head, which is the squash-and-rebase
case the whole change exists for. Unset falls back to the head; set-but-empty still refuses.

## The gate refuses a missing shellcheck image rather than skipping the step

A linter that is not installed produces no findings, which reads exactly like a
clean run. The step therefore fails loudly when the pinned image is absent (C9),
and the image is pinned by digest-bearing tag so the same input gives the same
verdict tomorrow (S5).

## `--only N` records nothing to the fleet gate ledger

The ledger answers "did this branch pass its gate?". A single step passing is not
an answer to that question, so a partial run is deliberately invisible to it —
otherwise debugging one step would leave a green mark nobody meant.

## `scripts/lib/deploy/` is read-only to the gate

The deploy library is vendored here and consumed by projects. The gate sources its
ledger helper and runs its tests; it never writes under that directory, so a gate
run can never be what changed the library a project is about to install.

## The gate's step order is a measurement, not a guess (2026-09-19)

T3 asks for the cheapest checks first, and this gate did not obey its own rule: the slowest
step ran third and four cheaper ones followed it. The steps were timed individually and
renumbered in that order:

| step | check | seconds |
|---|---|---|
| 1 | `bash -n` | 0.03 |
| 2 | `fleet-versions-test.sh` | 0.30 |
| 3 | `gate-image-tags-test.sh` | 0.32 |
| 4 | `fleet-budget-test.sh` | 1.27 |
| 5 | shellcheck | 1.75 |
| 6 | `queue-start-test.sh` | 2.08 |
| 7 | `scripts/lib/deploy/test.sh` | 4.74 |

Steps 4 and 5 are within run-to-run noise of each other and swapped places on one of the
review's repetitions; their order carries no meaning. The gaps that do are 1 ≪ 2,3 < {4,5} <
6 < 7. Re-measure before reordering again — these numbers rot as the tests grow.

## Three rules describe the check that happens, not the one we wish happened (2026-09-19)

- **C10** names PHPStan and ESLint and what each does not reach, rather than crediting
  "static analysis" with finding dead code most of it cannot see. Wiring an unused-public
  extension is the better fix where a project can afford it; until it is wired, the rule is
  checked by review and says so.
- **S6** recognises two shapes: a gate that refuses to run in a deployed checkout, and a gate
  that isolates its writes from one because it runs in overlay mode. Both are legitimate, and
  a project's `CLAUDE.md` must say in words which one it is — the rule was written as though
  only the first existed, so a project doing the right thing read as non-compliant.
- **C7** names the tool, not a project: this repository is public.

## VERSION is a date, plus a serial when a day carries more than one change (2026-09-19)

Two changes landed on 2026-09-19, and a date alone cannot tell them apart: a project
that vendored the text between them would declare the current version with a body that
differs from canonical, which `scripts/fleet-versions.sh` reports as DIVERGED — "local
edit re-stamped?" — accusing an honest adopter. VERSION therefore takes a `.N` suffix
from the second change of a day onward (`2026-09-19.2`). The header regex already
accepts any non-space token, so nothing else changes.

## S7 is checked by review today, and by two tools that do not exist yet (2026-09-19)

The rule arrived from a near miss: a `docker volume prune --all` handed to the owner to
type would have removed a stopped stack's named volume along with 56 unnamed ones,
because Docker counts a stopped stack's named volume as dangling. A dry run caught it.

Two mechanical halves are owed and are **not** credited in the rule until they run: the
fleet backlog's lint refusing an item whose code block carries a destructive line with no
preview line before it, and the same check over the deploy runbooks in `.claude/commands/`.
Crediting a check that does not exist is the failure the 2026-09-19 entry in `CHANGELOG.md`
records removing from three other rules; the clause will name these once they run.

## Every change to the standards body must move VERSION (2026-09-19)

The serial replaces one invariant with another. "One change per day" used to be enforced by
the date itself; "every change to the body moves VERSION" is enforced by nobody. If a body
change lands without a bump, a project that vendors the new text declares the current version
with a body that matches canonical — reported `ok` — while another project on the *previous*
body also declares that version and is reported DIVERGED, accused of a local edit it never
made. Until a gate step compares `ENGINEERING-STANDARDS.md` against `origin/main` and fails
when VERSION has not moved, this is checked by review of every PR that touches the body.

## The PR-title rule lives inside W4, not in a rule of its own (2026-09-20)

W4 governs what the person deciding to merge reads. The title and the four
headings are one object to that reader, and a standalone W10 would put half the
guidance where someone reading the other half would never meet it. The document
already carries compound rules joined by "and" (S7, T9), so the shape is not new.

The rule's own check is a repair, not a detection: a reviewer notices a
problem-statement title and runs `gh pr edit`. The mechanical half that is owed
is a title lint — a verb first: *Add*, *Added*, *Fix*, *Fixed*, … — in the shape
of `scripts/backlog-owners-lint.py`. Until that exists the rule is held by review,
and this entry is where that is admitted rather than left unsaid.

**Why this change carries no test (T4).** The bug it fixes is a PR whose title
promised a rule its diff did not contain, and nothing caught it. What would have
caught it is the gate step already owed above — compare the body against
`origin/main` — not a test of this repository's own text. The read-back that did
catch it is a human reading the merged file, which is W9 working as intended.

**What the rule is not.** The first release (VERSION 2026-09-20) had added "past-tense" and "no file
names" on its own. Ghie, reviewing it on 2026-09-20: a file name in the
title is fine when the change is one file, and the tense is not the rule — *Fix the
flicker* is as good as *Added caching*. The rule is that the title is the action.


## A build with no `image:` key still has a tag (2026-09-25)

**What the check could not see.** `scripts/gate-image-tags.sh` compared `image:`
keys, and two of this box's projects build every production service without one.
Compose does not leave those untagged: it tags them `<project>-<service>`, and
`docker ps` on this box shows `scribly-symfony` and `reflection-symfony` running
from exactly such a tag. So the check read those projects as *"no built image tag
resolved here — nothing a gate run could overwrite"*, which is the silent pass
dcc8376 set out to remove, arriving by a different door. A gate compose file
holding `image: scribly-symfony` beside a build was called clean while production
ran that tag; so was a gate file that named no tag either, because both sides'
implicit tags are the same string. The check now resolves the implicit tag on both
sides and compares it like a written one.

**Where the project name comes from.** The file's own top-level `name:` if it has
one, else the directory basename lower-cased with everything outside `[a-z0-9_-]`
dropped and leading `-_` trimmed, which is what compose-go's project-name
normalisation does. It is read per file on purpose: these compose files carry
`name:` per file (`memento`, `memento-e2e`, `memento-staging`), and it is that
name — not the one a `-p` flag might carry at run time — that the file itself
claims. A gate run that passes `-p something-else` builds a different tag and this
check will not know; that is a limit of reading files rather than processes, and it
is why the gate side is compared on the value in the file.

**An inherited `image:` is an image.** A service merging `<<: *app` where the
anchor carries `image:` has one, so it gets no implicit tag — Fineprint's three
production services are that shape, and inventing `fineprint-app` for them would
have been a tag nothing builds. Where the merged anchor is not defined in the
file, the tag is *unresolved* and named as such rather than guessed: loud beats
quiet, and a guess here would print a FAIL naming a tag that may not exist.
`extends:` is treated as a build, as it already was for `image:` lines, but it no
longer earns an implicit tag. The extended service usually carries an `image:`
this check does not follow, and inventing `<project>-<service>` printed a tag
nothing builds: on a file whose `worker` extends an `app` with `image:
myapp/api:prod`, real `docker compose config --images` answers `myapp/api:prod`.
A service that extends and names no `image:` of its own is now *unresolved* and
named, like the unknown anchor above. The residue is the opposite direction: where
the extended service builds and names no image anywhere, compose does tag it
`<project>-<service>`, and this check says it could not tell rather than saying so.

**A `name:` on one file is the project of the file beside it.** Compose takes one
project name per invocation, so `-f docker-compose.yml -f docker-compose.ci.yml`
with the name on the base alone builds the overlay's services under the base's
name: a base declaring `name: chosen` beside a nameless overlay gives `chosen-app`
for both, not `<directory>-app`. A file that declares no `name:` of its own is
therefore compared under the names declared beside it *and* the directory, and a
collision on any of them is a finding. `COMPOSE_PROJECT_NAME` and `-p` stay
residue: they are set at run time, not in the file, so a run that passes one builds
a tag this check cannot know — the same limit as reading files rather than processes.

**A body it cannot read is not a pass.** `symfony: {build: ./docker/app, image:
flowproj-symfony}` and `"image": 'demo/app:ci'` are valid compose and invisible to
line regexes; both read as "no image here", which is the silent pass arriving by a
third door. A service whose own line carries a `{` outside a `${…}` default, or whose
`build`/`image`/`extends` key carries one or is written in a form these regexes do
not match, is reported *unresolved*: the flow map is refused, not parsed. A `{` on
any other key is not one — `healthcheck: {test: […]}` is ordinary compose, and
hiding a whole service behind it cost the check the collision it was there to see.
A value that comes back still holding flow punctuation (`p4-app }`, out of a
multi-line `app: {` body) is unresolved for the same reason: a mangled tag compared
as if it were real is worse than a named gap. `build.tags` entries
are read as built tags in the same pass — that is a tag the build writes even when
`image:` beside it names a throwaway one.

**A gate-only `name:` is not production's project (2026-09-25).** Every name
declared in the directory used to be a candidate for every file in it, so a gate
file's `name: p8-ci` beside a nameless `docker-compose.yml` made `p8-ci-app` a
production tag too, and the check failed on a collision with a project name
production is never run under. The names offered to a file that declares none of
its own are now the ones the *production* files declare, plus the directory; a gate
file gets the gate side's names as well, because a name on the base really is the
name a nameless overlay is built under. `COMPOSE_PROJECT_NAME` and `-p` stay
residue either way: set at run time, they are invisible to a check that reads files.

**A quoted `"services":` is still the services key (2026-09-25).** The top-level key
was matched as `^services *:`, so `"services":` — valid YAML, and what a
JSON-flavoured compose file writes — was never found: the service walk never ran,
a gate file whose service builds with no `image:` contributed no tag, and the
verdict was `built tags: 0` on a file that builds. The key is now dequoted like any
other mapping key. When no top-level `services:` is found at all and the file still
carries an `image`/`build` key, that is reported *unresolved* rather than read as an
empty file, because "nothing is built here" and "I could not find the services"
must not look alike.

**Why `unrecognised:` still exits 0 unless it builds.** A compose file named
outside `*ci*`/`*e2e*`/`*prod*` is read as production on its filename alone. Failing
closed on that name was the recommendation, and it is not what this change does:
Fineprint's `docker-compose.realip.yml` is a genuine production-side proof stack
whose name says neither, and an unconditional refusal would have turned a green
project red for a file that builds nothing. The narrower rule is the one that
matters — an unrecognised file that **builds** a tag now fails, because that is the
file whose side decides whether a real collision is reported. A non-building
unrecognised file can still hide the case-6 finding (a gate that only *runs*
production's tag), and that residue is named in `ROLLOUT.md` rather than left
unsaid.
