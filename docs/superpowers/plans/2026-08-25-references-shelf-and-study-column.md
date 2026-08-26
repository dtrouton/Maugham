# The references shelf and the study column — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The References shelf shows everything a piece is pinned to (including research it *contains*), grouped by the region it came from and superseded by the note a region became; studying a pin takes the right column rather than a fourth one; a research note keeps its line breaks; ⌘\ on the canvas gives the canvas the window.

**Architecture:** One pure projection (`PinnedReferences.pinned`) gains a third input and a sectioned return type; its one assembler (`PinnedReferenceResolver`) and three readers (`ReferencesPane`, `AssistantColumn`, the compiler listing) adapt. The study column moves from an `HStack` wrapper on the centre column to an arm of `ProjectWindow.detailColumn`. Two rendering fixes are local to one file each, and each is pinned by a measurement that is red before the fix.

**Tech stack:** Swift 6 / SwiftUI / AppKit, XCTest. Build/test via `./scripts/test.sh` (fast loop) and `./scripts/test.sh full` (gate). `./gen.sh` after any `project.yml` change (none expected).

**Spec:** `docs/superpowers/specs/2026-08-25-references-shelf-and-study-column-design.md` — read it first; this plan argues from it.

## How this plan is written

Per Denver's standing guidance (`memory/feedback_plan_code_is_a_liability.md`): **contracts, symptoms and verified signatures, not pasted code.** Every signature below was read off the tree on 2026-08-25 at the commit this plan sits on. Re-verify before relying on one; if it moved, the tree wins. Every fix that answers a visible symptom (Tasks 4, 5, 6) must include the **disable experiment**: revert the fix, run the pinning test, watch it go red, restore.

## Global constraints

