# One guard-mutant runner, holding only what every packet's copy meant the same way

Card 578, 2026-10-23.

Six hand-written T5 sweeps existed (card 434b `run-mutants.sh` and `run-install-mutants.sh`, their
434c copies and `run-reap-mutants.sh`, card 491 `guard-mutants.sh`). `scripts/guard-mutants.sh` takes
what all six do the same way (C1) and nothing that only some do (C2):

| | every copy | where they differ — left to the caller |
|---|---|---|
| mutation | one line changed in a copy saved on disk | exact-line text (434b/c) or a grep-picked line number (install, 491) |
| no-op | a copy equal to the original is not a mutant | it exits (434b/c) or counts as not red (install, reap, 491) |
| verdict | the suite run against the mutant | named `FAIL <case>` lines (434b/c) or a last line not `0 failed` (install, 491) |
| result | a line per mutant, a count, non-zero unless all red | serial or `xargs -P 3`; root (reap) or nobody; temp under `TMPDIR`, `/tmp` or a dir aside |

**The table is exact text, never a line number.** A number cannot be refused when it hits the wrong
line; text that matches no line, or more than one, is refused before any case runs, so a mutant can
never silently no-op. A target with two identical guard lines needs one of them reworded first.

**A case is a shell command and its verdict is its exit code**, run with `MUTANT_TARGET` set to the
copy. That covers both verdict styles (a case can grep a log for `^FAIL T3 `) and both ways a suite
was handed its mutant (an env var, or the copy dropped into a packet tree). Who runs it and how
parallel is the caller's: a sweep of a script that copies, chmods or deletes still runs as `nobody`.

**New: the case must be green on an unmutated copy.** No source copy checked this, and a case already
red on the original makes every mutant "red" and proves nothing. Each distinct case runs once on the
original, and a red one refuses the run.

**A red only counts when the case really ran (review of #57).** A mutant whose copy fails `bash -n`
is refused, not red: a syntax error fails almost any case. A target that is not bash on the original
(491's Python) skips that check, and says so. Each case runs in a fresh empty directory, so state a
case leaves cannot fake red on the next run nor land in the caller's cwd, and under `timeout`
(`GUARD_MUTANTS_TIMEOUT`, default 120s, fractions allowed so the suite stays quick); a timeout is a
failure, never red. The case runs as a background job the runner `wait`s on, because bash defers a
trap until a foreground child exits; bash runs the EXIT trap on TERM and HUP itself (measured: an
extra `trap 'exit 143' TERM` survived deletion), and that trap stops the case and removes the temp dir.

**Step 3, by measurement.** Best of three on 2026-10-23: `version-text-pair` 0.64s, then
`guard-mutants-test.sh` 1.30, `fleet-versions-test.sh` 1.38, `fleet-budget-test.sh` 1.30 — the last
three within noise — so it runs third and the old steps 3–8 are now 4–9. Proven on card 491's 40-line
selection, converted in a lane: `40, 40 red`, matching that packet's own sweep (before this round's
changes). Moving the packets onto the runner is later work.
