# Cross-Surface Contracts (phone ↔ Mac)

> You were likely sent here by a failing tripwire test. A tripwire fires when
> surface code reimplements something both surfaces share. Find the contract
> below, call its choke-point (Tier 1) or satisfy its contract type (Tier 2),
> and the tripwire passes. Spec: docs/superpowers/specs/2026-06-03-cross-surface-contracts-design.md

Tiers: **1** shared implementation (one MaughamCore impl; surfaces call it) ·
**2** contracted divergence (shared decision + contract test in both targets) ·
**3** free divergence (recorded as having no cross-surface invariant).

| Contract | Tier | Choke-point / contract type | Test | Tripwire |
|---|---|---|---|---|
| op-log filename ↔ docId | 1 | `OpLogStore.docId(fromOpLogFilename:)` / `docIds(inOpsDirectoryFilenames:)` | `OpLogFilenameTests` (core) + `OpLogFilenameContractTests` (both targets) | `test_noReachAroundOpLogFilenameParsing` (both targets) |
| Fountain bold/italic emphasis | 2 | `ScreenplayEmphasis.contract(for:)` | `ScreenplayEmphasisContractTests` (both targets) | — |

_Remaining contracts are populated by the Task 7 audit._
