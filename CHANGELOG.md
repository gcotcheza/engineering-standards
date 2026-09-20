# Changelog

## 2026-09-20 — W4: a PR's title is one past-tense action (VERSION 2026-09-20)
Ghie, on a Memento PR titled "The phone never caches card images": **"when creating a PR, title should be
action, 'what was done?' Like this should be: Added caching for card images."**

W4 already governed the PR body and said nothing about the title, so the rule was carried in each
session's head and applied unevenly. It belongs in W4 rather than in a rule of its own because the title
and the four headings are one object — what the person deciding to merge reads — and splitting them would
put half the guidance where nobody looking at the other half would find it.

The previous release claimed this rule in its own title and did not carry it: PR #11 was called "Added S7
(preview before any bulk delete) and W4's title rule" and its diff to the standard added S7 alone. Found
by reading the merged text rather than the PR (W9), which is the same class of mistake the standard's own
audit was hunting — a claim nobody exercised.

## 2026-09-19 — S7: nothing is deleted in bulk until its read-only twin has run (VERSION 2026-09-19.2)
Ghie, on being handed a `docker volume prune` line to type: **"Make this fleetwide, very important."**

The near miss, found by the personal-vps session: a prune offered as finished gate leftovers would also
have taken a live app stack's named database volume. Docker counts a **torn-down** stack's named volume
as dangling — `compose down` removes the containers that held it, and nothing then holds the volume — so
`docker volume prune --all` proposes data while reading as a cleanup. An "are you sure?" and a dry run
caught it. That volume turned out to be empty; on a stack that had ever run it would have been data with
no backup. Reproduce the shape, read-only, before trusting any count:
`docker volume ls -f dangling=true --format '{{.Name}}' | grep -vcE '^[0-9a-f]{64}$'` — on 2026-09-19 that
is 56 named volumes, including the database and search volumes of six gate and review stacks.

The rule's second half is not about Docker: **a refusal by a permission layer is never re-routed to a
person without the preview and the count.** A layer refusing a destructive command is a decision, and
handing the same line to someone else walks around it.

**VERSION takes a serial** — a date alone cannot distinguish two changes made on one day, and a project
vendoring between them reads DIVERGED ("local edit re-stamped?") rather than STALE. Two things follow:
`scripts/fleet-versions.sh` validated the canonical VERSION as a strict date and would have refused to
report on any project at all (it now accepts `YYYY-MM-DD[.N]`, with a test for each), and every project's
drift test asserts the same shape, so **each adoption or bump PR widens its own regex** — ROLLOUT.md
step 4 says so. The invariant the serial trades into — every change to the body moves VERSION — is
checked by review until a gate step enforces it; `docs/DECISIONS.md` records both.

## 2026-09-19 — three rules stop claiming more than they check; the gate obeys T3 (VERSION unchanged)
From the audit of claims nobody had exercised (fleet backlog 83/87), which hunted statements the system
makes about itself that nobody proved by running them. C10 credited "static analysis" with finding dead
code most of it cannot see; S6 claimed every gate refuses a deployed checkout, when two of five isolate
their writes instead, deliberately; C7 named a project, in a public repository. What each rule now says,
and why both S6 shapes are legitimate, is in `docs/DECISIONS.md`.

The gate itself broke T3: `scripts/check.sh` ran its slowest step third with four cheaper ones behind it.
The seven steps were timed individually and renumbered cheapest-first; the measurement, and the caveat
that steps 4 and 5 sit inside run-to-run noise, are in `docs/DECISIONS.md` — which now exists, because
the repo kept its long-form why in the README while W7 tells every project to keep the file.

**VERSION does not move, and there is a window to know about.** VERSION is a date, and PR #9 moved it to
`2026-09-19` earlier today, so two different bodies now carry that string. `scripts/fleet-versions.sh`
reaches STALE only when the declared version differs, so a project that vendored the text *between* #9's
merge and this one reads DIVERGED — "local edit re-stamped?" — when it has done nothing wrong. Today's
five adopters all declare `2026-08-23` and correctly read STALE. Land this before the next adoption, and
no project ever sits in the window.


