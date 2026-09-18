# Changelog

## 2026-09-18 — vendored deploy library (tooling only; the standard is unchanged and VERSION is not bumped)
`scripts/lib/deploy/` — `summary.sh`, `resolve.sh`, `ledger.sh`, `preflight.sh` and its own `VERSION`, the shared half of a deploy script that Fineprint, Reflection and Scribly each needed (C1: the third copy). Moved out of Fineprint's `scripts/deploy.sh` rather than rewritten: same function names, same sentences. Every file carries `# fleet-deploy-lib <VERSION> sha256:<body>` on line 1 and each project's gate recomputes it, which is the same drift mechanism `docs/STANDARDS.md` already uses. `scripts/lib/deploy/test.sh` proves every function, every refusal sentence and every header against fakes; each check was proved red once. README: "Vendored scripts".

## 2026-09-16 — rollout note (docs only; the standard is unchanged and VERSION is not bumped)
ROLLOUT.md step 0 and the floor decision: the machine-wide floor goes in the CLAUDE.md of the directory the non-project sessions start in, not in the user-level rules folder, because a user-level rule loads in every session and doubles the standard in every project that has vendored its copy. Verification is a headless session's transcript, not the symlink's existence.

## 2026-09-04 — published
Published: README, LICENSE, ROLLOUT and SOURCES rewritten for a public reader; the standard itself unchanged.

## 2026-08-23 — fleet-level check (tooling only; the standard is unchanged and VERSION is not bumped)
`scripts/fleet-versions.sh` compares every project's vendored `docs/STANDARDS.md` against the canonical clone — the one comparison no project gate can make, since each project's drift test only checks its copy against its own header. Reports ok / MISSING / UNREADABLE / BADHEADER / DRIFTED / DIVERGED / STALE / VERSION / NOLINK / BADLINK; a project with no vendored copy, or a run that checks zero projects, is a failure rather than a pass. Prints the canonical HEAD it measured against. ROLLOUT.md step 5.

## 2026-08-23 — first adopted version
36 rules in four groups (Code C1–C13, Tests T1–T8, Security & privacy S1–S6, Workflow W1–W9), derived from what the nine projects already practised; nine cross-project conflicts resolved (SOURCES.md); proposals P1 (dependency audit in the gate) and P3 (three facts in every project header) adopted, P2 deferred to the next browser-gate touch per project, P4/P5 kept as notes. Rollout one project at a time; see ROLLOUT.md for the mechanism. Adopted by Ghie.
