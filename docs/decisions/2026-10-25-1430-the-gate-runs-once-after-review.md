# The full gate runs once per pull request, on the final commit, after the adversarial review

**What went wrong.** W2 put the gate before the adversarial review. Every finding the reviewer
returned meant a fix commit and another full gate run, and on 2026-10-25 the VPS gate queue held
runs for 20 to 55 minutes. With two review rounds, a pull request would wait in that queue three
times for the one result that counted.

**The rule (Ghie, 2026-10-25).** Self-review, then the adversarial review, then the full gate once
on the final commit; only a green row on that head lets the pull request go ready. While building
and fixing findings, the builder runs narrow checks (the changed file's own suite, a lint, a probe)
and quotes their output, so the reviewer judges evidence, not a claim. The gate reruns only if it
fails on that commit; any commit after it is a new final commit, which needs its own gate run.

**What stays.** T1's scope: a docs-only change needs no test run, so it has no gate step; a
script-only change runs its own small suite. The reviewer is still never the builder.

**The option not taken.** Gating every fix commit "to be safe". The reviewer reads the diff either
way, and only the final commit can merge, so earlier gate runs prove nothing that ships.
