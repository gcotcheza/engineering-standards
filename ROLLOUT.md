# Rollout — how one standard applies to many repositories without becoming many standards

## The recommendation, in three sentences

**Vendor one file per repo and let the harness load it — (a) + (c) combined — with (b) underneath as a machine-wide floor.** The canonical text lives in a small `engineering-standards` repository; each project vendors it byte-identically at `docs/STANDARDS.md`, adds `.claude/rules/standards.md` as a **symlink** to that same file (symlinks inside `.claude/rules/` are supported, for single files and directories), and its own gate runs a drift test on it — so *one* copy is at once readable on GitHub, reviewable in a PR diff, and loaded at launch into every session started in that project. Underneath it, a canonical clone on the host with a symlink into the user-level rules directory gives every session the same rules even when it starts outside a project, and each project's `CLAUDE.md` keeps only what is genuinely local.

Two things this design depends on, both worth stating plainly:

- **No `paths:` frontmatter on the rules files.** A rule file *without* `paths:` loads at session launch like `CLAUDE.md`; one *with* a `paths:` glob loads lazily, only when a matching file is read. A standard that only appears once someone happens to open a PHP file is not a standard.
- **Subagents are not guaranteed to receive rules** — the documentation does not say either way, so we must not assume it. That is exactly why worker briefs keep quoting the bar verbatim (the comment cap, the four PR headings), and why the **repo copy still matters**: a reviewer on GitHub, a laptop checkout and a worker in a scratch clone all see the file, whatever the harness did or did not load.

**Precedence**, low to high: managed policy → user (`~/.claude`) → project (`./CLAUDE.md`, `./.claude/rules`) → `./CLAUDE.local.md`. That runs the right way round: the fleet floor sits at user level, and a project can override it in its own repo — which is where a written exception belongs.

## Why this combination, and what each part costs

| Option | What it gets right | What it costs / why not alone |
|---|---|---|
| **(a) Canonical repo + vendored `docs/STANDARDS.md` + gate drift check** | The rules travel with the code: a GitHub reviewer, a laptop checkout and a scratch-clone worker all read the same text the author did. The gate turns drift into a failing test instead of a discovery, and it needs no network. | Nothing pulls the update by itself — a project can sit on an old version until someone opens the bump PR. On its own it is also invisible to the harness: nobody's session *loads* it, they have to go and read it. |
| **(b) Canonical clone on the host + a symlink into the user-level rules directory** | Zero copies and zero drift by construction — one file on disk, applied to every project on the machine, loaded at launch by every session including ones started outside any project. | Invisible on GitHub, invisible to a laptop, invisible in a PR diff, and **not guaranteed for subagents** — so it silently does not cover the situations where a worker is most likely to do damage. It is a floor, never the whole thing. |
| **(c) Per-repo `.claude/rules/standards.md`** | In the repo *and* loaded at launch, which is exactly the gap (a) leaves; it is drift-checkable like any other tracked file, and project precedence means a local exception can legitimately override the fleet floor. | A second file per repo if you copy it — which is why we make it a **symlink to `docs/STANDARDS.md`** rather than a duplicate: one set of bytes, one hash, one thing to drift-check, and `docs/` keeps the human-facing path people already link to. |

**What we deliberately do not use: cross-repo `@path` imports.** `CLAUDE.md` can import other files by path (absolute paths allowed, nesting up to 4 deep), which looks like the obvious way to point many repos at one canonical file — but an import that points **outside the project triggers a one-time approval dialog**. With a set of mostly unattended always-on sessions, that is a session sitting on a prompt nobody is there to answer. A symlink is resolved by the filesystem and asks nobody anything.

## The mechanism, concretely

