# Engineering standards — all projects

One set of rules for every project on this box. Nothing here is new: each rule is
something we already do somewhere and want everywhere. A project may be *stricter*;
it may not be looser without saying so in its own file and saying why.

Read each rule as three things: **the rule**, *why it exists*, and **how it is
checked** — because a rule nothing checks is a preference, and preferences drift.

---

## Code

**C1. Extract on the third copy, not the second.** Two similar blocks are often a coincidence; by the third the copies have already started to disagree with each other. — *checked by:* review; the extracted piece gets its own test.

**C2. Do not merge things that only look alike.** Shared code is right when two callers mean the same thing, and wrong when they merely resemble each other — a menu is not a dialog, and one file's repetition can be the thing that makes it work. — *checked by:* review; where the repetition is deliberate, a test that fails if someone "tidies" it away.

**C3. Say it in the name, not in a comment.** A comment that restates the code rots, bloats the diff and buries the two comments that actually matter. — *checked by:* review, against the survival test: *what would someone break if this line were deleted?* Nothing → delete it and improve the name.

**C4. A surviving comment is at most 2 lines.** State the constraint, not the argument for it; most files should carry none at all. — *checked by:* review; a file with more than five comment blocks is suspect by default.

**C5. A rationale that needs a paragraph is documentation.** It goes in `docs/DECISIONS.md` with at most a one-line pointer in the code, so the code stays readable and the reasoning stays findable. — *checked by:* review.

**C6. One unit, one job.** Small pieces can be tested without booting the world, and a function that does two things has to be read twice to change one of them. — *checked by:* review; pure logic must be testable without mounting a screen or booting a container.

**C7. Where a project has layers, they only point inward.** The business rules must not depend on the framework, the database or the screen, or they cannot be tested or replaced. — *checked by:* Deptrac (memento), or review where no tool is wired.

**C8. Validation lives at the edge, the rule lives in the domain.** The edge rejects malformed input in one place; the domain refuses invalid states however it was reached — including data read back off disk. — *checked by:* form-request/validator classes at the boundary, plus a test that exercises the domain rule directly.

