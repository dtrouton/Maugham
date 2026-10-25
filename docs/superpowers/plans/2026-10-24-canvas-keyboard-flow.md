# Canvas Keyboard Flow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Denver can pick the book or a chapter in the binder, Tab to the canvas, and make, chain, connect and name scraps and regions without the mouse. Everything he makes belongs to the chapter he picked, and a PNG dragged from the Finder lands on the canvas.

**Architecture:** New canvas logic follows the CanvasView split's pattern (`docs/superpowers/plans/2026-10-20-canvasview-split.md`). Pure decisions live in pure files that are not on the surface list:
- key decoding, placement and arrow targets: `CanvasKeyboard.swift`;
- drop routing: `CanvasDropRoute.swift`;
- drop wrapping: `CanvasDropWrap.swift`.

Everything that writes `@State` lives in per-call `@MainActor struct` helpers, built only in `CanvasView`'s computed properties. These are `CanvasScrapFlow` (make and enter a scrap) and `CanvasRegionTitleEditing`, plus new methods on the existing `CanvasKeyHandler`, `CanvasClickHandler`, `CanvasDragHandler` and `CanvasDropHandler`.

Keys reach the canvas by two doors only:
- `CanvasEventNSView`, when it holds first responder;
- the scrap editor's own text view (`ScrapEditorContainer`), for the in-scrap keys.

Escape keeps the `WindowEscapeArbiter` path.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit (TextKit 2), XCTest. macOS 27 deployment target.

**Spec:** `docs/superpowers/specs/2026-10-24-canvas-keyboard-flow-design.md`. It is binding; read it whole before any task. Read `Maugham/Canvas/AREA.md` before touching `Maugham/Canvas/**`, and `docs/tripwires.md` rows 25–33 and 57.

**One plan, not two.** There are ten tasks (0–9), within CLAUDE.md's ~10 cap. Tasks 5, 6 and 8 are the heavy ones, and each carries its own measurement step, so no task is planned against an API that does not exist yet.

## Global Constraints

- **Tripwires 2, 3, 6, 25–33 and 57 hold.** In particular:
  - one text editor is mounted at a time;
  - focus is *requested* (in `viewDidMoveToWindow`/`updateNSView`), never taken in `makeNSView`;
  - text folds on `textDidChange`;
  - membership changes only by creation, by centre;
  - no mid-gesture mutation from the surface;
  - no test presses a control and waits, and no test synthesises a mouse click outside the allow-lists;
  - no `load()` closure reads a plain stored view property.
- **Per-call helpers.** A new helper:
  - takes a `Binding` for every `@State` it touches and a `let` for every view input;
  - is never stored;
  - is never given `$sceneRevision`;
  - is built only in a `CanvasView` computed property inside `// MARK: - Helpers, built per call`.
  
  A file that holds a sibling helper contains no `Task {`, `Task.detached`, `DispatchQueue` or `@escaping`. Every new surface file joins `CanvasSourceCensus.surfaceFiles` in the task that creates it.
- **Tripwire 57 placement rule.** Never add `subject`, `itemIndex` or any other plain stored view value to `CanvasEditFocus` or `CanvasLayoutPass`, because `load()`'s closures reach both. `subject` goes only to `CanvasScrapFlow`, `CanvasDropHandler`, `CanvasKeyHandler` and `CanvasDragHandler`, which `load()` does not reach. `TripwireGrepTests.test_theCanvasLoadClosuresReadNoChangingViewValue` must stay green.
- **Pure statics stay off surface types.** `test_theCanvasSurfaceHelpersAreBuiltByCanvasViewOnly` fires on a surface type's static member called from elsewhere, so pure functions go in the pure files named above.
- **Undo** (spec §1, "Undo"):
  - A key-created scrap is one `"New Scrap"` step, and for Tab that step includes the line. Typing is a separate `"Edit Scrap"` step.
  - A canvas rename is `"Rename Region"`, the inspector's name.
  - An undo test asserts the step name (`CanvasUndo.undoMenuItemTitle`).
- **Surface verbs.** On the surface, a mutation uses `mutate`/`withScene`/`beginGesture`. Only drops (an outside bracket) use `mutateFromInspector`.
- **Read-only canvases** (`CanvasEditGate`) refuse every creating, entering or renaming key and drop. Arrow selection still works there.
- **No new MCP surface, no phone, no restyling** (spec Non-goals).
- **Docs:**
  - `Maugham/Canvas/AREA.md` is capped at 8,000 words (`DocBudgetTests`). Task 0 frees room, and each later task adds its Map row and raises `wordCeilings` with a reason.
  - Every new file goes on the Map in the task that adds it (`DocBudgetTests.test_everyAreaGuidesMapNamesEveryFileInItsFolder`).
- **Gates after every task:**
  - `./gen.sh` when a file was added;
  - `./scripts/test.sh only <the task's classes> CanvasViewMountingSurfaceTests CanvasViewMountingEditingTests CanvasViewMountingRegionTests TripwireGrepTests CanvasCompositionTests CanvasEditGateTests`;
  - `./scripts/test.sh core` when `AREA.md`/`DocBudgetTests` changed;
  - `./scripts/test.sh`.
  - After any `CanvasView.body` edit, run a Release build from a script file, only when `pgrep -x xcodebuild` is empty.
  - Task 9 runs `./scripts/test.sh full`.
  - Never raw `xcodebuild test`, never bare `swift test`, never `git push`. Reviewers do not build during a gate.
  - Each report pastes the gate's tail.
- **Commit by path**, ending with the two attribution lines from the session.
- **Models:** Task 4 sonnet. Task 0 and Task 9 sonnet. All others opus.

## Review Focus

1. **Return, Tab or Escape pressed while an input method is composing** (marked text: Japanese, accents via ⌥e). The writer expects the key to finish the composition, not the scrap, and no character lost. *Pinned in Task 5:* `test_aKeyDuringMarkedTextIsLeftToTheInputMethod`.
2. **Modified keys meant for something else**: ⌘⇧↩ (Promote…), ⌥↩, ⌃↩, and ⌘↩ while focus is in the inspector, find bar or binder. The writer expects Promote… to still promote and other fields to keep their keys. *Pinned in Task 4:* the decode table. *Task 5:* `test_commandShiftReturnInsideAScrapIsNotTaken`. *Task 6:* `test_commandReturnIsClaimedOnlyWhileTheCanvasIsFirstResponder`.
3. **A canvas key arriving mid-gesture.** For example Tab or Return while the mouse still holds a card, or in the runloop turn after a double-click with "Edit Scrap" open. The writer expects nothing to happen, and above all no nested undo bracket. *Pinned in Task 6:* `test_everyCanvasKeyIsRefusedMidGesture`.
4. **Crowded placement.** A wall of cards to the right, a card exactly one gap away, a collapsed region, or a huge region. The writer expects the new card clear of every visible card, and the search to always end. *Pinned in Task 4:* `test_placementStepsPastAColumnOfCardsAndTerminates` and `test_placementIgnoresHiddenCards`.
5. **Tab while renaming a chapter in the binder**, or while in the binder's other text fields. The writer expects Tab to stay with the rename. *Pinned in Task 7:* `test_tabDuringABinderRenameStaysInTheRename`.

