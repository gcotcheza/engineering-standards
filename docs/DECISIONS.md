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

**An unlisted repository is attention, and its row shouts.** The project list is the contract —
it is what "the fleet" means — but a list cannot notice a project that joins the box and never
joins the check, which is exactly how a project goes unchecked for months. The check now names
any directory under `$ROOT` that holds a `.git` and is not a project. It gets a
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
trap compares: if HEAD has moved, nothing is recorded and both commits are named. (A
dirty tree was still stamped `<sha>-dirty` here; since 2026-10-03 it gets no row at all —
see the entry below.) The row format is
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
and nothing else — and it is the one we could not check. Nothing in the fleet
classifies a module graph against the two lockfile sections; it would need a new tool,
wired into every gate, that resolves the bundler's entrypoints and maps each resolved
package back to its section, and that tool would have to understand aliases,
conditional imports and the bundler's own injected runtime. It also starts from a debt
rather than a clean sheet: three of the nine surveyed front-end manifests list an HTTP
client under `devDependencies` today — so (b) would first need those three
reclassified, a dependency rewrite to keep a flag that (a) simply drops. If such a tool
is ever wired, (b) is the better rule and this entry is the argument for revisiting it.

**Why the rule does not simply say "no `--omit=dev`, everywhere".** On a project with no
bundle, `--omit=dev` is the right flag and says something true: what production installs
is what `--no-dev` installs. The scope clause in T1 is the whole content of the rule, so
it is stated as a property of the deploy ("ships a bundle built out of `node_modules`")
rather than as a list of project names, which would go stale the first time a project
adds or drops a front end.

## By hand reads the ledger and overrides it out loud, and the refusal names routes that exist (2026-10-01)

**The rescue path used to be a blindfold.** `gated()` returned on `BY_HAND` before it touched the
ledger, so a tip whose `ci` row was red deployed and the log said only `GATED BY HAND: the ledger
was not read`. Nothing printed the row that was being overridden, and `DONE` recorded the deploy as
`gated by hand` — indistinguishable from a by-hand deploy of a tip every gate had passed. That
mattered most where by-hand is the documented route rather than the exception: a project with no
browser gate cannot satisfy `for kind in ci e2e` at all, so every one of its deploys took the
blindfold. `gated()` now reads the rows first and builds one verdict — `green`, `red` or `absent`
per kind, behind the commit it asked about and whether that commit was the head or the merge — then
by hand prints `GATE NOT GREEN <verdict>` and records `by hand over [<verdict>]`, which is the shape
health-tracker's `deploy.sh` already used over its `gate-row.sh`. What by hand still does **not** do
is refuse: it is the path out of a hole, so a missing ledger, an unresolved commit and a red row are
all printed and all deploy. The one case that is not an override is a by-hand deploy of a tip the
ledger does clear: that records `by hand over [GREEN <verdict>]`, so `DONE` carries a verdict either
way, and the flag is told it was not needed. Reading the ledger on a path that previously did not
touch it is why the per-kind lookup carries `|| v=unreadable` — every caller runs under `set -e`, and
a command substitution that dies there would have turned the rescue path into a silent exit. That is
why the by-hand cases in the suite run under `set -e` too, and why one of them shims `awk` to exit 2:
without the guard, the deploy never reaches the line after `gated`.

**The old refusal named a remedy that could not be followed.** `gate that $what, then deploy` is an
instruction to gate a commit that, by the time `gated()` runs, `resolve()` has already proved is
`origin/main` — and a gate that scans `origin/main..HEAD` refuses an empty range, so following the
sentence burned a gate run and wrote a *red* row for the tree the operator wanted cleared, one step
from hand-writing a row. The sentence now says what is missing (which kind, and what every row says)
and names three routes: gate a commit before it is merged; once it is in main, whatever route that
project's gate documents for it; or `--gated-by-hand`, which deploys and records the deploy as
ungated. It deliberately does not name any project's flag. A base override is the shape such a route
takes where one exists — one project's gate has it, others do not — and a library that claimed
`--base` would send operators of the rest looking for a flag their gate never had. "Where it has
one" is doing real work in that sentence, not hedging.

## Four lessons folded into existing rules rather than written as new ones (2026-10-01)