1. **Canonical repo** `engineering-standards`: `ENGINEERING-STANDARDS.md`, `SOURCES.md`, a `VERSION` line, and its own `CHANGELOG.md`. Changes go through the same flow as code — branch, PR, four headings, the owner merges.
2. **Machine-wide floor:** clone the canonical repo once onto the host, then symlink `ENGINEERING-STANDARDS.md` into the user-level rules directory (`~/.claude/rules/`). No `paths:` frontmatter, so every session loads it at launch. Updating the floor is `git pull` in one directory.
3. **Vendored copy** in each project at `docs/STANDARDS.md`, byte-identical, carrying a header line of the form `<!-- standards-version: <this repo's VERSION> · sha256: <sha256 of the body> -->` — the space after `sha256:` is not optional, `scripts/fleet-versions.sh` requires it, plus `.claude/rules/standards.md` as a symlink to it (`ln -s ../../docs/STANDARDS.md .claude/rules/standards.md`). One file, two doors.
4. **Drift check in the project's gate**, modelled on a pattern one of the Laravel projects already uses: a unit test that reads a *second file* out of the repo and asserts the two halves agree. Here it hashes the vendored file, compares it to the hash declared in its own header, and fails if a local edit crept in — and asserts the symlink still resolves. **Its version assertion must accept `YYYY-MM-DD` and `YYYY-MM-DD.N`** — the canonical VERSION takes a serial from the second change of a day onward, and the five tests written before 2026-09-19 assert a bare date, so each adoption or bump PR widens its own regex. No network, so it cannot make the gate flaky.
5. **A fleet-level update pass** (an always-on session, not a project gate) compares each project's declared version against the canonical repo and opens the bump PR where they differ. That is the only piece that needs to see both repos at once. `scripts/fleet-versions.sh` is that check.
6. **Each `CLAUDE.md` shrinks** to roughly:

```markdown
# <Project> — house rules
Fleet engineering standards: docs/STANDARDS.md (also loaded via .claude/rules/standards.md).
They apply here in full; anything below overrides them and says why.
- Where work happens: <worktree path / clone / staging checkout> — this checkout is <production / not production>.
- Merging to main <does / does not> deploy. Runbook: .claude/commands/deploy.md.
- The gate: <scripts/check.sh | scripts/ci.sh>. Browser gate: <scripts/e2e.sh | none yet>.
- Layers: <one line, or "none — plain MVC">.
- Why-decisions: docs/DECISIONS.md.
- Project-specific rules below.
```

## Step 0, before any project PR

Set the floor up first — it is one clone and one symlink, it needs no project's cooperation, and it means the sessions that run outside any project already have the standard while the per-project PRs are still being written:

```
git clone <engineering-standards> <canonical-path>
ln -s <canonical-path>/ENGINEERING-STANDARDS.md <non-project-session-dir>/CLAUDE.md
```

`<non-project-session-dir>` is the directory those sessions start in (a home directory, typically). Do not put the floor in the user-level `~/.claude/rules/` or `~/.claude/CLAUDE.md`: those load in *every* session, so once a project vendors its own copy (step 3) the standard sits in that session's context twice, on every call.

Then verify it the way rule W9 asks — start a headless session from a subdirectory of that directory and read which files its transcript says were loaded — rather than concluding it from the fact that the symlink exists.

## Three things to decide before starting

- **Who owns the canonical file.** One repo, one reviewer, changes by PR — otherwise the vendored copies will disagree within a month, which is exactly the failure this whole exercise exists to prevent.
- **Where the floor lives.** Recommended: a project-level `CLAUDE.md` symlink in the directory the non-project sessions start in, not a user-level rule. A user-level `~/.claude/rules/` file is one line to add and remove, but it loads in every session on the machine, and after the rollout that doubled the standard in every project session (measured at roughly 3.5k tokens re-read per call). Either way it is a floor and never the whole answer — subagents are not guaranteed to receive it.
- **What a project does when it cannot meet a rule yet.** Recommended: an `## Exceptions` block in its own `CLAUDE.md`, each line naming the rule, the reason and what would have to be true to drop it. Silence must stop being an option — it is what conflicts 6 and 7 in `SOURCES.md` are made of.

## T9 — where each project stands

A rule that needs a change in several repositories needs a status, not a schedule. `scripts/gate-image-tags.sh <project-root>` is the check; run from the canonical clone against each project root — the way `scripts/fleet-versions.sh` is — this is the tally on 2026-09-19. A tally and not a list of names on purpose: this repository is public, and where a live system is weak *today* is not something to publish. The named detail lives with the owner.

| Where a project stands | Projects |
|---|---|
| The gate's tag is already separate from production's | 4 |
| **Still builds one tag for both the gate and production** | **1** |
| Builds no app image at all — the code is bind-mounted | 2 |
| Builds an image but has no gate compose file to share it with | 2 |
| No compose file beside the root | 2 |

