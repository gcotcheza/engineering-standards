# Root gates run from a hash-verified export of one sha

Root ran an app's scripts/check.sh, scripts/e2e.sh and docker compose straight from an app-owned
worktree. bash reads a script as it runs and compose re-reads its files, so the app user could
rewrite either before or during a run and have root execute it; that undid the root-owned env copy
(card 716) and is a root escalation. A commit landing mid-run could also earn a ledger row for a sha
that never ran (card 717).

A gate now runs only through `scripts/gate-run.sh <app> <sha40> <script>`. The entry copies
scripts/lib/gate and scripts/lib/deploy blob by blob from the box clone's origin/main, with
fleet-deploy's clone_lib checks, and execs that copy. It takes an explicit 40-hex sha and fetches it
from GitHub, and only from GitHub, so git hashes every object; an unpushed sha is refused. The
objects land in the run's own `repo.git`, which borrows root's mirror through alternates (root writes
the mirror's literal path, and only when the mirror's objects, every parent and everything beneath
them are root's alone, with no link), so the
mirror keeps holding main only, as fleet-deploy-on-merge requires; origin/main comes from GitHub in
the same fetch, never from the app's repo. Every entry is judged before a byte is written (links,
submodules, odd paths, compose include and extends file, a committed .env), and the tree is written
by root into /run/<app>-gate/<id>, after a check that /run has twice the tree's size free.

Scripts, compose files and env files are read from there only. The gate script runs under `env -i`
from `cd /`, with the existing ledger seams pointed into the run: GATE_LEDGER at `<run>/status` and
the CI_GIT, CHECK_GIT, E2E_GIT and GATE_LEDGER_GIT seams at `repo.git` with the exported tree, so
the deploy lib's own record rules (75 not recorded, rc 0 needs suite-passed) apply unchanged. After
the run gate-run re-hashes the tree against its manifest; a changed or added file means rc 1. Then
`<run>/status` must hold exactly one row, for the exported sha and the script's kind: zero rows, two,
or another sha's row is refused with no ledger row at all, and a row whose rc differs from the
script's real exit is written as rc 1. Only then does it append to the real ledger. A deliberate red
proof (rule 20) passes `--ledger <file>`, refused unless the file is named `*ledger*` and it and its
directory chain are root's alone, so its row never reaches the real ledger. `env -i` drops a
GATE_LEDGER the caller set, so a set GATE_LEDGER without `--ledger` is refused rather than letting
that proof's row land in the real ledger.

Compose goes through `$GATE_COMPOSE`, which runs docker compose with the tree as project directory,
the deploy compose policy over the tree's files, and a root-written override that makes every tree
bind read-only and lays the build dirs over each service that mounts the tree. Both its `config
--format json` renders take `--profile '*'`, as the deploy policy does, so a service behind
`profiles:` gets the override and the check too; a `-f`, `-p`, `--project-directory` or `--env-file`
in any spelling after the leading options is refused, because compose would still read it. A
subcommand's own `-f` or `-p` (logs, rm, run) is therefore spelled long. The config is checked
before every call: a read-write bind under the run, a bind that is neither in the run nor exactly
one build dir, a build context outside the run, or a volume or network whose name is
outside the gate's own project (so `down -v` cannot reach production's) is refused. Every `-f` file,
whatever its name, is checked for `include:` and `extends.file`. The gate grants no extra binds, so the
deploy policy's /etc/fleet/app-binds list is not read. composer, npm and vite run as the app uid
(`--build`, `run --user <uid>:<gid>`) in /var/tmp/<app>-gate-build/<id>. Both of those directories
are root's, 0755; root creates each build dir in `<id>` and hands only it to the app. Docker follows a
bind source that is a symlink, and a check of the link alone races the app; ownership closes it,
because the app cannot rename or replace an entry in a directory it cannot write. Before every compose
call each build dir is still checked (not a link, the app's, in root's `<id>` in root's parent) as a
backstop. Root never executes from them; at cleanup the app uid empties each one, then root removes the
empty directories.

Not closed: the sha's own code still runs as root, so review remains the guard on what a commit
contains; the app-writable build dirs can still fake a result, but cannot reach root; host steps
other than docker still run as root (backlog 720). The export-tree block is now one lib file;
fleet-deploy and fleet-deploy-on-merge are installed under /usr/local/sbin and still carry their own
copies until a packet makes them source it. Rejected: git archive through git-as, whose bytes
nothing ties to the sha; and a pack route from the app user, which gate-once makes unnecessary.
