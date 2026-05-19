# State of the Code — 2026-05-19

Author: Claude (synthesised from session-derived knowledge of recent editor + OpLog work plus targeted surveys of ProjectStore, DocumentStore, MCP layer, and the test directory). Not a refactoring plan — observations.

## Headline finding

**`Bootstrap.run` is never called from production code.** It's the migration pass that mints inline `¶id` HTML-comment anchors for legacy manuscripts on first open. It's defined, fully tested in `BootstrapTests`, and referenced in the spec. But `grep -rn "Bootstrap.run" Maugham/` returns *zero* call sites — only the test file. Consequence: existing manuscript files have no inline IDs. Every keystroke runs `RenderFilter.restoreComments(stored, displayEdited)`; with no IDs in the prior stored form, every paragraph falls all the way through to "mint fresh ID" on every keystroke. The whole "stable paragraph identity" infrastructure that the op-log foundation is built around isn't actually doing its job for any document opened today.

This is the largest single issue in the audit. It also explains why nothing surfaces in tests — the `EndToEndIntegrationTests` constructs ops directly without going through the production load path.

Severity: **real problem.** Fix is small (one call site in `EditorHost.loadDocumentIfNeeded` or `DocumentStore.openDocument`); the test gap that hid it is the bigger lesson.

---

## Editor layer

### `EditorHost.swift` — 235 lines, *just refactored*
Current shape (`$documentText` binding + `.onChange(of: documentText)`) is correct. The race that drove the refactor is gone.

- `.onChange(of: documentText)` and `.onChange(of: documentStore.lastWrittenText)` now both fire in response to editing; their interaction depends on `priorStoredMarkdown` as the disambiguation key. Two `@State` fields (`documentText`, `priorStoredMarkdown`) co-evolve. Document the invariant explicitly somewhere — easy to break next time someone adds a third onChange.
- Guard "newStored != priorStoredMarkdown" in the documentText onChange is doing real work — suppresses load echoes, parser-trim no-ops, etc. Worth a focused comment that says *which* paths it gates.
- The session-id `static let` is per-app-launch, fine. Device-id from `hostName` is workable for solo-multi-Mac; flagged in the spec.

### `EditorSurface.swift` — 277 lines
NSViewRepresentable that does a lot in `updateNSView`: text-mismatch check (→ applyExternalText), theme/typography reconciliation, typewriter scroll toggle, focus prefs sync, gutter install/remove, imagePasteHandler reset. Each branch is reasonable; the function has accreted a lot.

- The `applyExternalText` path is the bug-prone seam. With the EditorHost refactor it should only fire on genuine external content (Use-cloud resolution, conflict resolution). Untested at integration level. A regression test that asserts "during normal typing, applyExternalText must not fire" would have caught all three bugs we just shipped.

### `EditorCoordinator.swift` — 770 lines
The central nervous system. Reasonable as the NSTextViewDelegate but it's doing **a lot**:
1. Token + style application (`retokenizeAndStyle`, ~30 lines)
2. Cursor management (sync restore in `textDidChange`)
3. Tab/Shift-Tab cycle through screenplay elements (`cycle(in:direction:)` — ~200 lines of mutation logic with its own async cursor restore)
4. Smart typography substitution (em-dash, ellipsis) in `shouldChangeTextIn`
5. Find-match navigation, scene navigation, appearance-change observers
6. Focus dim
7. Image paste handler routing
8. Wiki-link hit-testing (delegated to `MaughamTextView.mouseDown`)
9. Holds a `CharacterAutocompleter` that's never shown — see below

A natural extraction: pull the Tab cycle into a `ScreenplayCycleController` and the styling pass into a `StylingPipeline`. The coordinator becomes thinner, the cycle path is independently testable. Not urgent — the file is large but each section is comprehensible.

**`CharacterAutocompleter` is dead code.** `updateAutocomplete` exists at line 565+ but isn't called from anywhere in `EditorCoordinator.swift` or elsewhere. The popover never displays. Memory note: "character autocomplete deferred (option-A fallback, NSPopover too brittle)" — confirmed never shipped. Either revive (per the writing-companion spec) or delete the file. Currently it's costing us ~190 lines, a property on the coordinator, and a dependency in tests (`CharacterAutocompleterDataTests`).

`applyFocusDim` is called from THREE places: inside `retokenizeAndStyle`, at end of `textDidChange`, and inside `textViewDidChangeSelection`. Redundant in the typing case; intentional in the cursor-move case. Trim or document.

