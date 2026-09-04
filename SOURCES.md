# Sources — where every rule came from

Every rule in `ENGINEERING-STANDARDS.md` was already practised in at least one project
before it was written down. This file is the receipt: rule → the text it was derived
from. The projects themselves are private, so each citation names the *kind* of file it
came from rather than a path — a project's `CLAUDE.md` (its house rules), its
`docs/DECISIONS.md` (the long-form why), its gate script, its tests, or the fleet's
shared memory (the owner's standing instructions to the AI sessions).

## Code

| Rule | Derived from |
|---|---|
| C1 Extract on the third copy | A Laravel project's `docs/DECISIONS.md`: a byte-size helper "replaced three copies of the same kB/MB rule… a fourth screen… reads this rather than writing a fourth copy"; "Two implementations of 'what counts as already here' would drift"; one gradient "written out 23 times across 17 components" |
| C2 Don't merge what differs underneath | The same `docs/DECISIONS.md`: a CSS custom property "IS RE-DECLARED IN ALL THREE `[data-child-theme]` BLOCKS, and that repetition is the entry… the theme test now fails if anybody tidies the repetition away"; and "A MENU IS NOT A MODAL, so it deliberately does NOT use `dialog-focus-traps-are-hand-rolled`" |
| C3 Names over comments | The fleet's shared memory (comment-style note), which states the survival test; a Laravel project's `CLAUDE.md` |
| C4 Comments ≤ 2 lines | The fleet's shared memory (comment-style note); a Laravel project's `CLAUDE.md` ("Inline comments run at most 2 lines") |
| C5 Paragraph-length rationale → docs | The fleet's shared memory (comment-style note); a Laravel project's `docs/DECISIONS.md` preamble; another Laravel project's `CLAUDE.md` |
| C6 One unit, one job | A Laravel project's `docs/DECISIONS.md` ("`EntryStore` exists to own one sequence"; pure `groupByYear`/`summarise` "tested without mounting anything"); a Laravel project's `CLAUDE.md` ("Controllers are thin") |
| C7 Layers point inward | A Laravel project's `CLAUDE.md` plus the Deptrac step in its gate script; the Clean Architecture map in a second Laravel project's `CLAUDE.md`; the contexts map in a third |
| C8 Validate at the edge, rule in the domain | A Laravel project's `CLAUDE.md` (Form Requests → DTO → Command); another's seven `app/Http/Requests/` classes and its `docs/DECISIONS.md` entry where the same rule is re-checked on a hand-edited file no middleware touched; a Symfony project's `CLAUDE.md` (MIME validation on upload) |
| C9 Fail loudly | A Laravel project's `docs/DECISIONS.md`: "fails loudly instead of half-reading", "refused loudly", and the deliberate exceptions — logged, swallowed, and repairable by a named mirror-verify / re-index command |
| C10 No dead code | The same `docs/DECISIONS.md`: code "deleted in a review as dead code — correctly, on the evidence… The finding was right and the fix was the wrong half" |
| C11 Design tokens are the only place a colour is decided | A Laravel project's `docs/DECISIONS.md` ("`tokens.css` calls itself the only place a colour is decided, and four values were being decided elsewhere") and the theme test that asserts the code and the stylesheet still agree; the design-token sections of two other projects' `CLAUDE.md` |
| C12 Inline validation mirrors the server | **Owner's instruction, 2026-08-23**: "all form fields should have front end inline validation" (after a tablet accepted `6778888899` as a date with no message). Mechanism from a Laravel project's inline-validation branch: request rules + `messages()`, a browser rules module, and a sentence-agreement test on the same two-files-must-agree pattern as the theme test |
| C13 Never the browser's native validation UI | **Owner's instruction, 2026-08-23**: "don't use browser default validation, they are ugly". Already the practice in a Laravel project's settings forms (`novalidate` on every `<form>`) |

## Tests

| Rule | Derived from |
|---|---|
| T1 Gate green before merge | A Laravel project's `CLAUDE.md` ("No exceptions for 'just a docs change'") and its seven-step gate script; two other projects' gate scripts |
| T2 Gate runs in the containers | A Laravel project's gate script: "a gate that passes against a PHP the production image does not have is worse than no gate, because it is trusted" |
| T3 Cheapest checks first | The same gate script, whose step list is headed "ORDER IS DELIBERATE" |
| T4 Every bug fix carries a test | A Laravel/Livewire project's `CLAUDE.md`, on a phone-layout bug that "passed every PHP test the whole time it was live"; a Laravel project's `docs/DECISIONS.md` entry recording a decision as a test |
| T5 Tests proven able to fail | A Laravel project's `docs/DECISIONS.md`: an assertion "checking an ARRAY THAT COULD NEVER RECEIVE AN EVENT… every spec's 'clean' was vacuous rather than earned"; and "The first version of this test recorded only THAT a removal happened, which a review proved hollow… Both mutations were then run against the current test and both turn it red" |
| T6 Browser E2E in-repo, throwaway stack | The fleet's shared memory (browser-E2E standard); the in-repo `e2e/` directories of three projects |
| T7 E2E resource caps | The fleet's shared memory (browser-E2E standard: three mandatory caps, "find it, don't assume"); the `playwright.config.js` worker limits of three projects and the `--memory=2g` flag on the container the browsers actually run in |
| T8 Accessibility baseline | A Laravel project's `docs/DECISIONS.md`: real `<button>`s "for the same keyboard-reachability reason"; a 44px touch target via `::after` where "the visible pill stays 22px"; hand-rolled focus traps where the opener holds a reference and takes focus back; re-anchoring focus past an unmounted control; a change that "would have closed the last keyboard path into it"; plus `aria-current` and `aria-describedby` usage in its components, and the viewport matrix asserted by a Laravel/Livewire project |

## Security & privacy

| Rule | Derived from |
|---|---|
| S1 No secrets, no real personal data | A Laravel project's `CLAUDE.md` privacy section; its `.githooks/pre-commit` (pattern layer + value layer); its gate script ("it must NOT skip when gitleaks is missing"); another project's `CLAUDE.md`; the fleet's shared memory |
| S2 A guard never prints what it caught | A Laravel project's `.githooks/pre-commit`: "A guard that echoes what it caught has just written the secret to a terminal" |
| S3 Rate limits on auth and expensive endpoints | The security sections of two Symfony projects' `CLAUDE.md` |
| S4 CSP, proved to reach the browser | A Laravel project's `docs/DECISIONS.md`: "`csp.spec.js`'s negative test… proves the detector can fail" |
| S5 Pin what you depend on | A Laravel/Livewire project's `composer.json` (`config.platform.php`) and `CLAUDE.md` (Playwright driver pinned to the image tag — "Playwright refuses a mismatched pair"); `.nvmrc` in three projects; committed lockfiles in every PHP/JS project |
| S6 Production checkouts are not workspaces | A Laravel project's `CLAUDE.md` ("This checkout IS production"); a Laravel/Livewire project's gate ("It refuses to run in the main working tree, which is the live site"); another project's gate script; the fleet's shared memory |

## Workflow

| Rule | Derived from |
|---|---|
| W1 Branch + PR, never straight to main | The fleet's shared memory (git-workflow note) |
| W2 Draft → adversarial review → ready | A Laravel project's `CLAUDE.md`: "the reviewer is never the builder" |
| W3 Only the owner merges | The fleet's shared memory (git-workflow note: "`gh pr merge` belongs to Ghie"); a Laravel project's `CLAUDE.md` |
| W4 The four literal PR headings, ≤150 words | The fleet's shared memory (comment-style note: the template, and "The four headings are LITERAL… not a vibe"); a Laravel project's `CLAUDE.md`, which holds the canonical wording |
| W5 Avoid stacks; retarget before merging | The fleet's shared memory (git-workflow note), recording a PR that merged into an already-merged branch and never shipped |
| W6 Stage by name; detail in the commit | The fleet's shared memory (git-workflow and comment-style notes: "Technical content belongs in commit messages, DECISIONS entries and the diff") |
| W7 `docs/DECISIONS.md` per project | A Laravel project's `docs/DECISIONS.md` preamble; another project's equivalent `docs/rationale-*.md` |
| W8 One deploy runbook per project | The `.claude/commands/deploy.md` runbooks of seven projects; the fleet's shared memory ("follow it literally; it encodes hard-won ordering") |
| W9 Exercise, don't read the config | The fleet's shared memory (two standing instructions: prove a mechanism by running it, and execute rather than narrate) |

---

# Conflicts between projects, and what should win

Nine places where two projects had already decided the same question differently. These
are the most instructive part of the exercise: a fleet standard is mostly a record of
which existing practice won, and why. The projects are private, so each is named by what
it is rather than by what it is called.

**1. How long may a comment be?**
- One Laravel project: *"Inline comments run **at most 2 lines**."*
- Another Laravel project: *"Compact why-comments… each stated once, why-first, **in full prose** — about half the length the repo used to carry."*
- **The 2-line cap wins.** It is the owner's own second-round instruction after "I would like to read the code, but I am bombarded with essay"; "full prose, half the old length" is the earlier, looser wording. The other project's *mechanics* are worth keeping and generalising, not overriding: never touch `@param`/`@return` tags in a comment sweep, and prove a comment-only change with token equality.

**2. What goes in a PR body?**
- One Laravel project: *"PR bodies. ≤150 words. One-line outcome, what to look at first, decisions needing the reviewer's judgement, merge-order note if stacked."*
- Another Laravel project: *"PR descriptions are for the person deciding to merge, not the developer: plain business language, ≤150 words, template **What changed** · **Why** · **What you'll notice** · **How it was checked**…"*
- **The four-heading template wins**, and the headings are literal. The first is a superseded earlier version — and that same project is exactly where the drift recurred across three PRs. Its `CLAUDE.md` should be corrected first.

**3. How strict is static analysis, and are baselines allowed?**
- One Laravel project: *"The phpstan baseline is EMPTY (`ignoreErrors: []`) and stays that way… never regenerate a non-empty baseline to get green."*
- A Laravel/Livewire project: *"PHPStan/**Larastan** (level 5, baselined)"* — *"what it asserts is that the branch added no new findings"*.
- Two other Laravel projects run level 8 with no baseline; the two Symfony projects run Psalm level 4.
- **The empty-baseline rule wins as the principle**, the level stays per-project: run the highest level the project holds with an empty baseline; where a baseline already exists it is a named debt that shrinks and never regrows to make a branch green.

**4. Which code-style configuration?**
- Four Laravel projects ship a byte-identical `pint.json`: laravel preset, `"=>": "align_single_space_minimal"`, `ordered_imports.sort_algorithm: "length"`.
- A fifth diverges: `"align_single_space"`, `sort_algorithm: "alpha"`, `imports_order: [class, function, const]`, plus `simplified_null_return`, `blank_line_before_statement`, `concat_space`.
- A Vue SPA has **no** `pint.json` at all — *"`./vendor/bin/pint` — Laravel Pint (PSR-12)"*.
- **The four-project config wins** (it is already the majority and is what "the fleet rules" means). The diverging project gets one mechanical reformat PR; the SPA gets the file added.

**5. Does merging to `main` deploy?**
- One Laravel project: *"Merging to `main` is deploying: the always-on session's merge-watch runs the README 'Deploy checklist' on every merged PR."*
- A Laravel/Livewire project: *"Merging to `main` is not deploying."*
- **Neither wins — both are true locally.** The standard's fix is to require every project to say which it is, in its header (rule W8). Guessing wrong in either direction is how something ships unreviewed or silently never ships.

**6. Where does work happen?**
- Two projects mandate worktrees. Five others say **nothing at all**, while one of those five in practice uses a separate staging checkout.
- **The worktree/clone rule wins fleet-wide (S6)**, with that staging checkout named in its own file as its equivalent. Silence is the dangerous option: it reads as "branch in the prod checkout".

**7. Are tests expected at all?**
- The game: *"**Tests/lint**: none configured."*
- **T1 wins, with a written exemption rather than silence.** It is a static two-file game; the honest minimum is a formatter wired to a script plus one browser smoke test if it is ever changed again. An exemption that is written down can be revisited; an absence cannot.

**8. Host toolchain or containers?**
- One Laravel project: *"**IMPORTANT:** Always run `nvm use` before any npm/node commands"* — host PHP and host Node.
- Another: *"EVERYTHING RUNS IN THE CONTAINERS, not on the host… a gate that passes against a PHP the production image does not have is worse than no gate"*.
- **Containers win (T2).** The first project keeps `nvm use` as a local convenience note, not as how its gate runs.

**9. How many browser engines?**
- A Laravel/Livewire project drives *"**WebKit and Chromium** through **seven screens at sixteen viewport sizes**"*; two other projects run Chromium only.
- **Chromium is the floor; a second engine where the product is phone-shaped or an installed PWA.** That second pass exists because it is the only thing that can see a phone-layout bug every PHP test missed — that is a reason, not a preference, and it applies more widely.

---

# Proposed new — not yet stated by any source

Five rules that arguably belong, flagged as proposals because no file or note stated them
at the time. They should be argued about before they are adopted.

1. **A dependency-advisory step in the gate (`composer audit`, `npm audit --omit=dev`), failing on High and Critical.** *Rationale:* the gate scans for leaked secrets but nothing notices that a shipped package has a published vulnerability; one project's framework-pinning note shows dependency drift is already a live concern.
2. **An automated accessibility pass (axe-core) in the browser gate, on every screen it already visits.** *Rationale:* T8 is currently enforced entirely by hand-written assertions in one project, so a missing label on a new screen is caught only if someone remembers to look.
3. **Each project's header states three facts: where work happens, whether merging deploys, and what the gate command is.** *Rationale:* it is the smallest fix for conflicts 5 and 6, and it is exactly what a new session or worker reads first before doing something irreversible.
4. **A dependency update cadence — monthly, one PR per project, majors pinned deliberately.** *Rationale:* without a cadence, updates happen only when something breaks, which is when they are least safe; one project already needs explicit major-version pins to stop transitive drift.
5. **Each project names, in one line, the data it holds and where the restore-proven backup is.** *Rationale:* one project states this and no one else does; for an archive meant to last twenty-five years, "is it backed up?" should not require reading a runbook to answer.
