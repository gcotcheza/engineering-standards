# Changelog

## 2026-10-05 — root's ownership repair, head read and build hash follow no app-user link, and a build re-reads the tracked files (deploy-lib VERSION 2026-10-05.4; the standard is unchanged and VERSION is not bumped)
**New `scripts/lib/deploy/ownership.sh`: `chown_root_owned <dir> <user>:<group> [<skip pattern>…]`**
(card 363) runs `/usr/bin/find -P <dir> -xdev -user 0 … -execdir chown -h <owner> {} +` under its own
absolute `PATH`, and replaces the five per-app `find … -exec chown` copies at their next re-vendor; pass
it `$ROOT` itself, whose parent only root can write, never a directory inside it. Refusals (stderr,
return 1): `chown_root_owned: <dir> is not a plain absolute directory`, `'<owner>' is not user:group`,
`find or chown failed under <dir>, so root-owned paths may remain`.
**`summary.sh`:** `deploy_head_file` reads `symbolic-ref HEAD` and `refs/heads/main` through `git-as
<app> -C "$ROOT"` (`DEPLOY_GIT_AS` is a test seam), never as files; new `deploy_app_user`; new
`deploy_build_hash <dir>`, a sha256 of `find -P . -type f` read as the app user, refusing `<dir> could
not be hashed as <user>` and a `<dir>` that is not absolute. It replaces memento's
`built_output`/`build_files` at its re-vendor; its paths read `./x`, not `x`, and a link is no longer
followed, so a hash stored by the old code never matches a new one.
**`preflight.sh`:** `refuse_if_dirty` and the new `deploy_refuse_if_tracked_dirty` (ghiecode's
`refuse_if_tracked_dirty`, given the `deploy_` prefix so an app's own copy cannot shadow it) refuse a git
status that fails, naming its exit code, rather than reading it as clean. ghiecode's own copy reads a
failing git as clean: at re-vendor it deletes it and calls the lib's.
**`compose.sh`:** `compose.sh run`, the one route every compose call takes (`deploy_compose`, and
`$DEPLOY_COMPOSE` in a job's own `bash -c`), re-reads the tracked files through `git-as <app>` before
`build`, `up`, `create` and every `run`, plain or `--build`, since compose builds a missing image on
either (card 371), and refuses an edit or a failing git. An app whose own deploy steps rewrite a tracked
file before an `up` or a `run` is refused from its re-vendor on. Before the subcommand a caller's joined
`-fx.yml`, `-f=x.yml`, `-pX` or `-p=X` refuses like `-f x.yml` (card 372): any single-dash argument there
does, as does compose's hidden `--workdir`, and the word after `--profile` and its kin is always its value.
**Every app's deploy-test needs two stubs at re-vendor:** `finish` now reaches `git-as` through
`deploy_head_file`, which the real one refuses on a test checkout, so fineprint, ghiecode, ghie-writes,
kidsquest, memento, orbit, reflection and scribly each set `DEPLOY_GIT_AS` (a stub) and
`DEPLOY_APP_USER` in their deploy-test env; a deploy-test that drives a compose `build`, `up`, `run` or
`create` exports the same `DEPLOY_GIT_AS` to it. Suite: the new `ownership-test.sh` (run by `test.sh`
as root, and as nobody for the red proofs), the record cases moved to an app-owned tree read through a
`git-as` stub, and a case for each new refusal. All eight headers are re-stamped. Why:
`docs/DECISIONS.md`.

## 2026-10-05 — a gate run counts for every commit of an identical tree (deploy-lib VERSION 2026-10-05.3; the standard is unchanged and VERSION is not bumped)
**A ledger row gains a sixth, last field: the tree of the commit the run was armed on** (card 329),
`<sha> <kind> <utc> <rc> <log> <tree|->`. `gate_ledger_tree` writes the tree only after `git status
--porcelain` ran and printed nothing, otherwise `-`, which no lookup matches. Ignored files (`vendor/`,
`node_modules/`) are outside `--porcelain`, exactly as for the sha rows already. `gated` reads the exact
sha first, as before; only when a kind has no row there does it take the newest 6-field row of that
kind whose tree is the gated commit's, and only rc 0 is green. ci and e2e are matched independently,
both still owed; a red exact row is never overruled by a tree; a 5-field row matches its own sha only,
and nothing is backfilled. A tree acceptance prints `<kind> accepted by identical tree <tree12> from
<sha7>`, the verdict item reads `<kind> green|red by identical tree from <sha7>`, and GATED gains
`, by identical tree: <kind> <sha7>[, …]`. `--gated-by-hand` is unchanged. Readers of fields 1 to 5
keep working. A deploy commit whose tree git cannot read is `-` too, and `gated` skips every tree match for it. Fields are compared as strings. Suite: 30 new checks; red proofs, one saved mutant per new guard, in the lane of card 329.
All seven headers are re-stamped for `2026-10-05.3`; `.2` is reserved by the compose env-keys branch,
which lands first. Why: `docs/DECISIONS.md`.

## 2026-10-05 — a hand deploy may count a GitHub Actions e2e run on the exact commit (deploy-lib VERSION 2026-10-05.1; the standard is unchanged and VERSION is not bumped)
**`gated` asks GitHub for `e2e` when the ledger's row is absent or red** (card 352), and never for
`ci`. Off unless root holds `/etc/fleet/github-e2e/<app>` (`R=`, `N=`, `W=`, `W_SHA256=`; root-owned,
in a root-only directory; `<app>` is `ROOT`'s basename) and `/etc/fleet/github-e2e/token` (root 600,
fine-grained, checks:read and actions:read). `gh api repos/<R>/commits/<sha>/check-runs` (one whole
page, `filter=all`) and `repos/<R>/actions/runs?check_suite_id=` per candidate; a run counts only as
the newest `N` check run by app 15368 on `<sha>` whose workflow run is `W` in `R`, head repository
`R`, event `push` or `workflow_dispatch`, completed `success`, with `W`'s blob at `<sha>` hashing to
`W_SHA256`. When the head and merge trees are identical (gated reads the head), a run on the merge
commit `resolve` read counts too, under the same rules, and the newest across both decides. Every gh or jq failure, a partial page, or a suite with other than one workflow run is
`unreadable`. New verdict items: `e2e github:green run <id> on <head|merge> <sha7>`, `e2e github: none for <sha7>`,
`e2e github: unreadable`, `e2e github: off (no config)` / `(no token)`; a `GITHUB E2E <why>` line
when a config or token is unsafe or a run is not green; GATED `ledger ci + github e2e <R> run <id>
(<W>, <N>) on <head|merge> <sha7>` and a `GATED` line with the run's URL and completed_at. With the route off,
a not-green `e2e` now reads `e2e absent, e2e github: off (no config)`; nothing else changes.
`--gated-by-hand`, docs and non-UI scopes are unchanged. The token reaches gh only as `GH_TOKEN` in
a child that never traces. Suite: 42 new cases on a fake gh serving JSON in the shape of a real
run; red proofs, one saved mutant per guard line, in the lane of card 352. All seven headers are
re-stamped for `2026-10-05.1`; apps adopt it on their next re-vendor. Why: `docs/DECISIONS.md`.

## 2026-10-04 — a gate's literal is guarded by one library function that sees every form (deploy-lib VERSION 2026-10-04.4; the standard is unchanged and VERSION is not bumped)
**New `scripts/lib/deploy/literal.sh`: `gate_literal_once <file> <NAME> <value>`** is 0 and silent
only when the gate writes `NAME` once, as `NAME=<value>` (bare, `'…'` or `"…"`) at column 0, and
otherwise names it only as `${NAME}` after that line. It replaces each app's count of
`^GATE_LIB_SUITE=` lines, which missed an indented write, `${NAME:=…}`, `export NAME=` and quoted
names. Refusals: `LITERAL <NAME> refused: <file> never writes …`, `… names it other than as ${NAME}
after its one write: <lines>`, `… could not be scanned …`, and `LITERAL refused: [<x>] is not a
variable name`. Comments are scanned like code, so a comment naming it is refused. The suite
carries a case per form. All seven headers are re-stamped for
`2026-10-04.4`; apps adopt it on their next re-vendor. The README now spells out how a project
declares `.fleet/test-scope`: one entry per line, `#` comments, most specific entry per path,
strictest class per diff, no file means UI. Why a name scan and not an assignment list:
`docs/DECISIONS.md`.

## 2026-10-04 — root's `docker compose` reads only root's files: `compose.sh` (deploy-lib VERSION 2026-10-04.3; the standard is unchanged)
**New file `scripts/lib/deploy/compose.sh`** (backlog 320). Every root compose call goes through one
argv: `docker compose --project-directory <ROOT> -p <app> -f <run>/compose/<file> [-f …] --env-file
/etc/fleet/app-env/<app>.env …`, where `<run>` is the directory `fleet-deploy` exported `scripts/`
into, found from the lib's own location. `deploy_compose_init <MERGE_SHA>` runs before the first
compose call: it refuses, naming `fleet-deploy`, when `<run>/compose/`, `<run>/export-sha` or a named
file is missing (an export from the 317 `fleet-deploy` or `fleet-deploy-on-merge` has none), when the
env file is not root 600 in a root 700 directory, or when the files were exported at another sha. It
then reads `--profile '*' config --no-env-resolution --format json` (every profile's services) through
jq, and `deploy_compose_exec` reads it again right before every `build`, `up`, `run` or `create`; both
refuse `privileged`, `pid`/`ipc`/`network_mode`/`uts`/`userns_mode`/`cgroup: host`, a `container:`
`pid`/`ipc`/`network_mode` or `volumes_from`, `cap_add`, `devices`, `device_cgroup_rules`, any
`security_opt` but `no-new-privileges` (`:true`, `=true` or bare), a `docker.sock` mount, a `provider:`
service, build `secrets`/`ssh`/`additional_contexts`/`entitlements`, `build.privileged`,
`build.network: host`, a volume's `driver_opts`, an external volume, a network with `driver: host` or
external and named `host`, an external network not on `FLEET_COMPOSE_SHARED_NETWORKS` (`whisper-net`
only), a normalised project `name` other than the app, a top-level volume or network not named
`<app>_…`, and any bind source, `env_file`, build context or
secret/config file that resolves outside `ROOT`. Then it refuses any key not on its allow-lists, which
hold exactly what the seven apps' deploy compose files use today: 4 top-level keys plus `x-*`, 21
service keys, 3 `build` keys, 6 volume-entry keys and the types `bind`/`volume`, 2 top-level volume and
4 top-level network keys, with a volume `driver` only `local`, a network `driver` only `bridge` and
`ipam` empty (`env_file`, `sysctls`, `runtime`, `cgroup_parent`, `group_add`, `volumes_from`,
`network_mode` and `build.network` among the refused); the lists are in docs/DECISIONS.md. A bind source outside `ROOT` passes only when it equals
a path in root's `/etc/fleet/app-binds/<app>` (root-owned, not group/other-writable, exact paths, no
prefixes; `/`, `/etc*`, `/root*`, `/proc*`, `/sys*`, `/dev*`, `/boot*`, `/usr*`, `/var/run*`, `/run*`,
`/var/lib/docker*`, `/var/lib/fleet*`, `/home*` and `docker.sock` never). The refusal names the service
and key, never a value.
It sets `DEPLOY_COMPOSE` (`bash <lib>/compose.sh run …`), which works in-process and inside a job's text.
Before `build`, `up`, `run` or `create`, every file `fleet-deploy` exported to `<run>/buildcheck/`
(tracked `docker/**`, `Dockerfile*`, `.dockerignore`) must `cmp` equal to the tree's copy, reached through
no symlink; `docker/` holds nothing untracked; each build context's Dockerfile and `.dockerignore` are
tracked, and the Dockerfile lies inside its context. `compose watch` refuses. A caller's own `-f`, `--env-file`, `--project-directory` or `-p` refuses, and no `COMPOSE_*` from
the caller reaches docker. `deploy_app_env_value KEY` reads `.env` through `sudo -n -u <app>`; when sudo fails it prints a
`REFUSED:` line on stderr and returns 1, so a caller writes `v=$(deploy_app_env_value KEY) || refuse …`. Its suite is
the new `compose-test.sh` (stub docker), which `test.sh` runs as root; the red proofs, one saved mutant
per guard line (88 deletions, among them each argv check of the run mode, each allow-list, each driver pin, the
name pin and `-p`, and 4 edits: the two `--profile '*'`, the shared list emptied, whose red includes
scribly's and reflection's replay rows, and the shared list given a second name), run it as `nobody` with
`DEPLOY_ROOT_UID` standing in for root (a test seam; unset, as under fleet-deploy's `env -i`, the owner
must be uid 0), and live in the lane of backlog 320. Both suites check that `/dev/null` keeps its mode
and owner. Every lib file is re-stamped for VERSION 2026-10-04.3. The lib now needs `FLEET_DEPLOY_REPO` (fleet-deploy
and fleet-deploy-on-merge set it) to name the app; an app's `deploy.sh` needs no change for it.

**Re-vendor only after fleet install packet 320 is INSTALLED** (its env seed first, then `fleet-deploy`
and `fleet-deploy-on-merge`): under the 317 tools the new lib refuses at `deploy_compose_init`.
**Policy verdicts on today's deploy compose files** (values stubbed, with packet 320's bind lists for
scribly `/var/scribly-audio` and reflection `/var/journal-audio`): all seven compose projects pass;
ghiecode, ghie-writes and pig-dice-game run no compose.

**Caller changes the re-vendor round carries, per project** (runbooks unchanged):
- every project that runs compose: copy `compose.sh` with the other lib files and source it; after
  `resolve`, call `deploy_compose_init "$MERGE_SHA"` and set `COMPOSE=$DEPLOY_COMPOSE` (or call
  `deploy_compose`) for every compose call, the job text included; drop `DEPLOY_COMPOSE` as an
  override. kidsquest, scribly and reflection set `DEPLOY_COMPOSE_FILES=docker-compose.prod.yml` instead
  of `-f docker-compose.prod.yml`. `scripts/deploy-test.sh` fixtures gain a run directory with
  `compose/`, `buildcheck/` and `export-sha`, and `DEPLOY_APP_ENV_DIR` naming a root 700 directory.
- health-tracker: `seam_scan` walks every `DEPLOY_*` shell variable, so `deploy_compose_init` runs after
  it (the lib sets no `DEPLOY_*` name when sourced).
- root's chown sweeps become `find -P … -exec chown -h …`: memento's `deploy_job`, orbit's
  `rooted_count`, scribly's and reflection's `root_owned`; memento's `chown -R memento:memento
  $ROOT/node_modules` in `deploy_job` becomes the same `find -P` form. fineprint's `repair_ownership`
  already passes `-h`.
- `.env` read by root goes through `deploy_app_env_value` or is dropped: the `APP_URL` grep in `site_url`
  (fineprint, kidsquest, ghiecode, ghie-writes); kidsquest's `ASSET_URL` grep in `main`.
  kidsquest's `chmod 600 "$ROOT/.env"` (in `land` and in `deploy_job`'s job text) runs as the app user
  (`sudo -n -u kidsquest`), since chmod follows a symlink.
- every gate that runs this suite: nothing new; `compose-test.sh` needs `jq`, and its two root-only cases
  (an env file another user owns, a `.env` read through `sudo -u nobody`) run when `test.sh` runs as root.

## 2026-10-04 — the deploy owes ledger rows by test scope: docs-only none, non-UI `ci`, anything else `ci` and `e2e` (deploy-lib VERSION 2026-10-04.2; VERSION 2026-10-04)
**`gated` now classifies what the deploy changes** — the checkout's HEAD against the gated commit —
by the project's own `.fleet/test-scope` in that commit, and asks only for the rows that class owes.
Lines are `docs <entry>` or `non-ui <entry>`, an entry being `dir/`, a root-level `*.ext` or one
exact path. The library declares nothing itself: a path is docs or non-UI only when the project says
so. An undeclared path, anything under `e2e/`, and the declaration file itself are UI; no
declaration, an unreadable one, a malformed line or a line naming `e2e/` makes every path UI, and
so does a symlink or submodule anywhere in the diff. Overlapping entries: the most specific wins, a
tie goes to non-UI. A manifest or lockfile is non-UI only through an exact-path entry.
That list: composer.json/.lock, package.json, package-lock.json, npm-shrinkwrap.json, yarn.lock,
pnpm-lock.yaml, bun.lock, bun.lockb and Gemfile.lock, at any depth.
- New line before the verdict: `SCOPE <docs|non-ui|ui>: <why> per test-scope 2026-10-04`.
- New verdicts: `GATED <sha7> ci green in <ledger>; e2e not required: non-UI diff (<entries>) per
  test-scope 2026-10-04` and `GATED <sha7> no gate row owed: docs-only diff (<entries>) …`; `DONE`
  records `ledger <what> <sha7> ci (non-UI)` and `no row owed <what> <sha7> (docs-only)`.
- A UI diff prints exactly what it printed before. A project with no declaration is unchanged.
- `--gated-by-hand` is unchanged; over a non-UI diff its verdict names the `ci` row alone.

**T1 names the three scopes in Ghie's words** (2026-10-04) and loses "no exceptions for just a
docs change", which the scope now contradicts; its npm/devDependency rationale and T5 proof move,
unchanged in force, to `docs/DECISIONS.md`, so the file shrinks. deploy-lib VERSION is
`2026-10-04.2` (a same-day serial, as VERSION already allows): `2026-10-04` is vendored as is, and
all five headers are re-stamped. Why an allowlist, why the diff is the deploy's and
not the branch's, and why the declaration is read from the gated commit: `docs/DECISIONS.md`.

## 2026-10-04 — two messages the guard-diff lint misread are reworded, and this gate runs the lint (deploy-lib VERSION 2026-10-04; the standard is unchanged and VERSION is not bumped)
**`fleet-lint-guard-diff` read message text as a `git diff` call**, so it failed every gate that
runs it over these scripts, the re-vendor of this library included. The lint stays conservative
inside quotes on purpose (a `bash -c "git diff …"` is a real call), so the words change:
- `resolve`'s refusal now reads `REFUSED: the tree comparison of head <sha> and merge <sha> exited
  <rc>, …` (rest unchanged). `resolve.sh` is re-stamped; the other lib files are re-stamped for the
  new VERSION only.
- `version-text-pair.sh` now prints `version-text-pair: the changed-file comparison against <sha>
  failed, so nothing was judged.`
- Their test pins move with them (`lib/deploy/test.sh`, `version-text-pair-test.sh` case 4b).

**Step 1 of `scripts/check.sh` now also runs `fleet-lint-guard-diff scripts`**, then lints a
one-line canary holding a bare diff call and fails unless the lint flags it (exit 1, naming
`--no-ext-diff`), so a lint that passes everything cannot turn the step green. It fails loudly when
`/usr/local/sbin/fleet-lint-guard-diff` is missing or not executable (C9). Why it runs on the host
and inside step 1, and the re-measured cost: `docs/DECISIONS.md`.

**Callers that pin the old refusal must update.** A read-only grep of `/srv/sessions/orbit/repo`
and `/var/www/*/scripts` finds it only in vendored copies of this library, which the re-vendor
replaces: `resolve.sh` and `test.sh` in fineprint, ghie-writes, health-tracker, reflection and
scribly (at `resolve.sh:63`) and in ghiecode (`resolve.sh:45`). No project's own script pins
either string, and neither tree pins the `version-text-pair` sentence.

## 2026-10-03 — root runs a deploy only from `fleet-deploy`'s export: the lib refuses any other copy, and `resolve` takes the repository from root (deploy-lib VERSION 2026-10-03, amended; the standard is unchanged)
**`summary.sh` refuses to run from anywhere the app user could write** (backlog 317). When it is
sourced, and again in `deploy_log_open` once `ROOT` is set, it walks the running `deploy.sh`,
`summary.sh` itself and every directory above each up to `/`: a symlink, an owner other than root,
or a group/other write bit refuses with `REFUSED: <path> is …, so root does not run it. Deploy with:
fleet-deploy <app> <PR#>` and exit 1, before anything past the libs runs; so does a `deploy.sh` at or
inside `ROOT`. Nothing turns it off. The refusal lives in app-writable code, so it is no boundary
against an app user who edits `deploy.sh` (or a `bash -s` started from a root directory): it catches
the old habit of running the tree's copy, and the boundary is `fleet-deploy` plus the runbooks. `fleet-deploy <app> <PR#>` (fleet install packet 317, root's
tool) exports `scripts/` at the merge commit out of root's own mirror into a root 700 directory, which
passes. **`resolve` takes `REPO` from `FLEET_DEPLOY_REPO` only** (`owner/repo`), never from the
checkout's origin URL: unset, it refuses and names `fleet-deploy`. `gh_repo` and `DEPLOY_GH_REPO` are
removed. When `FLEET_DEPLOY_MERGE_SHA` is set, gh's merge commit must equal it. The origin/main ==
merge check stays. The suite's work directory is fixed under `/srv/worker-scratch` (root 755,
exec-capable) and the suite reads no `TMPDIR`: `/tmp` is world-writable, so the guard refuses it, and
`/run` is mounted `noexec`. It proves the guard on real copies (app-owned, group-writable, a symlink, inside `ROOT`, and the old
`cd /var/www/<app> && scripts/deploy.sh` shape). Red proofs, one saved mutant per guard line: the
symlink, owner and mode tests, the call at source time, the call in `deploy_log_open`, the inside-`ROOT`
test, and `resolve`'s unset, malformed and merge-sha refusals. `summary.sh` and `resolve.sh` are
re-stamped.

**Caller changes the re-vendor round carries, per project** (each in the same PR as the re-vendor).
**Re-vendor only after fleet install packet 317 is INSTALLED:** before it, the old command refuses,
`fleet-deploy` does not exist, and `fleet-deploy-on-merge` sets no `FLEET_DEPLOY_REPO`, so nothing deploys.
- every runbook: the one deploy command becomes `fleet-deploy <app> <PR#>` (with `--gated-by-hand`
  where the runbook passes it); `cd /var/www/<app> && scripts/deploy.sh` and every copy run from a
  worktree or scratch lane now refuse, so those lines go: orbit `deploy.md:36`, kidsquest `:114`,
  health-tracker `:48`. health-tracker's `systemd-run … /var/www/health-tracker/scripts/deploy.sh <N>`
  (`:19-21`) runs `fleet-deploy health-tracker <N>` instead; ghie-writes `:13` likewise.
- every runbook's rollback block that sources the lib for `deploy_record_rollback`: source
  `summary.sh` from a root 700 copy taken out of root's mirror (`/var/lib/fleet/deploy-src/<app>.git`),
  never from the tree, which now refuses.
- every `scripts/deploy-test.sh`: `DEPLOY_GH_REPO=` becomes `FLEET_DEPLOY_REPO=`. Each runs
  `$SCRIPT_DIR/deploy.sh` out of the worktree (fineprint `:14`, memento `:15`, orbit `:16`, health-tracker
  `:19`, kidsquest `:15`, ghiecode `:16`, scribly `:13`, reflection `:13`, ghie-writes `:7`), and none but
  kidsquest looks at its uid (`AS_ROOT`, `:26`, and it still runs when not root). Under this lib every
  case refuses at the guard whenever the worktree is not root-owned, whoever runs it, and a non-root run
  cannot make a root-owned copy. So each becomes root-only, refusing in one loud line when not root, and
  runs a copy of `scripts/` in a root 700 directory under `/srv/worker-scratch`. The gates that hand
  their steps to the owner (ghiecode `check.sh:70-87`, ghie-writes `:118-127`, scribly `DROP` `:85-94`,
  reflection `as_owner` `:111`) move it to their root half, where the canonical lib suite already runs;
  fineprint `ci.sh:445`, memento `check.sh:570`, orbit `check.sh:247`, health-tracker `ci.sh:634` and
  kidsquest run it as whoever runs the gate, so a non-root gate run stops there loudly.
- orbit `deploy.sh:82` reads `repo=${DEPLOY_GH_REPO:-$(gh_repo)}`: it becomes `repo=$FLEET_DEPLOY_REPO`.
- fineprint `deploy.sh:46` and health-tracker `:109` run `docs-only.sh` through `$ROOT`, which is the
  tree's copy: they reach it through the script's own directory, as memento, orbit and kidsquest do.
- health-tracker `:154-155` pipes `git show origin/main:scripts/gate-row.sh` out of the app's `.git`
  into root's bash: it runs `"$(dirname "$0")/gate-row.sh"` from the export instead. Its `seam_scan`
  walks `${!DEPLOY_@}` only, so `FLEET_DEPLOY_*` is not refused; `DEPLOY_GH_REPO` leaves its lib-seam
  list and `deploy.md:133`.
- ghie-writes' timer path is fleet-deploy-on-merge, which (packet 317) passes `FLEET_DEPLOY_REPO`; it
  exports only `deploy.sh` and `lib/deploy/`, so a project whose `deploy.sh` runs another `scripts/*.sh`
  cannot be enabled there until that export widens.
- ghiecode, scribly, reflection, kidsquest, memento: the runbook line and `deploy-test.sh` only.
- every gate that runs this suite: nothing new. It must still run as root, and `/srv/worker-scratch`
  must exist (root 755); the suite reads no `TMPDIR`, so the exported-name checks in ghiecode and scribly
  have no new name to refuse.

## 2026-10-03 — `finish` writes root's deploy record, and takes only the full merge sha (deploy-lib VERSION 2026-10-03; the standard is unchanged)
**`finish` appends `DONE <full MERGE_SHA> <utc> <log>` to `${DEPLOY_RECORD_ROOT:-/var/lib/fleet/deploy-on-merge}/<basename ROOT>.record`
by path, before it prints DONE** (backlog 280). The live tripwire reads that file before any deploy
log, and no step of the deploy holds a descriptor on it, so an app-uid step that prints a DONE row into
the log no longer vouches for a HEAD. A `RED …` tail on `EXTRA_DONE` is carried onto the row. Before it
writes, `finish` refuses — `REFUSED:`, exit 1, no DONE line, no row — when its argument is not 40 hex,
is not the `MERGE_SHA` resolve read from GitHub, is not what `.git/HEAD` names when read as files
(`ref: refs/heads/main`, loose or packed, neither link followed), when `basename ROOT` is not a name the
tripwire reads, when `ROOT` is not under `/var/www/` and `DEPLOY_RECORD_ROOT` is unset, or when the record
is anything but a 600 file in a 700 directory, both owned by the running uid and neither a symlink. A
row after a torn last line starts on a new line. `deploy_record_rollback <full sha> <source>` appends a
`ROLLBACK` row through the same checks for a runbook's rollback block; the source is one word, never `RED`.
New names, all `deploy_`-prefixed so a project's own helpers cannot shadow them: `deploy_head_file`,
`deploy_owned_by_me`, `deploy_record_safe`, `deploy_is_full_sha`, `deploy_record_row`,
`deploy_record_rollback`, and the variable `DEPLOY_RECORD_ERR`.

**Compatibility — option (a): the advisor's ruling, 2026-10-03 16:28Z (message to the orbit moderator).**
Every project passes `finish` a short, app-uid `rev-parse` today; the new `finish` refuses it loudly. A
silent short-sha fallback would be the very gap this closes. Re-vendoring lands in the same project PR as:
- every `finish` call taking `"$MERGE_SHA"`, the docs-only or early one included: orbit `deploy.sh:61`,
  fineprint `:41`, memento `:82`, kidsquest `:77`, health-tracker `:468`, besides each project's last one;
- a `deploy_record_rollback` line in the runbook's rollback block;
- `scripts/deploy-test.sh` exporting `DEPLOY_RECORD_ROOT` to a temp dir before its first case, because
  it runs on the host as root and the default is the live directory;
- ghie-writes deleting `write_record` and its `if ! write_record DONE "$MERGE_SHA"` block before
  `finish` (both together would write two rows). Its own `head_file`, `owned_by_me` and no-argument
  `record_safe` no longer collide, and may be replaced by the `deploy_` ones (C1).

`test.sh` gains 79 `ok` lines (226 to 305), all against a fake record root and a fake `.git` in the
suite's temp dir; the cleanup cases now finish on a landed full sha. Red proofs, one saved mutant each,
header re-stamped so only the edit counts: both 40-hex checks, the `MERGE_SHA` compare, the landed check,
the HEAD-is-main check, each `! -L` in `deploy_head_file`, the packed-refs match, the ROOT, name and
`/var/www/` checks, the directory and file checks, the owner compare, the `deploy_record_safe` call,
`umask 077`, the one-word and not-`RED` ROLLBACK source, the torn-line newline, the `|| refuse` after the
write, and the write by path. Why: `docs/DECISIONS.md`.

## 2026-10-03 — the fleet check discovers its projects, and a deployed mirror is not one (tooling only; the standard is unchanged and VERSION is not bumped)
**The ten project names left the script.** `scripts/fleet-versions.sh` now takes its projects from
`$ROOT/*/docs/STANDARDS.md`, the very file the rest of it measures, so vendoring the file is
joining the check and there is no second repository to remember. The rows did not change on the
day of the change, only their order, which is now the root's own and pinned to C collation
(`LC_ALL=C` inside the discovery loop) so a caller's locale cannot reorder the report; case 20
asserts that order. `STANDARDS_PROJECTS` still overrides and still refuses to be empty, and a
root where nothing is vendored is still exit 2, never a clean fleet of zero.
**A `*-staging` or `*-worktrees` directory is excluded on both sides.** Discovery and the UNLISTED
row now share one `is_fleet_project_name`, instead of the UNLISTED row holding the only copy of
the pattern. A deployed staging checkout that pulls a vendored `docs/STANDARDS.md` would
otherwise join the fleet as a project of its own and go STALE on the deploying project's
schedule, which the watchdog reads as a failure. Cases 19 and 20 are new, proved red first — 19 against the discovery-without-a-filter
version, 20 against the same script with the collation pin removed. What discovery gives up — a
project whose directory *vanishes* was a MISSING row and is now invisible — and two consequences
for the watchdog are written out in `docs/DECISIONS.md`.

## 2026-10-03 — S1: a test harness may drive git through a candidate hook in a throwaway repository it made (VERSION 2026-10-03)
**Ghie's approval of 2026-10-03, written into S1 as one sentence with a pointer.** S1 listed every
repo-local `core.hooksPath` as a finding, whatever the diff held. A `pre-merge-commit` or
`pre-applypatch` hook can only be proved by running `git merge` or `git am` through it, so the rule
left installing an untested guard live as the only way to see one run. The exception covers a test
harness that points a repo-local `core.hooksPath` at a sha-checked, hook-ON candidate copy of the
fleet guard, inside a repository the test created, fills with fixtures, never gives a push remote
and deletes on every exit, and that ends by proving the real trees', the global and system
`hooksPath` and the fleet hooks directory byte-unchanged. The seven conditions, (a) to (g), are in
`docs/DECISIONS.md`; missing one puts the harness back under the rule. Anything that points hooks
away from a guard stays an absolute finding, except a T5 mutant run that meets every condition in
`docs/DECISIONS.md`. First use: fleet packet 284+285 (orbit). The standards text moved, so
`VERSION` moves with it. A T5 harness may also run deliberately broken copies of a hook or of
itself under six further conditions, named mutant mode and a marked `mktemp` repository among
them; `docs/DECISIONS.md` lists them, and states the case is no `hooksPath` precedent.

**What it means for the projects.** No project code changes; each takes the text when it next
re-vendors `docs/STANDARDS.md`, and `scripts/fleet-versions.sh` reports every project `STALE` until
then. The three gates that compare their vendored copy against this host's canonical clone by path
go red on every branch the moment the canonical clone is updated to this text, and stay red until
each re-vendors; `ROLLOUT.md` gives the merge order that keeps that window short.

## 2026-10-03 — a dirty tree writes no gate-ledger row, and the deploy-lib suite proves the hook ran and runs only as root (deploy-lib VERSION 2026-10-02, amended; the standard is unchanged)
**A gate run on uncommitted work no longer leaves a `<sha>-dirty` row.** `gate_ledger_sha`
refuses with `gate-ledger: dirty tree: no ledger row — commit, then gate the tip` and exit 2;
`gate_ledger_record` prints it, writes nothing and returns 0, so a `set -e` caller's EXIT trap
keeps its own exit code and reaches its teardown (backlog 268). `gated()` still ignores
`-dirty` rows already in a ledger. App tests that assert a `-dirty` row change at re-vendor.

On top of the entry below, `scripts/lib/deploy/test.sh` refuses to run unless root and gains a
hook canary (backlog 264b): a clean fixture commit and the whole suite must add `caller=root …
result=clean` lines to the real checker log, and a planted random `ghp_` token must be refused,
with no commit and the token never printed. The root-check probe exits 3, so a leaked
`LIB_TEST_ROOT_PROBE` can never pass a gate. 214 `ok` lines to 226. Red proofs, one saved
mutant each: the dirty guard's `return 2` deleted; the record's `return 0` turned back to 2
under a `set -e` caller; the root check deleted; the probe set back to exit 0; the planted token
swapped for plain words. **Re-vendoring needs an app-side change:** scribly, reflection,
ghiecode and ghie-writes run this suite as the app owner and must run it as root.

`ledger.sh`'s header is re-stamped and the pinned `SUITE_SHA256` becomes
`4f5b0f5ab3addf3083967f94ffcfaf5d177f29b6a1275d07c5b630d50566d88c`.

## 2026-10-03 — the deploy library's test fixtures commit through the fleet hook (deploy-lib VERSION unchanged; the standard is unchanged)
**`scripts/lib/deploy/test.sh` no longer skips the hook.** Its fixtures committed with
`-c core.hooksPath=/dev/null` and `--no-verify` (9 lines), against S1. Both are removed, and a
new first check scans the suite's own text, continuation lines joined, and fails on the forms
`docs/DECISIONS.md` lists: `core.hooksPath` in any case, `--no-verify` and its prefixes to
`--no-v`, `HUSKY=0`, any `GIT_CONFIG_*`, a `HOME=` or `XDG_CONFIG_HOME=` assignment, `commit-tree`,
`fast-import`, `hash-object -w`, and a short `-n` on commit or merge. An unreadable file or a
grep that exits above 1 (a broken pattern) fails the scan instead of reading as clean; three
new assertions hold that, one for a missing file and one per grep (210 `ok` lines to 214).
Each case now copies a repository built once per kind, so a run makes 8 personal-data checker
calls instead of 245 and stays at about 15 s (backlog 265). `VERSION` stays `2026-10-02`: no
library file changed. The pinned `SUITE_SHA256` becomes
`13728ad47730ae4bc17ebb40b0f09de03ffe7e7fa5fa18799a4d7b1d3026ccde`.

## 2026-10-03 — the after-deploy cleanup keeps a worktree whose ignored `.env*` directory sits in a subfolder (deploy-lib VERSION 2026-10-02, amended; the standard is unchanged)
**Neither probe term reached `api/.env.d/prod`.** The plain `'.env*'` reaches inside a top-level
`.env.d/` only, and in `':(glob)**/.env*'` the `*` never crosses a `/`, so a merged worktree whose
ignored env files live in a nested `.env*` directory was removed with them. `cleanup_envfiles` now
adds `':(glob)**/.env*/**'`; the vendor and node_modules exclusions still apply to it (card 273).

`scripts/lib/deploy/test.sh` gains one fixture and three assertions (207 `ok` lines to 210): an
ignored `api/.env.d/prod` keeps the tree under `envfiles`, the log names the file, and the tree is
still on disk. Against the probe without the new term all three go red. The "ls-files exited"
guard card 273 named as untested is already held by `cleanup-envfiles-unreadable`: with that guard
line deleted and the header re-stamped, its two assertions go red.
The new term also reaches a top-level `.env.d/prod`, so the plain `'.env*'` is now redundant
(same four paths with or without it on a fixture); it stays to match `check_repo`, and the entry
below's red proof for deleting it no longer holds.

`VERSION` stays `2026-10-02` for the reason the entry below gives. `cleanup.sh`'s header is
re-stamped, and the pinned `SUITE_SHA256` becomes
`83fc2db2cd53840dfe868f6bb624c0e8a604562ee934d6843adfc7361b1f9ae7`. `fleet-scratch-reap`'s
`check_repo` gets the same term through its own install packet, not through this repository.

## 2026-10-02 — the after-deploy cleanup keeps a worktree whose ignored `.env` sits in a subfolder (deploy-lib VERSION 2026-10-02, amended; the standard is unchanged)
**`cleanup_envfiles` looked at the top of the tree only.** Its probe was `git ls-files -o -i
--exclude-standard -- '.env*'`, and a pathspec without magic matches the top level alone, so a
merged worktree whose ignored env file lives at `api/.env` (reflection's layout) was removed with
that file in it. The probe now adds `':(glob)**/.env*'`, which on git 2.43 reaches `.env*` files below the top level,
minus `':(glob,exclude)**/vendor/**'` and `':(glob,exclude)**/node_modules/**'`, so a vendored
package's own `.envrc` cannot keep every tree for ever. The plain `'.env*'` stays, because only it
reaches inside a top-level `.env.d/`. These are the four terms `fleet-scratch-reap`'s `check_repo`
already uses (card 263).

`scripts/lib/deploy/test.sh` gains five fixtures and eleven assertions (196 `ok` lines to 207): a
nested `api/.env` keeps the tree, so does a top-level `.env.d/prod`, an ignored `.env*` only under
`vendor/` or only under `node_modules/` (at the top and one level down) does not, and a tree whose
only ignored files are not `.env*` is removed. The existing top-level case stays green. Against the
old pathspec the nested case's three assertions go red; with either exclusion deleted, that
directory's two go red; with the plain term deleted, the `.env.d` case's two go red. The new
fixtures add no hooks-off line; they reuse `cleanup_fixture`, whose hooks-off commits are card 264's.

**Where it takes effect.** No project vendors `cleanup.sh`. Its one live caller is
`/usr/local/sbin/fleet-merged-reap`, which sources the installed copy at
`/usr/local/lib/fleet-merged-reap/cleanup.sh` (still the 2026-10-01 header with the old probe), so
the fix reaches production when that copy is re-installed. `VERSION` stays `2026-10-02`: no project
has vendored that version, so this amends the day's library rather than joining it. `cleanup.sh`'s
header is re-stamped, and the pinned `SUITE_SHA256` becomes `334c523882c74fe8523a62d6be29ebb6b4ab554de39b45985dfb04e7b4ce1928`. The measured probes are in
`docs/DECISIONS.md`.

## 2026-10-02 — W3: a session may merge a pull request whose every commit is authored by `dependabot[bot]` once the project gate is green on its head (VERSION 2026-10-02)
**Ghie's rule of 2026-10-02, written into W3, with W2 excepting the same pull requests.** A
dependency bump nobody on the box wrote has no builder whose diff needs a second reader, and waiting
on Ghie to merge each one left security fixes sitting green and unshipped. A session may merge one
once two things are shown in a PR comment before the merge: `gh pr view <n> --json commits -q
'.commits[].authors[].login'` printing only `dependabot[bot]`, and a green ledger row for every kind
the project gates on the head sha. It then deploys by the runbook. The rule keys on the commits, not
on the opener, so a commit pushed onto a dependabot branch by anyone else puts the PR back in
Ghie's hands. Dependabot's commits never pass the fleet pre-commit hook, so the gate's secrets step
is their only S1 layer. The standards text moved, so `VERSION` moves with it.

**It takes effect only when Ghie amends the permission layer.** `autoMode.hard_deny` in the
session settings still blocks merging "by ANY means"; until that sentence carries the same
exception, the rule is written and the permission layer still refuses it, and the refusal wins.

## 2026-10-02 — a gate that never got a slot records nothing instead of a failure (deploy-lib VERSION 2026-10-02; the standard is unchanged)
**A suite that waited out its hour for a `heavy-work` slot was recorded red.** The serializer
exits 75 when it gives up; `gate_ledger_record` wrote a row with rc 1 for a run that never
started, and the ledger then called that commit red until a green re-run undid it. One give-up
cost two gates.

`gate_ledger_record` now writes no row for rc 75 and says so on stderr:
`gate-ledger: heavy-work gave up (rc=75), so the <kind> run is NOT recorded — it never ran`. The
row stays absent, and `gated` reads absent as absent — ungated, not red. Two fixtures in
`scripts/lib/deploy/test.sh` cover it, five assertions (191 ok lines to 196); four of the five
were watched red against a copy of the library with the guard's own four lines deleted, the fifth
being the one that asserts the gate carries on afterwards.

`ledger.sh`'s header carries the other half in two lines: the fleet convention that a step
exiting 75 ends the gate with `=== GATE NOT RUN (step N: name — heavy-work gave up) ===` and
exit 75, never `GATE FAILED`. The full text and the option not taken are in `docs/DECISIONS.md`,
and `ROLLOUT.md` carries it as open work — this library never sees a step, so only each
adopter's own `check.sh`/`ci.sh` can honour it, when it next re-vendors. Until a project's gate
passes rc 75 through to `gate_ledger_record`, it still records a give-up as its ordinary failure:
the guard takes effect gate by gate, as each one does.

deploy-lib VERSION is 2026-10-02 and all five vendored headers are re-stamped, `cleanup.sh`'s
included, so re-vendoring is its own round per project, and the pinned `SUITE_SHA256` those
projects hold becomes
`8ab224a02df3d82bcc830dc359c242f2016f773e6f77fa9b300ce86423714c94`.

## 2026-10-02 — the gate fails when VERSION and the standards text move apart (tooling only; this change alone moves neither the standard nor VERSION)
**`VERSION` was paired with the text by habit, and the habit had already slipped once.** The
advisor's ruling on backlog 228 says the version is bumped exactly when `ENGINEERING-STANDARDS.md`
changes. Every one of the seven first-parent commits that touched `VERSION` had also touched the
text — but eight touched the text, and the merge of PR #10 on 2026-09-19 carried no bump. Nothing
checked either direction. `scripts/version-text-pair.sh` now does: it diffs the working tree
against `git merge-base HEAD origin/main` and fails naming whichever of the two moved alone, so the
failure line is the repair. Neither moved, or both moved, and it passes — which is what `main`
itself looks like. A clone with no `origin/main` fails loudly rather than skipping, because a rule
nobody checked must never look like a rule that passed (C9).

**The step is second of eight, by measurement.** Each step body was timed alone, three
repetitions, in two runs: the new step costs 0.66s and 0.59s, against `bash -n`'s 0.04s and
`fleet-versions-test.sh`'s 0.63s and 0.71s. The same runs found `gate-image-tags-test.sh` had grown
from the 0.32s that put it third to above 3s, so it moves to seven, and shellcheck dearer than
`queue-start-test.sh` both times, so those two swap and shellcheck is step six. The numbers, and why
the check and its own test share one step, are in `docs/DECISIONS.md`.

**Its test is proven able to go red four ways.** `scripts/version-text-pair-test.sh` drives the
real script through one throwaway repository — both moved, neither, only `VERSION`, only the text,
a `git diff` that fails (exit 2, nothing judged), only `VERSION` among a diff larger than a pipe
buffer, and no `origin/main` — and each of the script's four guard lines was deleted in turn from a
saved copy, each turning its own case red (T5). The large-diff case is red against a `moved()` that
pipes `printf` into `grep -q`: under `pipefail` the early exit becomes SIGPIPE, rc 141, and the
check passed a branch it should have refused. `moved()` reads a here-string instead.

## 2026-10-01 — the deploy library can remove the worktrees and scratch lanes of the pull request that just deployed (VERSION unchanged)
**New `scripts/lib/deploy/cleanup.sh`, with its cases and one red-proved mutant per guard in
`scripts/lib/deploy/test.sh`.** `deploy_cleanup` takes the one pull request the deploy was
invoked with, selects the worktrees of the repository that are on its head branch, and removes
only those that pass every check — merged into `main`, merge commit an ancestor of `origin/main`,
head in `origin/main` or still on a remote branch, clean, no process working inside it, no
running container mounting it, and no root-owned file in it — with `git worktree remove` and
never `--force`. Any check that fails, or cannot be answered, keeps the worktree and names the
check. The scratch half calls `fleet-scratch-reap` read-only first and applies with the `--expect`
hash that run printed. It never fails the deploy: it is wired as an `EXIT` trap, captures every
exit code, and returns 0.

**Nothing calls it yet.** `LIB_FILES` in `scripts/fleet-versions.sh` is untouched and
`scripts/lib/deploy/VERSION` does not move, so no project is reported `DIVERGED` for a file it does
not vendor; arming it in each project's `deploy.sh` is the re-vendor round, and `ROLLOUT.md` carries
it as open work, together with the two gaps the library cannot close by itself — gates that leave
root-owned files in a worktree, and scratch lanes that carry no `.fleet-scratch` label. The standards
body is unchanged, so no project's drift test and no declared version changes. Why after a deploy
rather than on a timer, why one named pull request is not an S7 bulk sweep, and why `--force` and
`rm` are both refused are in `docs/DECISIONS.md`.

## 2026-10-01 — four rules tightened from one day's mistakes: a guard's test, a runbook's blocks, the hook that always runs, and a word count by command (VERSION 2026-10-01)
**Four things went wrong in one day, and every one of them was already covered by a rule that
was not specific enough to catch it.** No rule was added — C1 and C2 cut both ways here, and a
fleet that reads 38 rules will not read 42 — so each landed in the rule whose check it belongs to.

**T5 now says what proving a guard means.** A test suite for a shell guard stayed green with the
script's `set -e` and its `trap` deleted, because each case still printed the string the assertion
looked for: the test was watching the output, not the guard. T5's rule sentence now carries the
stronger form — a test of a guard is proven able to fail with *the guard itself deleted*, not only
with the input changed — and its checked-by names the second half of the same morning: a red proof
driven from a `<(...)` process substitution reported 0 of 3 cases passing, which read as a clean red
and was not one, because a multi-case suite opens that path once and every later case reads it
empty. The red proof runs against a file saved on disk.

**W8 now says that a fenced block is a shell.** A runbook step exported `APP_HOME` and the next
block used it; between the two, the variable was gone, and the line that would have used it was an
`rm -rf`. The rule's own sentence carries it, and its checked-by asks for `${VAR:?}` on a
destructive line, so an empty name stops the step rather than widening what it reaches.

**S1 now says the hook always runs.** `-c core.hooksPath=…`, `--no-verify`, `HUSKY=0` — and the two
persistent shapes of the same bypass, a repo-local or global `core.hooksPath` aimed anywhere but the
fleet hooks directory and a throwaway `GIT_CONFIG_GLOBAL` that drops it, which differ from the flags
only in lasting past one command — were
placed with S1 rather than S2 or S6: the pre-commit hook is already S1's *check*, so a commit that
goes around it has not merely skipped a tool, it has left S1 unchecked — whereas S2 governs what a
guard may print once it fires and S6 governs where work happens. S1's checked-by adds review of
the command that made the commit and of the hooksPath in effect, because neither the flag nor the
config is visible in the diff.

**W4's 150 words is now counted by a command, and the 150 is prose only** — the `## ` headings, the
closing pointer line and the attribution footer are excluded. Before create the count reads the body
file, because there is no `<n>` to query until the PR exists; before ready the same `sed` is fed by
`gh pr view <n> --json body -q .body`. All three patterns are anchored: an unanchored
`sed '/Generated with/,$d'` cuts at the first line of *prose* that mentions the phrase, which on a
130-word probe printed 19 and passed. The placement reasoning is in `docs/DECISIONS.md`; the rule
count is unchanged at 38, so no project's drift test changes shape — only its vendored copy and its
declared version.

**`ROLLOUT.md` now carries the project-side work these clauses create** — S1's checkouts, W8's
runbooks, T5's existing guard suites — as a tally in the shape of the T1 entry above it, with every
count honestly `not yet measured`. `VERSION` stays `2026-10-01`: it is a date, this is the same day's
standard, and the entry above is amended rather than joined by a second one.

## 2026-10-01 — a by-hand deploy prints the gate verdict it overrides, and the ungated refusal names routes that exist (tooling only; the standard is unchanged and VERSION is not bumped)
**The rescue path was a blindfold.** `gated()` returned on `--gated-by-hand` before it read the
ledger, so a tip whose `ci` row was red deployed and the log said only `GATED BY HAND: the ledger
was not read` — and `DONE` recorded it exactly as it recorded a by-hand deploy of a tip every gate
had passed. It now reads the rows first and builds one verdict — `green`, `red` or `absent` per
kind, behind the commit it asked about and whether that was the head or the merge — prints
`GATE NOT GREEN <verdict>`, and records `by hand over [<verdict>]`, the shape health-tracker's
`deploy.sh` already used over its own `gate-row.sh`. By hand still never refuses: a missing ledger,
an unresolved commit and a red row are all printed and all deploy, because it is the path out of a
hole. A by-hand deploy of a tip the ledger does clear records `by hand over [GREEN <verdict>]` and
is told the flag was not needed.

**And the refusal named a remedy nobody could follow.** `gate that <what>, then deploy` asked for a
commit to be gated that `resolve()` has already proved is `origin/main`; a gate scanning
`origin/main..HEAD` refuses an empty range, so following it burned a run and wrote a *red* row for
the tree the operator wanted cleared. The sentence now says which kind is missing and what both rows
say, then names three routes — gate a commit before it is merged, take whatever route that project's
gate documents for one already in main (a base override, where it has one), or `--gated-by-hand`,
which deploys and records the deploy as ungated. No project's flag is claimed to exist.
`scripts/lib/deploy/test.sh` gains six cases and sixteen assertions (95 `ok` lines to 111) and
re-states the six that quoted the old sentence through one `no_green` helper, so the wording lives in
the suite once. Every by-hand case runs under `set -e`, the shell each caller's `deploy.sh` uses.
Against `main`'s library the new suite reports 22 FAIL; the two assertions that `REFUSED` is *absent*
cannot go red that way, since the old by-hand never refused either, so they were proved against a
mutant whose by-hand branch is unreachable (12 FAIL, the two among them), and a second mutant with
the `|| v=unreadable` guard removed reddens exactly the two unreadable-row assertions.
deploy-lib VERSION is 2026-10-01 and all four vendored headers are re-stamped, so
`fleet-versions.sh` reports every project's vendored copy STALE until it re-vendors; re-vendoring is
its own round per project, and the pinned `SUITE_SHA256` those projects hold becomes
`6b23e851ba1e2999aa04e960e7743229acec3425aa05eeed44077e8932238e9b`. Each project's own `scripts/deploy-test.sh` asserts the old sentence too and is
re-stated in that same round. The long-form why is in `docs/DECISIONS.md`.

## 2026-09-30 — T1 names the dependency-advisory step, and says what a bundled front end audits (VERSION 2026-09-30)
**P1 was adopted and never written down.** The 2026-08-23 entry below records proposal P1
(a dependency-advisory step in the gate) as adopted, but no rule in the standard mentioned
it: T1's list of what the gate runs went style, static analysis, boundaries, front-end lint,
unit tests, the suite, secrets — and stopped. The only text anywhere was the proposal itself
in `SOURCES.md`, which is not a rule and which projects do not vendor. T1's checked-by now
carries the step: `composer audit --locked --no-dev --abandoned=report` and `npm audit
--audit-level=high`. The npm floor is High; composer's is deliberately absent, so that
half fails on any advisory and is not to be narrowed with `--ignore-severity`.

**And the flag in the proposal was the bug.** P1 wrote `npm audit --omit=dev`. A gate running
exactly that exited 0 while a package under a published High advisory was in its shipped
bundle: the bundler follows imports from the entrypoints, and the package was imported by one
while listed under `devDependencies`. `--omit=dev` reads a lockfile section; a build does not.
So T1 adds a scope clause — where the deploy ships a bundle built out of `node_modules`, the
npm step carries no `--omit=dev` — and a T5-grade way to prove it: pin one devDependency the
bundle imports to a published High advisory, run the gate, quote *the gate's own* failure line,
revert. The more precise alternative (keep the flag, require every bundled import to be a
`dependency`) is in `docs/DECISIONS.md` with what it would have cost: a tool no project has.

`SOURCES.md` P1 is annotated rather than rewritten — it stays the proposal as it was argued.
`ROLLOUT.md` carries the 2026-09-30 survey of the nine gates as a tally, not a list of names —
both halves of the step, and the same four gates are short in each — with an open-work row per
project. Two project gates compare their vendored copy against this host's canonical clone by
path, so they go red the moment that clone fast-forwards, not when this merges, and on every
branch of both; their re-vendor pull requests are not written yet. That the step fails loudly
is proved in the pull request, not assumed.

## 2026-09-29 — the unrecognised-filename example names the file Fineprint actually has (docs only; the standard is unchanged and VERSION is not bumped)
Backlog 164. `docs/DECISIONS.md` argued the narrow `unrecognised:` rule from Fineprint's
`docker-compose.realip.yml` — a production-side proof stack whose name said neither side. Fineprint's
PR #92 has since renamed that file `docker-compose.ci-realip.yml` and moved it to the gate's side:
`scripts/ci.sh` drives it and it runs the tag that gate builds, and the `ci-` prefix is deliberate so
the check reads the side off the name instead of guessing at it. The entry now says which name was
which and when, so a reader checking the example against Fineprint's tree finds it. The rule itself
is unchanged.

## 2026-09-29 — the gate ledger records the commit a run was armed on (tooling only; the standard is unchanged and VERSION stays 2026-09-20.2)
**A green row for a tree no step read.** `gate_ledger_record` is called from a gate's EXIT
trap and read HEAD there, minutes after the gate decided what it was judging — so a commit
landing in the checkout mid-run was handed the run's green row and a deploy could ship it
on evidence from the commit before it. `gate_ledger_arm` now pins HEAD before the first
step and the writer compares at trap time: HEAD moved, or it could not be read at arming,
and nothing is recorded — the run says which commit it began on and which one HEAD is now.
A dirty tree is still stamped `<sha>-dirty` rather than refused, because that is a sha no
deploy can resolve and it leaves evidence the gate ran. The row stays
`<sha> <kind> <utc> <rc> <log>`, so no reader anywhere changes. A gate that never calls
`gate_ledger_arm` records nothing and says so: fail-closed, because the silent alternative
is a project taking this version and keeping the bug. Sourcing discards an inherited
`GATE_ARMED` the way it already discards `GATE_SUITE_PASSED`. `scripts/check.sh` arms on the
line after `GATE_LEDGER_GIT`. The guard and its name are health-tracker's (`scripts/ci.sh`),
which Reflection #34 and Scribly #19 each hand-rolled into their own gates; this is the same
guard moved into the library those three vendor.
**Pre-flight's test no longer pins the stub's mood.** `preflight-clean` asserted the literal
`heavy-work free` while `preflight()` prints whatever `$HEAVY --status` answers; the fixture's
stub now answers what the case asks for, the case asks for a busy slot, and the assertion
reads that back — the seam is stubbed rather than the match loosened. The stub answers on two
lines as well, so `head -1` has a test. `scripts/lib/deploy/test.sh` gains four ledger cases
and twelve assertions; five mutations were watched go red first (the armed comparison, the
un-armed guard, the `unset`, the `heavy-work` half of the pre-flight line, and `head -1`).
deploy-lib VERSION is 2026-09-29 and all four vendored headers are re-stamped, so
`fleet-versions.sh` reports every project's vendored copy STALE until it re-vendors;
re-vendoring is its own round per project, and the pinned `SUITE_SHA256` those projects hold
becomes `d838dc7f6e132e172be0bb3ba682e5f7005f9a38ce603e6b5ee0520da6d23904`. The long-form why
is in `docs/DECISIONS.md`.

## 2026-09-29 — the image-tag check judges the file sets a gate really runs (tooling only; the standard is unchanged and VERSION stays 2026-09-20.2)
**A compose file judged alone is not what a gate runs.** The check read each file beside a root on
its own, so two shapes were invisible. An overlay that only sets `image:` for a service, with no
`build:` next to it, read as a tag nothing builds — while `docker compose -f base -f overlay`
inherits the base's `build:` and really does build under the overlay's tag. And a gate that passes
no `-f` at all runs compose over the production file itself: one project's gate built and ran
production's own tag for weeks under a green *"none shared"*, and when that hole was fixed the
check could not credit the fix either, because the new overlay's tag still looked unbuilt.

The check now reads `scripts/check.sh`, `ci.sh`, `e2e.sh` and `gate.sh` for the files each
`docker compose` call passes — `-f`, an exported `COMPOSE_FILE` (including one set in a file the
gate sources), or compose's own default base-and-override pair — and judges each set merged the
way compose merges it: a later `image:` wins, a `build:` anywhere in the set builds. A variable is
read from the assignments *above* the call, not from whichever value the file sets last, and a
call continued over several lines with `\` keeps every `-f` it names. Its report gains a
`gate scripts:` line, a `gate runs:` line naming what each run builds, and a line for every call
it could not resolve. It was run over every root on this box with a compose file beside it — 47 of
them, 11 project roots and 36 git worktrees, as listed by

    find /var/www -maxdepth 3 \( -name 'docker-compose*.y*ml' -o -name 'compose.y*ml' \) -printf '%h\n' | sort -u

45 of which carry a gate script this check reads. Four roots change verdict against `main`, all on
the same hole — `orbit`, whose gate passes no `-f` and so reaches production's tag, and three stale
memento worktrees (`deploy-lib-102`, `secrets-scan-102`, `standards-bump`), which that project's
own `main` has already closed; orbit is green again on the branch that fixes it. `date-picker` was
already red before this change. No root goes red on the new unread-call rule, and the later commits
of this branch move no verdict at all: 47/47 identical to `79188c1`. Nothing else moves.

Three smaller changes ride with it. Any `.yml` or `.yaml` beside the root carrying a `services:`
key at column 0 is now read, whatever its name, so a compose file renamed out of `docker-compose*`
is judged rather than invisible — case 7b of the test therefore ends in a FAIL naming the file
(exit 1) instead of the whole-root refusal (exit 2), which still stands for a root where nothing
carries `services:`. The column matters: an indented `services:` belongs to a `.gitlab-ci.yml`
job, not to compose. A call whose subcommand only inspects or tears down (`down`, `ps`, `logs`, …)
is printed as read but not judged, whatever named its files, because a teardown is not a build —
and a wrapper that carries a file set but no subcommand of its own is judged where it is *used*.
And a gate line naming `docker compose` that yields no call this reader can follow — an `eval`, an
`sh -c`, a wrapper built from a string — is printed as an unjudged call rather than looking like a
gate that never calls compose; it does not change the exit code, and `docs/DECISIONS.md` says why.

**A call this check cannot read is a refusal, not a note.** Reading a shell by regex leaves holes,
and a hole printed under a green exit is a hole nobody reads. A `-f` naming a file that is not
here, a variable given two values above the call, a wrapper defined one way in one branch and
another way in the next, or a `source` line that resolves to nothing now end the run with exit 1
and a line naming the call. A directory written into a `-f` value is this root unless only the
environment supplies it: `-f "$SHARED/compose.yml"` is no longer matched to the file of that name
beside this root, while a directory the script assigns is still taken to be this tree — including
one a command substitution computes and one assigned inside a single branch, the known limit
`docs/DECISIONS.md` now names. Four more shapes are read rather
than guessed at — a chain of `source` four deep, `$(dirname "$0")/lib.sh` and
`${BASH_SOURCE[0]%/*}/lib.sh`, a call continued over any number of lines, and a `docker compose`
line inside a heredoc body, which is text and not a call. The report now says which subcommand it
read instead of "no subcommand read", says nothing at all on a line that only defines a wrapper
judged further down, and reports a call that cannot build — `exec`, `start`, `restart` — as
*running* a tag rather than building it. The verdicts over the roots on this box are unchanged.

Forty-one new cases in `scripts/gate-image-tags-test.sh` (197 checks in all). Thirty-six of them
go red against a copy of the script from `main` — thirty-seven cases in all, counting case 7b,
which is not new but whose expected output changed. Seventeen deliberate mutations of the script
cover four of the five that cannot go red against `main`, and every case added or changed in the
last round goes red against the commit before it. The long-form why is in `docs/DECISIONS.md`.

**Order of merge.** The one project this turns red has its own fix open. Merge that project's pull
request first: every gate on this box runs the copy of this check that lives in the deployed clone
of this repository, so updating that clone before the project fix lands leaves that project's gate
red on a hole it has already closed.

## 2026-09-28 — the image-tag check refuses a root it found no compose file in (tooling only; the standard is unchanged and VERSION stays 2026-09-20.2)
**Nothing examined is no longer a pass.** Given a root with no `docker-compose*.yml` or
`compose*.yml` beside it, the check printed *"no compose file beside this root — nothing was
examined"* and exited 0, so a compose file renamed out of that pattern, or a root argument one
directory too high, was a green T9 step that had read nothing. The same sentence now goes to
stderr in one line naming the root, and the exit code is 2 — the code the script already uses for
"I cannot judge this", kept distinct from 1, which means a shared tag was found. No caller
changes: each of the eight call sites on this box reds on any non-zero, each passes its own
checkout root, and every one of those roots keeps its compose files in git — run against the
seven repositories they sit in, the new check exits 0 on every one. The `case` branches those callers wrote against the
old sentence are now unreachable rather than wrong. No opt-out flag: a project with no containers
does not wire T9's check into its gate, and a flag that silences this check is the flag that gets
added the day it goes red for the right reason. Case 7 of `scripts/gate-image-tags-test.sh`
changes with it and case 7b joins it (a compose file renamed to `stack.yml`), both proved red
first against a copy of the script from `main`. The long-form why is in `docs/DECISIONS.md`.

## 2026-09-27 — resolve refuses a deploy whose commits git cannot read (tooling only; the standard is unchanged and VERSION stays 2026-09-20.2)
**An unreadable commit is not "the trees differ".** `resolve()` compared the pull request's head
and merge commits with `if $GIT diff --quiet "$HEAD_SHA" "$MERGE_SHA"`, and `git diff` exits 128
when either object is missing or corrupt — a head branch deleted and garbage-collected, a merge
commit never fetched, a truncated loose object. The else branch read that 128 as *the trees
differ*, printed `RESOLVED #N merge … its tree is not head …'s`, set `GATE_SHA` to the merge
commit and deployed on a comparison that never happened. Both commits are now proved readable
with `git cat-file -e <sha>^{commit}` before anything is compared, each with its own refusal
naming the full sha and the command that repairs it — `git fetch origin refs/pull/<n>/head` for
the head, which GitHub keeps after the branch is deleted, and `git fetch origin <sha>` for the
merge, which is reachable from `main`; the comparison itself
distinguishes rc 0 (same tree) from rc 1 (differ) and refuses anything else, naming both shas and
the rc, so no third answer is ever folded into one of the two. The object check runs before the
`origin/main` tip comparison on purpose: an unreadable merge sha used to be reported as *main
moved since the merge*, which sent the operator to re-gate a commit that was never the problem.
`scripts/lib/deploy/test.sh` gains three cases — an unreadable head, an unreadable merge, and a
readable pair of commits whose shared tree object is gone, which is the rc-128 the third branch
answers — and six assertions. Five were proved red first against `resolve.sh` from `main`, where
the unreadable head and the unreadable tree both resolved as a merge to gate; the sixth holds the
merge refusal's wording, which `main` never printed. deploy-lib VERSION is 2026-09-27 and all four vendored headers are
re-stamped, so `fleet-versions.sh` reports every project's vendored copy STALE until it
re-vendors; re-vendoring into Reflection, Scribly and the rest is its own round, and the pinned
`SUITE_SHA256` those projects hold becomes
`c1e0bb3fcb038d75c143be4ac3e501ce90a5b4880cf5bfa4b62482079a7d4f0c`. `scripts/fleet-versions-test.sh`
case 14 went red on the bump — its "ahead of canonical" date was written out — and now derives it
from the canonical version, so the next bump cannot leave the fixture behind.

## 2026-09-25 — the image-tag check sees the tag compose invents, and refuses a built tag in a file it cannot place (tooling only; the standard is unchanged and VERSION stays 2026-09-20.2)
**A build with no `image:` key is not untagged.** Compose tags it `<project>-<service>`, which is
the tag `docker ps` shows two of this box's projects running in production — and the check
compared `image:` keys only, so it reported *"no built image tag resolved here — nothing a gate
run could overwrite"* for both. A gate compose file carrying `image: scribly-symfony` beside a
build passed that check while production ran that exact tag. Both sides now resolve the implicit
tag and compare it like a written one: the project comes from the file's own top-level `name:` if
it has one, else from the directory basename lower-cased and stripped the way compose-go
normalises a project name, and `x` is the same tag as `x:latest` as it already was. The finding is
located at the service's own line, the only line there is to point at. `extends:` counts as a
build on the gate side too, and an inherited `image:` counts as an image, so a service merging an
anchor that carries one keeps that tag instead of gaining an invented one; where the merged anchor
is not defined in the file the tag is counted *unresolved* and named, never guessed.
**A tag built in a file the classifier cannot place is now refused.** A compose file named outside
`*ci*`/`*e2e*`/`*prod*` was printed as `unrecognised: … read as production, on filename alone` and
exited 0, which is where a gate file under any other name has its disposable tag compared against
nothing. An unrecognised file that builds a tag now exits non-zero and says what to rename it to;
one that builds nothing still passes, and is still named. Failing on the name alone was the
recommendation and is deliberately not what this does — one project keeps a real production-side
proof stack under such a name, and reddening it for a file that builds nothing buys no safety.
The output line shapes are unchanged, because six projects' gates parse them; the counts move
where a project builds without naming tags. Seven new cases (15 to 21) in
`scripts/gate-image-tags-test.sh`, each proved red first against a copy of the script from `main`,
plus case 10's changed expectation. The long-form why is in `docs/DECISIONS.md`.

## 2026-09-20 — the fleet version check counts projects, names a moved canonical and notices an unlisted project (tooling only; the standard is unchanged and VERSION stays 2026-09-20.2)
Three defects, one script. **The tally counted rows, not projects.** `bad` grew once per failing
row — content and deploy-lib are two rows per project — while `checked` grew once per project, so
this box's ten projects reported `fleet: 10 of 10 project(s) need attention` when eight of them
do, and a count that can exceed its own denominator (`11 of 10`) as soon as an eleventh row fails.
A project is now one unit of attention however many of its rows fail: `8 of 10` today.
**A canonical that moved on read as a local edit.** The deploy-lib row compared bytes before it
read a header, so the day the deploy-lib VERSION went to 2026-09-20 every vendored copy reported
`DRIFTED (local edit, incl. a re-stamped header, or missing)` — advice that sent each project
hunting for an edit nobody made. The row now mirrors the content rows: the vendored
`# fleet-deploy-lib <ver> sha256:<h>` header is read first, a file that is not there is MISSING (it is not
byte-compared, so it no longer says it was), a body that disagrees with its own header is
DRIFTED, a header version sorting before the canonical is `STALE (deploy-lib <ver>, canonical
<cver>)`, and anything else that differs is DIVERGED — the same version re-stamped, or a version
sorting *after* the canonical, which means the clone we measured against is the unpulled one — the re-stamp the old code claimed to catch,
now named. Case 3 of the test changes with it: its fixture (body changed, header re-stamped to
the current version) is the DIVERGED case, and asserts that word instead of DRIFTED. The header
pattern also accepts a `.N` serial, as the canonical VERSION validator already did.
**A new project joined the fleet silently absent.** `DEFAULT_PROJECTS` stays the contract, but
after the run every directory under `$ROOT` holding a `.git`, not on the list and not named
`*-staging` or `*-worktrees`, gets a row of its own — `UNLISTED <name>` — and is counted as
attention, so the answer to "is the whole fleet checked?" comes from the check rather than from
memory. Each unlisted project is added to both sides of the summary, so the count can never again
exceed its own denominator. The row is ALL-CAPS and shaped like every other row deliberately: the
watchdog reads this output through `^\s+[A-Z]+\s` and reports an exit 1 carrying no such line as
"output format changed?", so a lowercase summary line would have turned the fleet's one real
finding into a parser complaint.
Three new assertions in `scripts/fleet-versions-test.sh` (cases 10 to 12), each proved red first
against a copy of the script from `main`, plus case 3's changed expectation.

## 2026-09-20 — the deploy library gates the commit that deploys, not the branch head (tooling only; the standard is unchanged and VERSION stays 2026-09-20.2)
`resolve()` compared the pull request's head tree with the merge commit's and refused every
difference, so a PR merged after `main` had moved was undeployable and the refusal's advice —
re-gate the merge commit — changed neither tree. Orbit hit it on its PR #80 and fixed it there
(`6d2d443`, `a2c4c28`); this is that change upstream, ported not redesigned. `resolve()` now sets
`GATE_SHA` and `GATE_WHAT`: the branch head when the two trees are identical, the merge commit
itself when they are not. `gated()` reads `GATE_SHA`, so the ledger is asked about the commit
whose tree actually deploys, the refusal names it (`gate that merge, then deploy`), and `GATED`
— and with it a project's DONE line — reads `ledger head <sha>` or `ledger merge <sha>` beside
the `by hand` that was always there. `--gated-by-hand` keeps its meaning exactly.
`ledger.sh` degrades on its own: a project that vendors it without the matching `resolve.sh`,
or a caller that never reaches `resolve`, leaves `GATE_SHA` unset, and under `set -u` that now
falls back to the head (`GATE_WHAT` "head") instead of dying — with a test that goes red when
the default is removed. A `GATE_SHA` that is set but *empty* is a different thing — a resolve
that was skipped or did not finish — and is refused outright rather than read as the head,
which would fail open in exactly the squash-or-rebase case this change exists for. `resolve.sh` also quotes its two literals and carries the two
`# shellcheck disable=SC2034` with the reason beside them, for lints that cannot see that
`ledger.sh` reads those two variables in the same shell.
`scripts/lib/deploy/test.sh` gains five assertions across three new cases (an ungated merge, a
gated merge, and the unset-`GATE_SHA` fallback) and tightens two existing ones; each was proved
red first against a copy of the old library, and the fallback against a copy with its default
removed. deploy-lib VERSION is 2026-09-20 and all four vendored headers are re-stamped, so
`fleet-versions.sh` reports every project's vendored copy DRIFTED or STALE until it re-vendors,
which each project does on its next deploy-lib bump.

## 2026-09-20 — W4 wording corrected: the title is the action (VERSION 2026-09-20.2)
The first release of the rule, above, said *one past-tense action with no file names*. Ghie, reviewing it:
"not necessarily filename, if there's only one file, that's fine. It should be the action, like 'Fix
flickering bla..'" Both clauses struck; W4 says *one action — what was done —* and shows both shapes.
Merged as #12 minutes before the correction was pushed, hence the serial: the second change of the day
takes `.2`, as 2026-09-19.2 did.

## 2026-09-20 — W4: a PR's title is one past-tense action (VERSION 2026-09-20)
Ghie, on a Memento PR titled "The phone never caches card images": **"when creating a PR, title should be
action, 'what was done?' Like this should be: Added caching for card images."**

W4 already governed the PR body and said nothing about the title, so the rule was carried in each
session's head and applied unevenly. Why it folds into W4 rather than standing as its own rule, what
its check really is, and why the change carries no test: `docs/DECISIONS.md`.

**The previous release claimed this rule twice and carried it neither time.** PR #11 was titled "Added S7
(preview before any bulk delete) and W4's title rule" and its body said "a pull request's title now says
what was done, not what was wrong" — and the word "title" appears nowhere in its eight-file diff. W4 was
untouched. It was found by reading the merged text rather than the PR (W9), which is the same class of
mistake the standard's own audit was hunting: a claim nobody exercised.

## 2026-09-19 — S7: nothing is deleted in bulk until its read-only twin has run (VERSION 2026-09-19.2)
Ghie, on being handed a `docker volume prune` line to type: **"Make this fleetwide, very important."**

The near miss, found by the personal-vps session: a prune offered as finished gate leftovers would also
have taken a live app stack's named database volume. Docker counts a **torn-down** stack's named volume
as dangling — `compose down` removes the containers that held it, and nothing then holds the volume — so
`docker volume prune --all` proposes data while reading as a cleanup. An "are you sure?" and a dry run
caught it. That volume turned out to be empty; on a stack that had ever run it would have been data with
no backup. Reproduce the shape, read-only, before trusting any count:
`docker volume ls -f dangling=true --format '{{.Name}}' | grep -vcE '^[0-9a-f]{64}$'` — on 2026-09-19 that
is 56 named volumes, including the database and search volumes of six gate and review stacks.

The rule's second half is not about Docker: **a refusal by a permission layer is never re-routed to a
person without the preview and the count.** A layer refusing a destructive command is a decision, and
handing the same line to someone else walks around it.

**VERSION takes a serial** — a date alone cannot distinguish two changes made on one day, and a project
vendoring between them reads DIVERGED ("local edit re-stamped?") rather than STALE. Two things follow:
`scripts/fleet-versions.sh` validated the canonical VERSION as a strict date and would have refused to
report on any project at all (it now accepts `YYYY-MM-DD[.N]`, with a test for each), and every project's
drift test asserts the same shape, so **each adoption or bump PR widens its own regex** — ROLLOUT.md
step 4 says so. The invariant the serial trades into — every change to the body moves VERSION — is
checked by review until a gate step enforces it; `docs/DECISIONS.md` records both.

## 2026-09-19 — three rules stop claiming more than they check; the gate obeys T3 (VERSION unchanged)
From the audit of claims nobody had exercised (fleet backlog 83/87), which hunted statements the system
makes about itself that nobody proved by running them. C10 credited "static analysis" with finding dead
code most of it cannot see; S6 claimed every gate refuses a deployed checkout, when two of five isolate
their writes instead, deliberately; C7 named a project, in a public repository. What each rule now says,
and why both S6 shapes are legitimate, is in `docs/DECISIONS.md`.

The gate itself broke T3: `scripts/check.sh` ran its slowest step third with four cheaper ones behind it.
The seven steps were timed individually and renumbered cheapest-first; the measurement, and the caveat
that steps 4 and 5 sit inside run-to-run noise, are in `docs/DECISIONS.md` — which now exists, because
the repo kept its long-form why in the README while W7 tells every project to keep the file.

**VERSION does not move, and there is a window to know about.** VERSION is a date, and PR #9 moved it to
`2026-09-19` earlier today, so two different bodies now carry that string. `scripts/fleet-versions.sh`
reaches STALE only when the declared version differs, so a project that vendored the text *between* #9's
merge and this one reads DIVERGED — "local edit re-stamped?" — when it has done nothing wrong. Today's
five adopters all declare `2026-08-23` and correctly read STALE. Land this before the next adoption, and
no project ever sits in the window.

## 2026-09-19 — a gate must not build the image production runs (new rule T9; VERSION moves to 2026-09-19)
Backlog 80, found by the personal-vps session reviewing Memento #99: Memento's live container was
recreated from a `memento/app:latest` that a browser-gate run on an unmerged branch had overwritten,
so it came up carrying the `gd` and `exif` extensions that only that branch builds. Memento's own fix
has since shipped. Running the new check across every project on the box on 2026-09-19 answers: **one
project still builds one tag for both its gate and production**, and that fix is its own pull request;
the rest either keep the two apart already, build no app image, or have no gate compose file at all.
ROLLOUT.md carries the tally — counts and not names, because this repository is public.

T9 has two halves: a gate's image tag is separate and disposable, and a deploy builds the production
tag itself from the merged tree and proves the running container by image id rather than by tag.
`scripts/gate-image-tags.sh <project-root>` is the first half's check; its own header says what it
reads, and this file does not repeat it. **The second half has no check anywhere yet** — no deploy on
this box compares a running container's image id against the id its deploy built — so T9 says so
plainly rather than naming a mechanism that does not perform the check, which is the very failure the
rule exists to stop. ROLLOUT.md carries it as open work.

`scripts/gate-image-tags-test.sh` drives the check from fixtures in a temp dir: a shared tag, separate
tags, a resolved `${CI_APP_IMAGE:-x/app:ci}`, a default that IS the production tag, a gate that only
runs a tag it did not build, an unresolvable `${VAR:?}`, a build inherited through a YAML merge key, an
untagged image, an unrecognised compose filename, a double-quoted value, a `compose.yaml`, a symlinked
file, a CRLF file, a bind-mount project and an empty directory. Ten mutations were made against a
scratch copy, one per behaviour, and the matching fixture went red every time. The check never exits
silently: it prints the files it read, the values it could not resolve and the built-tag count, because
a silent pass made "nothing is built here" and "I could not tell" look identical — and a build
inherited through `<<:` or `extends` counts as built, which is what made that silence reachable. The
gate grew a seventh step.

This entry changes the standard, so VERSION moves to 2026-09-19 — every vendored `docs/STANDARDS.md`
is STALE to `scripts/fleet-versions.sh` until its project takes the bump. README: the rule count,
"The gate", and `scripts/gate-image-tags.sh`.

## 2026-09-19 — deploy scripts find their own helpers (docs only; the standard is unchanged and VERSION is not bumped)
Backlog 76, found by the orbit session landing its own PR #89 today: a project's
`scripts/deploy.sh` that resolves `docs-only.sh` and `verify.sh` through `"$ROOT/scripts/…"`
cannot land itself — on a first deploy those helpers are not on the box yet, so the call exits
127 and the first landing had to be done by hand instead. The vendored `scripts/lib/deploy/`
files were already loaded the right way, from the script's own directory, not `$ROOT`'s. README:
"A deploy script finds its helpers in its own directory".

## 2026-09-19 — a busy pane's queued line no longer looks undelivered (tooling only; the standard is unchanged and VERSION is not bumped)
`scripts/queue-start.sh` borrowed its delivery transport from merge-notify, including the
verified-Enter loop that expects the input row to go empty. When the target session is mid-turn,
Claude Code queues a typed line instead of clearing the row — the sentence still arrives at the
next turn boundary, but the loop saw the row non-empty after 3 Enters, logged it as not
delivered, and recorded nothing in the state file, so the next tick would type the same sentence
again. `deliver()` now checks, after the Enter tries, whether the row still holds OUR sentence
(the existing 10-char-prefix check) with no permission dialog on screen; if so it logs
`queued in a busy pane <p>: <session> item N (the line is consumed at its next turn)` and returns
success, so the caller records the item like a normal delivery. A row holding something else, or
a dialog on screen, keeps the old behaviour unchanged. `merge-notify` is untouched.

## 2026-09-19 — queued work starts itself under a budget (tooling only; the standard is unchanged and VERSION is not bumped)
`scripts/fleet-budget.sh` answers one question in one line: `ok <numbers>` or `hold <reason>`.
It reads the three meters the CLI's own `/usage` shows, from the endpoint the CLI uses
(`/api/oauth/usage`) with root's OAuth token, and holds when any meter is at or above its cap
(`FIVE_HOUR_MAX=50 WEEK_ALL_MAX=60 WEEK_FABLE_MAX=60`, overridable in `/root/fleet-budget.conf`),
when the box is over a capacity red line (load15 above the core count, under 1500 MB available,
memory `full avg300` above 10), or when anything is unreadable — a token that is missing or
expired, a 401, an unreadable `/proc` value. Unreadable is never coerced to zero. The response
is cached for ten minutes at mode 600; the token is never printed, logged or written anywhere.

`scripts/queue-start.sh` is the half-hourly tick that turns a green budget into work starting.
For each session in `/root/backlog-owners` it types one marked sentence into that session's pane
with merge-notify's transport and its safety (dialog defer, stranded-line handling, verified
Enter). A session is idle only if it keeps a registry file and that file is empty, no
`<app>-deploy-*` unit is active for an app it owns, and heavy-work holds no slot for it; a
missing registry means not idle, so a session opts in by keeping one. There is no walk-down:
only a session's top queued item is ever announced, and if that item is held or was announced
within 24 h the tick says nothing for that session.

`scripts/backlog-owners-lint.py` is red when a queued item has no owner, when an owners line
names an unknown session or an item that is not in the backlog, or when a line is malformed.

The gate grew two steps: `scripts/fleet-budget-test.sh` (5) and `scripts/queue-start-test.sh` (6).
Both are fakes only — a fake meter JSON, fake `/proc` files, a fake backlog, owners, registries,
budget script, `systemctl` and `heavy-work`. No network, no credentials, no tmux, no delivery.

## 2026-09-19 — the gate ledger cannot record green for a run that did not finish (tooling only; the standard is unchanged and VERSION is not bumped)
2026-09-19 05:58Z Fineprint's `scripts/e2e.sh` was killed while its stack was starting. The
EXIT trap read `$?` from the last command that had finished — 0 — and wrote a green `e2e` line
for that head; `scripts/ci.sh`'s cleanup has the same shape. `gate_ledger_record` now writes
rc 0 only when the gate script has set `GATE_SUITE_PASSED=1` after its suite returned 0.
Sourcing `ledger.sh` now `unset`s `GATE_SUITE_PASSED` at the top level, so an operator's
`export GATE_SUITE_PASSED=1` (or a CI wrapper's) is discarded rather than honoured — only the
gate script's own shell, set after its own suite, counts. Without the flag an rc of 0 is written as 1, loudly: `gate-ledger: rc 0 without
GATE_SUITE_PASSED — the run did not finish; recorded as a failure` on stderr. A non-zero rc is
unchanged. The reader is now newest-wins — the last line for a (sha, kind) decides, so a later
red overrides an earlier green and a re-run's green overrides an earlier red; the old awk took
any green line, so one false green vouched for a head forever. `scripts/check.sh` sets the flag
once its four steps have run. `scripts/lib/deploy/test.sh` gains eight groups (flag, no flag,
non-zero rc, green→red, red→green, append order deciding over an out-of-order timestamp, an
inherited env export discarded at source time, and 05:58Z's incident end to end); each was proved red once
against a mutated copy of the library. `scripts/fleet-versions-test.sh` reads the deploy-lib
VERSION instead of hardcoding it. deploy-lib VERSION is 2026-09-19, and `ledger.sh` changed
again in this same version, so `fleet-versions.sh`'s byte-for-byte file comparison catches
Fineprint, Reflection and Scribly's vendored copies first: they report DRIFTED, not STALE,
until they re-vendor — the VERSION comparison is never reached. Fineprint's `ci.sh` and `e2e.sh` set the
flag after their suites at the same time. README: "The gate ledger".

## 2026-09-18 — repo gate + deploy-lib drift check (tooling only; the standard is unchanged and VERSION is not bumped)
`scripts/check.sh` — this repo's own pre-merge gate: `bash -n` on every tracked script,
shellcheck (`koalaman/shellcheck:v0.10.0`, style severity, no `-x` — a missing image fails
loud, never skips), `scripts/lib/deploy/test.sh`, then `scripts/fleet-versions-test.sh`;
cheapest first (T3), prints `=== GATE OK ===` / `=== GATE FAILED (step N: name) ===`, and
records a full run to the fleet gate ledger the same way Fineprint's `ci.sh` does — a
partial (`--only N`) run records nothing. `scripts/fleet-versions.sh` now also compares
each project's vendored `scripts/lib/deploy/` against canonical: one extra parsable line
per project (`none` / `MISSING` / `STALE` / `DRIFTED` / `BADHEADER` / `ok`), same shape the
watchdog's line parser already reads, existing lines and exit codes unchanged. A body
edited without re-stamping the header is `DRIFTED`; a body edited AND re-stamped correctly
is also `DRIFTED` — the case a project's own drift test cannot see. `scripts/fleet-versions-test.sh`
proves both against fakes; each case proved red once. README: "The gate" and one sentence
under the fleet check.

## 2026-09-18 — vendored deploy library (tooling only; the standard is unchanged and VERSION is not bumped)
`scripts/lib/deploy/` — `summary.sh`, `resolve.sh`, `ledger.sh`, `preflight.sh` and its own `VERSION`, the shared half of a deploy script that Fineprint, Reflection and Scribly each needed (C1: the third copy). Moved out of Fineprint's `scripts/deploy.sh` rather than rewritten: same function names, same sentences. Every file carries `# fleet-deploy-lib <VERSION> sha256:<body>` on line 1 and each project's gate recomputes it, which is the same drift mechanism `docs/STANDARDS.md` already uses. `scripts/lib/deploy/test.sh` proves every function, every refusal sentence and every header against fakes; each check was proved red once. README: "Vendored scripts".

`resolve.sh` fix: Reflection's first live deploy refused at resolve — `gh pr view` with no `-R` infers the repo from the cwd's git remote and shells out to git as root inside the app-owned checkout, which "detected dubious ownership" and produced `REFUSED: gh could not read PR #20`. `gh_repo` now derives `owner/repo` from `git remote get-url origin` (scp, `ssh://` and `https://` forms), `DEPLOY_GH_REPO` overrides it, an unparsable origin refuses before any `gh` call, and the one `gh` call in the lib now carries `-R`. The old test's fake `gh` never checked for `-R`, so it never would have caught this; it now rejects a missing `-R` and the pre-fix `resolve.sh` proves red against it.

## 2026-09-16 — rollout note (docs only; the standard is unchanged and VERSION is not bumped)
ROLLOUT.md step 0 and the floor decision: the machine-wide floor goes in the CLAUDE.md of the directory the non-project sessions start in, not in the user-level rules folder, because a user-level rule loads in every session and doubles the standard in every project that has vendored its copy. Verification is a headless session's transcript, not the symlink's existence.

## 2026-09-04 — published
Published: README, LICENSE, ROLLOUT and SOURCES rewritten for a public reader; the standard itself unchanged.

## 2026-08-23 — fleet-level check (tooling only; the standard is unchanged and VERSION is not bumped)
`scripts/fleet-versions.sh` compares every project's vendored `docs/STANDARDS.md` against the canonical clone — the one comparison no project gate can make, since each project's drift test only checks its copy against its own header. Reports ok / MISSING / UNREADABLE / BADHEADER / DRIFTED / DIVERGED / STALE / VERSION / NOLINK / BADLINK; a project with no vendored copy, or a run that checks zero projects, is a failure rather than a pass. Prints the canonical HEAD it measured against. ROLLOUT.md step 5.

## 2026-08-23 — first adopted version
36 rules in four groups (Code C1–C13, Tests T1–T8, Security & privacy S1–S6, Workflow W1–W9), derived from what the nine projects already practised; nine cross-project conflicts resolved (SOURCES.md); proposals P1 (dependency audit in the gate) and P3 (three facts in every project header) adopted, P2 deferred to the next browser-gate touch per project, P4/P5 kept as notes. Rollout one project at a time; see ROLLOUT.md for the mechanism. Adopted by Ghie.
