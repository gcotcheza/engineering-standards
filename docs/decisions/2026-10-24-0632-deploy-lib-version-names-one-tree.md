# A deploy-lib version names one tree, and the gate makes every lib change raise it

**What went wrong.** `scripts/lib/deploy/VERSION` was set to 2026-10-16 by card 527, and the lib then
changed three more times without moving it: `ownership.sh` twice more for card 527 the same morning,
and `test.sh` for card 547 on 2026-10-19. An app that vendored 2026-10-16 early holds different files
from GhieCode's fresh copy (GhieCode #37), and nothing in either tree says so. The fleet check reads
the per-file headers, so it caught neither case: `ownership.sh` is not in its `LIB_FILES`, and
`test.sh` carries no header.

**The rule.** Any change to a file under `scripts/lib/deploy/`, tests included, raises `VERSION` in
the same change. `scripts/deploy-lib-version.sh` checks that in gate step 2, beside
`version-text-pair.sh`, against the merge base with `origin/main`. It fails when a lib file moved
and `VERSION` did not, and when `VERSION` moved without rising. That second guard catches an edit
to the same value or a step backwards, either of which would reuse a name. A missing base is a
failure (exit 1), as in `version-text-pair.sh`. A git call that fails is exit 2 and judges nothing.

**Why tests count.** An app runs the lib's own `test.sh` and `*-test.sh` from its vendored copy
(gate step 9 proves that path), so two copies with different suites are two different trees.

**Rising means `sort -V`.** Serials compare as numbers, so `.10` follows `.9`. The fleet check still
compares with a string `<`, which would order `.10` before `.9`. No day has needed ten serials, so
that is left as it is and named here.

**This change takes 2026-10-24.** The bump re-stamps every header, and no body changes. Every
project reads STALE in the fleet check until it re-vendors, which is the usual re-vendor round
after a standards merge. The bump does not touch `LIB_FILES` or arm `cleanup.sh` (`ROLLOUT.md`).
