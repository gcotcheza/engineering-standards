# One shared dialog check, sourced by queue-start and vendored by the Pi autoclear

Card 581, 2026-10-23.

**One master, not one regex per tool.** queue-start held its own `DIALOG_RE`, and the Pi's
session-autoclear held another; each fix landed in one and not the other. queue-start's copy read a
numbered Yes/No line anywhere, so a reply ending in a list ("1. Merge PR #19") was taken for a
dialog, and it read the screen with its escapes in, so a cursor drawn in colour
(`\e[38;5;153m❯\e[0m 1. Yes`), an underline with colon parameters or an OSC 8 link split the
line and the dialog was missed. It had no locale pin, and saw neither an option picker nor an exit
confirmation. `scripts/lib/dialog-lib.sh` is now the one check (`dialog_on <screen>`: 0 dialog, 1
none, 2 no C.UTF-8 locale); the autoclear vendors it byte-identical, and the dialog screens in
`scripts/queue-start-test.sh` are the same literals as the autoclear's suite.

**Only rc 1 means no dialog.** A check that cannot read the pane (rc 2, or any surprise) defers,
because typing into a dialog answers it and waiting costs one tick.

**A lib that does not load stops the tick, with exit 1.** queue-start otherwise exits 0, since a
cron job that fails loudly at 3am is a pager. Without the lib it cannot tell a dialog from a reply,
so it types nothing and says so in one line, and the non-zero exit makes the missed install step
visible to anyone reading the run. The lib is sourced at the top, before any pane is read, so a
half-installed box never reaches the typing code. It installs beside the fleet libs in
`/usr/local/lib/fleet/`, in the same packet as the queue-start copy, behind a `QS_DIALOG_LIB` seam
like the others.

**The T5 table is run by hand.** `scripts/queue-start-mutants.txt` holds the four guard mutants
(both load guards, the defer, and rc 2 counting as a dialog), all red on 2026-10-23. Each mutant
runs the whole queue-start suite, so the sweep is several times its cost; it stays out of
`scripts/check.sh` until the step order is re-measured with it.