## 2026-09-19 — a gate must not build the image production runs (new rule T9; VERSION moves to 2026-09-19)
Backlog 80, found by the personal-vps session reviewing Memento #99: Memento's live container was
recreated from a `memento/app:latest` that a browser-gate run on an unmerged branch had overwritten,
so it came up carrying the `gd` and `exif` extensions that only that branch builds. Memento's own fix
has since shipped. Running the new check across every project on the box on 2026-09-19 answers: **one
project still builds one tag for both its gate and production**, and that fix is its own pull request;
the rest either keep the two apart already, build no app image, or have no gate compose file at all.
ROLLOUT.md carries the tally — counts and not names, because this repository is public.

T9 has two halves: a gate's image tag is separate and disposable, and a deploy builds the production
tag itself from the merged tree and proves the running container by image id rather than by tag.
`scripts/gate-image-tags.sh <project-root>` is the first half's check; its own header says what it
reads, and this file does not repeat it. **The second half has no check anywhere yet** — no deploy on
this box compares a running container's image id against the id its deploy built — so T9 says so
plainly rather than naming a mechanism that does not perform the check, which is the very failure the
rule exists to stop. ROLLOUT.md carries it as open work.

`scripts/gate-image-tags-test.sh` drives the check from fixtures in a temp dir: a shared tag, separate
tags, a resolved `${CI_APP_IMAGE:-x/app:ci}`, a default that IS the production tag, a gate that only
runs a tag it did not build, an unresolvable `${VAR:?}`, a build inherited through a YAML merge key, an
untagged image, an unrecognised compose filename, a double-quoted value, a `compose.yaml`, a symlinked
file, a CRLF file, a bind-mount project and an empty directory. Ten mutations were made against a
scratch copy, one per behaviour, and the matching fixture went red every time. The check never exits
silently: it prints the files it read, the values it could not resolve and the built-tag count, because
a silent pass made "nothing is built here" and "I could not tell" look identical — and a build
inherited through `<<:` or `extends` counts as built, which is what made that silence reachable. The
gate grew a seventh step.

This entry changes the standard, so VERSION moves to 2026-09-19 — every vendored `docs/STANDARDS.md`
is STALE to `scripts/fleet-versions.sh` until its project takes the bump. README: the rule count,
"The gate", and `scripts/gate-image-tags.sh`.

## 2026-09-19 — deploy scripts find their own helpers (docs only; the standard is unchanged and VERSION is not bumped)
Backlog 76, found by the orbit session landing its own PR #89 today: a project's
`scripts/deploy.sh` that resolves `docs-only.sh` and `verify.sh` through `"$ROOT/scripts/…"`
cannot land itself — on a first deploy those helpers are not on the box yet, so the call exits
127 and the first landing had to be done by hand instead. The vendored `scripts/lib/deploy/`
files were already loaded the right way, from the script's own directory, not `$ROOT`'s. README:
"A deploy script finds its helpers in its own directory".

## 2026-09-19 — a busy pane's queued line no longer looks undelivered (tooling only; the standard is unchanged and VERSION is not bumped)
`scripts/queue-start.sh` borrowed its delivery transport from merge-notify, including the
verified-Enter loop that expects the input row to go empty. When the target session is mid-turn,
Claude Code queues a typed line instead of clearing the row — the sentence still arrives at the
next turn boundary, but the loop saw the row non-empty after 3 Enters, logged it as not
delivered, and recorded nothing in the state file, so the next tick would type the same sentence
again. `deliver()` now checks, after the Enter tries, whether the row still holds OUR sentence
(the existing 10-char-prefix check) with no permission dialog on screen; if so it logs
`queued in a busy pane <p>: <session> item N (the line is consumed at its next turn)` and returns
success, so the caller records the item like a normal delivery. A row holding something else, or
a dialog on screen, keeps the old behaviour unchanged. `merge-notify` is untouched.