### `RenderFilter.swift` — three-tier ID matching
Tiers: exact text → 4-word Jaccard shingle → 2-character bigram (`≥0.6`). The third tier lives in `RenderFilter` itself, not in `ShingleMatcher` (where the analogous Jaccard lives), because it was added as a late fix during T16 implementation. Cleanup: either move char-bigrams into ShingleMatcher as a sibling function, or rename the type to reflect that it's a similarity utility shared across two consumers (RenderFilter + Reconciler). Today it reads as "the matcher lives over there, but actually most of the work happens here too."

### `ProseMode.swift` / `ScreenplayMode.swift` / `WritingMode.swift`
Mode polymorphism is the right shape. ScreenplayMode's `applyTypography` is heavy (full-storage `setAttributes` + four passes) — that heaviness contributed to the race window where the recent bugs surfaced. Not buggy in itself; flagged because incremental tokenization would significantly reduce typing cost on large screenplays. Future optimization, not today's problem.

### `OpLog/` (16 files)
The cleanest part of the codebase. Each module has one clear responsibility, all are heavily tested. Some specific notes:

- **`OpLogStore` and `CheckpointStore` are siblings with ~95% duplicated structure**: NSFileCoordinator-coordinated JSONL append + load, with custom ISO8601 fractional-seconds Date coding via `nonisolated` strategy constants. A shared `JSONLAppendStore<T: Codable>` would compact ~120 lines. Not urgent — duplication is small and each is self-contained.
- **`Bootstrap.swift`** — see headline finding. Code is fine; calling site is missing.
- **`ShingleMatcher.swift`** function is now correctly named `overlapCoefficient` after the T25 rename. The char-bigram tier that should be its sibling lives in RenderFilter instead.
- **`Reconciler.swift`** has only 3 unit tests against pure inputs. No integration test for "an external tool edits the .md, presenter fires, Reconciler classifies, response is applied" — the path described in spec §3.2 is unverified end-to-end.
- **`PendingBufferTests` uses 1-char paragraph IDs ("a", "b") that wouldn't parse via `ParagraphID.parseComment`** (which requires exactly 4 chars). The tests pass because PendingBuffer doesn't validate IDs — but if PendingBuffer ever did, the tests would silently break. Test fixture hygiene issue.

---

## Stores layer

### `DocumentStore.swift` — 587 lines
Has accreted concerns: autosave (milestone 1e), conflict detection (1e), session tracking (2c), UI state (1d), cursor positions (1e), rename execution (2a), manifest IO (1d), op-log context (recent T17).

Each is reasonable in isolation. The op-log additions (`beginOpLogContext`, `recordParagraphChange`, `flushBurstNow`, `persistPendingBufferToDisk`) are bolted on at the bottom as a `MARK: - Op log integration` block. The `currentDocumentText` field is now used by both conflict detection AND op-log context, and its semantic (stored-form vs display-form) was a bug-bearing decision the agents wrestled with during T18.

Natural split point: factor the op-log context (struct + 5 methods) into a `DocumentOpLogContext` actor or extension that DocumentStore composes. Keeps the milestone-1e conflict / autosave code stable and untangles the integration. Not urgent.

The `wait*` helpers (`waitForConflictState`, `waitForLastWrittenText`) are test-only polling utilities living in production code. Should move to a test extension.

### `ProjectStore.swift` — 2760 lines
The largest file in the codebase. Clear natural seams:
- StructureItem CRUD (add/move/rename/duplicate/delete, ~750 lines, lines 174–913)
- Trash (lines 967–1010)
- Inspector mutation + search/replace (~150 lines, 1013–1130)
- Project metadata (targets, typography, gutter, save) (~120 lines)
- Research CRUD (~770 lines, 1185–1980)
- Collection-Pieces (~700 lines, 1995–2650) — this is the most recent addition and is in its own `MARK:` section + extension
- WikiLinkProject conformance (~30 lines)
- Reference resolution (~70 lines)

The file already uses `extension ProjectStore` to keep Collection-Pieces visually separate. Same pattern could apply to Research and Search/Replace and Trash. Splitting into multiple files (each its own extension in its own file) would cost zero behavior change and make each chunk independently readable.

The class itself doesn't suffer from the size — Swift type-checking and IDE navigation handle it fine. The cost is mental: when you fix a bug in research-import logic you have to scroll past Collection-Pieces. A pure file-level split with no logic changes is high-leverage, low-risk.

