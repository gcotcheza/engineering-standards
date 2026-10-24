# A deploy-lib version names one tree, and the gate makes every lib change raise it

**What went wrong.** `scripts/lib/deploy/VERSION` was set to 2026-10-16 by card 527, and the lib then
changed three more times without moving it: `ownership.sh` twice more for card 527 the same morning,
and `test.sh` for card 547 on 2026-10-19. An app that vendored 2026-10-16 early holds different files
from GhieCode's fresh copy (GhieCode #37), and nothing in either tree says so. The fleet check reads
the per-file headers, so it caught neither case: `ownership.sh` is not in its `LIB_FILES`, and
`test.sh` carries no header.

**The rule.** Any change to a file under `scripts/lib/deploy/`, tests included, raises `VERSION` in
the same change. `scripts/deploy-lib-version.sh` checks that in gate step 2, beside
`version-text-pair.sh`, on the commits from the merge base with `origin/main` to HEAD. The working
tree is not judged, and rename detection is off, so a file moved out of the lib counts as changed.
It fails when a lib file moved and `VERSION` did not, and when `VERSION` is not one dated line. It
also fails when `VERSION` does not rise above both the merge base's value and `origin/main`'s. The
second comparison catches two branches from one base that both bump to the same value: whichever is
re-gated after the other merges fails. A missing `origin/main`, no merge base, or a failed git call
exits 2 and judges nothing.

**The limit.** Two branches gated before either merges both pass. Merging the second without a
re-gate on main's new tip would still leave one name for two trees. Merging main into a branch
before it lands, which the fleet already does, closes that gap.

**Why tests count.** An app runs the lib's own `test.sh` and `*-test.sh` from its vendored copy
(gate step 9 proves that path), so two copies with different suites are two different trees.

**Rising means `sort -V`.** Serials compare as numbers, so `.10` follows `.9`. The fleet check still
compares with a string `<`, which would order `.10` before `.9`. No day has needed ten serials, so
that is left as it is and named here.

**This change takes 2026-10-24.** The bump re-stamps every header, and no body changes. Every
project reads STALE in the fleet check until it re-vendors, which is the usual re-vendor round
after a standards merge. The bump does not touch `LIB_FILES` or arm `cleanup.sh` (`ROLLOUT.md`).