## 2026-09-19 — queued work starts itself under a budget (tooling only; the standard is unchanged and VERSION is not bumped)
`scripts/fleet-budget.sh` answers one question in one line: `ok <numbers>` or `hold <reason>`.
It reads the three meters the CLI's own `/usage` shows, from the endpoint the CLI uses
(`/api/oauth/usage`) with root's OAuth token, and holds when any meter is at or above its cap
(`FIVE_HOUR_MAX=50 WEEK_ALL_MAX=60 WEEK_FABLE_MAX=60`, overridable in `/root/fleet-budget.conf`),
when the box is over a capacity red line (load15 above the core count, under 1500 MB available,
memory `full avg300` above 10), or when anything is unreadable — a token that is missing or
expired, a 401, an unreadable `/proc` value. Unreadable is never coerced to zero. The response
is cached for ten minutes at mode 600; the token is never printed, logged or written anywhere.

`scripts/queue-start.sh` is the half-hourly tick that turns a green budget into work starting.
For each session in `/root/backlog-owners` it types one marked sentence into that session's pane
with merge-notify's transport and its safety (dialog defer, stranded-line handling, verified
Enter). A session is idle only if it keeps a registry file and that file is empty, no
`<app>-deploy-*` unit is active for an app it owns, and heavy-work holds no slot for it; a
missing registry means not idle, so a session opts in by keeping one. There is no walk-down:
only a session's top queued item is ever announced, and if that item is held or was announced
within 24 h the tick says nothing for that session.

`scripts/backlog-owners-lint.py` is red when a queued item has no owner, when an owners line
names an unknown session or an item that is not in the backlog, or when a line is malformed.

The gate grew two steps: `scripts/fleet-budget-test.sh` (5) and `scripts/queue-start-test.sh` (6).
Both are fakes only — a fake meter JSON, fake `/proc` files, a fake backlog, owners, registries,
budget script, `systemctl` and `heavy-work`. No network, no credentials, no tmux, no delivery.

