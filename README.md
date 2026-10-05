# Engineering standards

One engineering standard for a small fleet of production web apps — Laravel, Symfony and
a couple of static sites — built and maintained by one person with an AI-assisted
workflow, where most of the code is written by AI sessions and reviewed before it ships.

`ENGINEERING-STANDARDS.md` is the standard itself: 38 rules in four groups (Code, Tests,
Security & privacy, Workflow). Each rule is stated three ways — **the rule**, *why it
exists*, and **how it is checked** — on the principle that a rule nothing checks is a
preference, and preferences drift.

`SOURCES.md` is the receipt. Every rule was already practised in at least one project
before it was written down; this file records the text it came from, and the nine places
where two projects had already answered the same question differently and one had to win.

`ROLLOUT.md` is how one file reaches many repositories without becoming many standards: a
vendored `docs/STANDARDS.md` per repo, a `.claude/rules/standards.md` symlink to it, a
drift test in each project's gate, and a canonical clone on the host underneath as a
floor. `scripts/fleet-versions.sh` compares every project against the canonical copy; the
projects are the directories under the root that carry `docs/STANDARDS.md`, so vendoring the
file is what joins the check — bar a `*-staging` or `*-worktrees` directory, which mirrors a
project's files rather than being one. The canonical path, the projects root and the project list
itself are all overridable by environment variable. It also compares each
project's vendored `scripts/lib/deploy/` against canonical, one extra line per project
(`none` / `MISSING` / `STALE` / `DRIFTED` / `BADHEADER` / `ok`) in the same shape the
watchdog's line parser already reads.

## The gate

`scripts/check.sh` is this repo's own pre-merge gate: `bash -n` on every tracked script and
`fleet-lint-guard-diff` over `scripts/` first (a missing lint fails the step), then the one
step that judges this repo's own tree — VERSION and ENGINEERING-STANDARDS.md moved together,
or neither moved — the five fixture-only tests and shellcheck (the pinned image, style
severity — a missing image is a loud failure, never a skip) in measured cost order, cheapest
first. The order is a measurement, not a list to keep in your head; `scripts/check.sh` prints each step
with its number and name as it runs. A full run records to the fleet gate ledger
(`scripts/lib/deploy/ledger.sh`); `scripts/check.sh --only N` runs one step alone and
records nothing, so debugging a step never pollutes the ledger. The long-form why —
including the measurement behind the step order — is in `docs/DECISIONS.md`, because
W7 applies to this repository too.

`scripts/gate-image-tags.sh <project-root>` is rule T9's check, and one of this repo's gate steps
runs its fixtures. Point it at a project root and it names the compose files it read, the image
values it could not resolve, and any tag that project builds for both its gate and production. It
never passes in silence, so "nothing is built here" and "I could not tell" cannot be confused. A
service that builds and names no `image:` is not untagged either: compose tags it
`<project>-<service>`, so that tag is resolved from the file's `name:` or its directory and
compared like a written one. A compose file whose name places it on neither side and that builds a
tag is refused, because that is the file whose side decides whether a collision is reported. A
root where no `.yml` carries a top-level `services:` is refused too — exit 2, one line — because a
wrong root would otherwise read as nothing-to-overwrite.

A compose file on its own is not what a gate runs, so the check also reads `scripts/check.sh`,
`ci.sh`, `e2e.sh` and `gate.sh` for the files each `docker compose` call passes — `-f`, an
exported `COMPOSE_FILE` (including one set in a file the gate sources), or compose's own default
base-and-override pair — and judges each merged set the way compose merges it: a later `image:`
wins, a `build:` anywhere in the set builds. A variable is read from the assignments above the
call, never from the file's last one. It prints what each gate run builds, and names every call it
could not read — an unresolved `-f`, a subcommand it never reached, or a line naming
`docker compose` that yielded no call at all — rather than assuming it away. A call whose file set
it could not read is a refusal (exit 1), not a note under a green run; a line that merely mentions
`docker compose` is printed and changes nothing.

## Vendored scripts

