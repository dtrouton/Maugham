# Splitting CanvasView's Input Handling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Maugham/Canvas/CanvasView.swift` (2,335 lines, issue #30 finding F7) sheds its input handling and its two helper passes into six small types, each in its own file, each readable alone:

| New type (file) | Moves out of `CanvasView` | Today |
|---|---|---|
| `CanvasLayoutPass` | `rebuildLayouts`, `measureScrap`, `remeasure` | :1010–1281 |
| `CanvasEditFocus` | `syncActiveEdit`, `commitActiveEdit`, `leaveTheOpenScrap` (the open scrap) | :1283–1381, :1575–1584 |
| `CanvasClickHandler` | `ClickTarget`, `clickTarget(at:)`, `handleClick` | :1383–1574 |
| `CanvasDragHandler` | `handleDrag`, `gestureName(for:)`, `pressStartsALine` | :1871–2334 |
| `CanvasDropHandler` | `handleDrop`, `handleCaptureDrop`, `handleExternalDrop` | :1586–1743 |
| `CanvasKeyHandler` | `deleteSelection`, `escapeAsksForTheWholeBoard` | :1745–1869 |

`CanvasView` keeps its stored inputs, every `@State`, `body`, the two editor gates, `mountedEditor`, `load()`, `bringArrivingResearchCardIntoView` and `rebuildHighlightAndTree`. Expected size afterwards: about 1,080 lines. The file is 73% comments today (1,711 of 2,335 lines), and this plan moves comments with their code without trimming them.

**Architecture — the decision.** Each new type is a `@MainActor struct`, not a `View`. `CanvasView` builds a fresh one **per call**, from a private computed property. The new type holds:
- a `Binding` (`$x`) for every `@State` it reads or writes;
- a `let` for every view input it reads (`model`, `subject`, `itemIndex`, `captureDrop`, …);
- the other helpers it calls (for example, the click handler holds a `CanvasEditFocus` and a `CanvasLayoutPass`).

