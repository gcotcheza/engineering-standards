# Engineering standards

One engineering standard for a small fleet of production web apps — Laravel, Symfony and
a couple of static sites — built and maintained by one person with an AI-assisted
workflow, where most of the code is written by AI sessions and reviewed before it ships.

`ENGINEERING-STANDARDS.md` is the standard itself: 36 rules in four groups (Code, Tests,
Security & privacy, Workflow). Each rule is stated three ways — **the rule**, *why it
exists*, and **how it is checked** — on the principle that a rule nothing checks is a
preference, and preferences drift.

`SOURCES.md` is the receipt. Every rule was already practised in at least one project
before it was written down; this file records the text it came from, and the nine places
where two projects had already answered the same question differently and one had to win.

`ROLLOUT.md` is how one file reaches many repositories without becoming many standards: a
vendored `docs/STANDARDS.md` per repo, a `.claude/rules/standards.md` symlink to it, a
drift test in each project's gate, and a canonical clone on the host underneath as a
floor. `scripts/fleet-versions.sh` compares every project against the canonical copy; it ships
with one host's layout as its defaults — the canonical path, the projects root and the
ten project names — all overridable by environment variable. It also compares each
project's vendored `scripts/lib/deploy/` against canonical, one extra line per project
(`none` / `MISSING` / `STALE` / `DRIFTED` / `BADHEADER` / `ok`) in the same shape the
watchdog's line parser already reads.

## The gate

`scripts/check.sh` is this repo's own pre-merge gate, cheapest checks first: `bash -n` on
every tracked script, shellcheck (the pinned image, style severity — a missing image is a
loud failure, never a skip), `scripts/lib/deploy/test.sh`, then
`scripts/fleet-versions-test.sh`. A full run records to the fleet gate ledger
(`scripts/lib/deploy/ledger.sh`); `scripts/check.sh --only N` runs one step alone and
records nothing, so debugging a step never pollutes the ledger. This repo carries no
`docs/DECISIONS.md`; this section is the record of why the gate is shaped this way.

## Vendored scripts

`scripts/lib/deploy/` is the half of a project's `scripts/deploy.sh` that is the same
everywhere: `summary.sh` (what a deploy prints, and its log), `resolve.sh` (which commit a pull
request number means), `ledger.sh` (the gate ledger) and `preflight.sh`. A project copies those
four files and `VERSION` into its own `scripts/lib/deploy/`, byte-identical, and sources them.

Line 1 of each file is `# fleet-deploy-lib <VERSION> sha256:<sha256 of line 2 to EOF>`, and the
project's own gate recomputes it, so a local edit to a vendored copy is a failing test. After
changing a file here, re-stamp it: `h=$(tail -n +2 f.sh | sha256sum | cut -d' ' -f1); sed -i
"1s|.*|# fleet-deploy-lib $(cat VERSION) sha256:$h|" f.sh`

Taking an update is: copy the files, run the project's own deploy test, open the PR.
`scripts/lib/deploy/test.sh` proves the library against fakes alone — no checkout, no docker.
The standards `VERSION` is **not** bumped for a library change: the library carries its own.

**The gate ledger.** The EXIT trap is what records a run, and a trap that fires on a kill sees
`$?` from the last command that finished, not from the suite. Sourcing `ledger.sh` discards
any `GATE_SUITE_PASSED` inherited from the environment, so an operator's `export` or a CI
wrapper's cannot fake a pass; a gate script must set `GATE_SUITE_PASSED=1` itself, in its own
shell, immediately after its suite returns 0. Without that flag an rc of 0 is recorded as a
failure and says so on stderr. Reading is
newest-wins: the last line for a (sha, kind) decides, so a later red overrides an earlier green
and a genuine re-run's green overrides an earlier red.

**Who it is for.** Anyone running several small apps alone, or with AI agents doing the
typing, who wants one answer to "how do we do things here" that is enforced rather than
hoped for. It is not a proposal or a wishlist — it is in daily use, and the rules are
loaded into every coding session as context.

**A note on reading it.** Files referenced by the rules — `docs/DECISIONS.md`,
`scripts/check.sh`, `.claude/commands/deploy.md` — live in the individual project repos,
which are private. The rules describe what those files must contain, not where to find
them. Rule W3 says only Ghie merges: Ghie is the fleet's owner and sole merger, so the
rule reads as "the person who reviewed the change is the person who ships it".

**Licence.** Documentation CC BY 4.0, `scripts/` MIT. See `LICENSE`.
