# The after-deploy cleanup keeps every worktree reached through a link and never removes it

**What went wrong.** Card 676 (#63) made the root-owned check look behind a worktree that git lists
by a link path, but left a clean linked worktree removable. `git worktree remove <link>` deletes
the files in the real folder and then fails on the link itself ("Not a directory"). The summary
then said `kept 1 (remove)`, while the folder had been emptied: a report that is not true (C9).
The same comparison by text also missed a process in the real folder, since a process's working
directory always reads as the real path (card 677).

**The rule.** `cleanup_worktree` reads the worktree's `realpath -e` (pinned, as `find` is) before
any other check. When it differs from the path git lists, because the worktree or a folder above
it is a link, the worktree is kept with the reason `link`, and the summary prints one line:
`kept <link> -> <real>: linked worktree, not removed; remove by hand with git -C <repo> worktree remove <link>`.
When the real path cannot be read, the worktree is kept with the reason `realpath`. A mount source
is compared both as written and as its own `realpath -m`.

**Why disk stays watched.** The scratch reaper (W10) still lists and reports these trees, so a kept
linked worktree does not grow unseen; removing one is a human step.

**The limit.** The by-hand command is the same `worktree remove`: run on the link it empties the real
folder and leaves the link and an empty folder, which the person running it then deletes.