It is never stored. Why this shape and not the others:
- **Extensions of `CanvasView`** share all of the view's state, so an agent must still load the whole view to change one handler. Plan 4 rejected this for the same reason.
- **A reference-type controller in `@State`** (`CanvasInputController`) would move `interaction`, `momentum` and `selectionWhenPressed` out of `@State`. `body` reads `interaction.pendingRegionDraw`, `interaction.pendingLine` and `momentum.isAtRest` to register redraw dependencies, so those reads would go through Observation instead. That is a second observable source beside `CanvasModel` (tripwire 6's shape). The controller would also need `subject` and `itemIndex` copied into it and kept current, which is the two-way sync tripwire 2 bans. Because it is a reference held across body passes, it is also exactly the frozen-value hazard tripwire 57 exists for.
- **Pure functions over one combined `inout` state struct** would mean folding many `@State` into one. Then a write to `lastKeystrokeAt` or `selectionWhenPressed` would invalidate `body`, which it does not today. That is a render-scheduling change, not a move.
- **Per-call structs over bindings** change nothing SwiftUI sees:
  - no `View` is added, and `body`'s tree is identical, so view identity holds and tripwire 27's layer order is untouched;
  - every `@State` stays where it is;
  - a binding writes the same storage the view writes, so nothing is synchronised (tripwire 2);
  - `CanvasEventView.updateNSView` re-assigns the input closures every pass, so a handler built inside one sees the latest view value, as the inline code does today;
  - `CanvasModel()` builds without a window (`CanvasDropTests` does it), so every handler can be tested windowless for the first time.

**Tripwire 57 stays complete under this shape.** The census walks only `CanvasView`'s own members and cannot see inside another type. But each helper is built inside a view computed property, so every value it receives is read in a member the walk does follow. The walk skips `$x` projections and argument labels, and it follows computed properties. A new census (Task 1) keeps the six types from being built anywhere else.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, XCTest.

**Spec:** issue #30 (F7, re-scoped 2026-10-20); the precedent is `docs/superpowers/plans/2026-10-18-foundations-plan4-projectwindow-split.md`.

## Global Constraints

- **No behaviour change.** Every moved function moves **verbatim**: same statements, same order, same comments. Only these change:
  - a read or write of a `@State` `x` becomes the binding's wrapped value. With `@Binding var x` the spelling is identical;
  - a call to a moved sibling gains its receiver (`rebuildLayouts()` → `layoutPass.rebuildLayouts()`);
  - `private` becomes internal where `CanvasView` calls the function;
  - a doc comment that names the old home (`CanvasView.handleClick`) names the new one.
  - Keep the function names (`handleClick`, `handleDrag`, `deleteSelection`, `rebuildLayouts`, …): comments across `Maugham/Canvas/` and the area guide cite them by name.
  - Reviewers check with `git diff --color-moved=dimmed-zebra --color-moved-ws=allow-indentation-change`. Every moved line must show as moved.
- **`CanvasView`'s surface does not change.** No stored property is added, removed or retyped, so the memberwise init, `ProjectWindow`'s call site and the ~70 test hosts are untouched. The new computed properties do not enter the memberwise init.
- **A helper takes a `Binding` for every `@State` it touches, even read-only ones.** It never copies `@State` into a `let`, so a read after a sibling call (for example `layouts` after `rebuildLayouts()`) is never a stale snapshot. View inputs (`subject`, `itemIndex`, `captureDrop`, `assetIngest`, `selectTheProjectRow`) are `let`s: they cannot change during a call.
- **Never `$sceneRevision`.** The view's copy is written only by the mirror in `body` (tripwire 30). A helper bumps the structural counter through `model.bumpSceneRevision()`, as today.
- **No `Binding(get:set:)` with logic in production** (tripwire 3). Pass `$x` projections only. Tests may build boxes.
- **`CanvasView.swift`'s five header contracts hold.**
  - `load()` stays the declaration right after `mountedEditor`.
  - `mountedEditorNodeID` stays after `body`.
  - The two editor gates keep their blank-line shape.
  - No comment names the accessibility element-list builder or the two hide modifiers.
  - The new computed properties go in one `// MARK: - Helpers, built per call` block at the **end** of the struct, after `rebuildHighlightAndTree`.
- **`load()`, `rebuildHighlightAndTree` and `bringArrivingResearchCardIntoView` stay on the view.**
  - Tripwire 57's census requires `CanvasView.load()`.
  - Header contract 2 pins `load()`'s position.
  - The other two are counted in `CanvasView.swift` by `CanvasHighlightTests` and `CanvasCompositionTests`, and are seven code lines between them.
- **Censuses stay as strong as before.** Most canvas censuses key by FILE (`"Maugham/Canvas/CanvasView.swift"`), not by type. Task 0 lists them. Task 1 introduces one named list of the files that hold the canvas surface's code, `CanvasSourceCensus.surfaceFiles`. A census that counts or bans a token over the view's code reads the whole surface. A census that slices `body` or checks order stays on `CanvasView.swift`, because that code does not move. Each retargeted census keeps or gains a planted control.
- **Docs travel with each file.**
  - Every new file goes on the Canvas `AREA.md` Map in the task that adds it (`DocBudgetTests.test_everyAreaGuidesMapNamesEveryFileInItsFolder`).
  - The guide is at 7,992 words against an 8,000 hard cap. Task 1 makes room; each later task raises `DocBudgetTests.wordCeilings` by its row, with a reason.
  - Do not edit `CLAUDE.md`. Its rows 32 and 57 stay true as worded.
- **Gates, after every task:**
  - `./gen.sh`, because every task from 2 to 6 adds a file;
  - `./scripts/test.sh only` with the task's named classes **plus the three mounted classes** `CanvasViewMountingSurfaceTests CanvasViewMountingEditingTests CanvasViewMountingRegionTests`. The fast gate skips these, and they are this refactor's behavioural safety net;
  - `./scripts/test.sh core` when the area guide or `DocBudgetTests` changed;
  - `./scripts/test.sh` (fast);
  - a Release build after any task that edits `body`: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`, run from a script file, only when `pgrep -x xcodebuild` is empty.
  - Never use raw `xcodebuild test` or a bare `swift test`. Never `git push`. Reviewers do not build while a gate runs.
- **Branch** `refactor/canvasview-split`, worktree `/Users/denver/src/testing/Maugham-wt/canvasview-split`, off main `67bde5a6`.

## Review Focus

1. **A `@State` read through a `let` snapshot instead of a binding**, which goes stale within one call. *Pinned by:* reviewers checking each helper's init against the constraint above, and by the mounted family (new-scrap click, resize, undo with a focused scrap).
2. **A moved statement reordered or dropped.** *Pinned by:* the colour-moved diff, where every moved line must show as moved. Every task's report pastes the `--stat` and names any line that is not a pure move.
3. **Tripwire 57 going blind:** a helper built outside a view member, or handed a frozen view value. *Pinned by:* Task 1's construction census, Task 2's retargeted #57 replay, and a new planted case (a helper built with a forbidden value fires).
4. **Tripwire 32's exemption widening past the surface.** Another column builds a surface helper and reaches the inside verbs through it. *Pinned by:* Task 1's census (the surface types are built in `CanvasView.swift` only), with a planted `RegionInspector` offender.
5. **A file-keyed census that went vacuous** because its token moved files. *Pinned by:* Task 0's table, worked through row by row. Each row is struck off by the task that moves its token, and the report names the row.
6. **The redraw counters.** `revision` must still tick on every path that ticks it today, and `sceneRevision` must keep exactly one writer. *Pinned by:* the mounted family, plus Task 1's surface-wide `sceneRevision` census.

---

### Task 0: The census of what pins CanvasView's layout (read-only)

**Files:** none changed. Work from this table and correct it against the branch head. Re-run the greps below, and add any row they find that the table misses.

```
grep -rn 'CanvasView\.swift\|type:CanvasView' MaughamTests Packages/MaughamCore/Tests
grep -rn 'CanvasView\.\(pressStartsALine\|handle\|delete\|rebuild\|sync\|commit\|leave\|remeasure\|escape\)' MaughamTests
grep -rn 'contentsOfDirectory\|enumerator(at' MaughamTests/Canvas   # directory-wide scans
```

| # | Test (file) | Reads | Keyed by | Touched by | Action |
|---|---|---|---|---|---|
| A | `TripwireGrepTests.test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly` | skips `theCanvasSurface = "CanvasView.swift"` by **file name**, then censuses inside verbs elsewhere | file | Tasks 2–5 (each helper uses `withScene`/`beginGesture`/…) | Task 1: the skip becomes `CanvasSourceCensus.surfaceFiles` |
| B | `…test_theCanvasSurfaceItselfUsesTheInsideVerbs` | `.mutate(` present and `mutateFromInspector` absent **in `CanvasView.swift`** | file | Task 5 (`deleteSelection` holds the only `.mutate(`) | Task 1: read the whole surface |
| C | `…test_theCanvasLoadClosuresReadNoChangingViewValue` + `…FiresOnAPlantedOffender` | walks `load()`'s closures through `CanvasView`'s members; `reachedMembers` must contain `rebuildLayouts`; #57 replay swaps `index: model.itemIndex,` in `CanvasView.swift` | type-walk within the view; replay by file | Task 2 | Task 2: re-point (see there). `canvasViewExtensionSources` skips `CanvasView.swift` by name; keep that one file constant |
| D | `TripwireGrepTests.test_theCanvasExternalDropUsesTheProviderRouteAndNeverAUrlDestination`, `…StringDropDestinationIsMountedBeforeTheProviderDrop` (`bothDropKinds`) | the two drop **modifiers** | file | none: the modifiers stay on `body` | verify green after Task 6 |
| E | `CanvasEditGateTests.test_theCanvasAsksTheGateBeforeEachAct` | gate-before-act order inside `func handleClick(` / `handleDrag(` / `deleteSelection(` / `handleDrop(` / `handleExternalDrop(`, sliced from `CanvasView.swift`; ban `guard clickCount >= 2` | file + function name | Tasks 3–6 | Task 1: slice each function with `SourceTree.declaration(named:under: "Maugham/Canvas")`, which throws on zero or two matches. Run the ban over the surface |
| F | `CanvasCompositionTests` (body slice, gate declarations, `mountedEditor`→`load()` slice, raw hide-modifier scan) | `CanvasView.swift` | file | none: this code stays | unchanged |
| G | `CanvasCompositionTests` counts/bans: `bringArrivingResearchCardIntoView` ×2, `straighten.isLevel(` ×1, `items: itemPresentation` ×2, `ScrapEditorGeometry.viewPoint` present, `CanvasGroundPalette.wash(fromHex: paletteSwatchHexes())` present | `CanvasView.swift` | file | Tasks 2–4 could add a second `isLevel(` or `itemPresentation` consumer | Task 1: counts and bans read the surface. "Present" checks stay on the view |
| H | `CanvasAccessibilityTests`: `.accessibilityChildren` present, element-list build after `.onChange(of: sceneRevision` (raw first occurrence), ban `.onChange(of: revision`, extracted `.equatable()` children | `CanvasView.swift` | file | none | the ban reads the surface (Task 1); the rest are unchanged |
| I | `CanvasHighlightTests`: draw-closure slice, `.onChange` triggers present, ban `.onChange(of: revision`, `CanvasHighlight.resolve` ×1, `rebuildHighlightAndTree()` ×4 | `CanvasView.swift` | file | a helper could add a second resolve | Task 1: counts and bans read the surface |
| J | `CanvasBoundPieceTests`: `pieceTitles: pieceTitles` ×2, the rename `.onChange` present, ban `CanvasPieceTitles.over(` | `CanvasView.swift` | file | same | Task 1: count and ban read the surface |
| K | `CanvasLiveSeamTests.test_theExternalChangeHookHasAProductionCaller` (`assigners(of:)` == `["CanvasView.swift"]`) and `test_theCensusFiresOnAPlantedRemoval` (literal `model.onSceneChangedExternally = { rebuildLayouts(bumpsStructuralCounter: false) }`) | `CanvasView.swift` | file | Task 2 changes the literal | Task 2: update the literal. Its "deletion patched nothing" arm fails loudly if you forget |
| L | `PromotionCommandTests` wiring census entry `("Maugham/Canvas/CanvasView.swift", [".dropDestination(for: String.self)", "CanvasDrop.apply(", "CanvasExternalDrop.ingest(", "CanvasExternalDrop.apply(", "CanvasDrop.payload(", "captureDrop.send("])` and its `missingTokens` falsifications at about :705, :716 and :847 | file path (the helper also takes `type:` keys) | file | Task 6 | Task 6: split the entry. `.dropDestination` stays on `CanvasView.swift`, and the five landing tokens go to `type:CanvasDropHandler`. Re-point the falsifications to match |
| M | `CanvasLineGestureTests` (nine calls to `CanvasView.pressStartsALine`) | API | compiler | Task 3 | Task 3: `CanvasDragHandler.pressStartsALine` |
| N | `CanvasRendererTests.test_everyScrapLayoutInProductionNamesTheCardInk` (directory walk: `ScrapLayout(` followed within 9 lines, same file, by `textColor: CanvasRenderer.cardInk`) | `Maugham/Canvas/` | directory | Task 2 moves `measureScrap`'s `ScrapLayout(` | verbatim move keeps it green |
| O | `DocBudgetTests` (Core): every file on the Map, Canvas word ceiling 7,992 (hard cap 8,000), backticked paths exist | `Maugham/Canvas/AREA.md` | file | Tasks 1–7 | Task 1 frees words; each task adds its row |
| P | Unaffected; confirm only: `CanvasRendererTests` rotation and raster bans, `CompositionTests.test_theCanvasRegistersUndoInExactlyOnePlace` (all directory-wide), `RegionBindingTests` `viewSites(of: "CanvasView(")` (the construction site, unchanged), tripwire 33 allow-lists (keyed by test, and no test changes its clicks) | — | — | — | — |

- [ ] **Step 1:** Run the greps, then correct and extend the table in the task report. Do not edit the plan file.
- [ ] **Step 2:** Run the baseline: `./scripts/test.sh only` over every class in the table plus the three mounted classes, and `./scripts/test.sh core`. Record green, the times, and `wc -l` plus the comment-line count of `CanvasView.swift`.
- [ ] **Step 3:** No commit. The report is the deliverable.

---

### Task 1: One surface list; file-keyed censuses read it; room on the Map

**Files:**
- Modify `MaughamTests/Canvas/CanvasSourceCensus.swift`
- Modify `MaughamTests/TripwireGrepTests.swift` (tripwire 32's MARK)
- Modify `MaughamTests/Canvas/CanvasEditGateTests.swift`, `CanvasCompositionTests.swift`, `CanvasAccessibilityTests.swift`, `CanvasHighlightTests.swift`, `CanvasBoundPieceTests.swift`
- Modify `Maugham/Canvas/AREA.md`, `docs/history/canvas.md`
- Modify `Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`

**Contract:**

```swift
// CanvasSourceCensus
/// The files that hold CanvasView's own code — the view and the helpers it builds per call.
/// Grows by one entry in each task that moves code out. Order: CanvasView.swift first.
static let surfaceFiles: [String]                     // ["CanvasView.swift"] after this task
static func surfaceSource() throws -> String          // concatenated; throws if a listed file is missing
```

- **Tripwire 32 (rows A, B).**
  - `canvasBracketCensus` skips `surfaceFiles`, not one name. Keep a separate `theCanvasViewFile = "CanvasView.swift"` for tripwire 57's extension scan.
  - The converse test reads `surfaceSource()`: `.mutate(` is present somewhere on the surface, and `mutateFromInspector` is in no surface file. Check per file, so the message can name the offender.
- **New: `test_theCanvasSurfaceHelpersAreBuiltByCanvasViewOnly`.**
  - For every type declared in a surface file other than `CanvasView.swift`, `TypeName(` appears in production code (comments stripped) only in `CanvasView.swift` and in the type's own file. Static calls (`TypeName.`) are fine.
  - With today's list this is vacuous, so a planted companion must prove it fires: in a temporary tree, put a `CanvasKeyHandler` declared in a listed file, plus a `RegionInspector.swift` that builds one.
  - The message names tripwire 32: a helper built from another column reaches the inside verbs.
- **New: `sceneRevision` keeps one writer.** Across `surfaceSource()`, there is exactly one `sceneRevision += 1` and zero `$sceneRevision`. Add a planted control. Put it in `CanvasAccessibilityTests` beside its tripwire-30 neighbours.
- **Rows E, G, H, I, J.**
  - The count and ban assertions read `surfaceSource()` (stripping comments where they did before).
  - The order, slice and "present" assertions keep reading `CanvasView.swift`.
  - `CanvasEditGateTests` slices each function with `SourceTree.declaration(named:under: "Maugham/Canvas")`. Keep `gate(_:runsBefore:)`'s rule. Add a control showing that a declaration missing from the tree throws.
- **Room on the Map.**
  - Six Map rows (about 20 words each) and one new Rules bullet (Task 7, about 45 words) need about 170 words. The guide has 8 to spare.
  - Move at least 200 words of **narrative-only** clauses (why and history, never a rule sentence, never a test citation) from `Maugham/Canvas/AREA.md` to the matching section of `docs/history/canvas.md`, as plan 5 did.
  - Lower the ceiling to the new actual, with a reason ("canvasview-split T1: narrative to history, room for six Map rows").
  - List each moved clause in the report.

- [ ] **Step 1:** Write the plants first, and watch each new census and each planted companion fire.
- [ ] **Step 2:** Implement. Run `./scripts/test.sh only TripwireGrepTests CanvasEditGateTests CanvasCompositionTests CanvasAccessibilityTests CanvasHighlightTests CanvasBoundPieceTests`, then `./scripts/test.sh core`, then the fast gate.
- [ ] **Step 3:** Commit: `test(canvas): the canvas surface is one named file list; file-keyed censuses read it; room on the Map`

---

### Task 2: `CanvasLayoutPass` and `CanvasEditFocus` — the two helpers `load()` reaches

**Files:**
- Create `Maugham/Canvas/CanvasLayoutPass.swift` and `Maugham/Canvas/CanvasEditFocus.swift`
- Create `MaughamTests/Canvas/CanvasSurfaceHelperTests.swift` (shared by Tasks 2–6)
- Modify `CanvasView.swift`, `TripwireGrepTests.swift` (tripwire 57), `CanvasLiveSeamTests.swift`, `CanvasSourceCensus.swift`, `AREA.md`, `DocBudgetTests.swift`

**Interfaces:**

```swift
@MainActor struct CanvasLayoutPass {
    let model: CanvasModel
    let itemIndex: CanvasItemIndex          // the view passes `model.itemIndex` — never its own `itemIndex` (#57)
    let thumbnails: CanvasThumbnails
    let projectRoot: URL
    @Binding var layouts: [CanvasNodeID: ScrapLayout]
    @Binding var itemPresentation: CanvasItemPresentation
    @Binding var thumbnailServiceTicket: Int
    @Binding var revision: Int
    func rebuildLayouts(bumpsStructuralCounter: Bool = true, bumpsThumbnailTicket: Bool = true)
    func remeasure(_ id: CanvasNodeID)
    // measureScrap stays private
}
@MainActor struct CanvasEditFocus {
    let model: CanvasModel
    @Binding var editingNodeID: CanvasNodeID?
    @Binding var caretIndex: Int?
    @Binding var straighten: CanvasFocusStraighten
    @Binding var lastKeystrokeAt: Date?
    @Binding var layouts: [CanvasNodeID: ScrapLayout]
    @Binding var revision: Int
    func syncActiveEdit(fromKeystroke: Bool = false)
    func commitActiveEdit()
    func leaveTheOpenScrap()
}
// CanvasView, in the end-of-struct block:
private var layoutPass: CanvasLayoutPass { CanvasLayoutPass(model: model, itemIndex: model.itemIndex, …, layouts: $layouts, …) }
private var editFocus: CanvasEditFocus { … }
```

Check every field against the moved code before writing it. The lists above are from a read of main; the code wins.

**Contract:**
- Move verbatim. Every caller in the view gains a receiver:
  - `load()`'s four hooks;
  - the `.task(id:)`, the item-index `.onChange` and `.onDisappear`;
  - `mountedEditor`'s `onTextChanged`;
  - `handleClick`, `deleteSelection` and `handleDrag`, which are still on the view until Tasks 3–5.
- In `CanvasItemPresentation.resolve(…, index: itemIndex, …)`, `itemIndex` is the pass's own field.
- **Tripwire 57 (row C).**
  - `reachedMembers` must contain `layoutPass` instead of `rebuildLayouts`.
  - The #57 replay swaps `itemIndex: model.itemIndex,` for `itemIndex: itemIndex,` in `CanvasView.swift`. It expects `onSceneChangedExternally → layoutPass → itemIndex` and `onSceneReplacedByUndo → layoutPass → itemIndex`.
  - Add a planted case: `private var pass: P { P(index: itemIndex, layouts: $layouts) }`, reached from a hook, fires on `itemIndex` and not on `$layouts`.
  - Update `docs/tripwires.md` row 57's enforcement text. The view's helpers are built in view computed properties, so the walk sees their inputs; the Task 1 census keeps them built nowhere else. Name the new planted case.
- Row K: update `CanvasLiveSeamTests`' literal.
- `surfaceFiles` gains both files. The Map gains both rows: `CanvasLayoutPass.swift` under Drawing and geometry, and `CanvasEditFocus.swift` beside the mounted editor. Raise the ceiling with a reason.
- **Tests (windowless, `CanvasSurfaceHelperTests`).** Build each helper over `CanvasModel()` with boxed bindings. Pin only what a mounted test already pins, and name that test in a comment:
  - `rebuildLayouts` heals a node with no `cachedHeight`;
  - `rebuildLayouts` drops a layout whose node is gone;
  - `syncActiveEdit` with no open scrap changes nothing;
  - `commitActiveEdit` clears `lastKeystrokeAt`.

- [ ] **Step 1:** Write the helper tests against the new names (red: they do not compile), then move the code. Run `./gen.sh`.
- [ ] **Step 2:** Run `./scripts/test.sh only CanvasSurfaceHelperTests TripwireGrepTests CanvasLiveSeamTests CanvasRendererTests CanvasCompositionTests CanvasThumbnailTests CanvasScrapMeasureTests` plus the three mounted classes. Then run core, the fast gate and the Release build.
- [ ] **Step 3:** Commit: `refactor(canvas): the layout pass and the open scrap are helpers CanvasView builds per call; tripwire 57 sees their inputs`

---

### Task 3: `CanvasDragHandler`

**Files:**
- Create `Maugham/Canvas/CanvasDragHandler.swift`
- Modify `CanvasView.swift`, `CanvasLineGestureTests.swift`, `CanvasSurfaceHelperTests.swift`, `CanvasSourceCensus.swift`, `AREA.md`, `DocBudgetTests.swift`

**Interface:**

```swift
@MainActor struct CanvasDragHandler {
    let model: CanvasModel
    let subject: CanvasSubject
    let layoutPass: CanvasLayoutPass
    @Binding var interaction: CanvasInteraction
    @Binding var momentum: CanvasMomentum
    @Binding var revision: Int
    @Binding var editingNodeID: CanvasNodeID?             // read only, still a binding
    @Binding var selectionWhenPressed: CanvasSelection?   // read only, still a binding
    func handleDrag(at contentPoint: CGPoint, phase: CanvasDragPhase, shiftHeld: Bool, timestamp: TimeInterval)
    private static func gestureName(for kind: CanvasInteraction.Kind?) -> String
    nonisolated static func pressStartsALine(at:selection:in:shiftHeld:) -> Bool
}
```

**Contract:**
- Move the whole `// MARK: - Drags` section, including its intro comment.
- `body`'s `onDrag` builds the handler and calls `handleDrag`.
- Row M: retarget `CanvasLineGestureTests` to `CanvasDragHandler.pressStartsALine`.
- `surfaceFiles`, the Map row (under Input) and the ceiling, as before.
- **Tests:**
  - `.began` while a scrap is open leaves `interaction` inactive and opens no gesture;
  - `.began` on a read-only canvas does the same;
  - `gestureName` is not reachable (private), so do not test it.

- [ ] **Step 1:** Tests, the move, then `./gen.sh`.
- [ ] **Step 2:** Run `./scripts/test.sh only CanvasSurfaceHelperTests CanvasLineGestureTests CanvasEditGateTests TripwireGrepTests CanvasRegionInteractionTests CanvasMembershipTests` plus the three mounted classes. Then core, the fast gate and the Release build.
- [ ] **Step 3:** Commit: `refactor(canvas): the drag state machine's wiring lives in CanvasDragHandler`

---

### Task 4: `CanvasClickHandler`

**Files:**
- Create `Maugham/Canvas/CanvasClickHandler.swift`
- Modify `CanvasView.swift`, `CanvasSurfaceHelperTests.swift`, `CanvasSourceCensus.swift`, `AREA.md`, `DocBudgetTests.swift`

**Interface:**

```swift
@MainActor struct CanvasClickHandler {
    let model: CanvasModel
    let editFocus: CanvasEditFocus
    let layoutPass: CanvasLayoutPass
    @Binding var selectionWhenPressed: CanvasSelection?
    @Binding var editingNodeID: CanvasNodeID?
    @Binding var caretIndex: Int?
    @Binding var lastKeystrokeAt: Date?
    @Binding var straighten: CanvasFocusStraighten
    @Binding var layouts: [CanvasNodeID: ScrapLayout]
    @Binding var revision: Int
    func handleClick(at contentPoint: CGPoint, clickCount: Int)
    // ClickTarget and clickTarget(at:) stay private
}
```

**Contract:**
- `selectionWhenPressed` is still written at the head of `handleClick`, before anything moves the selection. It stays `@State` on the view: written here, read by the drag handler.
- The two arms that open a scrap keep their inline statements. Do not fold them into an `editFocus.enter` (that would be a logic change, not a move).
- **Tests:**
  - a single click on empty canvas selects nothing and leaves no scrap open;
  - a double-click on empty canvas mints one scrap, opens it with `caretIndex == 0`, and records `selectionWhenPressed` from before the click.

- [ ] **Step 1:** Tests, the move, then `./gen.sh`.
- [ ] **Step 2:** Run `./scripts/test.sh only CanvasSurfaceHelperTests CanvasEditGateTests CanvasCompositionTests TripwireGrepTests CanvasLineGestureTests` plus the three mounted classes. Then core, the fast gate and the Release build.
- [ ] **Step 3:** Commit: `refactor(canvas): click routing lives in CanvasClickHandler; selectionWhenPressed is still captured first`

---

### Task 5: `CanvasKeyHandler` — Delete and Escape

**Files:**
- Create `Maugham/Canvas/CanvasKeyHandler.swift`
- Modify `CanvasView.swift`, `CanvasSurfaceHelperTests.swift`, `CanvasSourceCensus.swift`, `AREA.md`, `DocBudgetTests.swift`, `docs/tripwires.md` (row 32's wording)

**Interface:**

```swift
@MainActor struct CanvasKeyHandler {
    let model: CanvasModel
    let subject: CanvasSubject
    let selectTheProjectRow: () -> Void
    let editFocus: CanvasEditFocus
    let layoutPass: CanvasLayoutPass
    @Binding var editingNodeID: CanvasNodeID?
    func deleteSelection() -> Bool
    func escapeAsksForTheWholeBoard() -> Bool
}
```

**Contract:**
- `body`'s `onDeleteKey` and `onEscape` call through the handler. Escape still reaches the arbiter through the same closure, and `dimsTheBoard: subject.dimsTheBoard` is unchanged.
- Row B is now live: the only `.mutate(` moves here, and Task 1's surface-wide converse must stay green. Paste its output.
- `docs/tripwires.md` row 32: "from inside `CanvasView`" becomes "from the canvas surface (`CanvasView` and the helpers it builds; `CanvasSourceCensus.surfaceFiles`)". Name the construction census.
- **Tests (tripwire 32's guard, windowless at last):**
  - `deleteSelection()` returns `false` and removes nothing while `model.isInGesture`;
  - a selected line is removed in one step;
  - `escapeAsksForTheWholeBoard()` is `false` with a scrap open, and calls `selectTheProjectRow` exactly once on a dimmed board.

- [ ] **Step 1:** Tests, the move, then `./gen.sh`.
- [ ] **Step 2:** Run `./scripts/test.sh only CanvasSurfaceHelperTests CanvasEditGateTests CanvasEscapeMonitorTests TripwireGrepTests CanvasUndoTests` plus the three mounted classes. Then core, the fast gate and the Release build.
- [ ] **Step 3:** Commit: `refactor(canvas): Delete and Escape live in CanvasKeyHandler; the mid-gesture refusal is pinned windowless`

---

### Task 6: `CanvasDropHandler`

**Files:**
- Create `Maugham/Canvas/CanvasDropHandler.swift`
- Modify `CanvasView.swift`, `PromotionCommandTests.swift`, `CanvasSurfaceHelperTests.swift`, `CanvasSourceCensus.swift`, `AREA.md`, `DocBudgetTests.swift`

**Interface:**

```swift
@MainActor struct CanvasDropHandler {
    let model: CanvasModel
    let itemIndex: CanvasItemIndex      // the VIEW's current value, as handleDrop reads today (not the model's)
    let captureDrop: CanvasCaptureDrop
    let assetIngest: CanvasAssetIngest
    @Binding var camera: CanvasCamera
    @Binding var revision: Int
    @Binding var dropError: String?
    func handleDrop(_ payloads: [String], at viewPoint: CGPoint) -> Bool
    func handleExternalDrop(_ providers: [NSItemProvider], at viewPoint: CGPoint) -> Bool
    // handleCaptureDrop stays private
}
```

**Contract:**
- **The two drop modifiers, their ORDER and their long comment stay on `body`** (row D, and the smoke-settled order). Only the closures' bodies change.
- The `Task {}` bodies write `dropError` and `model.selection` after an `await`, through the binding, on the main actor, exactly as today.
- Row L: split `PromotionCommandTests`' entry:
  - `("Maugham/Canvas/CanvasView.swift", [".dropDestination(for: String.self)"])`;
  - `("type:CanvasDropHandler", [the five landing tokens])`, with the reason text kept beside it.
  - Re-point the `missingTokens` falsifications for the landing tokens to `type:CanvasDropHandler`. The drop-mount falsification stays on the view's file.
- This file uses no inside verb. It is on `surfaceFiles` because it is the view's code, so tripwire 32's converse and the construction census cover it.
- **Tests:** a payload of an unknown id returns `false` and changes nothing; a read-only canvas refuses `.place`.

- [ ] **Step 1:** Tests, the move, then `./gen.sh`.
- [ ] **Step 2:** Run `./scripts/test.sh only CanvasSurfaceHelperTests PromotionCommandTests CanvasDropTests CanvasEditGateTests TripwireGrepTests` plus the three mounted classes. Then core, the fast gate and the Release build.
- [ ] **Step 3:** Commit: `refactor(canvas): drop handling lives in CanvasDropHandler; the modifiers and their order stay on body`

---

### Task 7: The sweep — names, rules, numbers

**Files:**
- Modify `Maugham/Canvas/AREA.md` and `DocBudgetTests.swift`
- Modify comments only in `Maugham/Canvas/*.swift` and messages in `MaughamTests/**`

**Contract:**
- **Comments.**
  - Every `CanvasView.handleClick`, `.handleDrag`, `.deleteSelection`, `.rebuildLayouts`, `.remeasure`, `.syncActiveEdit` and `.commitActiveEdit` names its new type. Task 0's grep found them in `CanvasDrop`, `CanvasCapture`, `CanvasEditGate`, `CanvasModel`, `LineInspector`, `ScrapInspector`, `CanvasClaudeWrite`, `CanvasEventView`, `CanvasItemPresentation`, `CanvasAccessibility` and `CanvasScene`.
  - Do the same for test assertion messages that cite the old home. `CanvasView.selectionWhenPressed` stays correct, because the state is still the view's.
  - Run `git diff -w` to show only comment and string-literal lines changed.
- **The area guide.**
  - Rewrite the `CanvasView.swift` Map row: it owns the state and `body` and builds its helpers per call.
  - Fix the Rules and Recipes that name an old home (`AREA.md` :92, :122, :158, :221, :316, :335). The recipe "Add a region or line behaviour" points at `CanvasDragHandler.swift`/`CanvasClickHandler.swift`.
  - Add one Rules bullet under Ownership: **the view's helpers are per-call structs over `$state`, built only by `CanvasView`'s computed properties, never stored, never given `$sceneRevision`**, citing the Task 1 censuses.
  - Raise the ceiling with a reason. Stay at or under 8,000.
- **Numbers for the report.** For each of the seven files: `wc -l`, code lines and comment lines, before and after.

- [ ] **Step 1:** Do the sweep. Run `./scripts/test.sh core`, then the fast gate.
- [ ] **Step 2:** Commit: `docs(canvas): the area guide and comments name each handler's new home`

---

## Finish

1. `./scripts/test.sh full` green (it runs the mounted family), plus a Release build.
2. Whole-branch review on opus. It should:
   - run the colour-moved diff of `main...HEAD` over `Maugham/Canvas/`, and name every non-moved line in the production files;
   - check each helper's init against "bindings for `@State`, `let`s for inputs";
   - confirm `body`'s view tree is unchanged, apart from closure bodies;
   - strike off every Task 0 row;
   - confirm tripwire 57's and 32's plants still fire.
3. Smoke for Denver, on the Plan persona:
   - double-click empty canvas and type: the sentence is there after ⌘Q and relaunch;
   - drag, resize and flick a card;
   - ⇧-drag a line;
   - sweep a region over a chapter subject: it binds;
   - ⌫ a card, then ⌘Z;
   - Escape on a dimmed board;
   - drag a research row and a Finder photo onto the canvas.
4. Do not merge without Denver.
