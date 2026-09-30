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
Fineprint's real-ip proof stack was then named `docker-compose.realip.yml`, a
genuine production-side stack whose name said neither, and an unconditional
refusal would have turned a green project red for a file that builds nothing.
That example has since moved: Fineprint's PR #92 renamed the file
`docker-compose.ci-realip.yml` and put it on the gate's side, because
`scripts/ci.sh` drives it and it runs the tag that gate builds — the `ci-`
prefix is there so this check reads the side off the name instead of guessing
at it. The example is history; the rule it argues for is not.
The narrower rule is the one that
matters — an unrecognised file that **builds** a tag now fails, because that is the
file whose side decides whether a real collision is reported. A non-building
unrecognised file can still hide the case-6 finding (a gate that only *runs*
production's tag), and that residue is named in `ROLLOUT.md` rather than left
unsaid.

**An unreadable commit gets its own refusal, checked before the tip (2026-09-27).**
`resolve()` compared the pull request's head and merge trees with `git diff --quiet`
inside an `if`, so the only two answers it could give were "identical" and
"different". `git diff` has a third: rc 128, when an object is missing or corrupt —
a head branch deleted and gc'd on GitHub, a merge commit never fetched, a truncated
loose object. That 128 landed in the else branch, which says the merge commit has a
tree of its own and must be gated, and a deploy went out on a comparison that never
ran. Both commits are now proved with `git cat-file -e <sha>^{commit}` first, and
the diff's rc is read as 0, 1, or a refusal naming both shas and the rc.
Two choices inside that are deliberate. The object check runs **before** the
`origin/main` tip comparison, because an unreadable merge sha was being reported as
*main moved since the merge: re-gate* — true-looking, and it sends the operator to
re-gate a commit that was never the problem; "git cannot read this sha" is the fact
that is actually known. And an unreadable head **refuses** rather than falling back
to gating the merge commit, even though a merged-and-deleted head branch is ordinary
on GitHub and its commit may genuinely not be in the checkout: the fallback is what
the bug did, silently. The refusal names the sha and the one command that repairs it,
and the ledger's own greens are keyed to shas, so a head nobody can read has no greens
to inherit anyway.
Each refusal carries the command, and the two commands differ on purpose. The head's is
`git fetch origin refs/pull/$PR/head`, because the case that produces it is a merged
branch that was deleted: GitHub keeps that ref forever, while `git fetch origin <sha>`
needs the commit reachable from a ref the remote will serve. The merge's is
`git fetch origin ${MERGE_SHA}`, because a merge commit that is `origin/main` is
reachable by definition, and naming the sha is what tells the operator which one.
The third refusal, an rc that is neither 0 nor 1, carries no command: a store that has
the commits but not their tree is a repair for `git fsck`, not for one line a deploy can
hand over.

## A root with no compose file is refused, not passed (2026-09-28)

**What it did.** `scripts/gate-image-tags.sh` printed *"no compose file beside this
root — nothing was examined"* and exited 0. Every gate on this box reads that exit
status, so a compose file renamed out of `docker-compose*.yml` / `compose*.yml`, or a
root argument pointing one directory too high, was a green T9 step that had read
nothing at all — the silent pass this check exists to remove, arriving by the door the
check itself opened. Seven of the eight call sites on this box had already written the
same `case` branch on that sentence, and the eighth refuses any report carrying no
`built tags:` line — eight hand-written guards against one exit code, which is the sign
the exit code was wrong rather than their parsing. The next caller to wire T9 in would
have had to write a ninth, or be green on a tree nothing read.

**What it does now.** The same sentence, on stderr, in one line naming the root, and
exit 2 — the code the script already uses for "I cannot judge this" (`-h`, a root that
is not a directory), kept distinct from 1, which means a shared tag was found. Callers
need no change: each reds on any non-zero. Their `case` branches on the old sentence
are now unreachable rather than wrong, and are left to the projects to remove.

**No opt-out flag.** Every call site passes its own checkout root and every one of
those roots keeps its compose files in git, so no flag would be passed by anyone today
— and a flag that silences this check is the flag that gets added to a command line the
day it goes red for the right reason (C10, and S6's guard is never worked around). A
project with no containers does not wire T9's check into its gate; it has no gate tag
and no production tag to share. The one place the refusal is newly visible is the
fleet-wide tally in `ROLLOUT.md`, run by hand from this clone against every project
root: the two projects in its *no compose file beside the root* row now answer exit 2
with the reason, which is the honest reading and was always what that row meant.

## The ledger row names the commit the run was armed on (2026-09-29)

**A row was stamped with whatever HEAD said minutes later.** `gate_ledger_record` runs
from the gate's EXIT trap and read HEAD there, so a commit that landed in the tree while
the gate was working was handed a green row no step had ever read — the gate judged one
tree and cleared another. `gate_ledger_arm` now reads HEAD before the first step, and the
trap compares: if HEAD has moved, nothing is recorded and both commits are named. A
dirty tree is still stamped `<sha>-dirty`, unchanged, because `gated()` matches the
ledger's first field against a sha `resolve` names and `<sha>-dirty` is not one — such a
row leaves evidence a gate ran without ever clearing a deploy. The row format is
untouched: `<sha> <kind> <utc> <rc> <log>`, so a project re-vendoring this needs no
change to any reader.

**Why arming is a call the gate makes, not something sourcing does.** Every gate on this
box that names a git seam sets `GATE_LEDGER_GIT="${GIT}"` after sourcing `ledger.sh` —
`git-as <app> -C <worktree>`, because root's own git refuses an app-owned tree (memento's
and orbit's `e2e.sh` name none, so run as root they cannot name HEAD either way). Arming at
source time would therefore read HEAD through the wrong git, get nothing, and refuse every
row afterwards. So `gate_ledger_arm` is explicit and belongs after the seam and before the
first step, which is where health-tracker's `scripts/ci.sh` already puts its own copy of
this guard; the name is health-tracker's too, deliberately, because two spellings of one
idea is how a re-vendor drops one of them.

**A gate that never arms records nothing, loudly.** The alternative — record as before when
`GATE_ARMED` is unset — would let a project take this version and keep the bug it fixes,
silently. A missing row refuses a deploy and says why on stderr; a wrong row clears one. So
the un-armed case fails closed (C9), and re-vendoring this library into a project means
adding one `gate_ledger_arm` line to that project's gate. Sourcing discards an inherited
`GATE_ARMED` for the same reason it discards `GATE_SUITE_PASSED`: neither may be bought from
the environment.

**Pre-flight's own test stopped asserting the serializer's mood.** `preflight()` prints
`heavy-work $($HEAVY --status | head -1)` and the test pinned the literal `heavy-work free`,
which is only ever green because the fixture's stub answers `free`. The stub now answers
whatever the case asks for, the case asks for a busy slot, and the assertion reads that
string back — so the test proves pre-flight quotes the serializer rather than proving the
stub's default. The stub always answers on two lines as well, so `head -1` has a test.

## What a gate runs is a set of compose files, not one file (2026-09-29)

**What the check could not see.** `scripts/gate-image-tags.sh` read every compose
file beside a root on its own. Two shapes fall straight through that. An overlay
that sets only `image:` for a service, with no `build:` next to it, counted as a
tag nothing builds — but `docker compose -f base -f overlay` merges the pair, and
the merged service builds from the base's `build:` under the overlay's tag. And a
gate that passes no `-f` at all does not run its own file: compose resolves its
default file, which is the production one. Both ways the report said *"none shared"*
over an open hole, and — the tell — it said exactly the same thing after the hole
was fixed, because an overlay's tag still read as unbuilt. A check that cannot tell
the fix from the fault is measuring the wrong thing.

**Where the file sets come from: the gate scripts.** Three candidates were weighed.
A *convention* — an overlay named `*ci*` layers on `docker-compose.yml` when it
declares no build of its own — invents a pairing nobody wrote, and would have
missed the case that started this, where the gate passes no overlay at all and
there is nothing to pair. A *declared manifest* is a second place that has to be
kept true, and it is empty exactly where it matters: the project with a T9 hole is
the one that never wrote it. What remains is the running thing (W9): the gate's own
compose calls. `scripts/check.sh`, `ci.sh`, `e2e.sh` and `gate.sh` are the names T1
and T6 give those entry points; each `docker compose` call in them yields a file
set from its `-f` flags, from an exported `COMPOSE_FILE`, or — naming nothing —
from compose's own default-file precedence. Each set is merged as compose merges
it: a later `image:` wins, a `build:` anywhere in the set builds, and the set's own
`name:` decides an implicit `<project>-<service>` tag. A gate that lives under
another name is not guessed at; the report names the scripts it read.

**The shell is lexed, not run.** Quote and heredoc state is tracked across lines, so
`printf '  docker compose up -d app\n'` in a help string is not read as a gate run.
Reading quoted text as code was tried against the nine roots on this box: one project's
usage text invents a run over the production file, and on the project that really is red
the finding moves off the call that causes it and onto a line of help. A `-f` value naming a file this root does not have, a subcommand that was
never reached, a call whose files could not be resolved: each is printed on its own
line and none is judged. Loud beats quiet, but a guess is neither.

**A bare call that only tears down is not a build.** `down`, `ps`, `logs`, `config`
and their like are read as idle, and a wrapper that carries no subcommand of its own
(`DOWN=(docker compose -p "$PROJECT")`) is read as idle too, because the alternative
is a red gate for a teardown. Every idle bare call is still printed — *not judged, no
subcommand read* — so the gap is visible rather than silent. A bare call with a real
subcommand (`up`, `run`, `build`, `exec`) is judged against the production files.

**An overlay with `image:` and no `build:` is not refused outright.** Where the tag
it names is one production builds, nothing new is needed: the shared-tag rule that
has been here since the start already refuses it, and the test says so. Where it
names a tag of its own and no gate run read here passes that file, a refusal would
red a project whose gate is safe and merely written somewhere this check does not
look — one such stack is on this box today. That case is printed as an unjudged
overlay, naming the file, the tag and the build it would merge over, and the pair is
judged the moment a gate script names it.

**Discovery widened to any top-level `services:` file.** A compose file renamed out of
`docker-compose*.yml` / `compose*.yml` was invisible: the root refusal only fired
when there was no recognised file at all, so a root holding one recognised file and
one renamed one judged half of itself. Any `.yml` or `.yaml` beside the root
carrying a `services:` key **at column 0** is now read and classified by name, which means
a renamed builder ends in the existing *named for neither side* FAIL (exit 1) rather
than the whole-root refusal (exit 2). The refusal still stands where nothing beside
the root carries `services:`, which is what "wrong root" now means. A `.yml` that is
not a compose file at all — a `deptrac.yaml` — is left alone, because the
`services:` key is what makes a file one compose can be pointed at. The column
matters: `read_images` only finds a `services:` at indent 0, so a discovery that
accepted an indented one read a `.gitlab-ci.yml` (whose `services:` sits under a
job, beside an `image:`) as a compose file and compared a CI job's image with
production's tags. The two now ask the same question.

**`docker compose config` was weighed as the merge authority, and not adopted.**
The obvious way to stop hand-writing compose's merge rules is to let compose do
it: `docker compose config --no-interpolate` over each discovered set. It does
run without a daemon — proved here with `DOCKER_HOST` pointed at a dead socket —
and it is what proved the default-file order below. It is not the right thing to
*depend* on, for three measured reasons. It is all-or-nothing per set: a service
whose `extends:` names a missing file makes it exit 1 with no output at all, so
every other service in that set goes unread, where this check reports the one it
could not read and judges the rest. It can fail *quietly*: `-f base -f bad.yml`
with an unknown YAML anchor printed `go-yaml load error …` and still exited 0, and
a merge authority that returns nothing on success is worse than none. And it
inlines `env_file` paths into the model it prints, which is a poor thing to hold
in a check whose whole output is a gate log. Against that, the rules it would
replace are small, and a check made of bash and awk runs wherever a gate does,
with no CLI version to pin (S5). So compose stays the *authority we test against*,
not a dependency: the default-file order below was read out of it, and every rule
here is a fixture in `scripts/gate-image-tags-test.sh`.

**Compose's default files are two searches, not one.** When a call names no file,
compose picks a base — the first of `compose.yaml`, `compose.yml`,
`docker-compose.yaml`, `docker-compose.yml` — and then, *independently*, an
override: the first of `compose.override.yaml`, `compose.override.yml`,
`docker-compose.override.yaml`, `docker-compose.override.yml`. The two searches do
not have to agree on an extension, so `compose.yaml` + `docker-compose.override.yml`
is a merged pair, which the check used to miss and read as the base alone. Read out
of `docker compose config --no-interpolate`, which names the file it picked in a
warning when several match (W9), not out of the documentation.

**A variable is read from above the call, not from the file's last line.** The
reader collected every assignment in a gate script and kept the last, so
`export COMPOSE_FILE=base` … call … `export COMPOSE_FILE=base:ci` … call judged the
*first* call on the second value — passing a root whose first call runs production's
own file. Assignments now carry their line, and a call reads only those above it. An
assignment inside a branch (`if … then F=x; fi`) may or may not have run, so it adds
a possible value rather than replacing one: where two values remain possible the call
is printed as unread rather than resolved to whichever the file mentions last. The
same line ordering is what lets a `COMPOSE_FILE` set in a sourced file be followed —
four levels deep, `$(dirname "$0")/lib.sh` and `${BASH_SOURCE[0]%/*}/lib.sh` resolved
against the sourcing script, any other path's leading variable dropped and the rest
resolved under the root — and what makes a bare call under a sourced file this check
*cannot* read unjudged instead of falling through to compose's default.

**A line naming compose that yields no call is printed, and does not fail.**
`eval "docker compose …"`, `sh -c '…'` and a wrapper built from a string read as
*no compose call at all*, which looks exactly like a gate that never calls compose.
Every such line — outside a comment, which the shell provably never runs — is now
printed as an unjudged call. It does not change the exit code, for two reasons. It
is the weakest thing here, because it may not be a call at all: an unread call names
files and will run, a mention may be a sentence in a help string. And it was
measured: across the nine gate scripts on this box every single unjudged mention is
help text — `printf '  docker compose up -d app\n'` and its kin — and nothing else.
A check that goes red on a project's own documentation gets switched off. The line
is named and stable, so a project that wants it fatal greps its gate for
`unjudged calls:`.

**A wrapper is judged where it is used.** `DC=(docker compose -f docker-compose.yml)`
and `dc() { docker compose -f "$FILE" "$@"; }` carry a file set and no subcommand.
Judging them where they are built is wrong both ways: a teardown wrapper reds a gate
that only tears down, and treating them as idle would lose the gate that really does
`"${DC[@]}" up -d`. The file set is remembered under the name and judged at each use,
with the subcommand read there; a wrapper never used, or used somewhere this reader
cannot follow, keeps the idle verdict and is printed as *not judged*.

**A call whose file set cannot be read fails the check.** The first cut printed such a
call and exited 0, on the reasoning that this reader should not red a gate over its
own blind spot. That is backwards for anything that names files and will run: a `-f`
pointing at a file that is not here, a variable with two possible values above the
call, a wrapper defined differently in two branches, a `source` that resolves to
nothing — each is a set that really is merged at run time and might carry
production's tag, reported under a green exit nobody reads (C9). They now end the run
with exit 1 and a line naming the call. Measured before the change: across every root
on this box with a compose file beside it, no gate produces one, so nothing turns red
on this alone. A mention is the one thing left that is printed and not failed, for the
reason above.

**A `-f` directory is this root unless only the environment sets it.** `-f "$X/x.yml"`
used to be matched on its basename, so a file in someone else's tree was judged as the
file of that name here — and the reverse, `-f infra/x.yml`, was refused. The rule is
now the origin of the directory, not its spelling: a directory the script itself
assigns is taken to be this tree and the basename stands; one whose value only the
environment supplies is unknown, and the call is unread. Both live shapes stay
judged — `-f "${COMPOSE_FILE}"` over `COMPOSE_FILE="${REPO_ROOT}/docker-compose.ci.yml"`,
and a bare `-f x.yml` — while `-f "$SHARED/docker-compose.yml"` is not read as the
`docker-compose.yml` beside this root. A directory written out in full must still be
this root.

The known limit is what "the script assigns it" does not check: the value is never
traced back to a literal. A directory a command substitution produces — `$(cd … && pwd)`,
`$(mktemp -d)`, `$(git rev-parse --show-toplevel)` — is *assumed* to be this tree, and an
assignment made only inside a branch is read as if that branch had run. A gate pointing
`-f` at a computed directory in another tree is therefore judged against the file of that
name here. The stricter rule — the basename stands only where the path expands to a
literal — was written and run over the live gates: it reds 23 correct calls across
`/var/www/fineprint` and `/var/www/kidsquest`, every one of them the ordinary
`COMPOSE_FILE="${REPO_ROOT}/docker-compose.ci.yml"` shape. False reds on working gates
cost more than a gap no gate on this box has, so the gap stays and is written down here.

**A wrapper is read the way a variable is.** The file set under a name was kept
last-write-wins, so an `if`/`else` that built `DC=(…)` two ways passed on whichever
branch came last in the file — the safe one, if the unsafe one came first. Definitions
now carry their line and whether they sit inside a branch, exactly as assignments do:
an unconditional one replaces what is possible, one inside a branch adds to it, and two
possible file sets are not a file set. The line that only *defines* a wrapper judged
further down says nothing of its own, so one run is reported once.

**The limit that stays.** A gate that passes `-p` or `COMPOSE_PROJECT_NAME` at run
time still builds implicit tags this check cannot name; that is the limit the
2026-09-25 entry above records, and reading the gate scripts does not lift it.

## A bundled front end audits without `--omit=dev`, rather than policing its imports (2026-09-30)

T1 now names a dependency-advisory step and says what it covers on a project whose
deploy ships a bundle built out of `node_modules`. Two wordings were available and
only one is in the standard; this is the other one and what it would have cost.

**What went wrong first.** A gate audited with `npm audit --omit=dev --audit-level=high`
and exited 0 while a package under a published **High** advisory was in the shipped
bundle: the entrypoint the bundler starts from imports it, and the package is listed
under `devDependencies`. `--omit=dev` asks the lockfile which section a package is in.
A bundler never asks: it follows imports from the entrypoints and ships what it finds.
The two answers agree for a server-rendered app and disagree for a bundled one, and it
is the disagreement that reaches production.

**The option taken (a): drop `--omit=dev` where a bundle is shipped.** One flag, in one
line of one script, and it cannot be got wrong by a later edit somewhere else. Its cost
is real and accepted: the audit then also judges packages that never leave the
developer's machine — the dev server, the test runner, the build tool itself — so an
advisory in one of those turns the gate red although nothing shipped. We take that
trade because the failure is loud, legible and cheap to answer (bump, or record an
exception), whereas the failure it replaces is silent and shipped. Severity does the
narrowing that `--omit=dev` was doing badly: the floor stays High.

**The option not taken (b): keep `--omit=dev`, require every package the bundle imports
to be a `dependency`.** It is the more precise statement — it audits exactly what ships
and nothing else — and it is the one we could not check. Nothing in the fleet classifies
a module graph against the two lockfile sections; it would need a new tool, wired into
every gate, that resolves the bundler's entrypoints and maps each resolved package back
to its section, and that tool would have to understand aliases, conditional imports and
the bundler's own injected runtime. It also starts from a debt rather than a clean
sheet: three of the nine surveyed front-end manifests list an HTTP client under
`devDependencies` today — so (b) would first need those three reclassified, a
dependency rewrite to keep a flag that (a) simply drops. If such a tool is ever
wired, (b) is the better rule and this entry is the argument for revisiting it.

**Why the rule does not simply say "no `--omit=dev`, everywhere".** On a project with no
bundle, `--omit=dev` is the right flag and says something true: what production installs
is what `--no-dev` installs. The scope clause in T1 is the whole content of the rule, so
it is stated as a property of the deploy ("ships a bundle built out of `node_modules`")
rather than as a list of project names, which would go stale the first time a project
adds or drops a front end.
