# Decisions are one file each, and the change that adds the 10th rolls them up

**One file per decision.** Every branch that recorded a why appended to the bottom of one
`docs/DECISIONS.md`, so any two branches in flight conflicted there, and the second to merge
spent a rebase on prose. A file per decision, named `YYYY-MM-DD-HHMM-<slug>.md`, never collides
with another branch's, and its name sorts newest last. Fineprint has worked this way since
2026-09-05 (`docs/decisions/` there, with a frozen `DECISIONS.md` above it); W7 takes its file
form unchanged: `# <Title>`, a blank line, then prose.

**The roll-up rides in the change that adds the 10th file (Ghie, 2026-10-22).** A directory of
hundreds of files is not a history anyone reads, so the files are folded back into
`docs/DECISIONS.md`. The cadence is ten files, not a calendar: one roll-up per ten decisions, and
no separate pull request for Ghie to merge, because the change that adds the 10th runs
`scripts/decisions-rollup.sh` in the same branch and `decisions-check.sh` fails until it does.
Make the roll-up its own commit inside that change, titled `Rolled up N decisions into
DECISIONS.md`, so a reviewer can read the feature and the fold apart. A change that only rolls up
is docs-only and needs no test run (T1).

**A roll-up only appends.** Each entry is `### <slug>`, `*YYYY-MM-DD — <Title>*` and the body
unchanged, in filename order, at the bottom; nothing above moves. Two branches that both roll up
append at the same place, so the second either meets a conflict or, resolved carelessly, carries
one slug twice; the check names both, and a rolled `### <slug>` whose file changed or appeared on
main since the branch began, with "rebase onto main and re-run decisions-rollup.sh". The roll-up
itself refuses, writing nothing, on anything it could not fold faithfully, and is a no-op when there
is nothing to fold; the full list of refusals and findings lives in each script's header only, so it
cannot drift between copies. It refuses rather than repairs a file not in the full form, because it
copies from line 3 on and would otherwise drop line-2 prose, and it never follows a symlink, which
could fold in a file from outside the tree.

**Pointers are slugs, never line numbers.** `decision: <slug>` resolves to a file or to a rolled
`### <slug>`, so it survives the roll-up; a line number in either place moves with every roll-up
and every edit, so the check rejects it outright. The legacy `docs/DECISIONS.md: <slug>` form
resolves the same way. A slug is two or more lowercase words joined by hyphens: a one-word slug
made English prose read as a pointer (`the floor decision: the machine-wide floor` in this repo's
CHANGELOG was the first false hit). A comma list (`, `, ` and `, ` or `) names every slug in it, and
one that ends a line with a comma carries on to the next, because KidsQuest's `CLAUDE.md` wraps a
three-slug list that way; `DECISIONS:` and `` `DECISIONS.md`: `` spell the same pointer. Pointers are
judged in every tracked file, fenced blocks included: a fenced example is still read and copied as
real, so an example writes `<slug>`, which no slug matches.

**Where it runs, and what it refuses to judge.** Both scripts take the root and a git seam,
`DECISIONS_GIT`, which may be several words: on the box an app tree is app-owned, so it is
`DECISIONS_GIT="git-as <app> -C <tree>"`. They refuse, with git's own message, a root git does not
know, and a root that is not the top of its work tree (`rev-parse --show-toplevel` against
`pwd -P`): a subdirectory or a mistyped root holds no `docs/decisions/`, so it would pass by
judging nothing. `docs/decisions/.gitkeep` is the one other file allowed there and the roll-up
leaves it, so an emptied directory survives. A file saved with CRLF endings gets its own finding,
not a misleading "line 2 is not blank".

**The opening line.** While `docs/decisions/` holds files, a reader who opens `docs/DECISIONS.md`
must be told the newest decisions are elsewhere, so its first ten lines carry one exact line, the
one W7 quotes, and the check fails without it.

**Where the check runs in this repo's gate.** The check on this tree and the W4 closing-line test
take well under a second and sit in step 2 beside the other check of this tree's own text. The two
fixture suites take about ten seconds each and are step 10, placed last without a measurement; the
order in `scripts/check.sh` should be re-measured before anyone moves them. Their guard-deletion
mutants run as root in a scratch directory, not as `nobody`: the fixtures commit through the fleet
hook, which blocks a `nobody` commit (its personal-data layer hop fails) and is never bypassed.

**Apps migrate one owner at a time** (`ROLLOUT.md`, a row per app). Measured 2026-10-23 on fresh
clones: KidsQuest and Orbit already pass (their logs are `### <slug>` entries), and Fineprint does
not: 102 unrolled files beside a log it froze on 2026-09-05, whose `## Title` entries its pointers
cannot reach.