### Smaller stores
`DebounceScheduler`, `RecentsStore`, `SessionLog`, `SessionTracker`, `TrashStore`, `UIState`, `WikiLinkRewriter`, `ProjectFolderPresenter`, `ProjectFactory`, `ProjectSearchEngine`, `RenamePlan`, `LineDiff`, `ResearchKindInference`, `ConflictState`, `WikiLinkProject` — all small, focused, single-purpose. This is the model. The big files should aspire to be as tidy.

### Concurrency / NSFileCoordinator usage
Multiple stores use NSFileCoordinator: DocumentStore (manifest, document, sessions, conflict backup), OpLogStore (op log JSONL), CheckpointStore (checkpoints JSONL), TrashStore (per-entry move). The pattern is mostly consistent: create coordinator with presenter, capture writeErr, throw on failure. A small `CoordinatedFileWriter` helper that wraps the common shape would compact ~6 sites. Not high priority — the duplication is short.

Strict-concurrency warnings: just cleaned up a batch this morning. Likely more lurking when the language mode flips to Swift 6. A targeted sweep with `SWIFT_STRICT_CONCURRENCY=complete` build setting would surface them; manageable to fix incrementally.

---

## MCP layer

Generally clean.

- **`MCPServer.swift`** (227 lines) — accept loop is well-structured, uses `withCheckedContinuation` to wrap blocking syscalls, SIGPIPE handling is idempotent. The `dispatch` function correctly drops id-less notifications per JSON-RPC spec.
- **`MCPRouter.swift`** (28 lines) — minimal, correct.
- **14 tools registered** in `MaughamApp.swift:225-280`, matching 14 schemas in `MCPToolsListHandler.swift:23-65`. No drift.
- **`maugham-mcp/JSONRPCBridge.swift`** (244 lines) — the stdio↔socket bridge binary. This is where the deferred "first call after restart" bug lives. The retry logic has accumulated layers from multiple fix attempts (`b108e4e`, `1acb005`, `7d4e401`). Currently: single-threaded line loop, exponential reconnect backoff, isNotification handling, polled reconnect on hadPriorConnection. Code is sound for the parts that fired correctly; the residual flake suggests a path nobody traced fully. Worth a structured re-read with stderr logging on the next pass.

Test coverage for MCP is solid at the unit level (router, handlers, tools all have tests) and reasonable at integration level (`MCPBinaryIntegrationTests` exercises the binary with bogus sockets). Missing: a test for restart-window race (start MCP server, kill it, restart, send request through binary; assert response).

---

## Views (non-editor)

Most non-editor views are reasonable in size and scope:
- `ProjectWindow.swift` — large but composed of many small functions; uses extracted `ViewModifier`s to dodge Swift's type-checker (`SessionAndNavigationModifier`, `CollectionPieceModifier`, `CheckpointModifier`). The need for these is itself a quality signal — bodies are too long, but the extractions handle it cleanly.
- `CollectionResearchPane.swift`, `CollectionPiecesPane.swift` — the recent Collection milestone work. Clean.
- `CheckpointBrowserPane.swift`, `PartialRestorePicker.swift`, `CheckpointLabelPromptSheet.swift`, `BootstrapNoticeSheet.swift` — small, well-bounded.

The pattern of "extract ViewModifier to appease the type-checker" is established and works. The compiler frustration is real but localized.

---

## Tests

**706 tests, well-organized.** Subdirectories: `Collection/`, `MCP/`, `OpLog/`, `Fountain/`, `Fixtures/`. Per-module tests are thorough at the unit level.

