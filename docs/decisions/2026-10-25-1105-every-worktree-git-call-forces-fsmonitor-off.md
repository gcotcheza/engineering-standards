# Every git call the cleanup makes in a worktree forces core.fsmonitor off

**Card 694.** A worktree belongs to the app user, and its config can name a program as
`core.fsmonitor`. Card 677 forced that setting off on the preview's `ls-files`, but the dirty
check's `status --porcelain` and the `.env` probe's `ls-files` still read it. Probed on git 2.39.5
in a throwaway container: with a worktree-only `core.fsmonitor` naming a script, a plain `status`
and a plain `ls-files -o -i` each started the script, and with `-c core.fsmonitor=false` neither
did. So every git call the cleanup makes through `WT_GIT` now carries the override, and the rule is
one sentence to audit: a `${WT_GIT-}` line without `-c core.fsmonitor=false` is a bug.

**`-C` comes first.** The seam is `WT_GIT="git-as <app>"`, and every other `git-as` call in the
library is `git-as <user> -C <tree> ...`; `test.sh`'s fake checks the tree's owner only when `-C`
follows the user, as the real one does. The preview's call put its options before `-C`, so it now
puts `-C` first like the other two.

**Why `ROLLOUT.md` names the seam's value.** Root runs the deploy. With `WT_GIT=git`, root's git
refuses a worktree root does not own (`fatal: detected dubious ownership`, exit 128, probed the same
day), `status` fails, and `cleanup_worktree` keeps the tree on its `status` line. Nothing is lost,
but no worktree is ever removed, so a project that forgot the value would look armed and reclaim
nothing.

**The limit.** `${GIT} worktree remove` does not pass through `WT_GIT` and is not changed here.
It runs a `status` of its own inside the worktree, and in the same probe a plain `worktree remove`
started the worktree's fsmonitor script while `git -c core.fsmonitor=false worktree remove` did not.
That call is left to its own card, as are the `status` calls in `preflight.sh` and `compose.sh`
(in `ROOT`) and in `ledger.sh` (the gate's tree, at gate time), none of which force it off.
