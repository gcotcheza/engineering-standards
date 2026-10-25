# A worktree whose git config names a filter is kept, and every status forces fsmonitor off

**Card 714.** Card 694 left three gaps, each a program a tree's own git config can make git run.

**`worktree remove`.** Root's `${GIT} worktree remove` runs a `status` of its own inside the
worktree, which started the tree's `core.fsmonitor` program. It is now `${GIT} -c
core.fsmonitor=false worktree remove`, options after the seam as every other `${GIT}` call puts
them; card 694's probe showed the override reaches that inner `status`.

**The other `status` calls.** `preflight.sh`'s two read `ROOT`, the app's checkout, which the app
user can configure; `compose.sh`'s reads the same tree as the app user; `ledger.sh`'s two read the
gate's tree, which the developer owns. A non-root user can set `core.fsmonitor` in each, so all
five force it off. None was safe without it.

**Filters.** A `filter.<name>.clean` or `.process` program is run by `status` (and by `worktree
remove`'s inner `status`) on a tracked file whose stat changed, with fsmonitor off too (probed on
git 2.39.5 in a throwaway container). No single `-c` turns every filter off. So `cleanup_filters`
reads `git config --show-scope --get-regexp '^filter\..+\.(clean|process)$'` through `WT_GIT`
before `status`, and again just before `worktree remove`; a match in any scope but `system` (which
only root can write) keeps the tree as `filter`, and a failed read keeps it too. `diff.*.textconv`
is not checked: the same probe showed `status` never runs it.

**The limits, plainly.** The read is not atomic with the git call after it: an app that writes a
filter in that instant still has its program run, by `status` as its own uid through `git-as`
(no escalation), or by root's `worktree remove` in the shorter window the second read leaves. A
submodule's own config is not read, and `status` recurses into submodules; `worktree remove`
refuses a tree with submodules. A box whose app-user global config names a filter (git-lfs, say)
keeps every worktree as `filter` until that changes.

**The rest of the library.** Its other git calls (`rev-parse`, `merge-base`, `branch -r`,
`cat-file`, `show`, `fetch`, `worktree list`, and the commit-to-commit `diff`s in `resolve.sh` and
`ledger.sh`) never read a working tree, so fsmonitor and filters never start; they are unchanged.
