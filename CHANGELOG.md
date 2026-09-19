# Changelog

## 2026-09-19 — three rules stop claiming more than they check; the gate obeys T3 (VERSION unchanged)
From the audit of claims nobody had exercised (fleet backlog 83/87). The class hunted was a statement
the system makes about itself that nobody proved by running it, and three of these rules were in it.

**C10** credited "static analysis" with finding dead code. PHPStan finds unused *private* members only;
an unused public method or an orphaned front-end module is invisible to it unless a project has wired
the extra tooling, and four of the fleet's projects have not. The clause now says review, and says what
static analysis does and does not see. Wiring the extension remains the better fix where a project can
afford it — what is not acceptable is a rule that reads as though the tooling is already there.

**S6** said every gate "refuses to run in a deployed checkout". Three of five do. Two isolate their
writes from it instead, deliberately, because their gate runs in overlay mode — a legitimate second
shape the rule had no words for, so a project doing the right thing read as non-compliant. Both shapes
are now named, and a project says in its `CLAUDE.md` which it is.

**C7** named a project as its example of a wired boundary tool. This repository is public; the rules
carry tools and shapes, never project names.

**The gate itself broke T3.** `scripts/check.sh` ran its slowest step (the deploy library's tests,
4.74s) third, with four cheaper steps behind it — the header said so honestly and called reordering a
backlog item. The seven steps were timed individually (0.03, 0.30, 0.32, 1.27, 1.75, 2.08, 4.74s) and
renumbered in that order. The numbers are in the header and in `docs/DECISIONS.md`: re-measure before
reordering again.

**`docs/DECISIONS.md` now exists.** The repo kept its long-form why in the README and pointed a code
comment at a `docs/DECISIONS.md` it did not have, while W7 tells every project to keep one. It does now.

VERSION does not move: the rules' meaning is unchanged, and the vendored copies' sha256 is what tells a
project its text is out of date.

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
