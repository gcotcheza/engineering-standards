# Engineering standards — all projects

`ENGINEERING-STANDARDS.md` is the standard: each rule as the rule, why, and how it is checked.
`SOURCES.md` is the receipt for every rule and the record of the cross-project conflicts and how they were resolved.
`ROLLOUT.md` is how one file reaches every project without becoming nine: vendored `docs/STANDARDS.md` + `.claude/rules/standards.md` symlink + a drift test in each gate, with a box-wide floor underneath.

Changes go the same way as code: branch, PR with the four headings, the owner merges. Bump `VERSION` and `CHANGELOG.md` with every change.