**Why no new rules.** Each of the four had an obvious shape as a rule of its own — "prove a guard
by deleting it", "a fenced block is a shell", "hooks always run", "count the words" — and all four
were rejected in that shape. A standard is read in full by every session that loads it, so its cost
is its length, and four rules that each restate the check of a rule already present is exactly the
second-copy duplication C1 and C2 warn about: the copies start to disagree, and a reader who finds
two rules about proving a test has to decide which one governs. Folding each into the rule whose
*check* it sharpens keeps one answer per question, and keeps the count at 38 so no project's drift
test changes shape — only its vendored bytes and its declared version.

**Why the hook clause is S1 and not S2, S6 or W6.** The three candidates were real. S2 is about a
guard's output and would have read naturally — but S2 governs what a guard may print *once it has
fired*, and a bypassed hook never fires, so the clause would have sat under a rule it cannot
violate. S6 ends with "that guard is never worked around", which is the same sentiment, but S6's
guard is the gate's refusal to run in a deployed checkout: a different mechanism, a different
failure, and widening S6 to mean every guard everywhere would have made it the rule nobody can
check. W6 is about *what* is staged, not *whether* the commit was inspected. S1 won because the
pre-commit hook is already named as S1's check: a commit made with `--no-verify` has not skipped a
convenience, it has left S1 itself unverified, and the rule and its check then describe one thing.
The clause also names the behaviour and not only the flags — "any other way of standing a commit up
without it" — because the flag list is open-ended (`HUSKY=0` today, the next tool's switch
tomorrow) and a list is a thing to be outside of. Two shapes are named anyway, against that
preference, because they are not flags on a commit line and so are not what a reader checking a
transcript for `--no-verify` would look for: a repo-local or global `core.hooksPath` aimed anywhere
but the fleet hooks directory, and a throwaway `GIT_CONFIG_GLOBAL` that drops it. Both are set once
and then every later commit in that clone is unguarded silently, with nothing in the command and
nothing in the diff to show it — which is why S1's checked-by now reads the hooksPath in effect and
not only the command.

**Why W4's count is a command and not a review item.** "≤150 words of plain language" was checked
by the reviewer reading the body, which is the kind of check that passes when the reader is the
author. The count is mechanical and cheap, so it belongs in the checked-by as the command, run
twice — before create and before ready, because the body is edited between those two points. It is
two commands and not one: before create there is no `<n>` to query, so the count reads the body file
the PR will be made from, and `gh pr view` is the source only for the second run.

**What the 150 counts, and why every pattern is anchored.** The number is prose — the four `## `
headings and the one closing pointer line are required by this same rule, so counting them would
charge an author for obeying it, and the attribution footer and session link add words nobody wrote.
The first form of this check cut the body with `sed '/Generated with/,$d'`, unanchored, and that is a
false pass rather than a loose one: the phrase is ordinary English, so a body that mentions it in
prose is truncated at that line and the count comes back as a passing handful — 19 on a probe whose
real prose was 130. Each pattern is therefore anchored at the start of the line it means: the footer
by `^🤖 Generated with \[Claude Code\]`, the headings by `^## `, the closing line by its whole text.
The alternative considered was a shared script in `scripts/`; it was not taken, because a pipe a
reviewer can paste needs no vendoring round across ten repos.

**Why T5's new half names `<(...)` explicitly.** The general sentence ("the red proof runs against
a saved file") is true but does not teach the trap, and the trap is subtle: a process substitution
behaves correctly for a single-case run, so the habit is formed where it works and then carried into
a suite where the second case reads an empty stream and reports a pass-count of zero. A zero that
looks exactly like the red being sought is worse than a crash, so the mechanism is named in the rule
rather than left to the reader to rediscover.

## The deploy removes the one merged pull request's worktrees and lanes, and never sweeps (2026-10-01)

**The cleanup runs after a deploy because that is the moment something knows which pull request
just shipped.** Nothing removed per-PR worktrees under `/var/www/<app>-worktrees/` or scratch lanes
under `/srv/worker-scratch/` at all: no deploy script mentioned worktrees, and `fleet-scratch-reap`
— which does the lane half properly, per repo and PR, read-only twin first — was scheduled by
nothing and deliberately refuses a worktree of a production checkout, printing the `git-as` line for
Ghie to run by hand. The disk measured 128G on 2026-09-29 and 135G of 150G two days later, and a
hand pass on 2026-10-01 removed 17 merged worktrees. A timer would have to re-derive what a deploy
has already proved one function earlier: `resolve()` has established that the merge commit *is*
`origin/main` before `deploy_cleanup` is reached, so the cleanup asks `gh` once more only for the
facts resolve does not carry — the base branch and the head branch name.

