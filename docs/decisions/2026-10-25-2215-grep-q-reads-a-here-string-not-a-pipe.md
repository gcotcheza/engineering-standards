# grep -q reads a here-string, never a pipe

Under `set -o pipefail`, `<writer> | grep -q <pattern>` can give the wrong answer. grep -q exits at
the first matching line; if the writer then writes again, it gets SIGPIPE and exits 141, and
pipefail makes the whole pipeline fail. A match then reads as a miss, and a negated check
(`! ... | grep -q`) passes. All it takes is one more write after the matched line. Output past the
64 KiB pipe buffer does that every time. A short multi-line output does it now and then, because
bash's printf builtin may write a few lines in several calls: on the VPS's bash 5.2.21, case 30 of
gate-image-tags-test (577 bytes) went out in 7 writes with the match in the 6th, and the old pipe
missed it about once in 3000 runs (card 730).

So capture the text, then hand it to grep as a here-string: `grep -q <pattern> <<<"$text"`, or
`x=$(<writer>)` and then `grep -q <pattern> <<<"$x"`. A reader that consumes all its input
(`grep -c`, `wc`, `sort`, `sha256sum`) is safe in a pipe, and so is `head -n 1 | grep -q`: head has
written its one line before grep can match it. Cards 704 and 730.
