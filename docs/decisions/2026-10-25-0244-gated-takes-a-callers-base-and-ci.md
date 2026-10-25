# gated takes a caller's base, ci evidence and refusal route

**Card 684.** Ghie decided on 2026-10-24 that deploy-on-merge requires the browser tests: a head
deploys from main only when every row its test scope owes is green, the same rule a hand deploy
follows. Ghie Writes' `--from-main` judge read ci alone and recorded "e2e not read". Card 614 will
roll deploy-on-merge out to every app, so the rule stays in one place, `gated()`, and the judge
calls it instead of keeping its own copy.

The rule is the same; only what the judge reads from differs. So `gated()` gains three optional
inputs, each unset by every existing caller, which keeps today's behaviour and today's sentences:

- `GATE_BASE`: the live commit the test scope is read against. `test_scope_of` otherwise takes the
  checkout's HEAD. A deploy-on-merge judge reads from root's mirror, and a bare mirror's HEAD is the
  merge itself, which would make every diff empty and every scope UI. The caller passes its own
  record, which it has already proved is the live commit. `test_scope_of` still checks it: a base
  that is not a full 40-hex sha, not an ancestor of the commit, or the commit itself reads every
  path as UI, because a base the caller got wrong must never make a diff look docs-only.
- `GATE_CI_BY`: the caller's own ci evidence for the commit, such as Ghie Writes' GitHub Actions ci
  for the exact head. It fills only an absent ci row, never a red one, matching the rule that red
  wins. It never stands in for e2e: GitHub e2e evidence keeps its own root-owned route
  (`github_e2e`). The label is printed in the verdict and in GATED, so DONE says what was read.
  `GATE_CI_BY` is the caller's route, not the lib's: Ghie Writes' `--from-main` judge already read
  GitHub ci before card 684, and the lib only carries that evidence through, so card 352's rule
  that the lib's own GitHub route stands in for e2e "never for ci" still holds.
- `GATE_ROUTE`: the second half of the not-green refusal. The default names `--gated-by-hand`,
  which a deploy-on-merge judge cannot take, so that judge says what to do instead.

**The limit.** The no-ledger refusal still comes first whenever a row is owed. A judge whose ci
came from GitHub and whose e2e would come from GitHub refuses when the box has no ledger file at
all; every deploying box has one.
