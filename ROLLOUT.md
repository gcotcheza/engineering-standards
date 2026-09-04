# Rollout — how one standard applies to many repositories without becoming many standards

## The recommendation, in three sentences

**Vendor one file per repo and let the harness load it — (a) + (c) combined — with (b) underneath as a machine-wide floor.** The canonical text lives in a small `engineering-standards` repository; each project vendors it byte-identically at `docs/STANDARDS.md`, adds `.claude/rules/standards.md` as a **symlink** to that same file (symlinks inside `.claude/rules/` are supported, for single files and directories), and its own gate runs a drift test on it — so *one* copy is at once readable on GitHub, reviewable in a PR diff, and loaded at launch into every session started in that project. Underneath it, a canonical clone on the host with a symlink into the user-level rules directory gives every session the same rules even when it starts outside a project, and each project's `CLAUDE.md` keeps only what is genuinely local.

Two things this design depends on, both worth stating plainly:

- **No `paths:` frontmatter on the rules files.** A rule file *without* `paths:` loads at session launch like `CLAUDE.md`; one *with* a `paths:` glob loads lazily, only when a matching file is read. A standard that only appears once someone happens to open a PHP file is not a standard.
- **Subagents are not guaranteed to receive rules** — the documentation does not say either way, so we must not assume it. That is exactly why worker briefs keep quoting the bar verbatim (the comment cap, the four PR headings), and why the **repo copy still matters**: a reviewer on GitHub, a laptop checkout and a worker in a scratch clone all see the file, whatever the harness did or did not load.

**Precedence**, low to high: managed policy → user (`~/.claude`) → project (`./CLAUDE.md`, `./.claude/rules`) → `./CLAUDE.local.md`. That runs the right way round: the fleet floor sits at user level, and a project can override it in its own repo — which is where a written exception belongs.

## Why this combination, and what each part costs

| Option | What it gets right | What it costs / why not alone |
|---|---|---|
| **(a) Canonical repo + vendored `docs/STANDARDS.md` + gate drift check** | The rules travel with the code: a GitHub reviewer, a laptop checkout and a scratch-clone worker all read the same text the author did. The gate turns drift into a failing test instead of a discovery, and it needs no network. | Nothing pulls the update by itself — a project can sit on an old version until someone opens the bump PR. On its own it is also invisible to the harness: nobody's session *loads* it, they have to go and read it. |
| **(b) Canonical clone on the host + a symlink into the user-level rules directory** | Zero copies and zero drift by construction — one file on disk, applied to every project on the machine, loaded at launch by every session including ones started outside any project. | Invisible on GitHub, invisible to a laptop, invisible in a PR diff, and **not guaranteed for subagents** — so it silently does not cover the situations where a worker is most likely to do damage. It is a floor, never the whole thing. |
| **(c) Per-repo `.claude/rules/standards.md`** | In the repo *and* loaded at launch, which is exactly the gap (a) leaves; it is drift-checkable like any other tracked file, and project precedence means a local exception can legitimately override the fleet floor. | A second file per repo if you copy it — which is why we make it a **symlink to `docs/STANDARDS.md`** rather than a duplicate: one set of bytes, one hash, one thing to drift-check, and `docs/` keeps the human-facing path people already link to. |

**What we deliberately do not use: cross-repo `@path` imports.** `CLAUDE.md` can import other files by path (absolute paths allowed, nesting up to 4 deep), which looks like the obvious way to point many repos at one canonical file — but an import that points **outside the project triggers a one-time approval dialog**. With a set of mostly unattended always-on sessions, that is a session sitting on a prompt nobody is there to answer. A symlink is resolved by the filesystem and asks nobody anything.

## The mechanism, concretely

1. **Canonical repo** `engineering-standards`: `ENGINEERING-STANDARDS.md`, `SOURCES.md`, a `VERSION` line, and its own `CHANGELOG.md`. Changes go through the same flow as code — branch, PR, four headings, the owner merges.
2. **Machine-wide floor:** clone the canonical repo once onto the host, then symlink `ENGINEERING-STANDARDS.md` into the user-level rules directory (`~/.claude/rules/`). No `paths:` frontmatter, so every session loads it at launch. Updating the floor is `git pull` in one directory.
3. **Vendored copy** in each project at `docs/STANDARDS.md`, byte-identical, carrying a header line `<!-- standards-version: 2026-08-23 · sha256:… -->`, plus `.claude/rules/standards.md` as a symlink to it (`ln -s ../../docs/STANDARDS.md .claude/rules/standards.md`). One file, two doors.
4. **Drift check in the project's gate**, modelled on a pattern one of the Laravel projects already uses: a unit test that reads a *second file* out of the repo and asserts the two halves agree. Here it hashes the vendored file, compares it to the hash declared in its own header, and fails if a local edit crept in — and asserts the symlink still resolves. No network, so it cannot make the gate flaky.
5. **A fleet-level update pass** (an always-on session, not a project gate) compares each project's declared version against the canonical repo and opens the bump PR where they differ. That is the only piece that needs to see both repos at once. `scripts/fleet-versions.sh` is that check.
6. **Each `CLAUDE.md` shrinks** to roughly:

```markdown
# <Project> — house rules
Fleet engineering standards: docs/STANDARDS.md (also loaded via .claude/rules/standards.md).
They apply here in full; anything below overrides them and says why.
- Where work happens: <worktree path / clone / staging checkout> — this checkout is <production / not production>.
- Merging to main <does / does not> deploy. Runbook: .claude/commands/deploy.md.
- The gate: <scripts/check.sh | scripts/ci.sh>. Browser gate: <scripts/e2e.sh | none yet>.
- Layers: <one line, or "none — plain MVC">.
- Why-decisions: docs/DECISIONS.md.
- Project-specific rules below.
```

## Step 0, before any project PR

Set the floor up first — it is one clone and one symlink, it needs no project's cooperation, and it means every session already has the standard while the per-project PRs are still being written:

```
git clone <engineering-standards> <canonical-path>
ln -s <canonical-path>/ENGINEERING-STANDARDS.md ~/.claude/rules/engineering-standards.md
```

Then verify it the way rule W9 asks — start a session and check the rules actually loaded — rather than concluding it from the fact that the symlink exists.

## Three things to decide before starting

- **Who owns the canonical file.** One repo, one reviewer, changes by PR — otherwise the vendored copies will disagree within a month, which is exactly the failure this whole exercise exists to prevent.
- **Whether the machine-wide floor is `~/.claude/rules/` or `~/.claude/CLAUDE.md`.** Recommended: `rules/`, because a symlinked rule file is one line to add and one line to remove, and it keeps the standard separate from whatever personal preferences that CLAUDE.md accumulates. Either way it is a floor and never the whole answer — subagents are not guaranteed to receive it.
- **What a project does when it cannot meet a rule yet.** Recommended: an `## Exceptions` block in its own `CLAUDE.md`, each line naming the rule, the reason and what would have to be true to drop it. Silence must stop being an option — it is what conflicts 6 and 7 in `SOURCES.md` are made of.
