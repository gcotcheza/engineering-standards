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
nine project names — all overridable by environment variable.

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
