# grep -q never reads a pipe; a guard that must fail closed reads all its input

Under `set -o pipefail`, `<writer> | grep -q <pattern>` can give the wrong answer. grep -q exits at
the first matching line; if the writer then writes again, it gets SIGPIPE and exits 141, and
pipefail makes the whole pipeline fail. A match then reads as a miss, and a negated check
(`! ... | grep -q`) passes. All it takes is one more write after the matched line. Output past the
64 KiB pipe buffer does that every time. A short multi-line output does it now and then, because
bash's printf builtin may write a few lines in several calls: on the VPS's bash 5.2.21, case 30 of
gate-image-tags-test (577 bytes) went out in 7 writes with the match in the 6th, and the old pipe
missed it about once in 3000 runs (card 730).

So a guard that must fail closed reads its input fully: keep the pipe and drop -q
(`<writer> | grep <pattern> >/dev/null`). grep then reads to the end, so the writer never takes
SIGPIPE, and nothing touches disk. A here-string is no cure for such a guard: bash 5.2 keeps one
larger than the pipe buffer in a temp file, and with the temp dir full it prints "cannot create temp
file for here-document", grep reads nothing and the guard reads a miss (card 745, ES #83 review).
A here-string (`grep -q <pattern> <<<"$text"`) is safe only when its failure fails closed or its
input is small. The test helpers keep it, `matches` in the deploy lib's test.sh too: there a failed
here-string is a FAIL. A reader that consumes all its input (`grep -c`, `wc`, `sort`, `sha256sum`)
is safe in a pipe, and so is `head -n 1 | grep -q`: head has written its one line before grep can
match it. Cards 704, 730 and 745.