---

### Task 0: Baseline, census table, and room in the area guide

**Files:**
- Modify: `Maugham/Canvas/AREA.md`, `docs/history/canvas.md`, `Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`

- [ ] **Step 1: Grep the censuses.** Run these and list in the report every census each later task will touch, with file:line:
  - `grep -rn 'surfaceFiles\|dropDestination(for: String.self)\|onDrop(of:\|CanvasEventView(\|ScrapEditorHost(\|func handleClick(\|"New Scrap"\|clickCount: 2' MaughamTests`
  - `grep -n 'theCanvasStringDropDestinationIsMountedBeforeTheProviderDrop\|providerDropToken' MaughamTests/TripwireGrepTests.swift`
  - the `PromotionCommandTests` wiring census entry for `CanvasView.swift` and `type:CanvasDropHandler`.
  
  Known rows:
  - the drop-order tripwire and the provider-token census (Task 1);
  - `CanvasEditGateTests.test_theCanvasAsksTheGateBeforeEachAct` (Tasks 2, 6, 8);
  - `CanvasCompositionTests`' `mountedEditor` slice (Task 8);
  - `CanvasViewMountingRegionTests.test_leavingAScrapRefreshesTheRegionInspectorItIsSittingBeside` and `test_aRegionStaysSelectedWhileADoubleClickOpensAScrap`, which double-click the chrome bar at (200,30) to mint a scrap (Task 8 must keep these green);
  - `TripwireGrepTests.test_theCanvasSurfaceHelpersAreBuiltByCanvasViewOnly` and `test_theCanvasLoadClosuresReadNoChangingViewValue` (every task).
- [ ] **Step 2: Run the baseline.** Run `./scripts/test.sh only` over the classes above plus the three mounted classes, then `./scripts/test.sh core`. Record green and the times.
- [ ] **Step 3: Free about 350 words in `AREA.md`.** Move why-clauses (never rules) to `docs/history/canvas.md` under a heading "Moved from the guide by canvas-keyboard-flow Task 0". Fix one drift while there: the Routes rule says *"The external `.onDrop` is applied first (innermost) and the `String.self` destination after it"*, which is the reverse of `CanvasView.body`. Task 1 rewrites that rule anyway, so here only delete the wrong half. Lower `wordCeilings["Maugham/Canvas/AREA.md"]` to the new count, with a reason.
- [ ] **Step 4: Gate.** Run `./scripts/test.sh core` (DocBudgetTests, DocSyncTests). Expected: green.
- [ ] **Step 5: Commit.** `docs(canvas): room in the area guide for the keyboard flow; the drop-order rule's reversed half removed`

---

### Task 1: Finder image drop — root cause, failing test, fix

**Files:**
- Create: `Maugham/Canvas/CanvasDropRoute.swift` (pure)
- Create: `MaughamTests/Canvas/CanvasDropRouteTests.swift`
- Modify: `Maugham/Canvas/CanvasView.swift` (the drop modifiers, ~`.dropDestination`/`.onDrop` at the end of `body`), `Maugham/Canvas/CanvasDropHandler.swift`, `MaughamTests/TripwireGrepTests.swift` (drop-order and provider census), `MaughamTests/Canvas/PromotionCommandTests.swift` (wiring tokens), `Maugham/Canvas/AREA.md` (Routes rule + Map row)

**Interfaces:**
- Produces:
  - `enum CanvasDropRoute { case external, internalPayload, refuse }`
  - `static func route(typeIdentifiers: [String]) -> CanvasDropRoute`
  - `static let acceptedTypes: [UTType]` (`[.fileURL, .image, .utf8PlainText]`)
  - `CanvasDropHandler.handleDrop(providers:at:) -> Bool`
  
  Task 3 extends these handlers.

**Do not assume the spec's hypothesis.** The hypothesis is that the String `dropDestination` claims Finder file drags. Establish the cause with evidence first.

- [ ] **Step 1: Write the type census test (it stays as a regression test).** `test_aFinderFileDragCarriesTheseTypes` builds a provider set the way a Finder file drag does, both ways:
  - (a) `NSItemProvider(contentsOf: pngURL)`;
  - (b) an `NSPasteboard(name: .init("test-\(UUID())"))` written with `writeObjects([pngURL as NSURL])`, its items read back as type lists.
  
  Assert and record each provider's `registeredTypeIdentifiers`, plus whether any conforms to `UTType.utf8PlainText`/`.plainText` (String's Transferable import types). Use a PNG under `TestTemp.root`.
- [ ] **Step 2: Manual probe (the controller asks Denver; agents cannot drag).**
  - Add a temporary `#if DEBUG` `os_log` in both drop closures in `CanvasView.body`. It logs which closure fired and, in the provider one, `providers.map(\.registeredTypeIdentifiers)`.
  - Add one temporary log line at the head of `handleDrop` with the payload string.
  - Build a dev app. Denver drags in four things: a PNG from the Finder, an image from a browser, a research row, and an inbox capture.
  - The controller pastes the log into the report.
  - **Cause established** means: which closure received the Finder PNG, what payload it saw, and what it returned.
  - Remove the logging before Step 5. If the cause is not the String destination, **stop and report to the controller with the log**; do not fix blind.
- [ ] **Step 3: Write the failing regression test at the pure seam.** In `CanvasDropRouteTests`:
  - `test_aFinderPNGRoutesExternal`: `route(typeIdentifiers:)` over the type list Step 1/Step 2 recorded for the Finder PNG returns `.external`.
  - `test_aResearchRowRoutesInternal`: `[UTType.utf8PlainText.identifier]` returns `.internalPayload`.
  - `test_aBrowserImageRoutesExternal`: image plus `public.url` plus plain text returns `.external`.
  - `test_nothingUsableIsRefused`: `[]` returns `.refuse`.
  
  The rule is that a file URL or an image always wins over plain text. Run it: it fails (type undefined).