`scripts/lib/deploy/` is the half of a project's `scripts/deploy.sh` that is the same
everywhere: `summary.sh` (what a deploy prints, and its log), `resolve.sh` (which commit a pull
request number means), `ledger.sh` (the gate ledger), `preflight.sh`, `cleanup.sh` (the
after-deploy worktree reaper), `compose.sh` (root's compose, from `fleet-deploy`'s export only) and
`literal.sh` (a gate's literal guard, below). A project copies those files and `VERSION` into its
own `scripts/lib/deploy/`, byte-identical, and sources them.

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

**Root runs a deploy only through `fleet-deploy <app> <PR#>`**, which exports `scripts/` at the merge
commit from root's own mirror; `summary.sh` refuses a copy anyone but root can write, and `resolve`
refuses without the `FLEET_DEPLOY_REPO` it sets (`docs/DECISIONS.md`). That is also the first
landing, once per project — never a hand landing.

**The gate ledger.** The EXIT trap is what records a run, and a trap that fires on a kill sees
`$?` from the last command that finished, not from the suite. Sourcing `ledger.sh` discards
any `GATE_SUITE_PASSED` inherited from the environment, so an operator's `export` or a CI
wrapper's cannot fake a pass; a gate script must set `GATE_SUITE_PASSED=1` itself, in its own
shell, immediately after its suite returns 0. Without that flag an rc of 0 is recorded as a
failure and says so on stderr. A gate also calls `gate_ledger_arm` itself, on the line after
it sets `GATE_LEDGER_GIT` and before its first step: that pins the commit the run is judging,
and the trap records nothing if HEAD has moved under it — a gate that never arms records
nothing either, and says which of the two it was. Reading is
newest-wins: the last line for a (sha, kind) decides, so a later red overrides an earlier green
and a genuine re-run's green overrides an earlier red. A row's sixth field is the tree its
commit pointed at, or `-` when the gated tree was not clean by a status that ran. When the gated
commit has no row of a kind, the newest 6-field row of that kind on its tree stands in, and `gated`
prints `<kind> accepted by identical tree <tree12> from <sha7>`; ci and e2e are matched each on its
own, a red exact row is never overruled, and a 5-field row matches its own sha only. `--gated-by-hand` never refuses — it is the
rescue path — but it reads the same rows first, prints the verdict it is overriding (`green`,
`red` or `absent` per kind) and the deploy records `by hand over [<verdict>]`.

**An e2e run on GitHub.** When the ledger's `e2e` for the gated commit is absent or red, `gated` may
take it from GitHub Actions instead; `ci` comes from the ledger alone. The route is off unless root
holds two files. `/etc/fleet/github-e2e/<app>` (`<app>` is `ROOT`'s directory name, as for
`/etc/fleet/app-env`) is root-owned, in a directory only root can write, with four lines:
`R=<owner/repo>`, `N=<check-run name>`, `W=<workflow path>` and `W_SHA256=<sha256 of that workflow
file>`. `/etc/fleet/github-e2e/token` is root 600: a fine-grained read-only token, checks:read and
actions:read on the repositories named. A run counts only when it is the newest `N` check run by
GitHub Actions (app 15368) on the gated sha whose workflow run is `W` in `R` itself, from `push` or
`workflow_dispatch` (never `pull_request`, which tests a merge ref, and never a fork), and it
finished `success`, and `W` at that sha hashes to `W_SHA256`. When `gated` reads a head whose tree is
the merge's, a run on the merge commit `resolve` read counts too, under the same rules. Any gh or jq failure is
`unreadable`, which is not green. The verdict adds `e2e github:green run <id> on <head|merge> <sha7>`, `e2e github: none
for <sha7>`, `e2e github: unreadable` or `e2e github: off (no config|no token)`; GATED reads
`ledger ci + github e2e <R> run <id> (<W>, <N>) on <head|merge> <sha7>`. Nothing is written to the ledger.
`DEPLOY_GITHUB_E2E_DIR` and `DEPLOY_GITHUB_E2E_TOKEN` move both files, for tests.

**Test scope.** `gated` classifies what the deploy changes (the checkout's HEAD against the gated
commit) by the project's `.fleet/test-scope` in that commit. A project declares it one entry per
line, `#` starting a comment:

```
docs docs/
docs *.md
non-ui scripts/
non-ui tests/Unit/
```

The grammar is `<docs|non-ui> <entry>`, an entry being `dir/`, a root-level `*.ext` or one exact
path; anything else on a line refuses the whole file. Each changed path takes the class of the most
specific entry that matches it (exact path, then directory, then `*.ext`; a tie goes to non-UI),
and the diff takes the strictest class among its paths: all docs owes no row, docs and non-UI owe
`ci`, anything else owes `ci` and `e2e`. Undeclared paths, `e2e/` and the declaration itself are
UI, and no file at all, a malformed one, or a symlink or submodule in the diff makes every path
UI. A manifest or lockfile is non-UI only by its exact path. Its `SCOPE` line names the class and why.

**A gate's literal.** A gate that names what root runs by a variable (`GATE_LIB_SUITE`, the suite
root runs) proves it with `literal.sh`, from its own test: `. scripts/lib/deploy/literal.sh;
gate_literal_once scripts/check.sh GATE_LIB_SUITE <canonical path>` is 0 and silent only when the
gate writes the name once, as `NAME=<value>` (bare, `'…'` or `"…"`) at column 0, and otherwise
names it only as `${NAME}`, after that line. Anything else prints one `LITERAL … refused:` line and
returns 1: an indented copy, `${NAME:=…}`, `export`, `declare`, a quoted or backslash-split name,
`$NAME`, a read before the write, or any comment naming it.

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