**One named pull request is not the bulk filter S7 is about.** S7's "in bulk" means more than one
object chosen by a filter rather than named, and the counter-example it gives is a filter that reads
as "unused". Nothing here reads as unused: the set is the intersection of one pull request's
`headRefName` with the repository's own `worktree list --porcelain`, which is positive selection by
name, and it is the same pull request number the deploy was invoked with. The lane half keeps S7's
command pair intact rather than reimplementing it — the reaper's read-only run prints
`candidates: N  set: <sha256>`, and the apply is handed back that hash with `--expect`, which the
reaper recomputes before deleting, so a set that changed between the two runs is refused by the tool
itself. Dropping `--expect` would turn a proven set into a fresh one; a mutant that drops it is red
in the suite.

**`git worktree remove` is never given `--force`, and nothing is removed with `rm`.** The remove is
the last guard behind the dirty check, not a formality: the only shape in which it fires is a tree
that went dirty *after* the check passed, and `--force` would turn exactly that race into lost work.
`rm` is worse than useless here — it leaves the parent repository's `worktrees` metadata pointing at
a directory that is gone. A remove that exits non-zero keeps the worktree and names `remove` as the
reason, like every other failed check, and the deploy is not failed by any of it.

**The root-owned check is the one that will keep most trees, and the fix is not here.** Of the 28
merged worktrees measured on 2026-10-01, 11 were kept, and every one of those 11 carried at least
one root-owned file — five of fineprint's seven rows among them, whose gate leaves a root-owned
`.env` behind. The cleanup cannot `chown` and must not, so those trees stay until the gate that wrote them
stops running as root; that is its own item, not this one. `rootfiles` is the most expensive check — it
walks the tree, and `find -print -quit` stops at the first hit — so only the `.env*` listing runs
after it.

**What a removed tree takes with it, and what each check actually matches.** Probed on a throwaway
fixture worktree holding an ignored `.env` and an ignored `node_modules/`: the dirty check's
`status --porcelain` printed `porcelain=[]`, and a plain `git worktree remove` then printed
`dotenv deleted with the worktree` and `node_modules deleted with the worktree` — so gitignored
files go with the tree, and they are the disk this change reclaims. An ignored `.env*` file at the
top of the tree or below it is the one exception: `cleanup_envfiles` keeps such a tree under
`envfiles`, because an app's `.env` holds secrets and configuration that nothing in the repository
can regenerate, and a few kilobytes of it is not reclaimable disk the way a `node_modules/` is. A
listing it could not read keeps the tree too. The probe was top-level only until card 263: `'.env*'`
without magic matches the top of the tree alone, so reflection's `api/.env` went with its tree. It
now adds `':(glob)**/.env*'`, which on git 2.43 printed `api/.env` and `deep/a/b/.env.local` as well
as the top-level `.env` (the plain `'**/.env*'` did not reach the top level; the `glob` magic does),
minus `':(glob,exclude)**/vendor/**'` and `':(glob,exclude)**/node_modules/**'`. Without those two,
the same probe printed `api/vendor/x/.envrc` and `node_modules/y/.env`: a vendored package's own env
file would keep every tree for ever, the failure the `--ignored` reasoning below rejects. The plain
`'.env*'` was added because the glob printed nothing for an ignored `.env.d/prod`. Neither lists a
file inside a `.env*` directory below the top (`api/.env.d/prod`), so a third term,
`':(glob)**/.env*/**'`, does (card 273); it lists `.env.d/prod` and `api/.env.d/prod`, so on a
fixture the probe printed the same four paths with or without the plain term, which is now
redundant. It stays because `check_repo` carries the same terms. One shape is still not matched by name. A nested
repository is not looked inside: an unignored one shows as `?? sub/`
and keeps the tree under `dirty`, and an ignored one is listed by the glob as `sub/` whatever it
holds, so it keeps the tree under `envfiles`. `fleet-scratch-reap`'s `check_repo` uses the same
five terms once its card-273 packet is installed. Root-owned ignored files are not
an exception to that: `cleanup_rootfiles` walks the whole tree with `find -uid`, ignored paths
included, so a tree carrying one is kept under `rootfiles` before any remove is attempted.
`--ignored` is deliberately not added to the dirty check — the same probe printed
`ignored-aware=[!! .env` / `!! node_modules/]`, and every project's tree carries a `node_modules`,
`vendor` or `public/build`, so an ignored-aware dirty check would keep every tree for ever.
`cleanup_mounts` matches a container's mount source against the tree and everything below it and
never against an ancestor, because a container mounting `/var/www/<app>-worktrees` says nothing
about one worktree inside it. The `/proc/[0-9]*` glob in `cleanup_procs` only enumerates process
directories so their `cwd` can be read: nothing it yields is ever a removal target, and a glob that
matched nothing is itself a keep rather than a clean bill of health. It reads `cwd` alone and not
each process's open descriptors, which is accepted: an `fd` walk is a readlink per descriptor for
every process on the box, while a process that holds a file open inside a removed tree but sits
somewhere else keeps reading that file by inode and loses nothing.

