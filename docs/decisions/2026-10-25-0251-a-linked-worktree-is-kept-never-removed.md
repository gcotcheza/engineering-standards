# The after-deploy cleanup keeps every worktree reached through a link and never removes it

**What went wrong.** Card 676 (#63) made the root-owned check look behind a worktree that git lists
by a link path, but left a clean linked worktree removable. `git worktree remove <link>` deletes
the files in the real folder and then fails on the link itself ("Not a directory"). The summary
then said `kept 1 (remove)`, while the folder had been emptied: a report that is not true (C9).
The same comparison by text also missed a process in the real folder, since a process's working
directory always reads as the real path (card 677).

**The rule.** `cleanup_worktree` reads the worktree's `realpath -e` (pinned, as `find` is) and runs
the process, mount, root-owned-file and ignored-`.env` checks on that real path. When one refuses,
its reason is reported and nothing more is printed. When all pass and the real path differs from
the path git lists, because the worktree or a folder above it is a link, the worktree is kept with
the reason `link`, and the summary prints one line:
`kept <link> -> <real>: linked worktree, not removed; remove by hand with: git -C <repo> worktree repair <real> && { [ ! -L <link> ] || unlink -- <link>; } && git -C <repo> worktree remove <real>`,
every path quoted with `printf %q`, so a space or a shell character in a path cannot widen the command.
Just before it, the ignored paths `worktree remove` would delete are previewed and counted (S7):
a read-only `ls-files -o -i --exclude-standard --directory` with `core.fsmonitor` forced off prints
the count and the first five, or `0 ignored paths`; when they cannot be listed, no line is printed.
When the real path cannot be read, the worktree is kept with the reason `realpath`. A mount source
is compared both as written and as its own `realpath -m`.

**Why disk stays watched.** The scratch reaper (W10) still lists and reports these trees, so a kept
linked worktree does not grow unseen; removing one is a human step.

**Why that sequence.** Tried on git 2.39 against a worktree moved and linked back:
`worktree remove <link>` and `worktree remove <real>` both emptied the real folder, dropped the
record and failed on the link ("Not a directory"); `rm <link>` then `worktree prune` dropped the
record but left the folder. Repairing the record to the real path first, then unlinking the link,
lets the ordinary `worktree remove <real>` end clean: no record, no link, no folder. It is never
run with `--force`, so a tree with modified or untracked files still refuses and is left whole, its
record now naming the real path. Ignored files do not make it refuse: git deletes them with the
tree. An ignored `.env*` is held back by the `envfiles` check, which runs first, so no line is
printed for a tree carrying one; any other ignored file is still deleted by the printed sequence,
which is why it is previewed and counted first.
Under a linked parent folder the `[ ! -L <link> ]` test skips the unlink, and the parent link stays.

**The limit.** The cleanup only prints the sequence; a person runs it.