**The tally above was measured with a check that could not see an implicit tag** (fixed 2026-09-25,
`CHANGELOG.md`). Two projects sat in the bind-mount row because every production service they build
names no `image:`; re-run against them today each resolves 4 built tags, and their row is "builds an
image but has no gate compose file to share it with". The whole tally is owed a re-measurement on
the new check before it is quoted again — the rows here are the 2026-09-19 reading, not today's.
One further residue: a compose file named outside `*ci*`/`*e2e*`/`*prod*` that builds nothing is
still read as production on its filename alone, so a gate file under such a name that only *runs*
production's tag is the one collision shape the check still cannot report.

One of the four is clean by its gate script rather than by the check: its compose files carry `${CI_APP_IMAGE:?…}`, which has no default and so resolves to nothing, and the per-branch tag is set in that project's `scripts/ci.sh`. The check says so itself — it counts and names every value it could not resolve, and never reports a clean sweep over values it did not judge — and that row was read from the gate script, not inferred from a clean-looking verdict.

**Merge order.** This repository's clone on the host is what every project gate calls by path, so
a change to `scripts/gate-image-tags.sh` reaches all of them the moment that clone fast-forwards.
Where a check change turns one project red and that project's own fix is already open, the project
fix merges **first**; otherwise that project's gate is red, on this box, on a hole it has already
closed. That is the order for the 2026-09-29 check change and the open project PR it names.

The one remaining fix is that project's own pull request, not this repo's: the gate compose file takes a tag of its own (`<app>/app:ci`, or `${CI_APP_IMAGE:-<app>/app:ci}` so a worktree can hold one per branch), and the project's gate calls the check. Until then the standing risk is the one that has already happened once — a gate run on any branch leaves production one `up -d` away from a container built from unmerged code.

### T9's second half is not mechanised

| Open work | What is missing | Owner |
|---|---|---|
| "a deploy builds the production tag itself and proves the running container by image id" | No project compares `docker inspect -f '{{.Image}}'` against the image id its deploy built. The deploy verifiers read `{{.State.StartedAt}}` instead, which a gate-built image satisfies exactly as well, and the nearest thing to a content check counts PHP extensions the offending image also had. The rule binds today; nothing checks it. | each project, in its own PR |

**How a project runs it.** From the canonical clone, not a vendored copy: the check reads only the compose files it is pointed at, so there is no project state to drift and nothing to re-stamp — unlike `scripts/lib/deploy/`, which a deploy script must source. A project whose gate must run without the canonical clone present vendors it like any other script and says so in its `CLAUDE.md`.

## T1's dependency-advisory step — where each project stands

The audit clause added to T1 on 2026-09-30 needs a change in several repositories, so it
needs a status rather than a schedule. This is a survey of the nine project gates as they
stood on 2026-10-01, read out of their gate scripts. A tally and not a list of names, for
the reason the T9 tally gives: this repository is public, and which live system is blind
*today* is not something to publish. The named detail lives with the owner, in the backlog
card this came from.

| Where a project's gate stands | Front end (`npm`) | Back end (`composer`) |
|---|---|---|
| Audits in the gate | 6 | 6 |
| Runs no dependency audit in the gate at all | 2 | 2 |
| Audits, but outside the gate, in a separate security script nothing gates on | 1 | 1 |

The two columns come up short on the same three gates: the two that audit nothing audit
neither half, and the one whose audit sits in a separate script runs both halves there. Of
the six that do audit in the gate, five run the composer step in exactly the form T1 names.
The sixth leaves `--no-dev` off, so it reads the development tree as well — wider than the
clause there — but its verdict comes from a report that passes any advisory below High and
can waive a named High by id: narrower in what actually fails it, and a severity floor is
the one thing T1 says the composer step never carries. That project's own file already
records the half as T1-partial. Those same five run the npm step with `--omit=dev` and the
sixth runs it without, which is the form T1 asks of a gate whose deploy ships a bundle. All
six build a bundle — each carries a bundler config beside its manifest — so the front-end
half is work for five of them, not a population still to be filtered. It is each project's
own deploy that settles that, though, not this table: the clause is about what the deploy
ships, and a project that ships no bundle keeps `--omit=dev` and is already correct. A tenth
project on the fleet list has no front-end manifest and no gate script at all; it is outside
this survey rather than a clean row in it.