**It is wired as an `EXIT` trap because `finish` exits.** `finish()` prints `DONE` and `PAPERWORK`
and calls `exit 0`, so nothing written after a `finish` call ever runs; the trap is armed on the
line before each success-path `finish`, which includes the docs-only landing that five of the eight
projects finish early. Probed under the options the deploy scripts actually set: inside an `EXIT` handler
under `set -e`, a command that fails both cuts the handler short and makes the script exit 1, and
reading an unset name does the same. So `deploy_cleanup` captures every exit code (`rc=0;
out=$(…) || rc=$?`), reads every caller-set name as `${X-}`, and ends in `return 0` — a handler that
returned non-zero as its last act was measured turning a successful deploy into `rc=3`. Two projects
already trap `EXIT` on their success path (ghiecode closes its `APP_HOME`, kidsquest reports
root-owned files); a second `trap … EXIT` replaces the first, so in those two the existing handler
calls `deploy_cleanup` rather than being replaced by it.

**A success marker, not the trap, is what decides the cleanup runs.** An `EXIT` handler fires on
every exit, a refusal included, and the two handlers above call `deploy_cleanup` unconditionally
because they already do their own work on every path. So each project sets `DEPLOY_SUCCEEDED=1` on
the line immediately before every success-path `finish`, and `deploy_cleanup` reads it before it
reads anything else: unset, it says `did not run: the deploy did not reach finish.`, removes nothing
and leaves the refusal's own exit code alone. Deciding it inside the handler rather than at each
`trap` line is what makes an unconditional call safe, and it is one sentence to audit per project
instead of one conditional per handler. Sourcing `cleanup.sh` discards an inherited
`DEPLOY_SUCCEEDED` the way sourcing `ledger.sh` discards `GATE_SUITE_PASSED`: a marker exported by
whatever called the deploy script would otherwise buy the removals of a deploy that refused, so the
only assignment that counts is the one the deploy makes in its own shell.

**The library defaults none of the names it reads.** `PR`, `GIT`, `GH`, `ROOT`, `WT_GIT`, `REAP`,
`DOCKER`, `PROC_ROOT` and `CLEANUP_ROOT_UID` are assigned by each project's `deploy.sh`, in the style
the rest of the library already uses, and a `${REAP:-/usr/local/sbin/fleet-scratch-reap}` is
deliberately absent: a test that forgot its fake would then run the real reaper with `--apply`
against the real scratch root. A deploy that assigned nothing is told which name is missing and
removes nothing, and that is one check over one list rather than a seam check beside a separate
argument check — `PR` unset is the same sentence as `REAP` unset, because to this handler they are
the same kind of mistake.

**Every zero says which zero it is.** Lanes carry a `.fleet-scratch` label now:
`find /srv/worker-scratch -maxdepth 2 -name .fleet-scratch | wc -l` printed `8` on 2026-10-01, in
the spelling the fleet worker rules landed that day — `repo=gcotcheza/<name>` and `pr=<n>`, the
first of which is what `deploy_cleanup` passes as the reaper's first argument. So a candidate set
can be non-empty, and the two readings of `candidates: 0` are never printed as the same sentence:
no lane carries this pull request's label reads
`scratch reaped 0 kept 0 (no lane is labelled <repo> #<PR>)`, while a reaper `kept:` count above
zero means every lane carrying the label was kept on purpose and the summary says
`every labelled lane was kept (N)`. The same rule covers every half that
could not run: a pull request that is not merged, a base that is not `main`, a merge commit that is
not an ancestor of `origin/main`, an unreadable `worktree list` and an unreadable reaper run each put
their reason where their counts would have gone, instead of printing zeros. The run prints one
`CLEANUP` summary line; the per-worktree keep lines go to the deploy log, and the only extra lines on
stdout are the loud ones the reaper's exit 2 and exit 4 are worth.

