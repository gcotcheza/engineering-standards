# Decisions

Why this repository is shaped the way it is, where the reason is too long for a
comment (C5) and too easy to lose (W7). One entry per decision, newest last; the
code carries a one-line pointer here, never the argument itself.

## The gate refuses a missing shellcheck image rather than skipping the step

A linter that is not installed produces no findings, which reads exactly like a
clean run. The step therefore fails loudly when the pinned image is absent (C9),
and the image is pinned by digest-bearing tag so the same input gives the same
verdict tomorrow (S5).

## `--only N` records nothing to the fleet gate ledger

The ledger answers "did this branch pass its gate?". A single step passing is not
an answer to that question, so a partial run is deliberately invisible to it —
otherwise debugging one step would leave a green mark nobody meant.

## `scripts/lib/deploy/` is read-only to the gate

The deploy library is vendored here and consumed by projects. The gate sources its
ledger helper and runs its tests; it never writes under that directory, so a gate
run can never be what changed the library a project is about to install.

## The gate's step order is a measurement, not a guess (2026-09-19)

T3 asks for the cheapest checks first, and this gate did not obey its own rule:
the slowest step ran third and four cheaper ones followed it. The steps were timed
individually — 0.03s, 0.30s, 0.32s, 1.27s, 1.75s, 2.08s, 4.74s — and renumbered in
that order. Re-measure before reordering again; the numbers move as the tests grow.

## Three rules stopped claiming more than they check (2026-09-19)

An audit of claims nobody had exercised found three of these rules crediting a check
that does not exist or does not reach:

- **C10** credited "static analysis" with finding dead code. PHPStan finds unused
  *private* members only; an unused public method or an orphaned front-end module is
  invisible to it unless a project has wired the extra tooling. Four of the fleet's
  projects could not perform the check the rule claimed. The clause now says review,
  and says what static analysis does and does not see.
- **S6** said every gate "refuses to run in a deployed checkout". Three of five do.
  The other two isolate their writes from it instead, by design, because their gate
  runs in overlay mode. Both are legitimate; the rule now names the two shapes and
  asks each project to say which it is.
- **C7** named a project as the example of a wired boundary tool. This repository is
  public, so the rules carry no project names: the clause now names the tool.

The alternative for C10 — wiring an unused-public extension everywhere — remains open
and is the better fix where a project can afford it. What is not acceptable is a rule
that reads as though the tooling is already there.
