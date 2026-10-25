# The gate ledger refuses a run whose tree moved between arm and record

**Card 717.** A commit landed in a Fineprint worktree while a gate ran, and the ledger holds green
rows for 1a9b835 that the orchestrator says no run read. `gate_ledger_record` already refused a
HEAD that moved since `gate_ledger_arm` (acaeee2), and the rows still landed, so the HEAD check
alone is not enough: under one HEAD the files can still change. A tree dirty at arm and cleaned
(checked out, stashed or reset) before record passed every check, and so did a tree that went dirty
between record's dirty check and its tree read; the second was even pinned by a test as a row with
tree `-`, and a sha-keyed green row counts whatever its tree says.

`gate_ledger_arm` now also stores `gate_ledger_tree` of the armed sha, the tree identity the ledger
already writes: the commit's tree after a status that ran clean, otherwise `-`. Record re-reads it
after the HEAD check, and a different value writes no row at all, the lib's existing dirty rule,
with one stderr line naming both. The return code stays 0, as for every other refusal, so a
`set -e` gate still reaches its teardown. Health Tracker's own `ci.sh` writes a changed tree as
`<sha>-dirty`; the shared lib keeps its no-row rule (backlog 268) instead.

Not covered: `-` at both ends. A status or tree read that cannot run at arm and again at record
still writes the `-` row card 329 settled on, so a tree dirty at arm whose status then fails at
record can still land; and an edit made and undone inside the run is invisible at both ends.