**`scripts/lib/deploy/VERSION` does not move in this change.** The vendoring header on `cleanup.sh`
carries the same date as the other four files, but `LIB_FILES` in `scripts/fleet-versions.sh` is
untouched, so no project is reported `DIVERGED` for a file it does not vendor yet. The version bump
and the entry in `LIB_FILES` belong to the re-vendor round, where they land together with the eight
`deploy.sh` edits that arm the trap — one change, one report, rather than a week of red rows for
work nobody has done yet.

## VERSION and ENGINEERING-STANDARDS.md move together, and the gate says so (2026-10-02)

**The pair was a habit, and the habit had already been broken once.** The advisor's ruling on
backlog 228 is the rule in one sentence: `VERSION` is bumped exactly when the standards text
changes. Read against `main` the ruling holds in one direction and leaks in the other — all seven
first-parent commits that touched `VERSION` also touched the text, but eight touched the text and
one of those, the merge of PR #10 on 2026-09-19, carried no bump. A version that is sometimes the
version of the text is worse than no version at all, because a reader has no way to tell which
kind they are holding. `scripts/version-text-pair.sh` is that one sentence as a gate step, and it
fails naming the file that moved alone: "the pair is broken" would send the reader off to diff two
files to learn which one it was.

**It judges the tree, not the last commit.** The comparison is `git diff` against
`git merge-base HEAD origin/main` — what this branch does to `main`. `HEAD~1` would be wrong: a
three-commit branch that bumps the version first and edits the text last is correct, and a
per-commit check calls it wrong twice. A committed-only diff would be wrong too, because the gate
runs against a working tree and a forgotten `VERSION` edit should fail before the commit rather
than after it. An empty diff — `main` itself, or a branch carrying nothing — passes: neither file
moved, so the rule has nothing to say.

**A missing `origin/main` fails rather than skips.** A clone that has never fetched has no base to
judge against, and the tempting behaviour is to return 0 and let the gate go green. That is exactly
C9's silently swallowed error: it would turn every offline or shallow clone into a green gate for a
rule nobody checked. The script exits 1 and names the ref it could not find.

**The check and its own test are one step, not two.** The step enforces the pair on this
repository, then proves the enforcer still works against fixtures. Split, they would occupy two
slots that nothing distinguishes — the check alone is 0.01s and its fixtures 0.63s, in the
same run as the table below — and a reader scanning the gate's output for "was the pair checked" would have to
find both.

**The step order, re-measured.** Each step body was timed alone, three repetitions, best of three,
the way the 2026-09-19 entry describes, in two separate runs on 2026-10-02 against the merged tree
that also carries the after-deploy cleanup's cases:

| step | check | run 1 | run 2 |
|---|---|---|---|
| 1 | `bash -n` | 0.04 | 0.04 |
| 2 | `version-text-pair.sh` and its test | 0.66 | 0.59 |
| 3 | `fleet-versions-test.sh` | 0.63 | 0.71 |
| 4 | `fleet-budget-test.sh` | 1.24 | 1.26 |
| 5 | `queue-start-test.sh` | 2.01 | 2.05 |
| 6 | shellcheck | 2.80 | 2.80 |
| 7 | `gate-image-tags-test.sh` | 3.39 | 3.10 |
| 8 | `scripts/lib/deploy/test.sh` | 11.39 | 12.70 |

They will rot again. Three things in them carry meaning. The new step and `fleet-versions-test.sh`
swap places between the runs, so nothing should be read into their order. Shellcheck was dearer
than `queue-start-test.sh` in both runs, by 0.79s and 0.75s, so the two swap: shellcheck is now
step 6. `gate-image-tags-test.sh` is not noise: it was step 3 at 0.32s when its fixtures were new
and it is above 3s now, dearer than all four steps that used to run after it, so it moves to 7.

## A gate that never got a slot records nothing, and says NOT RUN (2026-10-02)

`/usr/local/sbin/heavy-work` exits 75 (`EX_TEMPFAIL`, log line `giveup`) when it has waited its
hour for a slot, which means the work never started. On 2026-10-01 a project gate turned that 75
into `=== GATE FAILED (step 10: api unit suite) ===` and `gate_ledger_record` wrote a row with
rc 1 for a suite that never ran. The ledger then holds that commit red, and only a green re-run
undoes it: one give-up cost two gates.

An rc that means "never ran" is not a verdict, so neither half may read it as one.