- Tripwire 2: no flag-guarded bidirectional SwiftUI↔AppKit sync; no stash/restore of `showInspector` for the study column (spec §3.2).
- Tripwire 4: no per-row computation in list rows without caching — sections are built once in `ReferencesPaneHost`'s `.task`, never in `body`.
- Tripwire 15: any `ContentUnavailableView` chains `.frame(maxWidth: .infinity, maxHeight: .infinity)`.
- Tripwire 22: thumbnail cache keyed by path — unchanged.
- The assembly census `ReferencesPaneTests.test_thePinnedProjectionIsAssembledInExactlyOneProductionFile` must stay green: `PinnedReferences.pinned` is called from `PinnedReferenceResolver.swift` and nowhere else in `Maugham/`.
- Mounted tests read their premise off the window they got (CI's display is 1024pt wide) and skip **by name** where the display cannot afford them; a synthetic click needs the host to be the active app (CLAUDE.md build-flow notes).
- After Task 5 (a `ProjectWindow.body` change): a local **Release** build before the branch is called done (`xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`).
- Commit per task on branch `claude/references-shelf-2026-08-25`; no push.

## Verified signatures (2026-08-25)

```
// Maugham/Compiler/PinnedReferences.swift
struct PinnedReference: Identifiable, Equatable, Sendable { let id: String; let kind: Kind; let title: String }
enum PinnedReference.Kind { case research(itemId: String), palette(cardId: String), photo(path: String), scrap(nodeId: String) }
enum PinnedReferences {
  static let scrapTitleCharacterLimit = 80
  static func pinned(forDocId: String, links: [String]?, scene: CanvasScene?, scraps: [CanvasNodeID: String], items: CanvasItemIndex) -> [PinnedReference]
}
// Maugham/Compiler/PinnedReferenceResolver.swift
enum PinnedReferenceResolver { @MainActor static func pins(forDocId: String, store: ProjectStore, projectRoot: URL) -> [PinnedReference] }
// Maugham/Stores/ResearchScope.swift
ProjectStore.derivedResearchItems(forDocumentId: String) -> [ResearchItem]   // collection: contained assets; shortStory/screenplay: every asset; novel/unknown: []
ProjectStore.linkedResearchIds(forDocumentId: String) -> [String]
// Maugham/Canvas/RegionBinding.swift
RegionBinding.references(forPiece: String, in: CanvasScene) -> Set<CanvasNodeID>   // residents of bound regions ∪ self-bound nodes
RegionBinding.bind(_ region: CanvasRegionID, toPiece: String, in: inout CanvasScene)
// Maugham/Canvas/CanvasMembership.swift
CanvasMembership.residents(of: CanvasRegionID, in: CanvasScene) -> Set<CanvasNodeID>
// Maugham/Canvas/CanvasScene.swift
scene.unorderedRegions: [CanvasRegion]; scene.region(_:) -> CanvasRegion?; scene.node(_:) -> CanvasNode?; scene.unorderedNodes: [CanvasNode]
// Maugham/Canvas/CanvasRegion.swift
CanvasRegion { id, label: String, boundPieceID: String?, promotedItemID: String?, homeMembers }
// Maugham/Canvas/CanvasNode.swift
CanvasNode { id, kind (.scrap | .item(CanvasItemReference)), origin: CGPoint, boundPieceID: String?, promotedItemID: String? }
// Maugham/Canvas/Promotion.swift (both PRIVATE today)
private static func readingOrder(_ ids: Set<CanvasNodeID>, in scene: CanvasScene) -> [CanvasNodeID]   // y, then x, then id
private static func regionTitle(_ region: CanvasRegion) -> String                                     // trimmed label, or a fallback
// Maugham/Canvas/CanvasItemFacts.swift
CanvasItemIndex.over(research: [ResearchItem]) -> CanvasItemIndex; index.entry(of: String) -> Entry? { title, kind: CanvasItemKind }
// Maugham/Views/ReferencesPane.swift
ReferencesPane(rows: [Row], projectRoot: URL, persona: Persona, assistant: AssistantColumnModel)
ReferencesPane.Row: Identifiable { reference: PinnedReference; glyph: String; thumbnailPath: String?; id = reference.id }
static func rows(for pins: [PinnedReference], in items: CanvasItemIndex) -> [Row]
ReferencesPaneHost(store:projectURL:docId:persona:assistant:)  // @State rows, .task(id: reloadKey) calls PinnedReferenceResolver.pins
// Maugham/Views/AssistantColumn.swift
final class AssistantColumnModel { private(set) var studied: PinnedReference?; var width: Double; func study(_:); func dismiss(); func isStudying(_:) -> Bool }
AssistantColumn(store:projectRoot:assistant:); static let closeLabel = "Close reference"
static func isPresented(studied: PinnedReference?, persona: Persona, isNoChromeOn: Bool) -> Bool
struct AssistantColumnModifier: ViewModifier { store, projectURL, documentStore, window, isNoChromeOn, persona, activeDocId, assistant }  // HStack: column + resizeHandle + content
final class AssistantColumnEscape { func sync(model:window:persona:isNoChromeOn:); func stop() }
// Maugham/Stores/UIState.swift
public var assistantColumnWidth: Double; static let defaultAssistantColumnWidth = 340; static let assistantColumnWidthRange = 260...620; static func clampedAssistantColumnWidth(_:)
// Maugham/Views/ProjectWindow.swift
@State showInspector: Bool; @State columnVisibility: NavigationSplitViewVisibility; @State detailSegment: DetailSegment; @State selectedSubject: BinderSubject?; @State assistant = AssistantColumnModel()
private func detailColumn(store:documentStore:) -> some View   // `if showInspector { HStack { detailResizeHandle; inspectorPane } .navigationSplitViewColumnWidth(effectiveDetailColumnWidth(...)) }`
static func revealResearchColumn(persona:subject:showInspector: inout Bool, detailSegment: inout DetailSegment)
static func canvasCollapse(route:isNoChromeOn:showInspector:stash:) -> CanvasCollapse   // .collapse(.doubleColumn, showInspector: false, stash:) / .release(.all, prior) / .unchanged
static func applyCanvasCollapse(_:columnVisibility: inout, showInspector: inout, stash: inout)
static func effectiveDetailColumnWidth(persisted: Double, containerWidth: Double?) -> Double
centre column: `.modifier(AssistantColumnModifier(...)).navigationSplitViewColumnWidth(min: centreColumnFloor, ideal: 720)`  (~line 1306-1316)
// Maugham/Compiler/CompilerEnvironment+Project.swift
pinnedListing: { docId in PinnedReferenceResolver.pins(...).map(Self.pinnedListingLine) }   // ~line 324; pinnedListingLine(_:) -> String ~line 381
// Maugham/Views/ResearchNotePreviewPane.swift
private static func expandParagraph(_ lines: [String], noteDir: URL) -> [Block]   // joins buffer with " " → attributedParagraph(joined)
private static func attributedParagraph(_ joined: String) -> Block               // AttributedString(markdown: joined), default options
// Tests
MaughamTests/PinnedReferencesTests.swift (fixture: research()/index()/scene()/pins(links:scene:scraps:docId:))
MaughamTests/ReferencesPaneTests.swift (mounted shelf tests + assembly census + planted offender)
MaughamTests/AssistantColumnTests.swift (width tests at lines ~114-149 die with the width; Escape/persona tests survive)
MaughamTests/DetailColumnWidthTests.swift (DetailColumnProbe {mounted, pane, visibility, width}; private DetailColumnHarness = a 3-column NavigationSplitView mirroring ProjectWindow's; mount/pump/settle helpers)
MaughamTests/Canvas/CanvasCollapseTests.swift (pure decision)
MaughamTests/ResearchNotePreviewParseTests.swift
MaughamTests/CompilerPromptTests.swift, CompilerRunCommandTests.swift, DiagnosticsPaneTests.swift (read pinnedListing)
```

---

### Task 1: The sectioned projection

**Files:** Modify `Maugham/Compiler/PinnedReferences.swift`, `Maugham/Compiler/PinnedReferenceResolver.swift`, `Maugham/Canvas/Promotion.swift` (visibility of `readingOrder`/`regionTitle` only). Test `MaughamTests/PinnedReferencesTests.swift`.

**Produces:**
```
struct PinnedSection: Equatable, Sendable { let title: String?; let references: [PinnedReference] }
struct PinnedShelf: Equatable, Sendable {
  let sections: [PinnedSection]
  var references: [PinnedReference]     // flat, section order, deduplicated on id — the old return value
  static let looseCardsTitle = "Cards"
}
PinnedReferences.pinned(forDocId:links:derived:scene:scraps:items:) -> PinnedShelf   // `derived: [String]` — research asset ids from derivedResearchItems
```
`derived` sits beside `links` as a required parameter (a caller that forgot it would silently short every Collection, the same reason `scraps` is required today).

**Contract (spec §2):** sections in order — (1) untitled: `links` then `derived`, manifest order, one section; (2) one titled section per region with `boundPieceID == docId`, regions ordered by `regionTitle` then `id.raw`; a region whose `promotedItemID` resolves through `items.entry(of:)` contributes exactly that pin and none of its residents; otherwise its residents in `Promotion.readingOrder`, resolved as today (unresolvable dropped); (3) titled `PinnedShelf.looseCardsTitle`: nodes with `boundPieceID == docId` not already taken, reading order, omitted when empty. Dedup on id across the whole shelf, first wins; an empty titled section (everything deduped away or dropped) is omitted. `scene == nil` → section (1) only.

- [ ] Read the spec's §2 and the existing `PinnedReferencesTests` fixture. Widen the fixture's `pins(...)` helper to take `derived: [String] = []` and return `PinnedShelf`; existing tests that assert a flat list read `.references` and must stay green unmodified in their assertions **except** `test_linkedComeFirstInManifestOrderThenTheCanvasSetByTitle` and `test_theCanvasOrderTiebreaksOnIdSoTwoEmptyScrapsDoNotSwap`, which asserted the alphabetical order the spec retires — rewrite them as reading-order tests (place scrap B above scrap A by `origin.y`; assert B first).
- [ ] Write the new tests, red first: a derived id pins (Collection shape — no link, id in `derived`); linked-then-derived order; a derived id already linked lands once; a bound region yields a section titled with its label; two bound regions sort by label then id; a promoted region whose `promotedItemID` is `"res-note"` yields one `.research("res-note")` pin under the region's title and no scrap pins; a promoted region whose `promotedItemID` is `"gone"` falls back to its residents; a card resident in two bound regions appears in the first section only; a self-bound card outside any bound region lands under `"Cards"`; `"Cards"` is absent when empty; `.references` equals the sections' concatenation minus duplicates; `scene: nil` yields one section.
- [ ] Make `Promotion.readingOrder` and `Promotion.regionTitle` `static` internal (drop `private`). They are not restated.
- [ ] Implement. Keep `pinned` pure; keep the dedup closure shape (`take`).
- [ ] `PinnedReferenceResolver.pins` passes `derived: store.derivedResearchItems(forDocumentId: docId).map(\.id)` and returns `PinnedShelf`. Fix the two callers to compile against the shelf minimally: `ReferencesPaneHost` uses `.references` for now (Task 2 replaces it); `CompilerEnvironment+Project` uses `.references` for now (Task 3 replaces it).
- [ ] Run `swift`-side: `xcodebuild … -only-testing:MaughamTests/PinnedReferencesTests -only-testing:MaughamTests/ReferencesPaneTests` (raw invocation; no gate). Green. The assembly census still names one file.
- [ ] Commit: `feat(references): the pinned projection is sectioned and knows what a region became`.

### Task 2: The shelf draws its sections

**Files:** Modify `Maugham/Views/ReferencesPane.swift`. Test `MaughamTests/ReferencesPaneTests.swift`.

**Produces:** `ReferencesPane(sections: [Section], …)` where `ReferencesPane.Section: Identifiable { let title: String?; let rows: [Row]; id }` (id = title ?? "" + first row id, or an index — stable across recompute, never minted). `static func sections(for shelf: PinnedShelf, in items: CanvasItemIndex) -> [Section]` wraps the existing `rows(for:in:)`. Remove the `rows:` initializer.

**Contract:** a titled section draws a caption header row (`.font(.caption)`, `.foregroundStyle(.secondary)`, uppercase not required) with `accessibilityLabel` = the title; untitled sections draw none; the empty state is unchanged; the studying/inert behaviour per row is unchanged; `ReferencesPaneHost` builds sections in its `.task`, never in `body` (tripwire 4).

- [ ] Tests red first: `sections(for:in:)` preserves shelf order and titles; a mounted shelf with one untitled and one titled section exposes exactly one header string (use the file's `allStrings(in:)` helper); the existing mounted click tests still promote.
- [ ] Implement; delete `rows(for:)`'s public surface only if nothing else calls it (grep).
- [ ] Run `ReferencesPaneTests` + `AssistantColumnTests`. Green.
- [ ] Commit: `feat(references): the shelf groups pins under the region they came from`.

### Task 3: The briefing carries the same grouping

**Files:** Modify `Maugham/Compiler/CompilerEnvironment+Project.swift`. Test: whichever of `CompilerPromptTests`/`CompilerRunCommandTests`/`DiagnosticsPaneTests` asserts listing lines (grep `pinnedListing`), plus a new unit on a static `pinnedListingLines(_ shelf: PinnedShelf) -> [String]`.

**Contract:** one line per pin exactly as `pinnedListingLine` writes today, preceded by `## <title>` for each titled section; untitled sections emit no header. `CompilerPrompt.listingSections` is unchanged (it takes lines).

- [ ] Test red: a shelf with an untitled section (1 pin) and a titled section "Act II fog" (1 pin) yields `[line, "## Act II fog", line]`.
- [ ] Implement `pinnedListingLines(_:)` as a static beside `pinnedListingLine`; the closure maps the shelf through it.
- [ ] Run the three compiler test files. Green.
- [ ] Commit: `feat(compiler): the briefing lists pins under their region`.

### Task 4: A line break inside a paragraph renders as one

**Files:** Modify `Maugham/Views/ResearchNotePreviewPane.swift` (`expandParagraph`, `attributedParagraph`, `markdownAttr`). Test `MaughamTests/ResearchNotePreviewParseTests.swift`.

**Symptom:** `expandParagraph` joins a paragraph's lines with `" "` before parsing; every single newline the writer typed inside a scrap is lost when the promoted note is read.

**Contract:** lines join with `"\n"`; `attributedParagraph` and `markdownAttr` parse with `AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)`; the paragraph's rendered string contains the newline; `"a\n\nb"` still yields two paragraphs; `*a\nb*` still resolves emphasis across the break (assert the run has `.inlinePresentationIntent` containing `.emphasized`); solo-image lines still split the paragraph; headings/lists/quotes/tables unchanged (existing tests).

- [ ] Tests red first (the join test is the disable-experiment witness).
- [ ] Implement. Verify `.inlineOnlyPreservingWhitespace` does not swallow the list/quote arms — those parse elsewhere (`markdownAttr` callers); if a caller depended on whitespace collapse, say so in the commit body.
- [ ] Run `ResearchNotePreviewParseTests` + `AssistantColumnTests`. Green. Disable experiment: revert the join, the newline test goes red, restore.
- [ ] Commit: `fix(research): a line break inside a note's paragraph renders as one`.

### Task 5: The study column takes the right column

**Files:** Modify `Maugham/Views/ProjectWindow.swift` (`detailColumn`, the centre-column modifier at ~1306-1316, `assistant` restore at ~3586, the `.onChange` chain), `Maugham/Views/AssistantColumn.swift` (`AssistantColumnModel.width` gone; `AssistantColumnModifier` inserts no view), `Maugham/Stores/UIState.swift` (width field, default, range, clamp deleted; decoder tolerant of the old key). Tests: `MaughamTests/AssistantColumnTests.swift` (delete the width tests ~114-149; re-point `test_nothingStudiedIsNoColumn`, `test_aStudiedReferenceMountsTheColumn`, `test_theColumnGoesWithTheChrome` at the new arm), a new `MaughamTests/StudyColumnMountTests.swift`.

**Contract (spec §3):**
- `detailColumn`: when `AssistantColumn.isPresented(studied: assistant.studied, persona: persona, isNoChromeOn: isNoChromeOn)` → `HStack { detailResizeHandle; AssistantColumn(...) }` at the same `navigationSplitViewColumnWidth(effectiveDetailColumnWidth(...))` as the pane; else the existing pane; the hidden arm is untouched by this task (Task 6 owns it).
- **Study reveals:** studying a pin while `showInspector == false` sets it true. Do this in the window's `.onChange(of: assistant.studied?.id)` (nil → non-nil ⇒ `showInspector = true`), not inside the model — the model must stay window-free.
- **Newest act wins:** `.onChange(of: detailSegment)` → `assistant.dismiss()`; `.onChange(of: selectedSubject)` → `assistant.dismiss()`; `activeDocId` dismiss stays. A dismiss on a segment change must not fire when the *segment write* was the picker's own no-op snap (see `DetailPaneToggle.onChange(of: segment)` — it writes only when snapped == newValue); assert with a test that studying then re-selecting the SAME segment value keeps the study (SwiftUI does not fire `onChange` on equal values, so this is a guard on the implementation's spelling, not a behaviour to build).
- `AssistantColumnModifier` keeps only the Escape sync chain and the dismiss chain; it inserts no view and has no handle. If the chain reads better on `detailColumn`'s host, fold it there and delete the type — the plan does not decide.
- The comment at ~1310 about squeezing goes; `navigationSplitViewColumnWidth(min: centreColumnFloor, ideal: 720)` stays.
- `UIState`: delete `assistantColumnWidth`, `defaultAssistantColumnWidth`, `assistantColumnWidthRange`, `clampedAssistantColumnWidth`; the custom `init(from:)` must not reference them; an existing test that a file WITH the key still decodes (`test_aFileWithoutTheKeyDecodesToTheDefault`'s inverse) — keep one test asserting a `ui-state.json` carrying `"assistantColumnWidth": 400` decodes.
- **Mounted test** (`StudyColumnMountTests`, on the `StatementMountFixture`/`AssistantColumnTests` hosting pattern — read both before writing): mount a `ProjectWindow`-shaped harness is NOT required; mount the real thing only if a fixture already does (grep `ProjectWindow(` in MaughamTests). If none does, the measurement is on a `DetailColumnHarness`-style split view with a real `AssistantColumn` in the detail arm and a `GeometryReader`-reported centre width: study → the centre column's width is unchanged (±1pt) and the detail column shows `closeLabel`; close → the detail arm shows the pane again. Skip by name if the display cannot afford 980pt.

- [ ] Delete the width machinery first (compiler finds every reader); tests red.
- [ ] Implement the arm, the reveal, the dismiss chain. Re-point the three named tests. Write the mount test.
- [ ] Run `AssistantColumnTests`, `ReferencesPaneTests`, `DetailColumnWidthTests`, `StudyColumnMountTests`, `UserPreferencesTests`, and whatever asserts on `UIState` decoding (grep `assistantColumnWidth` in MaughamTests — must be zero hits after).
- [ ] **Release build** (`ProjectWindow.body` changed): `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`. Green.
- [ ] Commit: `feat(references): studying a pin takes the right column, not a fourth one`.

### Task 6: ⌘\ on the canvas gives the canvas the window

**Files:** Modify `Maugham/Views/ProjectWindow.swift` (`detailColumn`'s hidden arm; possibly `canvasCollapse`), `MaughamTests/DetailColumnWidthTests.swift` (harness + new test), `MaughamTests/Canvas/CanvasCollapseTests.swift` if the decision changes shape.

**Symptom (spec §5):** with `columnVisibility == .doubleColumn` and the detail arm rendering nothing, the split gives the content column its `ideal` (720) and the remainder to an empty detail column.

**Contract:** under the collapse, the content column's measured width equals the container width minus the split's divider (±2pt); under `.all` with the inspector hidden, the same (already true — assert it too, it is the control). Release restores three columns.

- [ ] **Reproduce first.** Add to `DetailColumnHarness` a `GeometryReader`-based centre-width reporter (`probe.noteCentreWidth`), then a test: `probe.mounted = false; probe.visibility = .doubleColumn; settle; XCTAssertEqual(centreWidth, containerWidth, accuracy: 2)`. It must be RED on the current tree. If it is green in the harness, the harness does not mirror production closely enough — diff it against `ProjectWindow.body`'s `NavigationSplitView` (the binder's `min/ideal`, the centre's `min/ideal`, the detail's spelling) until it reproduces. Do not proceed to a fix on a green reproduction.
- [ ] Fix candidate 1: in `detailColumn`, an `else` arm rendering `Color.clear.navigationSplitViewColumnWidth(0)` (mirror in the harness — the harness's `detailColumn` should call a shared `ProjectWindow.hiddenDetailColumn` static view so the two cannot drift; add it). Measure. If green, disable experiment, stop here.
- [ ] Fix candidate 2 (only if 1 fails): keep `.all`; drive the binder's width to 0 while collapsed via a state-dependent `navigationSplitViewColumnWidth`; `canvasCollapse` returns `.all` and a new `binderHidden: Bool`; `CanvasCollapseTests` moves with it (`test_theCollapsedVisibilityIsNotDetailOnly` stays true). Measure.
- [ ] Run `DetailColumnWidthTests`, `CanvasCollapseTests`, `PromotionCommandTests`, and the three `CanvasViewMounting*` classes (they collapse). Green.
- [ ] Commit: `fix(canvas): focus mode gives the canvas the whole window`.

### Task 7: Docs move with the code

**Files:** `docs/guide/right-pane.md` (§References mode: the column is the right column; sections; a promoted region shows its note), `docs/guide/compiler.md` (§"References, and what you can study"), `docs/roadmap.md` (new ✓ entry dated 2026-08-25; the M2 and M3 entries' "between binder and editor" get a parenthetical "— moved to the right column 2026-08-25"), `CLAUDE.md` (`Maugham/Compiler/` cell: the assistant column's placement; `Maugham/Canvas/` cell's `⌘\` sentence gains "the hidden detail arm holds zero width"), `Maugham/Views/AREA.md` and `Maugham/Compiler/AREA.md` (wherever the column's placement or the projection's inputs are described — grep "assistant column", "pinned"), the two amended specs (one line at the amended section pointing here), `docs/superpowers/specs/2026-08-25-…-design.md` status line.

- [ ] Grep the tree for "between binder and editor", "between the binder and the prose", "assistantColumnWidth", "fourth column", "alphabet" near "pinned"; fix every hit that is now false. Help describes what ships.
- [ ] `DocSyncTests` (if it gates guide↔shortcut claims) green.
- [ ] Commit: `docs: the references shelf and the study column`.

### Task 8: Whole-branch review and the gate

- [ ] Whole-branch review (spec + full diff), per `memory/feedback_whole_branch_review_earns_it.md`: name the seams — projection↔three readers; study-reveal↔canvas collapse (both write `showInspector`; a study in Author must not leak a collapse stash; ⌘\ in Author with a study up must hide it and keep it); research-subject reveal (`revealResearchColumn`) vs study dismiss on `selectedSubject` change — order of the two `onChange`s; `UIState` decode of old files.
- [ ] Fix what it finds in the same branch; each fix gets its pinned test.
- [ ] `./scripts/test.sh full`. Green, no skips beyond the display/lock skips-by-name. Record the xcresult path.
- [ ] Merge to `main` locally (no push — Denver smokes first). Update memory: a `project_milestone_references_shelf.md` file + `MEMORY.md` line.

## Self-review

- Spec §2 → Tasks 1–3. §3 → Task 5. §4 → Task 4. §5 → Task 6. §7 → Task 7. Whole-branch → Task 8.
- No placeholders: every task names its files, its contract, its red-first test, its run and its commit.
- Names used across tasks: `PinnedShelf`, `PinnedSection`, `PinnedShelf.references`, `PinnedShelf.looseCardsTitle`, `pinned(forDocId:links:derived:scene:scraps:items:)`, `ReferencesPane.Section`, `sections(for:in:)`, `pinnedListingLines(_:)`, `ProjectWindow.hiddenDetailColumn`, `probe.noteCentreWidth` — consistent above.