## 2026-09-19 — the gate ledger cannot record green for a run that did not finish (tooling only; the standard is unchanged and VERSION is not bumped)
2026-09-19 05:58Z Fineprint's `scripts/e2e.sh` was killed while its stack was starting. The
EXIT trap read `$?` from the last command that had finished — 0 — and wrote a green `e2e` line
for that head; `scripts/ci.sh`'s cleanup has the same shape. `gate_ledger_record` now writes
rc 0 only when the gate script has set `GATE_SUITE_PASSED=1` after its suite returned 0.
Sourcing `ledger.sh` now `unset`s `GATE_SUITE_PASSED` at the top level, so an operator's
`export GATE_SUITE_PASSED=1` (or a CI wrapper's) is discarded rather than honoured — only the
gate script's own shell, set after its own suite, counts. Without the flag an rc of 0 is written as 1, loudly: `gate-ledger: rc 0 without
GATE_SUITE_PASSED — the run did not finish; recorded as a failure` on stderr. A non-zero rc is
unchanged. The reader is now newest-wins — the last line for a (sha, kind) decides, so a later
red overrides an earlier green and a re-run's green overrides an earlier red; the old awk took
any green line, so one false green vouched for a head forever. `scripts/check.sh` sets the flag
once its four steps have run. `scripts/lib/deploy/test.sh` gains eight groups (flag, no flag,
non-zero rc, green→red, red→green, append order deciding over an out-of-order timestamp, an
inherited env export discarded at source time, and 05:58Z's incident end to end); each was proved red once
against a mutated copy of the library. `scripts/fleet-versions-test.sh` reads the deploy-lib
VERSION instead of hardcoding it. deploy-lib VERSION is 2026-09-19, and `ledger.sh` changed
again in this same version, so `fleet-versions.sh`'s byte-for-byte file comparison catches
Fineprint, Reflection and Scribly's vendored copies first: they report DRIFTED, not STALE,
until they re-vendor — the VERSION comparison is never reached. Fineprint's `ci.sh` and `e2e.sh` set the
flag after their suites at the same time. README: "The gate ledger".

## 2026-09-18 — repo gate + deploy-lib drift check (tooling only; the standard is unchanged and VERSION is not bumped)
`scripts/check.sh` — this repo's own pre-merge gate: `bash -n` on every tracked script,
shellcheck (`koalaman/shellcheck:v0.10.0`, style severity, no `-x` — a missing image fails
loud, never skips), `scripts/lib/deploy/test.sh`, then `scripts/fleet-versions-test.sh`;
cheapest first (T3), prints `=== GATE OK ===` / `=== GATE FAILED (step N: name) ===`, and
records a full run to the fleet gate ledger the same way Fineprint's `ci.sh` does — a
partial (`--only N`) run records nothing. `scripts/fleet-versions.sh` now also compares
each project's vendored `scripts/lib/deploy/` against canonical: one extra parsable line
per project (`none` / `MISSING` / `STALE` / `DRIFTED` / `BADHEADER` / `ok`), same shape the
watchdog's line parser already reads, existing lines and exit codes unchanged. A body
edited without re-stamping the header is `DRIFTED`; a body edited AND re-stamped correctly
is also `DRIFTED` — the case a project's own drift test cannot see. `scripts/fleet-versions-test.sh`
proves both against fakes; each case proved red once. README: "The gate" and one sentence
under the fleet check.

## 2026-09-18 — vendored deploy library (tooling only; the standard is unchanged and VERSION is not bumped)
`scripts/lib/deploy/` — `summary.sh`, `resolve.sh`, `ledger.sh`, `preflight.sh` and its own `VERSION`, the shared half of a deploy script that Fineprint, Reflection and Scribly each needed (C1: the third copy). Moved out of Fineprint's `scripts/deploy.sh` rather than rewritten: same function names, same sentences. Every file carries `# fleet-deploy-lib <VERSION> sha256:<body>` on line 1 and each project's gate recomputes it, which is the same drift mechanism `docs/STANDARDS.md` already uses. `scripts/lib/deploy/test.sh` proves every function, every refusal sentence and every header against fakes; each check was proved red once. README: "Vendored scripts".

`resolve.sh` fix: Reflection's first live deploy refused at resolve — `gh pr view` with no `-R` infers the repo from the cwd's git remote and shells out to git as root inside the app-owned checkout, which "detected dubious ownership" and produced `REFUSED: gh could not read PR #20`. `gh_repo` now derives `owner/repo` from `git remote get-url origin` (scp, `ssh://` and `https://` forms), `DEPLOY_GH_REPO` overrides it, an unparsable origin refuses before any `gh` call, and the one `gh` call in the lib now carries `-R`. The old test's fake `gh` never checked for `-R`, so it never would have caught this; it now rejects a missing `-R` and the pre-fix `resolve.sh` proves red against it.

## 2026-09-16 — rollout note (docs only; the standard is unchanged and VERSION is not bumped)
ROLLOUT.md step 0 and the floor decision: the machine-wide floor goes in the CLAUDE.md of the directory the non-project sessions start in, not in the user-level rules folder, because a user-level rule loads in every session and doubles the standard in every project that has vendored its copy. Verification is a headless session's transcript, not the symlink's existence.

## 2026-09-04 — published
Published: README, LICENSE, ROLLOUT and SOURCES rewritten for a public reader; the standard itself unchanged.

## 2026-08-23 — fleet-level check (tooling only; the standard is unchanged and VERSION is not bumped)
`scripts/fleet-versions.sh` compares every project's vendored `docs/STANDARDS.md` against the canonical clone — the one comparison no project gate can make, since each project's drift test only checks its copy against its own header. Reports ok / MISSING / UNREADABLE / BADHEADER / DRIFTED / DIVERGED / STALE / VERSION / NOLINK / BADLINK; a project with no vendored copy, or a run that checks zero projects, is a failure rather than a pass. Prints the canonical HEAD it measured against. ROLLOUT.md step 5.

## 2026-08-23 — first adopted version
36 rules in four groups (Code C1–C13, Tests T1–T8, Security & privacy S1–S6, Workflow W1–W9), derived from what the nine projects already practised; nine cross-project conflicts resolved (SOURCES.md); proposals P1 (dependency audit in the gate) and P3 (three facts in every project header) adopted, P2 deferred to the next browser-gate touch per project, P4/P5 kept as notes. Rollout one project at a time; see ROLLOUT.md for the mechanism. Adopted by Ghie.