**`gate_ledger_record` writes no row for rc 75** and prints
`gate-ledger: heavy-work gave up (rc=75), so the <kind> run is NOT recorded — it never ran` on
stderr, beside the refusals for a gate that never armed and a HEAD that moved mid-run. The row
stays absent, which `gated` already reads as absent: the tip is ungated and still needs a run,
which is a different claim from a red it never earned.

**The fleet convention for a project's step runner**, which this library cannot enforce because
it never sees a step: a step that exits 75 ends the gate at once, printing
`=== GATE NOT RUN (step N: name — heavy-work gave up) ===` and exiting 75 — never `GATE FAILED`,
and never carrying on to the next step. The 75 leaves the gate unchanged, so whoever queued the
run can re-run it when the box is quieter, and nobody goes looking for a failure that does not
exist. `ledger.sh`'s header carries the two-line pointer to this entry.

**The option not taken:** recording rc 75 as a third row state (`notrun`). Every reader of the
ledger — `gated`, `scripts/fleet-versions.sh`, each project's own gate row reader — would have to
learn a state that says exactly what an absent row already says, and a reader that did not learn
it would read `notrun` as not-green and refuse the deploy, which is the red we are removing.

## W3 lets a session merge a dependabot pull request, and nothing else (2026-10-02)

**Ghie's rule, 2026-10-02.** A session may merge a pull request once the project's own gate is green
on its head commit, for every ledger kind the project gates, and deploy it by that project's
runbook — but only when every commit on the head is authored by `dependabot[bot]`. Every other pull
request still waits for Ghie, and W2's draft-and-review step carries the same exception.

**Keyed on the commits, not on who opened the PR.** An opener is one field; anyone can push a commit
of their own onto a dependabot branch, and that commit would then ride a merge nobody reviewed. So
the check is `gh pr view <n> --json commits -q '.commits[].authors[].login'`, which must print
`dependabot[bot]` and nothing else, run against the head being merged.

**The record is a PR comment before the merge.** It quotes that command's output and the green
ledger row for each kind on the head sha, so the merge list shows what the session relied on.

**The gate is the only secrets layer these commits get.** Dependabot commits on GitHub, so the fleet
pre-commit hook never sees them; the gate's secrets step is their whole S1 check.

**The permission layer still decides.** `autoMode.hard_deny` in the session settings blocks merging
"by ANY means". Until Ghie amends that sentence the rule is written and the merge is still refused,
and a refusal is never routed around.

**The option not taken:** letting any green pull request merge itself. The adversarial review in
W2 is what a gate cannot do, and every other author has a builder whose diff needs a second reader.

## The deploy library's fixtures commit through the fleet hook, from one template per kind (2026-10-03)

**No fixture skips the hook (S1, backlog 265; advisor ruling, cards 277/274).** `test.sh` used to
build every case's repository with `-c core.hooksPath=/dev/null` and `--no-verify`. Both are gone,
with no environment seam, test mode or carve-out in the hook: fixture content is plain text the
real hook passes.

