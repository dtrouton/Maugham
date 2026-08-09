# The register

Maugham's behavioural specification, operational. Two layers: **claims** — verified facts about
what the code does, each pinned by a permanently-running test — and **rulings** — Denver's product
decisions about what should be true, each with provenance and a basis. **Reconciliation** holds
them against each other; the mismatches drive fix loops.

Start at `START-HERE.md`. The arc is `PLAN.md`. The rulings are `RULINGS.md` (generated — the
ledger `01-claims-ledger.json` is the source of truth). Claims and verdicts per module are
`reconciliation/<Module>.{claims,filings}.json`; their pins live in `MaughamTests/Claims/` and
`register/ExperimentTests` (CI: `mac-tests` + `behavioural-claims`).

## Steady state — what "healthy" means

- Every writer-facing module claim-covered; every filed violation fixed or explicitly ROI-parked
  (PRINCIPLE-4's distinction, never limbo).
- A red claims pin means PINNED BEHAVIOUR CHANGED: the register moves with the fix (the fix-loop
  lifecycle — `scripts/flip-claim.py`), or the change was wrong.
- Ruling-text amendments trip `scripts/23-generate-rulings.py`'s hash check and print the
  re-check queue; state tables are generated (`scripts/27-generate-state.py`), never hand-kept.
- New features ship WITH claims (specs cite rulings at design time); characterisation is for
  legacy code only.
- Periodic health: claims green in CI, amendment queue empty, and a sampled blind re-filing
  round after any batch of author-flipped verdicts.

## History

The register began as an experiment (2026-08, ~50 phases). The phase reports, surveys, probe
files and frozen decoy snapshots live under `history/` — they are records, not live documents;
two of them are deliberately-preserved DAMAGED extractions kept as evidence. Read
`history/00-module-selection.md` onward only for how this came to be.
