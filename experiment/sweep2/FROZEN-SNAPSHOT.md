# `sweep2/RULINGS.md` is a FROZEN SNAPSHOT — do not read it as the ruling set

The `RULINGS.md` in this directory is the copy handed to the sweep-2 subagents on 2026-08-02. It is
kept **byte-identical to what they saw**, deliberately, because it is the evidence for a finding.

**The current ruling set is `experiment/RULINGS.md`** (generated from the ledger). Always read that
one.

## Why this copy is kept

This snapshot was produced by an extraction step that emitted only `family` / `statement` / `basis`
for the three ROOT rulings, silently dropping four other clauses. The most consequential drop was
RULING-19's `corollary RULED` — *"a repair firing at a lower layer means a guard above did not fire —
that is a BUG"* — a clause that **reverses** the ruling: without it R19 licenses a silent lower-layer
repair; with it a repair is a defect signal.

`Rewind.json`'s REW-D11 convicts under RULING-19 while quoting that corollary. Reading it against the
damaged file, the clause appears to be invented. It was not — the subagent had it, and the file
handed to the *next* reader did not. Phase 24 confirmed the conviction was correct and that the
clause is now restored (`RULINGS.md:35`).

Deleting this file would destroy the only record of what the sweep actually read.

## What this means for the findings in this directory

Every `product_decisions[].ruling` in `Annotations.json`, `DocumentTools.json`, `Promotion.json`,
`Rewind.json`, `Trash.json` and `WikiLink.json` was filed against this damaged set. Two consequences:

- A finding filed as `SETTLED_BY_ROOT_ONLY` may reach a **sub-ruling** under the repaired set. Two
  have already been re-filed this way (trash D4 → RULING-22; rewind D11 → RULING-22).
- These are **decision surveys, not claims.** Nothing here is pinned by a test. Treat every entry as
  a lead to verify, never as a fact. Phase 24 falsified one outright (REW-D9).

See `experiment/START-HERE.md`.