The gap is **integration-level coverage of the editor**. Only two files exercise editor wiring: `EditorCoordinatorCycleTests` (Tab/Shift-Tab) and `DocumentStoreSaveTests` (autosave round-trip). Nothing tests:
- The `textDidChange` → binding setter / onChange → `updateNSView` flow
- Rapid typing (the bug we just fixed wasn't reproducible from any test in the suite)
- End-of-file typing
- External edit ingestion through the Reconciler classification path
- The op-log ↔ editor render-filter round-trip under load
- BurstScheduler timing under real keyboard input

A `MaughamTests/Editor/` subdirectory with a handful of "drive an NSTextView, assert end state" tests would catch a class of bugs the unit suite can't see.

**Test fixture inconsistencies:**
- `PendingBufferTests` uses 1-char paragraph IDs (won't parse via ParagraphID).
- Earlier audits during the milestone caught 1-char IDs in T16 RenderFilter tests and T14 Reconciler tests — were fixed locally. The pattern recurs.
- A test-only helper `func makeValidID() -> String` would prevent this.

**Probabilistic test:** `ParagraphIDTests.test_mint_isUniqueAcrossManyCalls` was relaxed in T25 (threshold 4970 from 4990) because the test was hitting birthday-collision math. Documented; fine.

---

## Project infrastructure

- **`xcodegen` flow**: `project.yml` is the source of truth, `gen.sh` regenerates `Maugham.xcodeproj`. Several subagent commits over the past few days included `Maugham.xcodeproj/project.pbxproj` edits because the agent thought files needed adding to the project. They don't — xcodegen picks up files in `path: Maugham`. The pbxproj edits are harmless (next `gen.sh` overwrites them) but they're noise. Documenting "don't commit pbxproj" in `CLAUDE.md` or `gen.sh`'s output would help.
- **`.gitignore`** apparently *doesn't* gitignore `Maugham.xcodeproj/`. Inconsistent commits across this session — some included pbxproj, some didn't. Worth deciding: either gitignore the entire `.xcodeproj` (xcodegen recreates it) or commit it and stop the churn.

---

## Top findings, ranked

| # | Finding | Severity | Effort | Notes |
|---|---|---|---|---|
| 1 | `Bootstrap.run` never called from production | **real problem** | 1 commit | The op-log's stable-ID story isn't running for any real document. Headline of the audit. |
| 2 | No editor integration tests | **real problem** | 1 milestone | All three recent races (cursor jump, async restore, binding loop) lived in unt­ested wiring. Worth a dedicated harness milestone. |
| 3 | `Reconciler` path untested end-to-end | worth a look | 1 task | External-edit ingestion is spec'd but no test asserts presenter → Reconciler → ingest works. |
| 4 | `CharacterAutocompleter` is dead code | worth a look | 1 commit | ~190 lines, an unused property, and a test file. Delete or revive. |
| 5 | RenderFilter char-bigram tier in wrong file | imperfect-but-fine | 1 commit | Move to ShingleMatcher or rename. Naming, not correctness. |
| 6 | ProjectStore.swift at 2760 lines | imperfect-but-fine | 1 PR | Split into 4–5 files by concern (Structure / Research / Collection / Trash / Search). Pure file move, no behavior change. |
| 7 | DocumentStore op-log context bolted on | imperfect-but-fine | 1 PR | Factor into `DocumentOpLogContext` extension. Reduces 1e ↔ T17 entanglement. |
| 8 | Bridge restart race deferred | known deferred | unknown | First MCP call after restart still flaky. Needs stderr logging to diagnose. |
| 9 | OpLogStore + CheckpointStore duplication | imperfect-but-fine | 1 task | Share `JSONLAppendStore<T>`. ~120 lines compacted. |
| 10 | Pbxproj / gitignore inconsistency | imperfect-but-fine | 1 commit | Decide policy, document, stick to it. |
| 11 | `applyFocusDim` called from 3 paths | imperfect-but-fine | 1 commit | Trim or document the redundancy. |
| 12 | Test fixtures use IDs that violate ParagraphID contract | imperfect-but-fine | 1 commit | Add `makeValidID()` helper. |

---

## Recommended pass-2 candidates

If we want to do focused refactoring before pushing on to editing UX / craft principles / compile, my top three:

1. **Wire Bootstrap into the production load path** (finding #1). This restores the op-log's actual value proposition and is a small change.
2. **Build an editor integration test harness** (finding #2). The next class of bugs we'd ship is exactly the class the unit suite missed. The harness pays for itself across editing-UX and compile milestones.
3. **Split ProjectStore + factor out DocumentOpLogContext** (findings #6, #7). Pure cleanup, sets the stage for the editing-UX milestone which will touch both files heavily.

These three together would take roughly the same effort as one feature milestone and would substantially de-risk what comes next.

The rest (findings #3 through #5, #8 through #12) can be carry-forwards we pick up opportunistically. Most of them are 1-commit changes that fit naturally into "while you're in that file anyway" work.

---

## What I'd leave alone

- The mode polymorphism (`ProseMode` / `ScreenplayMode`) is the right shape.
- The `OpLog/` foundation is clean. No structural changes needed.
- The MCP tool surface and router architecture are working.
- The `.maugham/` sidecar directory layout is established and consistent (ops, conflicts, sessions, checkpoints, ui-state, scratch, trash — each has a clear owner).
- The "extract a ViewModifier to dodge the type-checker" pattern is fine. It's ugly but it works and it's localized.
- Most small files (every store under 200 lines, every model, every smaller editor module). They're well-bounded.