**What the self-scan covers, and nothing more.** A check at the top of the suite reads its own text,
with `\`-continued lines joined, and fails on: `core.hooksPath` in any letter case (git config
keys ignore case); `--no-verify` and every prefix of it down to `--no-v`; `HUSKY=0`; any
`GIT_CONFIG_*` name (`GLOBAL`, `SYSTEM`, `NOSYSTEM`, `PARAMETERS`, `COUNT`, ...); any `HOME=`
assignment, exported, inline or prefixed; `XDG_CONFIG_HOME=`; the plumbing that stands a commit up
without a hook (`commit-tree`, `fast-import`, `hash-object` with `-w`); and a short `-n` flag
cluster after `commit` or `merge` on the same logical line. It is a text scan, not a parser: a
bypass built at runtime (a flag in a variable, a `-c` key assembled from pieces, an alias) is not
seen, and review stays the check for those. Two false positives are known and fail loudly rather
than pass quietly: merge's own `-n` (no-stat) and a dash-n inside a `-m` message. Rephrase the
line; never widen the scan's exemptions.
An unreadable suite file, or either grep exiting above 1 (a pattern grep cannot compile), fails the
scan: grep's "no match" and "could not run" must never both read as clean.

**Built once per kind, then copied.** Committing through the hook per case meant 245 calls to the
personal-data checker per run and took the suite from 14 s to 145 s. The checker caps every caller
but root at 30 calls a minute, and ghiecode's gate runs this suite as its tree's owner, so a
re-vendored copy would have been refused by the cap. `fixture_template` builds the plain and
`trees-differ` repositories once, the `side` commit included under `refs/fixture/side`, and each
case copies one: 8 checker calls per run, 15 s.

**The option not taken:** `git commit-tree` for the fixture commits. It needs no flag, and it also
never runs a hook, so it is the same bypass under another name.

## A dirty tree gets no ledger row, and the lib suite proves the hook ran and runs only as root (2026-10-03)

**`<sha>-dirty` rows were noise that looked like evidence.** No deploy could resolve one, but
the mistake ledger mined 24 of them as red runs against commits nobody had gated (backlog
268). `gate_ledger_sha` now refuses a dirty tree — `dirty tree: no ledger row — commit, then
gate the tip`, exit 2 — and `gate_ledger_record` prints that and returns 0 without writing,
like every other refusal it makes: it runs from EXIT traps, and under `set -e` (fineprint,
memento, orbit, kidsquest, ghiecode) a non-zero return there replaces the gate's own exit code
and skips its teardown. The capture is `|| shrc=$?` for the same reason. `gated()` keeps
ignoring old `-dirty` rows, and its fixture stays to prove it.

**The suite proves the hook ran, and refuses to run unless root.** The entry below moved the
fixtures through the hook; this one adds the evidence (backlog 264b). A clean fixture commit must
add a `caller=root … result=clean` line to `/var/log/fleet-secrets-check.log`, the whole run must
add more, and a planted random `ghp_` token must be refused without being printed. Per the
advisor's 2026-10-03 ruling (root counted, not capped, by secrets-cap-175; app users stay capped;
no shim, no redirected counter) the suite refuses to start unless it is root — `lib test.sh
commits through the fleet hook: run it as root (advisor ruling 2026-10-03)` — never skips and
never goes hooks-off. Its test probe exits 3, never 0, so a leaked `LIB_TEST_ROOT_PROBE` cannot
pass a gate. This supersedes the entry below's owner-run allowance: scribly and reflection (via
`as_owner`), ghiecode and ghie-writes (whole gate under `runuser`) move the lib-suite step to
root at re-vendor.

## S1 lets a test harness drive git through a candidate guard, in a repository it made (2026-10-03)

**Ghie's approval, 2026-10-03 (advisor + personal-vps).** A merge or `am` hook can only be proved
by running git through it: `pre-merge-commit` fires on `git merge`, `pre-applypatch` on `git am`,
and nothing short of a real merge or `am` invokes either. Without this exception the only way to
see such a hook run is to install it live, untested, as the guard every commit on the box passes
through. The first use is fleet packet 284+285 (orbit), the `pre-merge-commit` and
`pre-applypatch` dispatchers.

**Allowed only when all seven hold:**
- (a) the repository is one the test created itself in a scratch directory, and a trap deletes it
  on every exit the shell can trap; the scratch root is reaped otherwise;
- (b) `core.hooksPath` points only at candidate copies of the fleet guard: a hook-ON path, a
  directory that contains the guard — never `/dev/null` and never an empty directory;
- (c) the repository holds fixture content only and has no push remote;
- (d) the packet's own `DECISIONS` names this exception;
- (e) the setting is written with `git config --local` inside that repository: never `--global`
  or `--system`, never a `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` redirection, and never
  `-c core.hooksPath=` at all — a command-line `-c` is not repo-local config, and S1 bans it;
- (f) the candidate directory is sha-checked against the packet's `SHA256SUMS` before use, and the
  harness asserts it is hook-ON;
- (g) the harness's last step proves byte-unchanged, by plain text reads (`cat`, `sha256sum`,
  `grep`) and never a `git config` read as root: every real tree's `/var/www/*/.git/config` and
  any per-worktree `config.worktree`, the global `/root/.gitconfig` and the system
  `/etc/gitconfig`, and the fleet hooks directory.

**Everything else stays as it was.** Anything that points hooks away from a guard is an absolute
finding, in a fixture or anywhere else, except a T5 mutant run that meets every condition in the
next paragraph. Every other repo-local `core.hooksPath` is a finding exactly as before, whatever
the diff held; a harness that misses any one condition is not under this exception at all.

**Deliberately broken copies, for T5 (Ghie's approval, 2026-10-03, advisor + personal-vps).** T5
asks for a guard's test to go red with the guard line deleted, so a harness may run a saved mutant
of a hook or of itself only when (a)–(g) hold, with (b) and (f) relaxed for that one file: the
hooks directory may also hold the single mutant `HARNESS_MUTANT` names, sha-checked like every
other entry, and (f)'s hook-ON assert still runs against everything else in it. The rest of
(a)–(g) holds unchanged, and so do:
- (1) mutant mode is switched on by name (`HARNESS_MODE=t5` and `HARNESS_MUTANT=<file>`); without
  it the harness admits only `githooks/` entries of its `SHA256SUMS`, by sha;
- (2) every mutant is listed in the packet's `SHA256SUMS` under a path outside `githooks/`, so
  normal mode can never admit one;
- (3) the real fleet pre-commit, byte-equal to the one in the fleet hooks directory, stays in the
  directory `core.hooksPath` names, so setup commits still pass it;
- (4) the harness makes the repository itself with `mktemp -d` under its own lane, writes a marker
  file into it, and refuses mutant mode unless the repository's top level is that marked
  directory — never under `/var/www`, never a registered worktree, never a path passed in;
- (5) before any mutant runs, it asserts that no remote has a reachable push URL;
- (6) the unmodified harness checks (1)–(5) itself before it starts any mutant, including a mutant
  of the harness, and the mutant runs only as its child.

This applies only inside a T5 harness that meets (1)–(6) as well as (a)–(g). It is no precedent for
any other `core.hooksPath` use: every use that falls under neither this nor the (a)–(g) exception
stays an S1 finding.

**The option not taken:** installing the candidate hook live and watching the next real merge.
That tests the guard on production work, and a broken dispatcher would either refuse every merge
on the box or, worse, pass them all in silence.

## The fleet check discovers its projects, and `docs/STANDARDS.md` is what joins one (2026-10-03)

The list of ten project names lived in the script, so joining the fleet meant two edits in two
repositories and a pull request nobody thinks of: vendor the standard, then come back here and
add the name. The check now takes its projects from `$ROOT/*/docs/STANDARDS.md` — the very file
the rest of the script measures — so vendoring the file is joining the check, and there is no
second place to forget. The names dropped out of the script; the rows did not change on the day
of the change, only their order, which is now the root's own rather than the order someone typed
them in — pinned to C collation inside the discovery loop, so the report does not reorder itself
when it is run from a session with a different locale than cron's.

`STANDARDS_PROJECTS` still overrides, and still refuses to be empty: set-but-empty is a caller
whose list did not come out, and falling back to discovery there would answer a question nobody
asked. A root where nothing is vendored is the same refusal (exit 2), never a clean fleet of
zero. What keeps an override entry a name and not a pattern is `read -r -a`, which splits on
whitespace and never pathname-expands; `set -f` is defence in depth for the rest of the script,
not the mechanism, and the case-18 test goes red against a rewrite that word-splits an unquoted
expansion instead — deleting `set -f` alone leaves it green. The one glob this script wants is
expanded inside `discover_project_names_c_ordered`, which lifts `set -f` and pins `LC_ALL=C` for
that loop alone.

`*-staging` and `*-worktrees` are excluded on **both** sides — discovery and the UNLISTED row —
through one helper, `is_fleet_project_name`, because two copies of that pattern are two things to
keep in step and the first version of this change already had them disagree. A deployed staging
checkout mirrors the files of the project it deploys (this box ran two when the change was first
written, and none on the day it merged): once it pulls a vendored `docs/STANDARDS.md`, it would
join the fleet as a project of its own without the exclusion and report STALE on its deploying
project's schedule — a watchdog failure for a directory nobody ever adopted.

Discovery cannot report a project as un-adopted, because an un-adopted directory is no longer a
project, and something *is* lost with that. A project whose directory disappears — renamed,
moved, un-deployed — used to be a MISSING row and exit 1, because its name was written into the
script; it is now invisible, and a fleet of nine reads exactly as clean as a fleet of ten. The
UNLISTED row catches only the narrower case where the directory is still there with a `.git` in
it. We take that trade rather than keep a floor list of names that must exist, because that list
is the hard-coding this change removes and it would have to be maintained by the same forgotten
pull request. Whether a project still exists is the box's inventory to answer, not this script's.

Two consequences for the watchdog, named here rather than changed. Its MISSING-row rollout timer
(`/usr/local/sbin/vps-health-check.sh`, the `standards.armed` / `unarmed-since` arming) is no
longer reachable from the default path: discovery emits no MISSING row, so
only an explicit `STANDARDS_PROJECTS` list can arm it. And a project directory the running user
cannot traverse is now invisible instead of MISSING — the glob cannot expand into it, and the
UNLISTED row's `.git` test fails on the same permission — so a non-root run reports a smaller
fleet, quietly, where it used to report a row.