**How this one landed.** A gate in the first row exited 0 while a package under a published
High advisory sat in its shipped bundle — imported by an entrypoint, listed under
`devDependencies`. That is the failure the clause is written against, and it is why the
second and third rows are not "nearly fine": a check that runs outside the gate is a check
the merge does not wait for.

| Open work | What is missing | Owner |
|---|---|---|
| T1's audit clause reaches each project's gate, both halves | The three gates with no in-gate step add both — `composer audit --locked --no-dev --abandoned=report` and the front-end one. Five of the six that already audit keep their composer step as it stands and drop `--omit=dev` from the npm step where the deploy ships a bundle; the sixth's npm step already reads the whole tree and needs nothing; its composer step reads wider than T1's form but fails only at High and can waive a named High, so that floor comes off before that half meets the clause. Each proves the front-end step the way T1 asks: one devDependency the bundle imports pinned to a published High advisory, the gate run, **the gate's own** failure line quoted, then reverted. Nothing here can do that for a project — only its own gate can say whether its own step fails loudly. | each project, in its own PR |

**Merge order.** Unlike the T9 check, nothing in this change reaches a project through
GitHub: the clause is text, and a project reads it when it re-vendors `docs/STANDARDS.md`.
Three gates compare their vendored copy against this repository's canonical clone on this
host by path, so each goes red the moment that clone's standard changes — not when the pull
request merges — and red on every branch of that project, because the comparison is against
the clone rather than against the branch. As of 2026-10-01 two of the three have re-vendored
and merged; the third's re-vendor pull request is written and reviewed, and that gate stays
red until it merges. The rest notice nothing until they bump.

## The 2026-10-01 clauses — project-side work, not yet measured

Three of the four clauses added on 2026-10-01 create work inside the projects rather than
in this repository, and that work needs a status rather than a schedule. A tally and not a
list of names, for the reason the T9 and T1 tallies give: this repository is public, and
which checkout or runbook is loose *today* is not something to publish. The named detail
lives with the owner, in the backlog card this came from.

