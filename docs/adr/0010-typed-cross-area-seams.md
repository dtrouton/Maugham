# 0010 — Type-driven cross-area contracts

**Status:** Accepted
**Date:** 2026-05-20

## Context

Maugham has several long-lived cross-area boundaries — Editor ↔ Document, DocumentStore ↔ OpLog, MCP ↔ OpLog, app-wiring ↔ MCP catalog — that historically carried their contracts implicitly. Three patterns recurred:

1. **String-prefix cascades.** `DocumentStore.presenterDidChangeSubitem` dispatched on `relativePath.hasPrefix(".maugham/ops/")` etc. Adding a new sidecar owner meant editing a free-text if-else with no compile-time guidance about who else might handle the same paths.

2. **Untyped state shared across phases.** `Document.lastWrittenText: String` joined the autosave path with the echo guard in `handleExternalDiskChange`. Any code that wanted to "remember some recent text" could clobber it; the contract that "only the file-write paths assign this" was convention only.

3. **Bool flags whose proof was elsewhere.** `Document._pendingOrphanSweep: Bool` was set in four code sites, each of which had separately computed "did a paragraph disappear?" The flag carried the answer but not the proof. A transient `Document` close-via-MCP could flip the flag against a sequence reconstructed from disk that legitimately differed from the live editor's in-memory state, then archive open annotations that hadn't actually been deleted.

The pattern that worked — `MCPToolCatalog.all` + `MCPCatalogConsistencyTests` — proved a contract holds across two consumers (`MCPToolsListHandler` and `MaughamApp.registerTools`) via a typed single source of truth plus a cross-area test owned by neither side. We want that pattern as the default at every cross-area seam.

## Decision

When a cross-area contract is identified, prefer in this order:

1. **A typed value at the boundary.** Replace stringly-typed dispatch with a `switch` over an enum whose cases the compiler walks. Replace bool flags carrying implicit proof with structs/enums that carry the proof as associated data. Replace shared mutable strings with structs constructible only via named factories.

2. **Single source of truth.** When two code sites must agree on a list (tool catalog, sidecar owner map), one is the source and the others derive — never two parallel lists.

3. **An integration test owned by neither side.** A test under `MaughamTests/Integration/` (or a peer location distinct from the per-area `MaughamTests/<Area>/`) that asserts the contract holds end-to-end. The test exists to catch silent drift — type-system guarantees catch *most* drift, but tests catch the rest (e.g., echo guards that depend on event ordering, not type compatibility).

This ADR records the pattern; it doesn't mandate retroactive rewrites. New seams should follow it; existing seams get rewritten opportunistically when the surrounding code is being touched anyway.

## Instances at time of writing

| Seam | Type | Source of truth | Integration test |
|---|---|---|---|
| App-wiring ↔ MCP catalog | `MCPTool` protocol + `MCPToolCatalog.all` | `MCPToolCatalog.all` | `MCPCatalogConsistencyTests` |
| `Document.load` ↔ all manuscript-load entry points | Implicit (only one entry point exists) | `Document.load` | `BootstrapWiringTests` |
| `DocumentStore.presenter` ↔ `Document` routing | `MaughamSidecarPath` enum | `MaughamSidecarPath.classify` | `PresenterRoutingTests.test_sidecarPathParser_roundTripsAllCanonicalSubdirs` |
| `Document.lastDiskEcho` ↔ echo guard | `EchoState` struct + three named factories | `EchoState` initializers | `PresenterRoutingTests.test_ourAutosave_doesNotReingestAsExternalEdit` and `..._resolveKeepMine...` |
| Orphan-sweep trigger ↔ sweep execution | `SweepReason` enum carrying the removed-paragraph set | `SweepReason.userTyped` / `.externalLog` / `.useCloud` factories | `PresenterRoutingTests.test_mcpAddAnnotationLive_doesNotTriggerOrphanArchive` |
| Rewind scrub state ↔ Deriver | `RewindCursor` enum | `RewindCursor.atOp` factory | `DeriverUpToTests` |
| Rewind modal ↔ ProjectWindow action dispatch | `RewindAction` enum | `RewindWindow.onComplete` callsite | `RewindEntryPointsTests` |
| Rewind scope today vs. v2 | `RewindScope` enum (single-case) | `RewindWindow` initializer | (compile-error workflow; no test needed for single case) |
| Op synthesisSource cause | `SynthesisSource` enum | `Op.Provenance.synthesisSource` field | `SynthesisSourceMigrationTests` + `RewindForensicProvenanceTests` |

## Consequences

- **Adding a new sidecar owner is a compile-error workflow.** `MaughamSidecarPath` has eleven cases today; a twelfth requires adding the case AND handling it in every consumer the compiler points at. Drift is no longer silent.
- **Writer surfaces for boundary state are auditable.** `EchoState` can only be constructed by three factories, all in `Maugham/OpLog/`. Any future code that tries to "remember some recent text" against the echo field is a compile error rather than a subtle bug.
- **Sweep is conservative by construction.** The new sweep archives only annotations on paragraphs in `SweepReason.removed` — a set the caller has to compute and pass in. The "anything missing from sequence" behavior is now structurally inexpressible.
- **The `MaughamTests/Integration/` subdirectory becomes a destination.** Cross-area regressions land there, not in the per-area test folders. The existing per-area suites stay focused on unit-level behavior; integration is its own concern.
- **AREA.md tripwires that named removed types stay as historical hints.** When a tripwire says "this field is overloaded" and the field has been replaced, the AREA file should be updated to point at the replacement, not deleted — future agents may search for the old name.

## References

- `Maugham/MCP/MCPTool.swift` — the original "single source of truth" pattern.
- `MaughamTests/MCP/MCPCatalogConsistencyTests.swift` — the test that proved the pattern works.
- `Maugham/Stores/MaughamSidecarPath.swift` — the typed sidecar-path dispatch.
- `Maugham/OpLog/EchoState.swift` — the typed echo-guard state.
- `Maugham/OpLog/SweepReason.swift` — the typed sweep trigger.
- `MaughamTests/Integration/PresenterRoutingTests.swift` — integration coverage for the routing seam.