- [ ] **Step 4: Implement `CanvasDropRoute.route(typeIdentifiers:)`.** Conformance is via `UTType(id)?.conforms(to:)`. Run Step 3: PASS.
- [ ] **Step 5: Fix (default, if Step 2 confirmed the hypothesis).** Replace the two modifiers with **one** `.onDrop(of: CanvasDropRoute.acceptedTypes, isTargeted: nil)` whose closure calls `dropHandler.handleDrop(providers:at:)`. That method:
  - routes on the union of the providers' types;
  - sends `.external` to the existing `handleExternalDrop`;
  - for `.internalPayload`, loads the first provider's string with `loadTransferable(type: String.self)` inside a `Task`, then runs the existing synchronous `handleDrop(_:at:)` logic on the main actor;
  - returns `false` for `.refuse`.
  
  The handler holds no sibling helper, so a `Task` is allowed there.
  - **Accepted cost (controller to confirm):** an internal payload with an unknown id is accepted and then does nothing, instead of springing back, because its string loads asynchronously.
  - Rewrite the long order comment in `body` to say why one modifier replaced two (the hover-claim history moves to `docs/history/canvas.md`).
- [ ] **Step 6: Re-point the censuses, each keeping a planted control.**
  - `test_theCanvasStringDropDestinationIsMountedBeforeTheProviderDrop` becomes `test_theCanvasHasOneDropModifierAndItIsTheProviderRoute`:
    - exactly one `.onDrop(of:` on the surface;
    - zero `.dropDestination(for:`;
    - `CanvasDropRoute.acceptedTypes` names `.fileURL`, `.image` and `.utf8PlainText`.
  - The provider-token census's String-destination control becomes the `CanvasDropRoute.route(` call.
  - `PromotionCommandTests`' `CanvasView.swift` token `.dropDestination(for: String.self)` becomes `.onDrop(of: CanvasDropRoute.acceptedTypes`, and its falsifications are re-pointed.
  - The `AREA.md` Routes rule is rewritten to state the one-modifier route. Add the Map row for `CanvasDropRoute.swift`.
- [ ] **Step 7: Gate** with `CanvasDropRouteTests CanvasDropTests PromotionCommandTests TripwireGrepTests`, plus a Release build. Then the controller asks Denver to smoke the same four drags.
- [ ] **Step 8: Commit.** `fix(canvas): a Finder PNG lands on the canvas — one provider drop routes file and image before text`

---

### Task 2: `CanvasScrapFlow` — one way to make and enter a scrap, chapter-aware

**Files:**
- Create: `Maugham/Canvas/CanvasScrapFlow.swift` (surface helper)
- Create: `MaughamTests/Canvas/CanvasScrapFlowTests.swift` (windowless, `SurfaceHelperBox`-style bindings as in `CanvasSurfaceHelperTests`)
- Modify:
  - `Maugham/Canvas/CanvasInteraction.swift` (one pure static);
  - `Maugham/Canvas/CanvasClickHandler.swift` (the `.scrap` and `.emptyCanvas` arms delegate);
  - `Maugham/Canvas/CanvasView.swift` (computed `scrapFlow`; the click handler gets it);
  - `Maugham/Canvas/CanvasBindingOffer.swift` (wording);
  - `MaughamTests/Canvas/CanvasSourceCensus.swift` (`surfaceFiles` += `"CanvasScrapFlow.swift"`);
  - `MaughamTests/Canvas/CanvasEditGateTests.swift` (the order entry for `func handleClick(` now reaches `scrapFlow.makeScrap(`);
  - `AREA.md` (Map row + one rule).

**Interfaces:**
- Produces:
  - `CanvasInteraction.creationBinding(subject: CanvasSubject, home: CanvasRegionID?, in scene: CanvasScene) -> String?`, which returns the piece to bind the new scrap to, or nil.
  - `CanvasScrapFlow`:
    ```swift
    @MainActor struct CanvasScrapFlow {
        let model: CanvasModel; let subject: CanvasSubject; let layoutPass: CanvasLayoutPass
        @Binding var editingNodeID: CanvasNodeID?; @Binding var caretIndex: Int?
        @Binding var lastKeystrokeAt: Date?; @Binding var straighten: CanvasFocusStraighten
        /// One "New Scrap" step: create at `origin`, measure, join by centre, bind per
        /// `creationBinding`, and (when `joinedTo` is non-nil) insert the line. Then enter it.
        @discardableResult func makeScrapAndEnter(at origin: CGPoint, joinedTo: CanvasNodeID? = nil) -> CanvasNodeID
        /// Enter an existing measured scrap at `caretIndex` (UTF-16); opens "Edit Scrap".
        func enter(_ id: CanvasNodeID, caretIndex: Int)
    }
    ```
  
  Tasks 5, 6 and 8 consume it.

- [ ] **Step 1: Write the failing pure tests** (`CanvasScrapFlowTests`):
  - `test_aChapterSubjectBindsANewLooseScrap`: subject `.piece("p1")` and home nil give `"p1"`.
  - `test_theBookLeavesItUnbound`: `.wholeProject` gives nil. `.group`, `.research` and `.piece` with home nil are covered too.
  - `test_anUnboundRegionStillGetsTheScrapItsOwnBinding`: home region unbound gives `"p1"`.
  - `test_aRegionBoundToTheSameChapterIsFollowed`: home bound to `p1` gives nil.
  - `test_aRegionBoundElsewhereLeavesTheScrapUnbound`: home bound to `p2` gives nil. **This is the spec's precedence; see the controller question in the report.**
