# Decisions

Why this repository is shaped the way it is, where the reason is too long for a
comment (C5) and too easy to lose (W7). One entry per decision, newest last; the
code carries a one-line pointer here, never the argument itself.

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

**What the rule is not.** Ghie, reviewing this entry on 2026-09-20: a file name in the
title is fine when the change is one file, and the tense is not the rule — *Fix the
flicker* is as good as *Added caching*. The rule is that the title is the action.