| Project-side work the clauses create | Projects affected |
|---|---|
| S1: checkouts carrying a repo-local `core.hooksPath` aimed anywhere but the fleet hooks directory (a test harness's throwaway repository under the 2026-10-03 exception is not one) | not yet measured |
| W8: deploy runbooks to audit for a name set in one fenced block and read in another | not yet measured |
| T5: existing guard suites whose red proof changed the input, to redo by deleting the guard | not yet measured |

Every cell is honestly empty: no survey has been run, and a number nobody measured would be
read as one somebody did. A blank is not a zero, and nothing downstream should infer either.
The clauses bind on the next commit, the next runbook step and the next guard test whatever
the survey eventually says — it measures the size of the backlog, not whether the rules apply.

## The after-deploy cleanup — the re-vendor round, not yet started

`scripts/lib/deploy/cleanup.sh` is in this repository and tested here. Its one live caller is
`/usr/local/sbin/fleet-merged-reap`, on a timer every 15 minutes, which sources an installed copy at
`/usr/local/lib/fleet-merged-reap/cleanup.sh`: a change here reaches production when that copy is
re-installed, not through any project. No project's deploy calls it yet:
no project vendors it, `LIB_FILES` in `scripts/fleet-versions.sh` does not compare it, and
`scripts/lib/deploy/VERSION` has not moved, so no project is reported `DIVERGED` for a file it
does not have. Arming it is one round of eight small pull requests, one per project, and they
want doing together — the version bump that makes the fleet check see the file is the same
change that would otherwise turn every project's row red for work nobody has done.

| Open work | What is missing | Owner |
|---|---|---|
| Each project's `deploy.sh` arms the trap | `trap deploy_cleanup EXIT` on the line before each success-path `finish` call — including the docs-only landing five of the eight finish early — plus the five seam assignments (`WT_GIT`, `REAP`, `DOCKER`, `PROC_ROOT`, `CLEANUP_ROOT_UID`) beside the ones it already makes, and `. "$LIB/cleanup.sh"` beside the other four. Where a success path already traps `EXIT`, the existing handler calls `deploy_cleanup`: a second `trap … EXIT` replaces the first, it does not add to it. The table below says which lines each project has. | each project, in its own PR |
| The fleet check compares the new file | `cleanup` added to `LIB_FILES` in `scripts/fleet-versions.sh`, and `scripts/lib/deploy/VERSION` bumped with the serial a second change in one day takes, in the same change as the last project's re-vendor | this repository, in the re-vendor PR |
| The gate stops leaving root-owned files in a worktree | The `rootfiles` check keeps a worktree it cannot explain, and it will keep a good share of them: of 28 merged worktrees measured on 2026-10-01, 11 were kept and all 11 carried at least one root-owned file — five of one project's seven rows among them, its gate-written `.env`. Until that gate writes as the app user, those trees are removed by hand. | each project whose gate writes as root |
| Scratch lanes carry a label | `fleet-scratch-reap` reaps only a directory holding a `.fleet-scratch` file naming its repo and PR, and lanes carry one now: a depth-2 `find` for `.fleet-scratch` under `/srv/worker-scratch` counted 8 on 2026-10-01, the command and its output quoted in `docs/DECISIONS.md`. Whoever creates a lane writes the label, and its `repo=` field holds `owner/repo` — what `deploy_cleanup` passes as the reaper's first argument. Rule 18 of the fleet worker rules has whoever creates a lane write `repo=gcotcheza/<name>` and `pr=<n>`; this pull request's own lane reads `repo=gcotcheza/engineering-standards`, so that spelling is matched literally rather than only contracted. | the worker briefs, separately |

| Project | The success-path `finish` | A docs-only `finish` as well | Already traps `EXIT` on the success path | `DEPLOY_SUCCEEDED=1` lines to add |
|---|---|---|---|---|
| fineprint | the last `finish` in its deploy function | yes, after its `LANDED docs-only` line | no | 2 |
| ghiecode | the last `finish` | no | yes — `app_home_close`, armed before that `finish` | 1 |
| health-tracker | the last `finish` | yes, inside its `if classify` block | no | 2 |
| kidsquest | the last `finish` | yes, after its `LANDED docs-only` line | yes — `report_root_owned`, armed *after* the docs-only `finish`, so that path arms `deploy_cleanup` directly and only the main path needs the handler to call it | 2 |
| memento | the last `finish` | yes, after its `LANDED docs-only` line | no | 2 |
| orbit | the last `finish` | yes, after its `LANDED docs-only` line | no | 2 |
| reflection | the last `finish` | no | no | 1 |
| scribly | the last `finish` | no | no | 1 |

The last column is one `DEPLOY_SUCCEEDED=1` per `finish` named in the two `finish` columns, on the
line immediately before it. `deploy_cleanup` reads that marker before anything else, which is what
makes ghiecode's and kidsquest's unconditional calls safe on a refusal: unset, it prints
`did not run: the deploy did not reach finish.` and removes nothing.

Nothing above is a schedule. The library half is finished and proved; each row is a change
somebody has to open, and the cleanup does nothing at all until the first one merges.

## A gate step that never got a slot is NOT RUN, not FAILED

`heavy-work` exits 75 when it has waited its hour and never started the work. The canonical
`scripts/lib/deploy/ledger.sh` now writes no ledger row for rc 75, so the commit stays ungated
rather than red. The other half is each gate's own step runner, and nothing here can do it for
them: the library never sees a step.

| Open work | What is missing | Owner |
|---|---|---|
| A step that exits 75 ends the gate with `=== GATE NOT RUN (step N: name — heavy-work gave up) ===` and exit 75, never `GATE FAILED` | Each adopter's `check.sh`/`ci.sh` still turns a give-up into its ordinary failure banner, which sends someone looking for a failure that never ran. Each takes the convention when it next re-vendors `scripts/lib/deploy/`, where the header comment names it and `docs/DECISIONS.md` carries the full text. | each project, in its own re-vendor PR |

## The 2026-10-03 S1 exception — merge order

**Merge order.** The exception is text, and a project reads it when it re-vendors
`docs/STANDARDS.md`; no project code changes. Three gates — fineprint's and health-tracker's
`ci.sh` standards-drift steps and orbit's `scripts/standards-drift.sh` — compare their vendored
copy against this host's canonical clone by path, so each goes red on every branch the moment
that clone is pulled to the new text, not when the pull request merges. The order is therefore:
prepare the three re-vendor branches first, merge this change, pull the canonical clone, then gate
and merge the three re-vendors back to back. The rest notice nothing until they bump, and
`scripts/fleet-versions.sh` reports them `STALE` until then.
