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
itself refuses, writing nothing, on uncommitted decision files, a file changed on main since the
merge base, or a slug collision, and is a no-op when there is nothing to fold.

**Pointers are slugs, never line numbers.** `decision: <slug>` resolves to a file or to a rolled
`### <slug>`, so it survives the roll-up; a line number in either place moves with every roll-up
and every edit, so the check rejects it outright. The legacy `docs/DECISIONS.md: <slug>` form
resolves the same way. A slug is two or more lowercase words joined by hyphens: a one-word slug
made English prose read as a pointer (`the floor decision: the machine-wide floor` in this repo's
CHANGELOG was the first false hit).

**The opening line.** While `docs/decisions/` holds files, a reader who opens `docs/DECISIONS.md`
must be told the newest decisions are elsewhere, so its first ten lines carry one exact line, the
one W7 quotes, and the check fails without it.

**Where the check runs in this repo's gate.** The check on this tree and the W4 closing-line test
take well under a second and sit in step 2 beside the other check of this tree's own text. The two
fixture suites take about ten seconds each and are step 10, placed last without a measurement; the
order in `scripts/check.sh` should be re-measured before anyone moves them. Their guard-deletion
mutants run as root in a scratch directory, not as `nobody`: the fixtures commit through the fleet
hook, which blocks a `nobody` commit (its personal-data layer hop fails) and is never bypassed.

**Apps migrate one owner at a time** (`ROLLOUT.md`), KidsQuest first as the worked example. An
app's existing `## Title` entries and `docs/DECISIONS.md: <slug>` pointers do not resolve against
`### <slug>`, so each migration either renames its pointers to files or rolls them up.