**C9. Failures are loud by default.** A silently swallowed error becomes wrong data that nobody notices for months. — *checked by:* review; if a failure genuinely must be swallowed (a search index being down must not fail someone's save), it needs a `DECISIONS` entry and a named repair command.

**C10. No dead code.** Unused code is read as if it were live and copied as if it were right. — *checked by:* static analysis + review — and before deleting, check which half is actually dead: the caller can be the mistake.

**C11. Colours, radii, shadows and spacing are decided in one file.** A value written out 23 times in 17 components cannot be changed and cannot be themed. — *checked by:* the project's tokens file (`tokens.css` / `_variables.scss` / `pixel-kit.css`) plus a test asserting the code and the stylesheet still agree.

**C12. Every form field validates inline in the browser — the same rules and the same sentences as the server, which still validates everything.** A person should learn a field is wrong when they leave it, not after a round trip; and two sets of rules drift unless a test holds them together. — *checked by:* one rules module per app that the browser reads; the server's request/validator classes emit the same sentences; a test reads both and fails the gate if they differ. Validate on blur, re-validate on input once touched; on submit show every message and move focus to the first invalid field; the submit button stays enabled, because a disabled button hides *why*.

**C13. Never the browser's native validation UI.** The default bubbles are unstyled, differ by browser, vanish on the next click and are invisible to some assistive tech — and they are not the app's voice. — *checked by:* every `<form>` carries `novalidate`; nothing is enforced through `required`/`pattern`/`type="date"`, `maxlength` truncation or `:invalid` styling; a browser test proves an empty submit shows the app's own sentence and nothing native fires.

---

## Tests

**T1. The gate is green before merge. No exceptions for "just a docs change".** The gate is the only claim about the branch that nobody has to take on trust. — *checked by:* `scripts/check.sh` / `scripts/ci.sh` — style, static analysis, architecture boundaries, front-end lint, unit tests, the suite, and the secrets scan.

**T2. The gate runs in the containers, not on the host.** Green against a PHP or Node the production image does not have is worse than no gate, because it is believed. — *checked by:* every gate step runs through `docker compose exec`/`run`.

**T3. Cheapest checks first.** A four-second style failure should not be discovered after a ninety-second analysis run. — *checked by:* the order inside the gate script.

**T4. Every bug fix carries a test that would have caught it.** Otherwise the same bug returns, and the fix has no way to defend itself against the next refactor. — *checked by:* review of the PR's diff — a fix without a test needs a stated reason.

**T5. A test must be proven able to fail.** A test that cannot go red is not evidence; we have shipped assertions that were watching an empty array. — *checked by:* break the thing on purpose once, see the test go red, then put it back — and say so in the PR's "How it was checked".

**T6. Browser tests live in the repo and run against a throwaway stack.** Unit tests have never seen a screen: a phone layout can be broken for weeks with every PHP test green. — *checked by:* `e2e/` in-repo (Playwright), a seeded disposable stack, never live or production data.

**T7. The browser gate runs inside its caps: workers ≤ 2, `--disable-dev-shm-usage`, and a ≤ 2 GB memory limit on the container the browsers actually run in.** An uncapped browser swarm was this box's single largest cause of out-of-memory kills. — *checked by:* `playwright.config.js` (workers), the launch args, and the `--memory` flag on the right container — find it, don't assume it.

**T8. Accessibility baseline, on every screen we ship.** Keyboard-only and screen-reader users are not an edge case, and these five are cheap to keep and expensive to retrofit. — *checked by:* browser-gate assertions and review:
  - real `<button>` and `<a>` elements, never a `<div>` with a click handler;
  - every interactive control reachable and operable by keyboard, focus visible;
  - dialogs trap focus and hand it back to the control that opened them;
  - `aria-current` on the item that is current, `aria-describedby` where a field carries help or an error;
  - touch targets at least 44px, even when the visible pill is smaller.

---

## Security & privacy

**S1. No secrets and no real personal data in a repository, ever — including in history.** Names, birthdates, health readings and keys are not recoverable once pushed. Real values live in `.env` and the database; repositories get fixtures. — *checked by:* the pre-commit hook (pattern layer + this repo's own `.env` values as fixed strings) and the gate's secrets step, which never skips itself.

**S2. A guard never prints what it caught.** A hook that echoes the secret has just written it to a terminal, a scrollback and possibly a log. — *checked by:* the hook reports the *key* that matched and stops.

**S3. Authentication and expensive endpoints are rate-limited.** Login, password reset, upload and AI calls are where a stranger's costs land on us. — *checked by:* the framework's rate limiter, configured, plus a test.

**S4. A Content-Security-Policy is served, and proved to reach the browser under test.** "No violations" and "no policy" look identical from the outside. — *checked by:* the policy on the app's own nginx (not only the host vhost) and a negative browser test: a deliberate inline script, asserted to be *caught*.

**S5. Pin what you depend on.** Reproducible installs are what make a gate's result mean anything tomorrow. — *checked by:* committed lockfiles, a platform pin (`config.platform.php`), `.nvmrc`, and a Playwright driver version matching its image tag.

**S6. Production checkouts are not workspaces.** Several of these trees are bind-mounted into running containers: editing, branching or building there changes the live site instantly. — *checked by:* work in a git worktree or a private clone; the gate scripts refuse to run in a deployed checkout, and that refusal is never worked around.

---

## Workflow

**W1. Branch and open a pull request; never commit to `main`.** The PR is the only place the change can be seen before it is live. — *checked by:* review; `main` is a convention here, not a protected branch.

**W2. A PR opens as a draft, gets an adversarial review by someone who did not build it, then goes ready.** The builder is the worst reader of their own diff. — *checked by:* `gh pr create --draft` → review → `gh pr ready`.

**W3. Only Ghie merges.** The merge is the moment a change reaches real users, and it triggers the deploy — so it belongs to the person who reviewed it. — *checked by:* nobody else runs `gh pr merge`; a stated intent is not consent.

**W4. PR bodies use these four headings, literally, in ≤150 words of plain language.** The body is for the person deciding to merge, not for the developer who wrote it. — *checked by:* the reviewer, before the PR goes ready:
  `## What changed` (plain, no file names) · `## Why` (the problem in user terms) · `## What you'll notice` (or "nothing in the app") · `## How it was checked`
  and one closing line: *Technical detail: commits and docs/DECISIONS.md.*

**W5. Avoid stacked PRs; if you stack, retarget the child to `main` before merging it.** GitHub retargets a stacked PR only when the base *branch is deleted* — a child merged after its base has silently merged into a dead branch and never shipped. — *checked by:* after any merge batch, prove each merge commit is an ancestor of `main` before deploying.

**W6. Stage files by name — never `git add -A` — and put the technical detail in the commit.** Blanket staging has swept cache junk into commits; the PR body is deliberately non-technical, so the commits and `DECISIONS.md` are where the detail belongs. — *checked by:* review of the diff.

**W7. Every project keeps `docs/DECISIONS.md`.** It is where the *why* goes when it is too long for a comment, and it is what stops the next person re-deriving a decision or "simplifying" a landmine. — *checked by:* review — a PR that removes a non-obvious option should add the entry that says why.

**W8. Every project has one deploy runbook, followed literally.** Deploys fail on ordering, ownership and restarts — things nobody remembers correctly under pressure. — *checked by:* `.claude/commands/deploy.md` in the repo; each project's runbook states whether merging to `main` deploys automatically or not.

**W9. Prove a mechanism by running it, never by reading its configuration.** Comments and config say what someone once believed; only the running thing says what is true. — *checked by:* run the command and quote its output — in the PR, in the report, in the answer to "is it working?".
