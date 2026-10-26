# A mutant is checked before its red is believed

A deletion mutant can go red for a reason that has nothing to do with the guard it removed, and the
red then reads as proof. Three of these have happened: deleting one line inside an if-block left the
script unparseable, so every case failed on a syntax error; a mutant copied without its exec bit
failed on "permission denied"; and a stale sed range removed more lines than the one under test.
`scripts/mutant-sane.sh <original> <mutant> [<from>[-<to>]]` refuses each of these before a sweep
trusts the red, and also refuses a mutant that is not a regular file on disk (a FIFO or a `<(...)`
path is read once, so a multi-case suite sees it empty on every later case) and one identical to the
original.

Each check looks removable and is not. The mode comparison looks redundant when a sweep copies with
`cp -p`, but a hand-made mutant is often `sed ... > copy` and loses the exec bit. The parse check runs
only when the original has a bash or sh shebang, because other files are not bash and would fail it
for no reason. The exact-deletion check compares bytes, not "some line went missing": with a range,
the mutant must equal the original with exactly those lines removed (and the range must lie inside
the original), and without one, `diff` must show one removed line and nothing added or changed.
A symlink is refused, not followed, for the original as well as the mutant: `/dev/fd/N` is one, and it
names whatever descriptor N holds in the process that opens it, so a case's child can read something
else, or nothing. `[ -L ]` looks at the last name after the kernel has resolved `//`, `..` and every
symlinked directory before it, so `//dev/fd/N`, a `..` route and a link to `/dev/fd` are all caught.
Resolving first (`realpath -e`, `readlink -f`) would not do: in the checker's own process it turns
`/dev/fd/N` into the file N holds there and passes it. A link a sweep made to a good file is refused
too, which costs nothing, because sweeps write real files. A hardlink is a regular file and is judged
by its bytes: one to the original is byte-identical, so it is refused.

A replacement mutant, `<line> --replaced-with <text>`, must equal the original with exactly that line
swapped for exactly that text, matched byte for byte, so `&` and backslashes mean themselves; the
line keeps its newline or its lack of one, so a sweep that adds a final newline is refused. Text with
a newline is a usage error, since it would swap one line for several. Text equal to the line's own is
refused as byte-identical, and a line past the end is refused before the comparison, which would
otherwise accept text appended to the file. Both forms count lines as awk does, so a last line with no
newline counts and may be deleted. `scripts/guard-mutants.sh` runs the check on every mutant it writes, after
its own `bash -n`, which stays a separate outcome: it parse-checks any target `bash -n` accepts,
including sourced libs with no shebang that this check skips. A refused mutant is never counted red,
and the summary line only gains a last field, so anything reading the older fields still matches.

It cannot see a deleted `exit` after which the script still prints the message a suite greps for:
the mutant is sane and the suite is weak. Suites assert the exit code as well as the text.
