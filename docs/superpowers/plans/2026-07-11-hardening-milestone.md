# Hardening Milestone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the full revised shortlist of the 2026-07-11 maintainability review: eliminate two silent-data-loss classes, harden palette (cross-surface), close doc-truth drift with generation tests, climb the enforcement ladder, fix the MCP-restart flake and the update progress bar.

**Architecture:** Seven ordered phases on one branch; Phase S is mechanical-structure-only and gates everything else. Fixes land in existing seams (Document/OpLog, ProjectStore, MCP catalog, MaughamCore) — no new subsystems.

**Tech Stack:** Swift / SwiftUI / AppKit; XCTest; xcodegen.

**Required reading for every task's implementer:** `CLAUDE.md` (hard invariants + tripwires), the finding cited in the task (in `docs/superpowers/notes/2026-07-11-maintainability-review.md`), and the `AREA.md` of any directory touched. The spec is `docs/superpowers/specs/2026-07-11-hardening-milestone-design.md`.

## Global Constraints

- Build/test: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`. Any task touching `Packages/MaughamCore` ALSO runs `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`.
- After `project.yml` or `Package.swift` edits (none planned): `./gen.sh`. Never edit or commit `Maugham.xcodeproj/`.
- TDD per task: failing test first, run it, minimal fix, run green, commit. One commit per task, message prefix per phase (e.g. `refactor(editor):`, `fix(oplog):`, `docs:`, `test(tripwire):`, `fix(mcp):`, `fix(updates):`).
- Undo tasks follow ADR 0023 conventions (D1 unconditional clear; no clear inside manual groups; weak-um redo).
- Any new raw file read of manuscript content is forbidden (tripwire 20); derived-content reads need `// adr-0018-ok:` annotations at the CALL SITE.
- New MaughamCore API = `public`. 4-char paragraph-id literals in tests from `[0-9a-hjkmnp-tv-z]` (tripwire 8).
- After Phase S completes: run a Release-config build (`-configuration Release build CODE_SIGNING_ALLOWED=NO`) because `ProjectWindow`-adjacent code changed (CLAUDE.md rule).

---

## Phase S — Structural (mechanical only; NO behavior change)