- [ ] **Step 2: Write the failing helper tests.**
  - `test_makeScrapAndEnterIsOneNewScrapStepThenAnEditScrapStep`. Make a scrap under subject `.piece("p1")`, type through `model.setScrapText` + `breakGesture`, then commit. Assert:
    - the first undo title is `"Undo Edit Scrap"`;
    - after it, `"Undo New Scrap"`, which removes the node;
    - `node.boundPieceID == "p1"` before undo;
    - `CanvasHighlight.resolve(subject: .piece("p1"), in:)` lights the node.
  - `test_aJoinedScrapsLineIsInTheNewScrapStep`: `joinedTo: a`. One undo removes both the new node and the line; the scene's lines count is back to its baseline.
  - `test_anEnteredScrapIsMeasuredBeforeTheEditStepOpens`: `cachedHeight != nil` at the moment `"Edit Scrap"` begins (the click arm's existing ordering, kept).
  - `test_aNewScrapInsideARegionJoinsItByCentre`.
- [ ] **Step 3: Implement.**
  - `creationBinding`: bind iff `subject` is `.piece(p)` and `home` is nil or the home region's `boundPieceID` is nil.
  - `makeScrapAndEnter`:
    - move the click handler's `.emptyCanvas` arm verbatim (comments included) into it;
    - add, inside the same `withScene` that joins, `scene.setBoundPiece(_:for:)` from `creationBinding`;
    - when `joinedTo` is set, add `scene.insertLine(CanvasLine(id: CanvasInteraction.newLineID(in:), from: joinedTo, to: id))`;
    - keep `model.bumpSceneRevision()` when either binding or membership changed.
  - `enter`: the `.scrap` arm's tail (`editingNodeID`, `caretIndex`, `lastKeystrokeAt = nil`, `straighten.focus`, `beginGesture("Edit Scrap")`).
  - The click handler keeps its caret arithmetic and calls `enter`.
  - Never hand `subject` to `editFocus` or `layoutPass`.
- [ ] **Step 4: Reword `CanvasBindingOffer.nothingBound.instruction`** to `"Double-click or press Return to add a scrap to it, or drag out a region."` Update `CanvasBindingOfferTests` if it pins the string.
- [ ] **Step 5: Run the tests.** Run `CanvasScrapFlowTests CanvasSurfaceHelperTests CanvasBindingOfferTests CanvasHighlightTests` and the mounted three. Expected: PASS, including the existing double-click mounted tests unchanged.
- [ ] **Step 6: Commit.** `feat(canvas): a scrap made while a chapter is selected belongs to it; making and entering a scrap is one helper`

---

### Task 3: A drop onto empty canvas with a chapter selected is wrapped in a bound region

**Files:**
- Create: `Maugham/Canvas/CanvasDropWrap.swift` (pure)
- Create: `MaughamTests/Canvas/CanvasDropWrapTests.swift`
- Modify:
  - `Maugham/Canvas/CanvasDrop.swift` (`CanvasDrop.apply`, `CanvasExternalDrop.apply` gain `wrappingInPiece: String?`);
  - `Maugham/Canvas/CanvasCapture.swift` (`Placement.dropped(at:wrappingInPiece:)`);
  - `Maugham/Canvas/CanvasDropHandler.swift` (gains `let subject: CanvasSubject`);
  - `Maugham/Canvas/CanvasView.swift` (pass `subject`);
  - `Maugham/Views/CentreColumn.swift` and `Maugham/Stores/InboxStore*.swift` (the capture closure carries the piece; read `Maugham/Stores/AREA.md` first);
  - `AREA.md`.

**Interfaces:**
- Consumes: Task 1's `handleDrop(providers:at:)`.
- Produces:
  - `CanvasDropWrap.wrap(_ ids: [CanvasNodeID], toPiece piece: String, in scene: inout CanvasScene) -> CanvasRegionID?`;
  - `CanvasDropWrap.frame(around frames: [CGRect]) -> CGRect`;
  - the drop paths return the wrapping region id when one was made (`CanvasExternalDrop.apply(...) -> (nodes: [CanvasNodeID], wrappedIn: CanvasRegionID?)`; `CanvasDrop.apply` likewise). Task 8 opens its title.

**Decisions:**
- Items whose centre lands in an existing region join it, as today.
- With subject `.piece(p)`, the remaining items of one drop share **one** new region bound to `p`.
- The region **joins only the dropped items, never bystanders.** It is the drop's container, not a sweep. Record this in `AREA.md` under "Creation absorbs".
- The frame is the union of member frames, padded by `CanvasClaudePlacement.padding` with `CanvasRegionMetrics.chromeHeight` above, and floored at `CanvasRegionMetrics.minimumSide` on each side.
- Membership goes through `CanvasMembership.join`. Everything stays inside the drop's existing `mutateFromInspector` bracket, so one ⌘Z.
- The subject is read at drop time. Any other subject means no wrap.

- [ ] **Step 1: Write the failing tests.**
  - `test_oneDroppedItemIsWrappedInARegionBoundToTheChapter`: region `boundPieceID == "p1"`, the item is its resident, and the item is lit under `.piece("p1")`.
  - `test_severalItemsInOneDropShareOneRegion`.
  - `test_anItemDroppedIntoARegionJoinsItAndNothingIsWrapped`.
  - `test_theBookLeavesDropsLoose`.
  - `test_theWrapAbsorbsNoBystander`: a loose card inside the computed frame stays loose.
  - `test_theWrapFrameIsNeverUnderMinimumSide`.
  - `test_oneUndoTakesTheItemAndItsRegion`: step name `CanvasDrop.undoStepName`.
  - `test_aWrappedCaptureDropLandsInABoundRegion`, through `CanvasCapture.apply`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** per the decisions above. The node is born measured (`itemLabelOnlyHeight`), so its frame exists before `wrap` reads it.
- [ ] **Step 4: Run.** `CanvasDropWrapTests CanvasDropTests PromotionCommandTests` plus the capture tests (`grep -rln CanvasCapture MaughamTests`) (check the capture wiring census token) and the mounted three. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(canvas): a drop on bare canvas with a chapter selected arrives in a region bound to it`

---

### Task 4: `CanvasKeyboard` — pure key decoding, placement and arrow targets

**Files:**
- Create: `Maugham/Canvas/CanvasKeyboard.swift` (pure; not a surface file)
- Create: `MaughamTests/Canvas/CanvasKeyboardTests.swift`
- Modify: `Maugham/Canvas/CanvasCamera.swift` (one pure method), `AREA.md` (Map row)

**Interfaces:**
- Produces:
  ```swift
  enum CanvasKey: Equatable { case returnKey, tab, backtab, commandReturn, arrow(CanvasArrow) }
  enum CanvasArrow: Equatable { case up, down, left, right }
  enum ScrapEditorCommand: Equatable { case finish, makeJoined, makeBelow }
  enum CanvasKeyboard {
      static func canvasKey(characters: String?, modifiers: NSEvent.ModifierFlags) -> CanvasKey?
      static func editorCommand(selector: Selector, modifiers: NSEvent.ModifierFlags,
                                hasMarkedText: Bool) -> ScrapEditorCommand?
      static func editorKeyEquivalent(characters: String?, modifiers: NSEvent.ModifierFlags) -> ScrapEditorCommand?
      static func clearOrigin(startingAt: CGPoint, stepping: CanvasArrow, size: CGSize,
                              in scene: CanvasScene) -> CGPoint
      static func newCardSize() -> CGSize   // defaultScrapWidth × CanvasScrapMeasure.height(text: "", cardWidth:)
      static func nearest(from: CGPoint, toward: CanvasArrow, in scene: CanvasScene,
                          excluding: CanvasNodeID?) -> CanvasNodeID?
      static func centre(of selection: CanvasSelection, in scene: CanvasScene) -> CGPoint?
      static let placementGap: CGFloat   // = CanvasClaudePlacement.cardGap
      static let placementStepLimit: Int // 200
  }
  // CanvasCamera
  mutating func reveal(_ rect: CGRect, viewSize: CGSize)  // pans the least distance to bring rect fully on screen; no-op if visible; zoom untouched
  ```

**Decisions:**
- **Modifiers.** A modifier set counts as "none" after removing `.numericPad`, `.function` and `.capsLock`.
- **`canvasKey`:**
  - `"\r"` or `"\u{3}"` with no modifiers gives `.returnKey`;
  - `"\r"` with exactly `.command` gives `.commandReturn` (⌘⇧, ⌘⌥ and ⌘⌃ give nil);
  - `"\t"` with none gives `.tab`;
  - `"\u{19}"`, or `"\t"` with exactly `.shift`, gives `.backtab`;
  - the four arrow function keys with none give `.arrow`;
  - everything else, Delete included, gives nil (⌫ keeps its existing arm).
- **`editorCommand`:**
  - `hasMarkedText` gives nil;
  - `insertNewline:` with no `.shift` gives `.finish`; with `.shift` it gives nil (the text view inserts the newline);
  - `insertLineBreak:` and `insertNewlineIgnoringFieldEditor:` give nil;
  - `cancelOperation:` gives `.finish`;
  - `insertTab:` gives `.makeJoined`;
  - `insertBacktab:` gives nil.
- **`editorKeyEquivalent`:** `"\r"` with exactly `.command` gives `.makeBelow`; otherwise nil.
- **`clearOrigin`:**
  - Test the candidate rect `(origin, size)`, inset by `-placementGap`, against every `scene.unorderedNodes` frame that is not hidden and is measured.
  - If it collides, step along `stepping`: `.down` moves to `colliding.maxY + gap`, and `.right` moves to `colliding.maxX + gap`. Tab steps `.down` (a column to the right of the source); ⌘Return steps `.down`; empty-canvas Return steps `.down`.
  - Stop after `placementStepLimit` steps and return the last candidate.
- **`nearest`:**
  - candidates are nodes not hidden, measured, and not `excluding`;
  - a candidate's centre lies within ±45° of the arrow's axis from `from`;
  - the smallest Euclidean distance wins, ties broken by the smaller id;
  - nil if there is no candidate.
- **`centre`:** a node's frame centre, a region's frame centre, or a line's endpoint-centres midpoint.

- [ ] **Step 1: Write the failing tests:**
  - `test_theCanvasKeyTable` (every row above, including ⌘⇧↩ → nil and ⌥↩ → nil);
  - `test_theEditorCommandTable`;
  - `test_aKeyDuringMarkedTextIsLeftToTheInputMethod`;
  - `test_commandShiftReturnIsNeverAnEditorKeyEquivalent`;
  - `test_placementOnAnEmptySceneIsTheStart`;
  - `test_placementStepsPastAColumnOfCardsAndTerminates` (a 300-card wall returns within the limit, never overlapping the first 199);
  - `test_placementIgnoresHiddenCards`;
  - `test_aCardExactlyOneGapAwayIsClear`;
  - `test_nearestRespectsTheConeAndDistance`;
  - `test_noCandidateIsNil`;
  - `test_nearestSkipsHiddenAndUnmeasured`;
  - `test_centreOfALineIsTheMidpoint`;
  - `test_revealIsANoOpForAVisibleRectAndPansTheLeastOtherwise`;
  - `test_revealNeverZooms`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `CanvasKeyboardTests CanvasCameraTests`. Expected: PASS. Then `./scripts/test.sh core` for the Map row.
- [ ] **Step 5: Commit.** `feat(canvas): pure keyboard decisions — key tables, clear placement, arrow targets, reveal`

---

### Task 5: Keys inside a scrap — Return, Shift+Return and Escape finish; Tab and ⌘Return make the next

**Files:**
- Modify:
  - `Maugham/Canvas/ScrapEditorHost.swift` (`textView(_:doCommandBy:)`, `performKeyEquivalent(with:)` on the container, `onCommand`);
  - `Maugham/Canvas/CanvasKeyHandler.swift` (`handleEditorCommand`);
  - `Maugham/Canvas/CanvasEventView.swift` (keyboard request);
  - `Maugham/Canvas/CanvasView.swift` (`@State keyboardTicket`, wiring);
  - `MaughamTests/Canvas/ScrapEditorHostTests.swift`, `CanvasViewMountingEditingTests.swift`;
  - `AREA.md`.
- Create: `MaughamTests/Canvas/CanvasEditorKeyTests.swift` (windowless handler tests)

**Interfaces:**
- Consumes:
  - `CanvasKeyboard.editorCommand`, `editorKeyEquivalent`, `clearOrigin`, `newCardSize` (Task 4);
  - `CanvasScrapFlow.makeScrapAndEnter(at:joinedTo:)` (Task 2).
- Produces:
  - `ScrapEditorContainer.onCommand: ((ScrapEditorCommand) -> Bool)?` and `ScrapEditorHost(…, onCommand:)`;
  - `CanvasKeyHandler.handleEditorCommand(_ c: ScrapEditorCommand, viewSize: CGSize) -> Bool`;
  - `CanvasEventView(…, keyboardRequest: CanvasKeyboardRequest)`, with `struct CanvasKeyboardRequest: Equatable { var fromCanvas = 0; var fromWindow = 0 }`.
  
  `CanvasKeyHandler` gains `scrapFlow: CanvasScrapFlow`, `@Binding var camera: CanvasCamera` and `@Binding var keyboardTicket: Int`. It holds siblings, so it schedules nothing.

**Decisions:**
- **Finish** = `editFocus.commitActiveEdit()` + `leaveTheOpenScrap()` + `model.selection = .node(id)` + `revision += 1` + `keyboardTicket += 1`. This hands the keyboard to `CanvasEventNSView` so Return, Tab and the arrows work next.
- **makeJoined:** finish, then `scrapFlow.makeScrapAndEnter(at: clearOrigin(start: (frame.maxX + gap, frame.minY), stepping: .down, …), joinedTo: id)`.
- **makeBelow:** the same with start `(frame.minX, frame.maxY + gap)` and no line.
- After a create, `camera.reveal(newFrame, viewSize:)`. `viewSize` is the container's superview bounds, passed with the command.
- **Typing is never lost.** `commitActiveEdit` runs `syncActiveEdit` first.
- **Empty scrap:** the same as clicking away today (no new rule).
- **Mid-gesture.** After the commit, if `model.isInGesture` is still true (a drag is open), refuse and return `false`. The finish has already happened, so no text is lost.
- **Read-only:** a mounted editor cannot exist there, but guard with `CanvasEditGate.keyCreates` (Task 6 adds the gate; add it here if Task 6 has not).
- **Delivery.** The container returns the command's Bool from `doCommandBy`. `performKeyEquivalent` claims ⌘↩ only when `window?.firstResponder === textView`.
- **Escape arbitration is untouched.** `CanvasEscapeMonitor.disposition` already passes Escape while an `NSText` is first responder, so it reaches `cancelOperation:` in the text view. No second monitor.
- **Keyboard request.** `CanvasEventNSView` keeps `servedKeyboardRequest`, initialised to the value at `makeNSView`, so mounting never steals focus. `updateNSView` claims first responder when the value changes. If `window` is nil, the claim is pended to `viewDidMoveToWindow` (requested, not taken).

- [ ] **Step 1: Measure the real routes.** In `CanvasViewMountingEditingTests`, send real `NSEvent.keyEvent` presses through `NSApp.sendEvent(_:)` to a mounted editor: Return, Shift+Return, Tab, ⌘Return, Escape. Record which selector `doCommandBy` sees for each, and whether ⌘Return reaches `performKeyEquivalent` before any menu. Write the finding as the comment on the delivery code. If ⌘Return arrives as a `doCommandBy` selector instead, route it there and keep the decode pure.
- [ ] **Step 2: Write the failing tests.**
  - Windowless, in `CanvasEditorKeyTests`:
    - `test_finishFoldsTheTextLeavesTheScrapSelectedAndAsksForTheKeyboard`: typed text is in `model.scraps`, `editingNodeID == nil`, the selection is `.node(id)`, and `keyboardTicket` was incremented.
    - `test_escapeFinishesAndNeverDiscards`.
    - `test_makeJoinedFinishesThenMakesAJoinedScrapToTheRightAndEntersIt`: the new frame does not intersect any other frame, a line A–B exists, and `editingNodeID` is B.
    - `test_makeBelowPlacesUnderWithNoLine`.
    - `test_tabThenTypeUndoesTextThenScrapAndLine`: titles `"Undo Edit Scrap"` then `"Undo New Scrap"`; after both, B and the line are gone and A's words are intact.
    - `test_aCommandMidDragIsRefusedAfterTheFold`.
    - `test_aNewChapterScrapFromTabIsBoundAndLit`.
  - In `ScrapEditorHostTests`, through `textView.doCommand(by:)`:
    - `test_returnIsTakenAndShiftReturnInsertsANewline` (string gains `"\n"`);
    - `test_aKeyDuringMarkedTextIsLeftToTheInputMethod` (`setMarkedText` first; Return is not taken);
    - `test_commandShiftReturnInsideAScrapIsNotTaken` (`performKeyEquivalent` returns false);
    - `test_commandReturnIsNotTakenWhenTheTextViewIsNotFirstResponder`.
  - Mounted (real events), in `CanvasViewMountingEditingTests`:
    - `test_returnInAScrapFinishesItAndTheCanvasHoldsTheKeyboard`: after the pump, `window.firstResponder` is the `CanvasEventNSView`.
    - `test_escapeInAScrapFinishesItAndADimmedBoardStaysDimmed`: subject `.piece`. The first Escape does not call `selectTheProjectRow`; the second one does. This pins the arbitration.
    - `test_mountingTheCanvasDoesNotTakeTheKeyboard`: a text field in the same window keeps first responder through the canvas mount.
- [ ] **Step 3: Run.** Expected: FAIL.
- [ ] **Step 4: Implement** per the decisions. `CanvasView.mountedEditor` passes `onCommand: { keyHandler.handleEditorCommand($0, viewSize: $1) }`; adjust the signature to carry the size. Keep header contract 2: `load()` stays right after `mountedEditor`.
- [ ] **Step 5: Run** `CanvasEditorKeyTests ScrapEditorHostTests CanvasEscapeMonitorTests CanvasEventViewTests CanvasCompositionTests` and the mounted three, then a Release build. Expected: PASS.
- [ ] **Step 6: Commit.** `feat(canvas): Return, Escape, Tab and ⌘Return inside a scrap finish it or make the next one`

---

### Task 6: Keys on the canvas — Return, Tab, ⌘Return and the arrows

**Files:**
- Modify:
  - `Maugham/Canvas/CanvasEventView.swift` (`keyDown` arms, `performKeyEquivalent`, `onKey`);
  - `Maugham/Canvas/CanvasKeyHandler.swift` (`handleCanvasKey`);
  - `Maugham/Canvas/CanvasEditGate.swift` (`keyCreates`);
  - `Maugham/Canvas/CanvasView.swift`;
  - `MaughamTests/Canvas/CanvasEditGateTests.swift`, `CanvasEventViewTests.swift`;
  - `AREA.md` (the keys rule beside ⌫).
- Create: `MaughamTests/Canvas/CanvasCanvasKeyTests.swift`

**Interfaces:**
- Consumes: Task 4 (`canvasKey`, `clearOrigin`, `nearest`, `centre`, `reveal`), Task 2 (`makeScrapAndEnter`, `enter`), and Task 8's `regionTitle.begin(_:)`. For the region-Return case, Task 6 leaves a `// Task 8` arm returning `false` until Task 8 wires it.
- Produces:
  - `CanvasEventNSView.onKey: ((CanvasKey, CGSize) -> Bool)?`, passing `bounds.size`;
  - `CanvasKeyHandler.handleCanvasKey(_ key: CanvasKey, viewSize: CGSize) -> Bool`;
  - `CanvasEditGate.keyCreates(isReadOnly:) -> Bool`.

**Decisions** (spec §1 tables). Every arm first requires `editingNodeID == nil` and `!model.isInGesture`; otherwise it returns `false`.

| Selection | Return | Tab | ⌘Return | Arrows |
|---|---|---|---|---|
| none | new scrap at `clearOrigin(start: camera.contentPoint(fromView: viewCentre) − half card, .down)`, entered | `false` | `false` | `false` (travels on) |
| scrap | `enter(id, caretIndex: utf16 length)` | joined scrap, as Task 5 | below, as Task 5 | nearest card, or swallowed with no beep if none |
| item card | `true`, does nothing | joined scrap | below | as above |
| region | rename (Task 8) | `false` | `false` | as above, from its centre |
| line | `true`, does nothing | `false` | `false` | as above, from its midpoint |

- Creating and entering keys ask `CanvasEditGate.keyCreates` first. Arrows ask no gate.
- An arrow sets `model.selection`, bumps `revision`, and calls `camera.reveal(frame, viewSize:)`.
- Backtab is decoded here but handled in Task 7. Until then, return `false`.
- `performKeyEquivalent` claims ⌘↩ only when `window?.firstResponder === self` and `onKey` returns true.
- Escape stays absent from `keyDown` (`test_escapeIsNotHandledHereBecauseTheMonitorIsWhatRuns` stays green).

- [ ] **Step 1: Write the failing tests.**
  - Windowless (`CanvasCanvasKeyTests`):
    - one test per table cell, named `test_<selection>_<key>`;
    - `test_returnOnAnEmptyCanvasMakesAScrapAtTheViewCentreClearOfCards`;
    - `test_everyCanvasKeyIsRefusedMidGesture` (open `beginGesture("Move Card")`; every key returns false and the scene is unchanged);
    - `test_everyCreatingKeyIsRefusedReadOnly`;
    - `test_arrowsStillSelectReadOnly`;
    - `test_anArrowWithNoCardThatWayIsSwallowedAndChangesNothing`.
  - `CanvasEditGateTests`:
    - add `("func handleCanvasKey(", "CanvasEditGate.keyCreates(isReadOnly: model.isReadOnly)", "scrapFlow.makeScrapAndEnter(")` to the order census;
    - extend `test_aWritableCanvasIsUntouchedByTheGate` and the read-only test.
  - `CanvasEventViewTests`, with real `NSEvent` keys to the view:
    - `test_returnReachesOnKeyAndAnUnusedKeyTravelsToSuper`;
    - `test_commandReturnIsClaimedOnlyWhileTheCanvasIsFirstResponder`;
    - `test_commandShiftReturnIsNeverClaimed`;
    - `test_deleteStillGoesToOnDeleteKey`.
  - Mounted: `test_returnOnASelectedScrapEntersItAndTypingLands` (real key events, then `insertText`).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the above, `CanvasKeyHandler`'s existing delete tests, and the mounted three, then a Release build. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(canvas): Return, Tab, ⌘Return and the arrows work on the canvas itself`

---

### Task 7: Tab from the binder to the canvas, Shift+Tab back (Plan persona)

**Files:**
- Modify:
  - `Maugham/Canvas/CanvasEventView.swift` (`canBecomeKeyView` if needed; the backtab arm);
  - `Maugham/Canvas/CanvasView.swift` (`var keyboardRequest: Int = 0` and `var returnKeyboardToTree: () -> Void = {}`, both defaulted, censused like `selectTheProjectRow`);
  - `Maugham/Views/CentreColumn.swift` (`canvasCentre` passes both);
  - `Maugham/Views/BinderView.swift` / `ProjectWindow.swift` (the binder's hand-off; read `Maugham/Views/AREA.md` first);
  - `MaughamTests/Canvas/PromotionCommandTests.swift` (wiring census tokens);
  - `AREA.md` (Canvas and Views).
- Test: a mounted ProjectWindow test beside the existing binder-in-a-window tests (find the harness with `grep -rln "BinderProjectRow\|ProjectWindow(" MaughamTests`).

**Interfaces:**
- Consumes: Task 5's `CanvasKeyboardRequest.fromWindow`.
- Produces: the two `CanvasView` inputs above.

- [ ] **Step 1: Measure, then choose.** Host the Plan persona with a project. Make the binder's outline view first responder and send a real Tab `keyDown` through `NSApp.sendEvent`. Read `window.firstResponder`.
  - If it is the `CanvasEventNSView` with no code, the key-view loop already works: keep it, and add only what the measurement shows is missing (e.g. `canBecomeKeyView`).
  - Otherwise use the explicit route:
    - `.onKeyPress(.tab)` on the binder `List`, active only when `persona.centresTheCanvas` and `renamingItemId == nil`, bumps a window `@State canvasKeyboardRequest`. That reaches `CanvasView.keyboardRequest` → `CanvasKeyboardRequest.fromWindow`.
    - `.backtab` on the canvas calls `returnKeyboardToTree`, which sets a `@FocusState` the binder `List` is `.focused(_:)` on.
  - Record which in the report. Shift+Tab is measured the same way.
- [ ] **Step 2: Write the failing tests:**
  - `test_tabInThePlanBinderGivesTheCanvasTheKeyboard`;
  - `test_shiftTabOnTheCanvasGivesTheBinderTheKeyboard`;
  - `test_tabDuringABinderRenameStaysInTheRename` (start a rename; Tab leaves first responder in the field editor and the canvas is not first responder);
  - `test_tabInTheAuthorBinderDoesNotReachTheCanvas`;
  - `test_theBinderKeepsItsReturnAndArrows` (Return starts a rename as today; ↓ moves the selection).
  
  All of them use real key events, no clicks.
- [ ] **Step 3: Run.** Expected: FAIL.
- [ ] **Step 4: Implement** the chosen route. Add the census tokens for the two new `CanvasView` arguments to `PromotionCommandTests`. A dropped argument must go red, as `selectTheProjectRow`'s does.
- [ ] **Step 5: Run** the new tests, `PromotionCommandTests`, the binder rename tests (`grep -rln renamingItemId MaughamTests`), and the mounted three, then a Release build. Expected: PASS.
- [ ] **Step 6: Commit.** `feat(plan): Tab moves from the binder to the canvas and Shift+Tab moves back`

---

### Task 8: Region names on the canvas

**Files:**
- Create:
  - `Maugham/Canvas/RegionTitleEditorHost.swift` (`NSViewRepresentable` + `RegionTitleField: NSTextField`, delegate in the container);
  - `Maugham/Canvas/CanvasRegionTitleEditing.swift` (surface helper);
  - `MaughamTests/Canvas/RegionTitleEditingTests.swift`.
- Modify:
  - `CanvasView.swift` (`@State regionTitleEditingID: CanvasRegionID?`; a second branch inside `mountedEditor`; the renderer argument);
  - `CanvasRenderer.swift` (skip the label of the region being named);
  - `CanvasClickHandler.swift` (a `ClickTarget.regionTitle` case);
  - `CanvasDragHandler.swift` (open after a sweep's `.create`);
  - `CanvasDropHandler.swift` (open after a wrap);
  - `CanvasKeyHandler.swift` (region Return);
  - `CanvasInteraction.swift` or `CanvasRegion.swift` (`CanvasRegionMetrics.titleHitRect(in:labelWidth:)`);
  - `CanvasSourceCensus.surfaceFiles`, `CanvasCompositionTests`, `CanvasEditGateTests`;
  - `AREA.md`; `docs/tripwires.md` row 32 (the repro wording).

**Interfaces:**
- Consumes: Task 3's `wrappedIn`, Task 5's `keyboardTicket`, Task 6's region-Return arm.
- Produces:
  ```swift
  @MainActor struct CanvasRegionTitleEditing {
      let model: CanvasModel; let editFocus: CanvasEditFocus
      @Binding var regionTitleEditingID: CanvasRegionID?; @Binding var editingNodeID: CanvasNodeID?
      @Binding var keyboardTicket: Int; @Binding var revision: Int
      func begin(_ id: CanvasRegionID)          // closes any open scrap visit first (commit + leave)
      func commit(_ text: String)               // "Rename Region" via model.mutate when changed; closes; asks for the keyboard
      func cancel()                             // closes, no step; asks for the keyboard
  }
  ```

**Decisions:**
- **One editor slot.** The title editor is the `else if let rid = regionTitleEditingID` branch of `mountedEditor`. A scrap editor and a title editor can never both exist, and the layer order (event view, then the one editor) is unchanged. `begin` commits and leaves any open scrap first. `CanvasScrapFlow.enter` and the click head clear an open title by committing it (`commitIfOpen()`, idempotent).
- **Its own text stack.** The field uses the window's field editor, not `ScrapLayout`'s shared TextKit stack, so tripwires 26 and 28 do not apply to it. The commit happens on Return, on click-away (`controlTextDidEndEditing`) and at the click handler's head, so typed text is never lost.
- **Requested focus.** Focus is requested in `viewDidMoveToWindow`/`updateNSView`, as `ScrapEditorContainer` does (tripwire 27).
- **Zoom.** Font size is scaled by `camera.zoom`; never `.scaleEffect` (tripwire 25). The field is level over the region's ≤1° tilt, and the renderer skips that region's drawn label while it is open.
- **Escape.** Escape reaches the field (the monitor passes `NSText`), and `control(_:textView:doCommandBy:)` takes `cancelOperation:` and cancels. A `cancelled` flag set before resigning stops the following `controlTextDidEndEditing` from committing. On creation, Escape leaves the region untitled and does **not** undo it.
- **When it opens:**
  - at the end of a sweep's `.ended`, **after** `model.endGesture()`, only on `.create`;
  - after a drop-wrap, only when `editingNodeID == nil` (otherwise the region is just selected);
  - on Return with a region selected (Task 6 arm);
  - on a double-click whose second click hits `titleHitRect`. That rect is the chrome bar from `labelInset` to `labelInset + max(drawn label width, 60)`, using the same font and elision the renderer draws with (`CanvasRenderer.regionLabelWidthBudget`/`elide`).
  - **A double-click elsewhere on the chrome bar still mints a scrap**, so tripwire 32's repro and its two mounted tests stand.
- **Gating.** Read-only means no `begin` (`CanvasEditGate.editsValues`). `commit` from the surface uses `mutate`, never `mutateFromInspector`. The label is written exactly as `RegionInspector.commitLabel` writes it (no trim, no-op when unchanged).

- [ ] **Step 1: Write the failing tests.**
  - Windowless (`RegionTitleEditingTests`):
    - `test_aSweptRegionOpensItsTitleAfterTheNewRegionStepCloses` (`isInGesture == false` at `begin`; the undo title is still `"Undo New Region"`);
    - `test_returnCommitsAsRenameRegion`;
    - `test_escapeLeavesTheRegionUntitledAndKeepsIt` (one undo removes the region, `"Undo New Region"`);
    - `test_cancelThenResignDoesNotCommit`;
    - `test_clickElsewhereCommitsWhatWasTyped` (`handleClick` head);
    - `test_beginClosesAnOpenScrapVisitWithItsWordsFolded`;
    - `test_enteringAScrapCommitsAnOpenTitle`;
    - `test_aWrappedDropOpensItsTitleOnlyWithNoScrapOpen`;
    - `test_returnOnASelectedRegionOpensItsTitle`;
    - `test_readOnlyOpensNothing`.
  - `CanvasInteractionTests` / click tests:
    - `test_aDoubleClickOnTheTitleRenamesAndOnTheBarElsewhereMintsAScrap`;
    - `test_theTitleHitRectFollowsTheDrawnLabelWidth`.
  - `CanvasCompositionTests`: `test_theMountedEditorSlotHoldsAtMostOneEditor`. The `mountedEditor` slice builds `RegionTitleEditorHost(` only in an `else if` after the `ScrapEditorHost(` branch, and `CanvasView.body` composes no other text editor.
  - Mounted (`CanvasViewMountingRegionTests`, real key events only):
    - `test_typingANameAfterASweepAndPressingReturnNamesIt`;
    - `test_escapeWhileNamingOnADimmedBoardKeepsTheDim` (Escape cancels and does not select the project row);
    - the two chrome-bar repro tests above stay green unmodified.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** The `RegionInspector` name field is unchanged.
- [ ] **Step 4: Run** the new tests, `CanvasCompositionTests CanvasRendererTests CanvasRegionInteractionTests RegionBindingTests TripwireGrepTests CanvasEditGateTests` and the mounted three, then a Release build. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(canvas): name a region where it is — on creation, on a double-click on its title, on Return`

---

### Task 9: Docs — the shortcut list, the guide, the area guide; the full gate

**Files:**
- Modify:
  - `Maugham/Resources/KeyboardShortcuts.swift`: a `"Canvas"` category with these entries:
    - Finish scrap ↩
    - New line in scrap ⇧↩
    - Finish scrap ⎋
    - New joined scrap ⇥
    - New scrap below ⌘↩
    - New scrap / edit selected ↩
    - Move selection ←↑→↓
    - Rename region ↩
    - Canvas from tree ⇥ (Plan)
    - Back to tree ⇧⇥
  - `docs/guide/getting-started.md` (§ The planning canvas, Regions, Getting things onto the canvas);
  - `Maugham/Canvas/AREA.md`;
  - `docs/tripwires.md` (row 32's repro now says "away from its title");
  - `docs/history/canvas.md`.

**Guide content.** Describe what ships, in the guide's voice:
- the keyboard flow, as two short lists matching the spec's tables;
- chapter-selected scraps belong to the chapter, with the precedence in one sentence;
- a drop on bare canvas with a chapter selected arrives in a region bound to it, titled for typing;
- naming a region on the canvas;
- Tab from the tree;
- remove "The Inspector (⌘⌥I) is where you name it" as the only route.

- [ ] **Step 1: Write the failing test** in `KeyboardShortcutsTests`: `test_theCanvasKeysAreListed` asserts the category and its entries.
- [ ] **Step 2: Write** the docs. The `AREA.md` rules are new one-liners under "Input" and "The mounted editor and Delete" naming each new file's job and test. Keep the guide under its ceiling, and raise `wordCeilings` with a reason.
- [ ] **Step 3: Gate.** Run `./scripts/test.sh core`, `./scripts/test.sh full` (no skips), and a Release build. Paste the tails.
- [ ] **Step 4: Commit.** `docs(canvas): the keyboard flow in the shortcut list, the guide and the area guide`

Then the controller runs the whole-branch review and asks Denver for these smokes:
- the four drags;
- arrow to a chapter → Tab → Return → type → Tab → type → ⌘↩ → type → Escape → arrows;
- sweep → type a name → Return;
- double-click a title.
