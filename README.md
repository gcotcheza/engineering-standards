# Engineering standards

One engineering standard for a small fleet of production web apps — Laravel, Symfony and
a couple of static sites — built and maintained by one person with an AI-assisted
workflow, where most of the code is written by AI sessions and reviewed before it ships.

`ENGINEERING-STANDARDS.md` is the standard itself: 37 rules in four groups (Code, Tests,
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
loud failure, never a skip), then the five fixture-only tests — `scripts/lib/deploy/test.sh`,
`scripts/fleet-versions-test.sh`, `scripts/fleet-budget-test.sh`, `scripts/queue-start-test.sh`
and `scripts/gate-image-tags-test.sh`. A full run records to the fleet gate ledger
(`scripts/lib/deploy/ledger.sh`); `scripts/check.sh --only N` runs one step alone and
records nothing, so debugging a step never pollutes the ledger. This repo carries no
`docs/DECISIONS.md`; this section is the record of why the gate is shaped this way.

`scripts/gate-image-tags.sh <project-root>` is rule T9's check, and this repo's seventh gate step
runs its fixtures. Point it at a project root and it names the compose files it read, the image
values it could not resolve, and any tag that project builds for both its gate and production. It
never passes in silence, so "nothing is built here" and "I could not tell" cannot be confused.

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

**A deploy script finds its helpers in its own directory.** Before any `cd`, `scripts/deploy.sh`
captures its own directory as an absolute path — `SCRIPT_DIR="$(cd -- "$(dirname --
"${BASH_SOURCE[0]}")" && pwd)"`, the pattern this repo's own scripts already use — and resolves
`docs-only.sh`, `verify.sh` and every other helper from `SCRIPT_DIR`, never from `ROOT`. `ROOT`
names only the checkout being deployed: on a first deploy its `scripts/` are not on the box yet,
so a helper resolved through it exits 127 and the landing gets done by hand instead. A project's
standards test greps `deploy.sh` for `"$ROOT/scripts/` and fails the gate on a match.

First landing, once per project, from a clone: `DEPLOY_ROOT=/var/www/<app> bash
<clone>/scripts/deploy.sh <PR#>` — never a hand landing.

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

`scripts/queue-start.sh` starts queued backlog work without anyone watching for the moment to
start it. Every half hour it asks `scripts/fleet-budget.sh` whether there is headroom — the
three meters from the CLI's own usage endpoint against the caps in `/root/fleet-budget.conf`
(`FIVE_HOUR_MAX`, `WEEK_ALL_MAX`, `WEEK_FABLE_MAX`, defaults 50/60/60), plus the box's capacity —
and on `ok` it types one sentence into the pane of each idle session that owns a queued item:
`[queue-start automation] budget ok (<numbers>): next queued item for <session> is <N> — <title>.
Start it by your rules, or mark it hold in /root/backlog-owners.` Anything unreadable is a hold.
Ownership and priority live in `/root/backlog-owners` (`<item> <session> [hold]`, order =
priority), checked by `scripts/backlog-owners-lint.py`. Ghie's cron line, in
`/etc/cron.d/queue-start`: `*/30 * * * * root /usr/local/sbin/queue-start >>/var/log/queue-start.log 2>&1`,
with a logrotate stanza beside merge-notify's. `--dry-run` prints the pane and the sentence and
delivers nothing; `--once <session>` runs one session for real.