### Task 1: Split EditorCoordinator.swift by MARK cluster

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift` (2,293 lines)
- Create: `Maugham/Editor/EditorCoordinator+ReviewRender.swift`, `EditorCoordinator+TabCycle.swift`, `EditorCoordinator+Typography.swift`, `EditorCoordinator+FindNavigation.swift` (final split set = the file's existing MARK clusters; keep NSTextViewDelegate core + stored properties in the base file)

**Interfaces:** No API change. All stored properties stay in the base class declaration (Swift extensions cannot hold stored properties). Methods move verbatim — same names, same access levels.

- [ ] Step 1: Read `Maugham/Editor/AREA.md` in full, then map the MARK clusters: `grep -n "// MARK" Maugham/Editor/EditorCoordinator.swift`.
- [ ] Step 2: Run the Editor test cluster as baseline: `xcodebuild … test -only-testing:MaughamTests/EditorIntegrationHarnessTests -only-testing:MaughamTests/EditorCoordinatorCycleTests CODE_SIGNING_ALLOWED=NO` → expect PASS.
- [ ] Step 3: Move each MARK cluster's methods verbatim into its extension file. NO edits beyond relocation + file headers. `applyFocusDim`'s three call paths stay intact (AREA.md warns: don't dedupe).
- [ ] Step 4: Full Mac suite → PASS. `git diff --stat` sanity: base file shrinks, no non-move changes (verify with `git diff --color-moved=dimmed-zebra`).
- [ ] Step 5: Commit `refactor(editor): split EditorCoordinator into MARK-cluster extensions (mechanical)`.

### Task 2: Bundle EditorSurface.init parameters into a config struct

**Files:**
- Modify: `Maugham/Editor/EditorSurface.swift`, `Maugham/Views/EditorHost.swift` (the ~40-param init at EditorHost.swift:81-234)

**Interfaces:**
- Produces: `struct EditorSurfaceConfiguration` (in EditorSurface.swift) grouping the closure/value parameters into nested sub-structs by concern (e.g. `paragraphProviders`, `annotationActions`, `reviewProviders`, `chrome`). `EditorSurface.init(document:configuration:)`.
- EditorHost constructs it in a dedicated `private func makeSurfaceConfiguration()` so the body type-checker load drops (ProjectWindow pattern).

- [ ] Step 1: Baseline: Editor harness tests PASS (as Task 1 Step 2).
- [ ] Step 2: Define the struct; move parameters 1:1 (same names, same types, no signature changes to the closures themselves). The `Binding` for text and tripwire-sensitive pieces (`applyExternalText` wiring, `_undoCoherentApplyPending` consumption) MUST NOT change shape — this is a parameter-packaging change only.
- [ ] Step 3: Full Mac suite → PASS; then Release-config build → succeeds (type-check budget).
- [ ] Step 4: Commit `refactor(editor): EditorSurfaceConfiguration bundles the init parameter wall (mechanical)`.

### Task 3: Shared makeTestProject helper

**Files:**
- Create: `MaughamTests/OpLog/OpLogTestProject.swift`
- Modify: the 13 duplicating files (list: `grep -rln "func makeProject" MaughamTests/OpLog/`)

**Interfaces:** `@discardableResult func makeTestProject(prefix: String, initialMd: String, file: StaticString = #filePath, line: UInt = #line) throws -> (dir: URL, docURL: URL)` — signature generalized from the duplicates; read 3 of them first and match the common shape (some return store handles — if variants genuinely differ, extract the majority shape and leave true variants alone; do NOT force-fit `AnchoredFileEmptyLogBootstrapTests`/`LoadDivergenceSnapshotTests` if their setup differs semantically).

- [ ] Step 1: Read the 13 duplicates; write the shared helper matching the majority shape.
- [ ] Step 2: Migrate callers file-by-file; run `-only-testing:MaughamTests/OpLog` suite → PASS.
- [ ] Step 3: Commit `test(oplog): shared makeTestProject helper, kill 13 duplicates`.

**PHASE GATE:** full Mac suite green + Release build green before Phase 1.

---

## Phase 1 — Sync & durability

### Task 4: Task-op appends become durable (E1)

**Files:**
- Modify: `Maugham/OpLog/Document+Tasks.swift` (`appendTaskOpInternal`, :192-212), `Maugham/OpLog/Document.swift` (`close()`, ~:944)
- Test: `MaughamTests/OpLog/TaskOpDurabilityTests.swift` (create)

**Interfaces:** Chosen design (smaller blast radius, keeps SwiftUI-facing mutators synchronous): `Document` gains `private var inFlightTaskAppends: [Task<Void, Never>]` (or a counting TaskGroup wrapper) — `appendTaskOpInternal` records its detached task; new `internal func drainTaskAppends() async` awaits and clears; `close()` awaits `drainTaskAppends()` BEFORE `flushBurstNow()`.

- [ ] Step 1: Write the failing test — a `Transcriber`-style injected slow op store is overkill; instead use the real store and assert the drain contract:

```swift
@MainActor
final class TaskOpDurabilityTests: XCTestCase {
    func test_close_drainsInFlightTaskAppends_opOnDiskAfterClose() async throws {
        let (dir, docURL) = try makeTestProject(prefix: "taskop-durability",
            initialMd: "- [ ] buy milk\n")
        let doc = try await Document.load(url: docURL, device: "test")
        let task = try XCTUnwrap(doc.tasks().first)
        doc.setTaskStatus(taskId: task.id, done: true)   // fire-and-forget append today
        await doc.close()                                 // must drain before husking
        // Reload from DISK only — if the append was dropped, status reverts.
        let reloaded = try await Document.load(url: docURL, device: "test2")
        XCTAssertTrue(try XCTUnwrap(reloaded.tasks().first).done,
            "task op must be durable once close() returns")
        await reloaded.close(); try? FileManager.default.removeItem(at: dir)
    }
}
```
   (Exact `Document.load`/`tasks()`/`setTaskStatus` spellings: mirror an existing test in `MaughamTests/OpLog/TaskUndoTests.swift` — copy its setup idioms.)
- [ ] Step 2: Run it. It may pass by luck (append races close) — make it deterministically RED by injecting delay: if `Document` has no injectable op-store seam, add a 0-line-risk test hook `Document._testDelayTaskAppends: Duration?` consulted inside the detached task. Verify RED.
- [ ] Step 3: Implement the drain-set; `close()` awaits it first. Also await the drain in `flushBurstNow`'s sweep path? NO — scope is close-time durability only (spec 1a).
- [ ] Step 4: Test → GREEN. Full OpLog suite → PASS.
- [ ] Step 5: Fix the false comment at the append site ("re-derive on reload reconciles") to state the real contract: mirror-first, drained at close.
- [ ] Step 6: Commit `fix(oplog): task-op appends drained before close — quit can no longer drop task/undo ops (E1)`.

### Task 5: External merge folds pending typing (E3a)

**Files:**
- Modify: `Maugham/OpLog/Document+ExternalChange.swift` (`handleExternalLogChange`, :47-115)
- Test: `MaughamTests/OpLog/ExternalMergePendingTests.swift` (create)

**Interfaces:** At the top of `handleExternalLogChange`, after the `isClosed` guard: if `pending.hasChanges` (spelling: see `PendingBuffer`), call `try await flushBurstNow()` BEFORE `opStore.load` — the local edits become real ops and participate in the merge like any peer's. This reuses the existing tested flush path rather than inventing a fold.

- [ ] Step 1: Failing test — seed a doc, type via `setFullText` (leaves pending un-bursted), append a foreign op to the on-disk log directly (`JSONLAppendStore` with a different device slug — mirror `RewindUndoTests`' foreign-op idiom), call `handleExternalLogChange()`, assert `displayText` still contains the un-bursted local edit AND the foreign op's effect. Expect RED (local edit gone).
- [ ] Step 2: Implement the flush-first. Watch the echo guard: after flushing, our new ops are in `_opLogMirror`, so the `newOps` filter still sees only the foreign op — verify this reasoning in the test.
- [ ] Step 3: GREEN; full OpLog suite PASS (especially the presenter/echo tests — `DocumentCloseFlushTests`, echo-guard tests).
- [ ] Step 4: Commit `fix(oplog): external log merge flushes pending burst first — peer sync no longer discards live typing (E3a)`.

### Task 6: Live merge derives like load (E3c)

**Files:**
- Modify: `Maugham/OpLog/Document+ExternalChange.swift:76-86`
- Test: extend `MaughamTests/OpLog/ExternalMergePendingTests.swift`

- [ ] Step 1: Failing test: build an op log whose merged derivation contains an orphan paragraph (id absent from final sequence — mirror the reconcile tests in `Document+Load` coverage, see `LoadDivergenceSnapshotTests` idioms); after `handleExternalLogChange`, assert orphan is trimmed (today it survives → phantom task rows).
- [ ] Step 2: Replace the bare `Deriver.derive(ops:)` + manual sequence-preservation block with the same `deriveWithSequenceFallback` + `reconcile` calls `Document.load` uses (`Document+Load.swift:217-218`). Keep the existing empty-sequence preservation semantics — read both sites and unify rather than blindly swapping (the legacy-recovery comment at :70-75 documents why the fallback exists).
- [ ] Step 3: GREEN; full OpLog suite PASS.
- [ ] Step 4: Commit `fix(oplog): live merge uses load's derive+reconcile path (E3c)`.

### Task 7: Pure-append merges preserve the undo stack (E3b, conservative slice)

**Files:**
- Modify: `Maugham/OpLog/Document+ExternalChange.swift` (:114), `Maugham/OpLog/Document.swift` (`_undoCoherentApplyPending` arming, ~:164)
- Test: `MaughamTests/Editor/MergeUndoPreservationTests.swift` (create, use `EditorIntegrationHarness`)

**Interfaces:** Compute `let pureAppend = (removedFromLog.isEmpty && <no existing paragraph's text changed>)` — concretely: derive-before vs derive-after paragraph maps are equal on the intersection of keys. If `pureAppend`, set `_undoCoherentApplyPending = true` before `recomputeDisplayText()`. Any other merge keeps today's behavior (D1-consistent clear). DECLINED design (spec): caret-aware gating.

- [ ] Step 1: Failing test via the harness: register a non-text undo action, inject a foreign APPEND-ONLY op (new paragraph), fire the merge, assert `undoManager.canUndo` still true. Second test: a foreign op that EDITS an existing paragraph → assert stack IS cleared (pins the conservative boundary).
- [ ] Step 2: Implement; GREEN; full Mac suite PASS (the ADR 0023 undo suites are the regression net).
- [ ] Step 3: Commit `fix(editor): pure-append peer merges no longer wipe the undo stack (E3b conservative)`.

### Task 8: Compound task-archive undo reopens swept annotations (1e)

**Files:**
- Modify: `Maugham/OpLog/Document+Tasks.swift` (compound undo :579-671, forward path near :541)
- Test: `MaughamTests/OpLog/TaskArchiveUndoAnnotationTests.swift` (create)

**Interfaces:** Forward path: when `archiveTask` deletes the sole-content paragraph, capture the annotation ids archived by the resulting sweep (mirror how `Document+RewindUndo.swift:99` obtains `sweepArchivedAnnotationIds` — reuse that mechanism, do not invent a parallel one). Compound undo closure: after `applyRestore`, emit `annotationReopen` ops for the captured ids (the `AnnotationInverse` factory from ADR 0023).

- [ ] Step 1: Failing test: paragraph whose only content is a task + an open annotation anchored to it; `archiveTask` (paragraph collapses, sweep archives the annotation); ⌘Z-equivalent (invoke the registered undo via the window's `NSUndoManager` — mirror `RewindUndoTests`); assert task restored AND annotation status open again. RED today (annotation stays archived).
- [ ] Step 2: Implement capture + reopen; GREEN; run `AnnotationLifecycleUndoTests` + `TaskUndoTests` + `RewindUndoTests` → PASS.
- [ ] Step 3: Commit `fix(oplog): task-archive compound undo reopens sweep-archived annotations`.

**PHASE GATE:** full Mac suite + phone suite green (Deriver/annotation semantics are shared).

---

## Phase 2 — Palette hardening (MaughamCore parse/render fixes serve both surfaces)

### Task 9: Rename-revert fixed — draft title is an intent, not a value (E2)

**Files:**
- Modify: `Maugham/Views/Palette/PaletteCardEditor.swift` (seed :411-413, persist :439-448)
- Test: `MaughamTests/Views/PaletteCardEditorRenameTests.swift` (create; store-level, no UI driving needed)

**Interfaces:** Editor keeps `private var baselineTitle: String?` captured in `seed()`. `persist()` sends `card.with(title:)` ONLY when `draft.title != baselineTitle` (user edited in-editor); otherwise it re-reads the store's current title into the outgoing card (external rename wins). After every successful persist, `baselineTitle = draft.title`. Additionally: `.onChange` of the store item's title (already observable via `manifest.modified`-driven reload) re-seeds `draft.title` + baseline when the user has no in-editor title edit pending.

- [ ] Step 1: Failing test at the store/editor-logic seam: simulate the P1 scenario — create card "Old", seed editor state, rename via `store.updateResearchItem(id:title:"New")`, then run the editor's persist with a draft whose title is still "Old" but whose BODY changed; assert the on-disk item title remains "New" and the file stays at the new slug. RED today (reverts to "Old" — probe P1's traced path).
- [ ] Step 2: Implement baseline-title logic. GREEN. Also run `ProjectStorePaletteTests` + `PaletteCardEditorTests` → PASS.
- [ ] Step 3: Commit `fix(palette): external rename survives editor saves — draft title treated as user intent (E2)`.

### Task 10: Palette writes are NSFileCoordinator-coordinated (2b)

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Palette.swift` (:57 template write, ~:120 update write), `Maugham/Stores/DocumentStore.swift` (expose the coordinated-write seam if not already internal-visible)
- Test: `MaughamTests/Stores/PaletteWriteCoordinationTests.swift` (create)

**Interfaces:** Route both writes through the same coordinated path research notes use (`DocumentStore.performFileSave` family, DocumentStore.swift:264-278) via ProjectStore's existing `documentStore` back-ref (see how research-note saves reach it; if `performFileSave` is `private`, widen to `internal`). Fallback when `documentStore == nil` (unit-test contexts): direct write is acceptable but must go through one named funnel `paletteCoordinatedWrite(_:to:)` so the grep in Step 3 has a single allowed spelling.
- [ ] Step 1: Failing-by-construction check: add to `MaughamTests/TripwireGrepTests.swift` a grep asserting no raw `.write(to:` in `ProjectStore+Palette.swift` (planted-offender self-check per that file's house pattern). RED (two raw writes exist).
- [ ] Step 2: Implement the funnel + coordination. GREEN; palette suites PASS.
- [ ] Step 3: Commit `fix(palette): card writes coordinated via NSFileCoordinator funnel + tripwire grep (A1-High)`.

### Task 11: Inline body images no longer harvested into imagePaths (2c)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/PaletteCard.swift` (parse :188-191, regex :224-225, render :256-268)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/PaletteCardParserTests.swift` (extend)

**Interfaces:** Parser harvests inline images ONLY from the dedicated Images section, not body prose; body keeps its `![]()` text verbatim (it's prose). Remote URLs (`://`) never enter `imagePaths` regardless of section.

- [ ] Step 1: Failing tests (3): body containing `![](./x_assets/a.png)` → `imagePaths` does NOT contain it and body round-trips verbatim; body containing `![](https://x/y.png)` → same; Images-section image still harvested. RED on the first two.
- [ ] Step 2: Implement (scope `inlineImagePaths` to the images section slice). GREEN; run BOTH schemes (MaughamCore change).
- [ ] Step 3: Commit `fix(palette): body prose images stay prose — kills un-removable bouncing thumbnail (A6)`.

### Task 12: Body round-trip preserves bytes (2d)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/PaletteCard.swift` (:134, :161-163, :196-209)
- Test: `PaletteCardParserTests.swift` (extend)

- [ ] Step 1: Failing tests: body with leading-indented lines and a 3-blank-line run → `parse(render(card)).body == card.body`. RED (trimmed/collapsed).
- [ ] Step 2: Implement: stop per-line trimming and blank-run collapsing inside the body region (structure detection for section headings may still trim its OWN probe copy of a line — presentation vs storage). Keep the documented `## Swatches`-in-body residual as-is (acknowledged deviation).
- [ ] Step 3: GREEN both schemes. Commit `fix(palette): body round-trip is byte-preserving (A6)`.

### Task 13: One inline-image regex (2e)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/PaletteCard.swift` (consume), `MarkdownBlockParser.swift` (expose)
- Test: `PaletteCardParserTests.swift` assertions already pin behavior from Tasks 11-12

- [ ] Step 1: Expose `MarkdownBlockParser`'s anchored solo-image matcher (:283) as a `public static` helper; PaletteCard's parser consumes it; delete `inlineImageRegex`.
- [ ] Step 2: Both schemes GREEN. Commit `refactor(core): single inline-image matcher — permissive palette duplicate deleted`.

### Task 14: Palette pane interaction tests (2f)

**Files:**
- Modify: `MaughamTests/Views/PalettePaneTests.swift` (2 tests today)

- [ ] Step 1: Add tests for: add-card (wall gains tile + file created), edit-card routes to `PaletteCardEditor` (selection → editor state seeded), reorder persists manifest order. Mirror the store-driven testing style of the existing 2 tests — no UI automation.
- [ ] Step 2: GREEN. Commit `test(palette): pane add/edit/reorder coverage`.

**PHASE GATE:** Mac + phone suites green.

---

## Phase 3 — Doc-truth + generation tests

### Task 15: Documentation corrections batch (3a + tripwire wording)

**Files:** `MaughamPhone/AREA.md`, `CLAUDE.md`, `docs/roadmap.md`, `docs/guide/reference.md`, `docs/guide/right-pane.md`, `Maugham/Editor/AREA.md`, `Maugham/MCP/AREA.md`, `MaughamPhone/Storage/CoordinatedFileIO.swift`, `MaughamPhone/Read/DocumentReaderView.swift`, `docs/RELEASING.md`

Precise edits (each verified in the review; re-verify each line still exists before editing — v0.20.0 may have shifted line numbers):
- [ ] `MaughamPhone/AREA.md`: replace "Undo/reopen is a deferred cross-surface milestone (see roadmap)." with "Reopen / Reopen & Revert shipped phone-v0.5.0 (ADR 0023, schema v3): rejected/archived → `annotationReopen`; accepted → full `claudeAcceptRevert` with drift-confirm." Add 2 lines under the Read-tab section: "Read tab displays the on-disk clean `.md` — a contracted Tier-2 divergence from ADR 0018 (registry row: cross-surface-contracts.md); annotations derive from the op log, so the two can briefly disagree while iCloud syncs. This is designed behavior."
- [ ] `CLAUDE.md`: delete the stale "Onboarding affordance for Annotations pane vs History pane is missing…" bullet. Tripwire 5: change "`CharacterAutocompleter` is dead code" to "`CharacterAutocompleter` was deleted (quality-maintainability v0.7.0)". Tripwire 14 "Enforced" phrasing: "typed mover + grep tripwire (`TripwireGrepTests`)" replacing any "by construction" claim. Add Default Workflow lines: "9. **Whole-branch review before merge** — after per-task reviews, one review of the full branch diff; per-task reviews cannot see emergent interactions (T5×T6 precedent)." and "10. When a roadmap item flips •→✓, sweep sibling docs (CLAUDE.md, AREA.md, guide) for now-false claims in the same commit." Add tripwire rows for husk-reload (key Document-binding reloads on PATH not id; canonical `EditorHost.needsReload`) — rows for mint/DeviceSlug are added by Tasks 17/18 alongside their enforcement.
- [ ] `docs/roadmap.md`: rewrite the :65-66 carry-forward — tooltips shipped 2026-05-22 (`DetailPaneToggle` `.help()`); only the empty-state-hint idea remains open. Delete the "39 surviving maugham.* names" count (prose points at `MaughamEvent.swift` instead).
- [ ] `docs/guide/reference.md`: add ⌘⌥4 History and ⌘⌥7 Palette rows. `docs/guide/right-pane.md`: intro acknowledges all seven modes; add History + Palette pointer lines mirroring the Tasks/Annotations ones.
- [ ] `Maugham/Editor/AREA.md`: add tripwire line: "The binding setter's side effects (`recordEditorTextWrite` → `recordWordCount`/`recordSessionActivity`) are part of the contract — pinned by `EditorBindingSideEffectsTests` (regression b37609a). Preserve them in any binding change."
- [ ] `Maugham/MCP/AREA.md`: add trust-boundary paragraph: socket is same-user-only, enforced by `~/Library` filesystem perms, not app auth (ADR 0003 assumption made explicit).
- [ ] Move `// adr-0018-ok:` from `CoordinatedFileIO.swift:68` to the `DocumentReaderView` call site (:276) so the generic primitive stops blanket-exempting all callers; run `TripwirePhoneGrepTest` to confirm the guard still passes with the relocated annotation.
- [ ] `docs/RELEASING.md`: correct the updater description — `.zip` payloads are verified in-app (codesign+notarization+TeamID); `.dmg` fallback is NOT in-app-verified, it is revealed in Finder and Gatekeeper-verified on launch.
- [ ] Run both grep-tripwire suites → PASS. Commit `docs: truth batch — stale claims fixed, workflow rules added, annotation relocated (review §3.3)`.

### Task 16: Generation tests (3b)

**Files:**
- Create: `MaughamTests/DocSyncTests.swift`

- [ ] Step 1: Three failing-capable tests: (1) extract the `(NN)` from "Tool catalogue (NN)" in `Maugham/MCP/AREA.md` AND the "NN tools" in `CLAUDE.md`'s MCP row, assert both `== MCPToolCatalog.all.count`; (2) enumerate `DetailPaneToggle.swift`'s `.keyboardShortcut("N", modifiers: [.command, .option])` occurrences by regex over the source file, assert each `⌘⌥N` token appears in `docs/guide/reference.md`; (3) assert each `DetailSegment` case name appears in `docs/guide/right-pane.md`. Resolve doc paths relative to `#filePath` (existing pattern: see how `TripwireGrepTests` locates sources). Include a planted-offender self-check per house style (feed a doctored doc string through the same parser, assert the test WOULD fail).
- [ ] Step 2: GREEN against the Task-15-corrected docs. Commit `test(docs): generation tests — tool count and keybinding tables can no longer drift silently`.

**PHASE GATE:** Mac suite green.

---

## Phase 4 — Enforcement ladder

### Task 17: ParagraphID.mint() guard

**Files:** `MaughamTests/TripwireGrepTests.swift`, `CLAUDE.md` (new row)

- [ ] Step 1: Grep test: no `ParagraphID.mint()` bare call outside `Packages/MaughamCore/Sources/MaughamCore/ParagraphID.swift` and test targets — production sites must use `mintUnique(excluding:)` (birthday-collision lesson, oplog-growth milestone). Planted-offender self-check. Expected: GREEN immediately (audit verified zero bare production call sites) — the self-check proves the alarm fires.
- [ ] Step 2: Add CLAUDE.md tripwire row 22 citing the test. Commit `test(tripwire): bare ParagraphID.mint() forbidden in production (+row 22)`.

### Task 18: DeviceSlug becomes construction-safe

**Files:** `Packages/MaughamCore/Sources/MaughamCore/DeviceSlug.swift` (or wherever it lives — find via `grep -rn "enum DeviceSlug\|struct DeviceSlug" Packages/`), all call sites, `CLAUDE.md` row
- Test: existing DeviceSlug/OpLog tests pin behavior

- [ ] Step 1: Convert to `public struct DeviceSlug { public let raw: String; private init… ; public static func make(from:) -> DeviceSlug }` — hand-building a slug string becomes a compile error at op-log call sites that take `DeviceSlug` (widen signatures where they currently take `String` slugs; keep a `raw` accessor for filename interpolation). Both schemes must compile+pass — this is the enforcement.
- [ ] Step 2: Tests that legitimately need arbitrary slugs use `.make(from:)` or a test-only `DeviceSlug.unsafe(_:)` marked clearly. CLAUDE.md row 23. Commit `refactor(core): DeviceSlug construction-safe — hand-built slugs are now compile errors (+row 23)`.

### Task 19: TW7 call-site census + TW15 grep + TW8 lint (three small grep tests)

**Files:** `MaughamTests/TripwireGrepTests.swift`

- [ ] Step 1: (a) `applyExternalText(` production call-site count == 1 (`EditorSurface.swift`); (b) `ContentUnavailableView(` in `Maugham/Views/` must be followed within its expression chain by `.frame(maxWidth: .infinity` (line-window heuristic: within the next 3 lines — crisp enough because the canonical examples all chain immediately); (c) test-target scan: 4-char ids inside `<!-- ¶… -->`/`ParagraphID("…")` literals restricted to `[0-9a-hjkmnp-tv-z]`. Each with planted-offender self-check.
- [ ] Step 2: All GREEN (or fix any real offender found). Commit `test(tripwire): TW7 census, TW15 frame guard, TW8 id-alphabet lint`.

### Task 20: OpKind ↔ undo exhaustiveness

**Files:** `MaughamTests/OpLog/OpKindUndoExhaustivenessTests.swift` (create)

- [ ] Step 1: Test iterating `OpKind.allCases` (add `CaseIterable` if absent — additive) asserting membership in exactly one of: (a) inverse-covered (registered via `AnnotationInverse`/`TaskInverse`/rewind machinery — expose a static coverage list next to each factory), (b) an explicit `nonUndoable` allow-list in the test citing why (checkpoint, bootstrap, externalEdit, creation ops, typingBurst-by-design). A NEW OpKind case fails the test until sorted into a bucket. RED-check by temporarily adding a fake case? NO — cannot modify production for the check; instead the allow-list is exhaustive-switch (`switch kind { … }`) so the COMPILER flags a new case in the test itself.
- [ ] Step 2: GREEN. Commit `test(oplog): every OpKind must declare its undo story (ADR 0023 completeness)`.

### Task 21: InboxConvention choke-point (4h)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/Inbox/InboxConvention.swift`
- Modify: `MaughamPhone/Capture/InboxCaptureWriter.swift` (:50,:54), `Maugham/Stores/InboxStore.swift` (asset resolution + :324-325), `docs/superpowers/notes/cross-surface-contracts.md` (row)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/InboxConventionTests.swift`

**Interfaces:** Mirror `PaletteConvention` exactly (it's the in-repo template): `public enum InboxConvention { public static let imagesSubdir = "images"; public static let audioSubdir = "audio"; public static func assetSubdir(for kind: InboxEntryKind) -> String?; public static func assetURL(kind:filename:inboxDir:) -> URL }`.

- [ ] Step 1: Failing test: round-trip — phone-writer path for an image and Mac-reader path resolve the SAME URL via the shared helper (extend `InboxPalettePromoteRoundTripTests` idiom). Then migrate both call sites; grep test (house style) forbidding the raw `"images"`/`"audio"` literals outside InboxConvention.
- [ ] Step 2: Both schemes GREEN. Registry row added. Commit `refactor(core): InboxConvention choke-point — inbox subdir literals unified (E5a)`.

### Task 22: Shared TaskMarkup predicate (4i)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/TaskMarkup.swift`
- Modify: `Maugham/OpLog/Document+Tasks.swift:24-25`, `Maugham/OpLog/TaskAnchorAlignment.swift:366-367`, `Maugham/Views/TasksPane.swift:734`
- Test: `MaughamCoreTests/TaskMarkupTests.swift`

- [ ] Step 1: Failing test: `TaskMarkup.lineContainsTaskMarker("- [X] done")` == true (uppercase — today's OpLog copies say false). Implement handling `- [ ]`, `- [x]`, `- [X]`, `[[todo:`, `[[done:`. Migrate the three sites; the TasksPane flip helper keeps its own replace logic but sources detection from the shared predicate.
- [ ] Step 2: Both schemes GREEN (cache-invalidation tests in `Document+Tasks` coverage now catch `[X]`). Commit `fix(core): shared TaskMarkup predicate — uppercase [X] no longer skips cache invalidation (A1-Med)`.

### Task 23: Phone filename-contract test hardening (4j)

**Files:** `Packages/MaughamCore` (tiny helper), `MaughamPhoneTests/OpLogFilenameContractTests.swift:9-14`, `MaughamTests/OpLogFilenameContractTests.swift`

- [ ] Step 1: Expose the id-shape as a MaughamCore helper (or golden constant) both tests consume — find what `ProjectStore.newId(prefix:)` guarantees and extract JUST the shape contract (prefix + 8-hex) into MaughamCore (e.g. `DocIdShape.isValid(_:)` + `DocIdShape.example`). Phone test now calls the shared shape; a Mac minter change breaks the phone test.
- [ ] Step 2: Both schemes GREEN. Commit `test(contract): doc-id shape shared — Mac minter change now fails the phone test (E5b)`.

**PHASE GATE:** Mac + phone suites green.

---

## Phase 5 — MCP robustness

### Task 24: Text response byte-budget (E4)

**Files:**
- Create: `Maugham/MCP/MCPResponseBudget.swift`
- Modify: `Maugham/MCP/Tools/DocumentTools.swift` (`emitManuscriptDoc` :90-100 + research text branch), other large-text emitters found by survey (`search`, `list_all_links` — survey the catalog, apply to any tool that can emit unbounded text)
- Test: `MaughamTests/MCP/MCPResponseBudgetTests.swift`

**Interfaces:** `enum MCPResponseBudget { static let maxTextBytes = 900_000; static func enforce(_ payload: Data, hint: String) throws -> Data }` throwing a structured `MCPError.payloadTooLarge(hint:)` rendered as the tools' loud-failure JSON with a machine-readable `hint` ("re-read by section: pass paragraph range/section id"). `read_document` gains optional `max_bytes`/section params ONLY if an existing param pattern fits — otherwise the hint names the existing section-scoped tools; do not invent new API absent need.

- [ ] Step 1: Failing test: synthesize a >1MB manuscript doc (builder loop), call the tool handler directly (house pattern in `MaughamTests/MCP/Tools/`), assert structured `payload_too_large` with hint — not a silent full emit. Second test: normal doc passes through untouched.
- [ ] Step 2: Implement; sweep the catalog for other unbounded-text emitters and wrap them (list each in the commit message). GREEN. Commit `fix(mcp): text responses enforce the 1MB budget with a structured too-large error (E4)`.

### Task 25: Closed-doc reads leave the main thread's hot path (E6 narrow)

**Files:**
- Modify: `Maugham/MCP/Tools/DocumentTools.swift:80` (closed-doc branch)
- Test: `MaughamTests/MCP/Tools/DocumentToolsTests.swift` (extend)

**Interfaces:** Closed-doc branch routes through `DerivedManuscriptCache` (which the search/links tools already use) instead of bare `DerivedManuscript.materialize` — freshness guard: the cache must be invalidated by op-log writes already (verify; it is the cache's contract per ADR 0018 area docs — read `DerivedManuscriptCache` before wiring). DECLINED design (spec): making Document access async.

- [ ] Step 1: Test: closed-doc read returns identical content via cache as via direct materialize (equivalence), and a second read hits the cache (observe via cache's stats/test hook if present, else skip the hit assertion and keep equivalence only).
- [ ] Step 2: GREEN. Commit `fix(mcp): closed-doc read_document rides DerivedManuscriptCache (E6 narrow)`.

### Task 26: One docId-keyed resolver for tool families (5c)

**Files:**
- Modify: `Maugham/MCP/Tools/DocumentTools.swift:77`, `Maugham/MCP/AnnotationToolHelpers.swift:34`, `Maugham/Stores/DocumentStore.swift:716-722`
- Test: `MaughamTests/MCP/Tools/DocumentToolsTests.swift`

- [ ] Step 1: Failing test pinning the split: open a doc, rename its path in the manifest (without registry re-key), call `read_document` — today it silently falls to the derived branch while `add_comment` uses the live doc (assert the ids disagree, or more simply assert `read_document` used the LIVE doc — decide after reading `DocumentStore.document(for:)`).
- [ ] Step 2: `read_document` resolves via `document(forDocId:)` first (same as annotation tools), path lookup as fallback only. GREEN; MCP suite PASS. Commit `fix(mcp): read_document resolves open docs by docId — closes the ADR-0018 re-divergence window (TB)`.

### Task 27: MCP first-call-after-restart — diagnose, fix, pin (5d)

**Files:** TBD by diagnosis — start at `Maugham/MCP/MCPServer.swift` (socket lifecycle), `maugham-mcp/` bridge (`JSONRPCBridge.swift` reconnect :100-106), `MaughamApp` MCP registration timing
- Test: `MaughamTests/MCP/MCPColdStartTests.swift` (create, on the `MCPBinaryIntegrationTests` real-binary harness)

**This is the milestone's one open-ended task. Time-box: if root cause isn't established within one focused session, STOP and report findings to the coordinator rather than churning.**

- [ ] Step 1: Reproduce: memory file `project_deferred_mcp_first_call.md` describes the symptom (first call after app restart fails/hangs; retry succeeds). Drive the real binary: start app-side socket, connect bridge, kill app socket, restart it, send a call immediately — capture the failure mode (`maugham_not_running` synthesis? stale-socket ECONNREFUSED race? half-open fd from the bridge's cached connection?). The bridge's reconnect path (:100-106) and its single-cached-fd design are prime suspects.
- [ ] Step 2: Fix at the diagnosed layer (likely: bridge invalidates its cached fd on EOF/EPIPE and retries once with fresh connect before synthesizing `maugham_not_running`).
- [ ] Step 3: Pin: cold-restart integration test exercising the exact sequence, RED against the pre-fix code (verify by stashing the fix), GREEN with it.
- [ ] Step 4: Commit `fix(mcp): first call after app restart succeeds — bridge reconnect race (+cold-restart regression test)`. Update `project_deferred_mcp_first_call` memory (delete or mark fixed) at milestone close.

**PHASE GATE:** Mac suite green.

---

## Phase 6 — Robustness + release pipeline

### Task 28: Resolve-inside-root helper at sidecar path sites (6a+6b)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/SafeRelativePath.swift`
- Modify: `Maugham/Stores/TrashStore.swift` (:87,:132), `Maugham/MCP/Tools/DocumentTools.swift` (:116,:160), `Maugham/Stores/InboxStore.swift` (:251)
- Test: `MaughamCoreTests/SafeRelativePathTests.swift`

**Interfaces:** `public enum SafeRelativePath { public static func resolve(_ relative: String, under root: URL) throws -> URL }` — rejects absolute paths, `..` escapes (compare `standardizedFileURL.path` prefix against root), and empty components. Callers throw their surface's loud error.

- [ ] Step 1: Failing tests: `"../../../etc/passwd"` under a temp root → throws; `"a/../b.md"` staying inside → resolves; symlinked root still contains. Then migrate the five call sites (each keeps its own error type).
- [ ] Step 2: Both schemes GREEN (InboxStore is Mac-only but MaughamCore change rebuilds phone). Commit `fix(stores): sidecar-supplied relative paths validated inside project root (A5)`.

### Task 29: mzseg inflate bound + terminate-path update fallback + dead params (6c, 6d, 6g)

**Files:** `Packages/MaughamCore/Sources/MaughamCore/OpLogSegment.swift:117-122`; `Maugham/MaughamApp.swift:50-53`; `Maugham/Views/CollectionPiecesPane.swift:9` + its `ProjectWindow.swift:639` wiring; `Maugham/Views/HelpClaudeDesktopSheet.swift:6-7`
- Test: `MaughamCoreTests/OpLogSegmentTests` (extend); `MaughamTests/Updates/` (extend)

- [ ] Step 1: Segment test: craft a segment whose header claims `expected` far larger than a sane ceiling → decode fails contained (quarantine-style), does not inflate first. Implement bound (`NSData.decompressed` capped: inflate in chunks or pre-check `expected` against ceiling AND post-check actual == expected).
- [ ] Step 2: Terminate-fallback test: `launchSwapHelper` returning false on the quit path sets a `revealPendingUpdateOnNextLaunch` UserDefaults flag (checked+consumed at startup → Finder reveal); mirror `installNow`'s fallback shape. Implement.
- [ ] Step 3: Delete the dead params + call-site wiring; suites GREEN. Commit `fix(core+updates): bounded segment inflate; quit-install failure no longer silent; dead params removed`.

### Task 30: Update download progress (6h)

**Files:**
- Modify: `Maugham/Updates/UpdateChecker.swift` (:20,:25,:31,:67,:83-101), `Maugham/Updates/UpdateSheet.swift` (:54 renders as-is once state updates)
- Test: `MaughamTests/Updates/UpdateProgressTests.swift` (create)

**Interfaces:** `downloadAsset` seam becomes `(URL, String, @escaping @MainActor (Double) -> Void) async throws -> URL`. `defaultDownload` switches to `URLSession.shared.bytes(from:)`: stream to the staging file in 64KB chunks, report `bytesWritten / expectedContentLength` (clamped 0…1) via the callback; `expectedContentLength <= 0` → report -1 once (UpdateSheet renders indeterminate `ProgressView()` for progress < 0). `performCheck` passes `{ self.state = .downloading(version: v, progress: $0) }`.

- [ ] Step 1: Failing test: inject a fake `downloadAsset` that invokes the callback with 0.25/0.5/1.0 — assert `state` sequences through `.downloading(progress:)` values (today the seam has no callback: compile-RED drives the signature change; then behavior test).
- [ ] Step 2: Implement streaming download + wire-through. Existing `UpdateCheckerTests` (injected-seam suite) updated for the new signature. GREEN. Commit `fix(updates): download progress actually reports — streaming download with progress callback (6h)`.

### Task 31: Release pipeline pinning + preflight (6e, 6f)

**Files:** `.github/workflows/release.yml` (:29,:38,:92,:99), `scripts/cut-release.sh`

- [ ] Step 1: Pin `xcode-version:` to the exact version currently resolved by `latest-stable` on the runner in use (read the last release run's log if accessible; else pin to the version in `xcodebuild -version` locally and note the runner must match); pin xcodegen (`brew install xcodegen` → a pinned formula tap or explicit bottle version — if brew pinning is impractical, pin via `mise`/direct binary download with checksum; pick the least-moving-parts option and document it inline). Switch `CFBundleVersion` to `$(git rev-list --count HEAD)` (both sed sites, scoped to the Maugham target block).
- [ ] Step 2: `cut-release.sh` preflight: for each `uses: owner/repo@SHA # vX` line in the three workflow files, `gh api repos/owner/repo/git/ref/tags/vX` (with graceful fallback for tag→tag-object indirection) and assert the SHA matches; abort the cut on mismatch. Add `--skip-pin-check` escape hatch for offline cuts.
- [ ] Step 3: These changes are unexercisable locally — flag in the PR/branch notes that a dry-run tag (patch ≥90) MUST validate before the real release ("dry run is the integration test"). Commit `ci(release): pin Xcode/xcodegen, monotonic CFBundleVersion, SHA↔tag preflight in cut-release.sh`.

---

## Final phase — whole-branch review + close-out

### Task 32: Whole-branch review (mandatory — the rule this milestone ships)

- [ ] Step 1: Dispatch a fresh reviewer subagent over the ENTIRE branch diff vs main with the review's emergent-bug-class checklist (two-correct-tasks-interacting is the target; T5×T6 precedent). Findings triaged binary; Criticals fixed before proceeding.
- [ ] Step 2: Run BOTH full suites + Release build one final time.
- [ ] Step 3: Update `docs/roadmap.md` (hardening milestone entry) + findings-note §5 statuses; per the new workflow rule, sweep sibling docs in the same commit.
- [ ] Step 4: Report to the user for manual smoke (standard smoke + task-toggle→quit→relaunch + palette rename→edit + merge-while-typing) and the paired release cut (dry-run tag first for Task 31).
