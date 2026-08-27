import XCTest
import AppKit
@testable import Maugham

final class CanvasUndoTests: XCTestCase {

    /// `groupsByEvent = false`, which is what `CanvasView` ships: every gesture
    /// is grouped explicitly by `CanvasUndo`, so the implicit per-event group can
    /// only collapse two gestures into one ⌘Z. See `CanvasModel.undoManager`.
    ///
    /// It is also required here for a second reason: calling `undo()`
    /// synchronously while an implicit group is open raises
    /// NSInternalInconsistencyException, and that group is closed by
    /// NSApplication's event loop rather than by a run-loop turn — so under the
    /// default it would never close in a test at all.
    private func manager() -> UndoManager {
        let m = UndoManager()
        m.groupsByEvent = false
        return m
    }

    /// Stands in for the state owner: `CanvasView`'s `@State` in 1C-a,
    /// `CanvasModel` in 1C-b. The seam is the same either way.
    private final class Box {
        var scene = CanvasScene()
        var scraps: [CanvasNodeID: String] = [:]
    }

    private func wire(_ undo: CanvasUndo, to box: Box) {
        undo.readSnapshot = { (scene: box.scene, scraps: box.scraps) }
        undo.applySnapshot = { box.scene = $0.scene; box.scraps = $0.scraps }
    }

    private func boxWithScrap() -> Box {
        let box = Box()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap,
                           origin: CGPoint(x: 100, y: 100), width: 240)
        n.cachedHeight = 80
        box.scene.insert(n)
        box.scraps[CanvasNodeID("a")] = "The falls at night."
        return box
    }

    func test_undoRestoresAMovedNode() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.mutate("Move Scrap") {
            box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 900, y: 900))
        }
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 900, y: 900))

        m.undo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
    }

    /// The brief's version of this test asserted only the post-redo origin, which
    /// is the origin the `mutate` alone produces — it passed with an empty stack,
    /// with no undo and no redo having run. The undo is asserted first, and
    /// `canRedo` before the redo, so the assertion can only be reached by a stack
    /// that actually holds a step.
    func test_redoReappliesTheMove() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.mutate("Move Scrap") {
            box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 900, y: 900))
        }
        m.undo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100),
                       "precondition: the undo ran, so the redo below is a real redo")
        XCTAssertTrue(m.canRedo, "the undo registered no redo step")

        m.redo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 900, y: 900))
    }

    func test_undoRestoresADeletedScrapAndItsText() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.mutate("Delete Scrap") {
            box.scene.remove(CanvasNodeID("a"))
            box.scraps[CanvasNodeID("a")] = nil
        }
        XCTAssertTrue(box.scene.isEmpty)

        m.undo()
        XCTAssertNotNil(box.scene.node(CanvasNodeID("a")))
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.",
                       "restoring a node without its words is not an undo")
    }

    /// A drag emits a position per frame. One ⌘Z must undo the whole gesture,
    /// not 60 of them.
    func test_oneDragIsOneUndoStep() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Move Scrap")
        for x in stride(from: CGFloat(110), through: 900, by: 10) {
            box.scene.move(CanvasNodeID("a"), to: CGPoint(x: x, y: 100))
        }
        undo.endGesture()

        m.undo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
        XCTAssertFalse(m.canUndo, "the whole drag must collapse into one step")
    }

    /// A drag that starts and ends on the same pixel must not leave a step
    /// behind — otherwise ⌘Z after a stray click undoes the writer's last REAL
    /// edit while appearing to do nothing.
    func test_aGestureThatChangesNothingPushesNoUndoStep() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Move Scrap")
        undo.endGesture()
        XCTAssertFalse(m.canUndo)
    }

    func test_undoActionNamesAreWriterFacing() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.mutate("Move Scrap") {
            box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 1, y: 1))
        }
        XCTAssertEqual(m.undoActionName, "Move Scrap")
        XCTAssertEqual(m.undoMenuItemTitle, "Undo Move Scrap",
                       "this string is the Edit menu item the writer reads")

        // The name has to survive the round trip, or ⇧⌘Z reads a bare "Redo".
        m.undo()
        XCTAssertEqual(m.redoActionName, "Move Scrap")
        m.redo()
        XCTAssertEqual(m.undoActionName, "Move Scrap")
    }

    func test_typingThenDraggingUndoesInReverseChronologicalOrder() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.mutate("Typing") { box.scraps[CanvasNodeID("a")] = "The falls at noon." }
        undo.mutate("Move Scrap") {
            box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 900, y: 900))
        }

        m.undo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at noon.",
                       "the drag came last, so it undoes first")
        m.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.")
    }

    /// Camera moves are navigation, not edits. Undoing a pan would be baffling.
    ///
    /// It cannot fail against today's empty `noteCameraChanged`; what it guards
    /// is a future author giving that method a body.
    func test_panningAndZoomingAreNotUndoable() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)
        undo.noteCameraChanged()
        XCTAssertFalse(m.canUndo)
    }

    func test_nestedBeginsAreBalancedRatherThanRaising() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Outer")
        undo.beginGesture("Inner")     // a gesture arriving mid-gesture
        box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 5, y: 5))
        undo.endGesture()
        XCTAssertTrue(undo.isInGesture, "the outer gesture is still open")
        undo.endGesture()
        XCTAssertFalse(undo.isInGesture)

        m.undo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
        XCTAssertFalse(m.canUndo, "the inner gesture registered a step of its own")
    }

    /// A stray `endGesture` must leave the recorder exactly where it found it.
    ///
    /// **The crash is not the interesting failure, and asserting only
    /// `isInGesture` cannot see the interesting one.** Remove `endGesture`'s
    /// `guard depth > 0` and nothing crashes and `isInGesture` is still false:
    /// `depth` goes to −1, and the `depth == 0` guard below it returns before
    /// anything registers. What breaks is the NEXT gesture — `beginGesture` takes
    /// −1 to 0, misses its own `depth == 1` guard, and so never takes a snapshot
    /// or a name. The writer then drags a card and ⌘Z does nothing at all.
    ///
    /// So the assertion that matters is on the gesture AFTER the stray end.
    func test_endWithoutBeginLeavesTheNextGestureWhole() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.endGesture()                       // stray, with nothing open
        XCTAssertFalse(undo.isInGesture)
        XCTAssertFalse(m.canUndo, "a stray end registered a step of its own")

        undo.beginGesture("Move Scrap")
        XCTAssertTrue(undo.isInGesture,
                      "the stray end took the depth below zero, so this begin never "
                      + "reached depth 1 — it took no snapshot and kept no name, and "
                      + "the drag it brackets will register nothing")
        box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 900, y: 900))
        undo.endGesture()

        XCTAssertTrue(m.canUndo, "the gesture after a stray end registered nothing")
        m.undo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
    }

    // MARK: - Granularity inside one visit

    /// A visit that ran to three sentences must not collapse into one ⌘Z.
    func test_breakingAGestureSplitsAVisitIntoSeparateSteps() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Edit Scrap")
        box.scraps[CanvasNodeID("a")] = "One."
        undo.breakGesture()
        XCTAssertTrue(undo.isInGesture, "the visit is still open")
        box.scraps[CanvasNodeID("a")] = "One. Two."
        undo.endGesture()

        m.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "One.")
        m.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.")
    }

    func test_breakingAGestureWithNothingTypedLeavesNoStepBehind() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Edit Scrap")
        undo.breakGesture()
        undo.breakGesture()
        undo.endGesture()
        XCTAssertFalse(m.canUndo, "a pause during which nothing was typed is not a step")
    }

    func test_breakingOutsideAGestureIsANoOp() {
        let undo = CanvasUndo(undoManager: manager())
        undo.breakGesture()
        XCTAssertFalse(undo.isInGesture)
    }

    /// Splitting an outer gesture from inside a nested one would close a bracket
    /// the caller still believes it holds.
    ///
    /// The brief asserted only the depth bookkeeping, which is unfalsifiable: a
    /// `breakGesture` with the `depth == 1` guard removed is depth-NEUTRAL at
    /// depth 2 (the inner `endGesture` returns early, the inner `beginGesture`
    /// returns early), so both spellings pass. What can fail is the stack: the
    /// outer gesture must come back in ONE step, so a break that split it is
    /// visible as a second entry.
    func test_breakingInsideANestedGestureLeavesTheOuterGestureWhole() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Outer")
        box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 5, y: 5))
        undo.beginGesture("Inner")
        undo.breakGesture()
        XCTAssertTrue(undo.isInGesture)
        box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 7, y: 7))
        undo.endGesture()
        XCTAssertTrue(undo.isInGesture, "the outer gesture must still be open")
        undo.endGesture()
        XCTAssertFalse(undo.isInGesture)

        m.undo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
        XCTAssertFalse(m.canUndo,
                       "a break inside a nested gesture split the outer one into two")
    }

    // MARK: - ScrapUndoBeat, the policy

    func test_aFinishedSentenceIsABoundary() {
        XCTAssertTrue(ScrapUndoBeat.completesASentence(before: "The falls at night",
                                                       after: "The falls at night."))
        XCTAssertTrue(ScrapUndoBeat.completesASentence(before: "", after: "?"))
    }

    func test_aPartialSentenceIsNotABoundary() {
        XCTAssertFalse(ScrapUndoBeat.completesASentence(before: "The falls at nigh",
                                                        after: "The falls at night"))
        XCTAssertFalse(ScrapUndoBeat.completesASentence(before: "", after: ""))
    }

    /// An ellipsis is one boundary, not three — and backing over a full stop is
    /// not a boundary at all.
    func test_repeatedTerminatorsAndDeletionsDoNotEachFire() {
        XCTAssertFalse(ScrapUndoBeat.completesASentence(before: "Well.", after: "Well.."))
        XCTAssertFalse(ScrapUndoBeat.completesASentence(before: "Well...", after: "Well.."))
        XCTAssertFalse(ScrapUndoBeat.completesASentence(before: "Well.", after: "Well"))
    }

    func test_stillnessLongerThanTheBeatIsABoundary() {
        let now = Date()
        XCTAssertFalse(ScrapUndoBeat.hasGoneIdle(since: nil, now: now),
                       "the first keystroke of a visit ends nothing")
        XCTAssertFalse(ScrapUndoBeat.hasGoneIdle(
            since: now.addingTimeInterval(-ScrapUndoBeat.idleSeconds / 2), now: now))
        XCTAssertTrue(ScrapUndoBeat.hasGoneIdle(
            since: now.addingTimeInterval(-ScrapUndoBeat.idleSeconds - 0.1), now: now))
    }

    // MARK: - ⌘Z with a live editor

    private func layout(_ text: String) -> ScrapLayout {
        ScrapLayout(text: text, width: 240,
                    font: NSFont(name: "Iowan Old Style", size: 13) ?? .systemFont(ofSize: 13))
    }

    @discardableResult
    private func host(_ view: NSView) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 100)
        let container = NSView(frame: frame)
        container.addSubview(view)
        let window = TestWindow.make(SilentTestWindow.self, contentRect: frame,
                                     contentView: container, present: .unshown)
        view.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }
    private var windows: [NSWindow] = []
    override func tearDown() { windows.removeAll(); super.tearDown() }

    /// I10. The mounted editor must not put its own step on the shared manager:
    /// one change would land twice, and the text view's copy would target an
    /// NSTextStorage that the snapshot's `rebuildLayouts()` has replaced — so the
    /// second ⌘Z would appear to do nothing.
    func test_typingIntoTheMountedEditorRegistersNothingOfItsOwn() {
        let m = manager()
        let container = ScrapEditorContainer(frame: .zero)
        container.canvasUndo = CanvasUndo(undoManager: m)
        container.mount(layout: layout("before"), unscaledSize: CGSize(width: 240, height: 100),
                        zoom: 1)
        host(container)

        container.textView?.setSelectedRange(NSRange(location: 0, length: 0))
        container.textView?.insertText("Z", replacementRange: NSRange(location: 0, length: 0))

        XCTAssertEqual(container.textView?.string, "Zbefore",
                       "precondition: the keystroke landed, so an empty stack below "
                       + "means the text view declined to register rather than that "
                       + "nothing was typed")
        XCTAssertFalse(m.canUndo,
                       "the text view registered a step of its own — with the "
                       + "canvas snapshot that is one change on the stack twice")
    }

    /// The Edit menu's Undo item is titled by whoever handles the action. Inside a
    /// scrap that is the container, not `NSWindow`, so without this the writer
    /// reads a bare "Undo" for every canvas step.
    ///
    /// **One recorder, handed to the container**, which is what production does
    /// (`CanvasView` passes `undo` to `ScrapEditorHost`). Wiring a second
    /// `CanvasUndo` onto the same manager still satisfies every assertion below —
    /// they all resolve through the manager — but it makes the setup blind to
    /// anything that depends on the CONTAINER's recorder holding an open gesture,
    /// which is exactly what `canUndo`'s pending term and `undo()`'s
    /// close-then-reopen are.
    func test_theEditMenuNamesTheCanvasStepWhileAScrapIsFocused() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        let container = ScrapEditorContainer(frame: .zero)
        container.canvasUndo = undo
        let item = NSMenuItem(title: "Undo",
                              action: #selector(ScrapEditorContainer.undo(_:)),
                              keyEquivalent: "z")

        undo.mutate("Move Scrap") {
            box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 900, y: 900))
        }
        XCTAssertTrue(container.validateUserInterfaceItem(item))
        XCTAssertEqual(item.title, "Undo Move Scrap",
                       "the writer reads a bare 'Undo' with no idea what it will take back")

        let redoItem = NSMenuItem(title: "Redo",
                                  action: #selector(ScrapEditorContainer.redo(_:)),
                                  keyEquivalent: "Z")
        XCTAssertFalse(container.validateUserInterfaceItem(redoItem),
                       "Redo is offered with nothing to redo")
        container.undo(nil)
        XCTAssertTrue(container.validateUserInterfaceItem(redoItem))
        XCTAssertEqual(redoItem.title, "Redo Move Scrap")

        // The PENDING case, which only one shared recorder can see. The manager's
        // undo stack is empty now (the step above was just undone), and the writer
        // is mid-run inside a scrap — so the only thing to take back is an open
        // gesture the manager knows nothing about. The item must be ENABLED, and
        // it must read a bare "Undo": a pending run is not a step until it closes
        // and has no action name, and enabled-and-honestly-unnamed beats greyed
        // out and wrong. Wiring a SECOND recorder onto this manager, as this test
        // used to, makes both of these unreachable.
        XCTAssertFalse(container.validateUserInterfaceItem(item),
                       "precondition: with nothing open and an empty stack there is "
                       + "nothing to undo")
        undo.beginGesture("Edit Scrap")
        box.scraps[CanvasNodeID("a")] = "The falls at noon"
        XCTAssertTrue(container.validateUserInterfaceItem(item),
                      "Undo is greyed out while the writer is halfway through the "
                      + "first run of typing inside a scrap, and ⌘Z would do nothing")
        XCTAssertEqual(item.title, "Undo",
                       "the pending run borrowed a name from a step it is not")
    }

    /// The whole shape, end to end: focus opens the gesture, blur closes it, one
    /// ⌘Z takes the visit back. It says nothing about `ScrapUndoBeat` — no
    /// keystroke and no clock goes through it, so no break is ever attempted.
    /// The policy running for real is
    /// `CanvasViewMountingEditingTests.test_undoInsideAScrapTakesBackASentenceAtATime`.
    func test_oneUndoAfterTypingRestoresTheTextTheWriterStartedWith() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Edit Scrap")                       // focus in
        box.scraps[CanvasNodeID("a")] = "The falls at noon."   // several keystrokes
        box.scraps[CanvasNodeID("a")] = "The falls at noon, and the ponchos."
        undo.endGesture()                                     // focus out

        m.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.")
        XCTAssertFalse(m.canUndo,
                       "an unbroken gesture is ONE step, not one per change folded "
                       + "into the model inside it")
    }

    /// I11. `beginGesture` captures its baseline at focus-in and registers
    /// nothing until focus-out, so the manager stays live and undoable for the
    /// whole visit. If the writer presses ⌘Z mid-visit, that baseline is stale
    /// the moment the undo lands — and closing the gesture against it registers a
    /// step whose UNDO re-applies exactly what was just undone.
    func test_undoingWhileAScrapIsFocusedDoesNotResurrectTheUndoneEdit() {
        let box = boxWithScrap()                     // a = "The falls at night."
        var second = CanvasNode(id: CanvasNodeID("b"), kind: .scrap,
                                origin: CGPoint(x: 400, y: 0), width: 240)
        second.cachedHeight = 80
        box.scene.insert(second)
        box.scraps[CanvasNodeID("b")] = "ponchos"

        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        // Visit A and leave.
        undo.beginGesture("Edit Scrap")
        box.scraps[CanvasNodeID("a")] = "The falls at noon."
        undo.endGesture()

        // Visit B, press ⌘Z mid-visit, keep typing, then leave.
        undo.beginGesture("Edit Scrap")
        m.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.",
                       "precondition: ⌘Z reverted A")
        box.scraps[CanvasNodeID("b")] = "ponchos, and the man selling them"
        undo.endGesture()

        m.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("b")], "ponchos",
                       "the second ⌘Z must take back what was typed into B")
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.",
                       "closing the gesture re-applied the edit the writer had "
                       + "already undone — the gesture's baseline was never "
                       + "refreshed after applySnapshot")
    }

    /// **⌘Z pressed without leaving the scrap must take back the run of typing
    /// still in progress**, not step over it to the one before.
    ///
    /// Everything typed since the last sentence or pause lives in the OPEN
    /// gesture and nowhere else — the manager has never been told about it — so
    /// `undoManager.undo()` on its own applies the step before it and both runs
    /// vanish at once. This is the difference between `CanvasUndo.undo()` and the
    /// manager's, and the assertion below fails on the manager's.
    func test_undoTakesBackTheRunOfTypingStillInProgress() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Edit Scrap")
        box.scraps[CanvasNodeID("a")] = "The falls at night. Rain."
        undo.breakGesture()                       // the sentence ended
        box.scraps[CanvasNodeID("a")] = "The falls at night. Rain. Nobody there"
        // No break: no terminator and no pause, so this run is open when ⌘Z lands.

        undo.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night. Rain.",
                       "⌘Z stepped over the run the writer was in the middle of and "
                       + "took back the sentence before it as well")
        XCTAssertTrue(undo.isInGesture,
                      "the visit's gesture was left closed, so nothing brackets what "
                      + "the writer types next")

        // And the reopened gesture is baselined on what the undo produced, so
        // leaving now registers nothing at all.
        undo.endGesture()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night. Rain.")
    }

    /// The redo half of the same shape: what ⌘Z took back comes forward again.
    func test_redoAfterUndoingTheRunInProgressBringsItBack() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Edit Scrap")
        box.scraps[CanvasNodeID("a")] = "The falls at night. Rain."
        undo.undo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night.",
                       "precondition: the open run was taken back")

        undo.redo()
        XCTAssertEqual(box.scraps[CanvasNodeID("a")], "The falls at night. Rain.",
                       "⇧⌘Z did not bring back what ⌘Z had just taken")
    }

    /// The Edit menu must offer Undo while the writer is still inside their first
    /// run of typing — at that moment the manager's own stack is EMPTY, because
    /// the only thing to take back is the open gesture.
    func test_undoIsOfferedWhileTheOnlyThingToTakeBackIsStillOpen() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.beginGesture("Edit Scrap")
        XCTAssertFalse(undo.canUndo, "an open gesture that changed nothing is nothing")

        box.scraps[CanvasNodeID("a")] = "The falls at noon"
        XCTAssertFalse(m.canUndo,
                       "precondition: the manager knows nothing about the open run, "
                       + "so the assertion below is about the pending term")
        XCTAssertTrue(undo.canUndo,
                      "Undo is greyed out while the writer is halfway through the "
                      + "first sentence they typed into a scrap — and ⌘Z would then "
                      + "do nothing at all")
    }

    /// A ⌘Z arriving inside a NESTED gesture still runs, and leaves both brackets
    /// standing for whoever opened them. The re-baseline inside `register` is what
    /// keeps the outer gesture honest afterwards.
    ///
    /// **This does NOT pin `closeResumableGesture`'s `depth == 1` guard, and
    /// saying so is the point.** Measured by mutation: relaxing it to `depth >= 1`
    /// leaves this test green, because close-then-reopen is depth-NEUTRAL at depth
    /// 2 — the inner `endGesture` goes 2→1 and returns before registering
    /// anything, the inner `beginGesture` goes 1→2 and returns before touching the
    /// snapshot or the name. Nothing observable differs, on the stack or in the
    /// bookkeeping. The guard is there so the next reader sees the decision; what
    /// this test guards is the OUTCOME, and it would catch an author who made
    /// `undo()` unwind the gesture stack rather than close one level of it.
    func test_undoInsideANestedGestureLeavesBothBracketsStanding() {
        let box = boxWithScrap()
        let m = manager()
        let undo = CanvasUndo(undoManager: m)
        wire(undo, to: box)

        undo.mutate("Move Scrap") {
            box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 900, y: 900))
        }
        undo.beginGesture("Outer")
        undo.beginGesture("Inner")
        undo.undo()
        XCTAssertEqual(box.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100),
                       "precondition: the undo still ran")

        undo.endGesture()
        XCTAssertTrue(undo.isInGesture, "the outer gesture was closed under its owner")
        undo.endGesture()
        XCTAssertFalse(undo.isInGesture)
    }

    func test_anUnwiredRecorderRecordsNothingRatherThanCrashing() {
        let m = manager()
        let undo = CanvasUndo(undoManager: m)   // no readSnapshot / applySnapshot
        undo.mutate("Move Scrap") { }
        XCTAssertFalse(m.canUndo)
    }

    /// The closures capture the state's owner, which owns the recorder, and the
    /// manager retains the recorder for every step on its stack. That is the same
    /// cycle `CanvasStore.beforeFlush` has, and `CanvasView.onDisappear` breaks
    /// both the same way — otherwise a closed canvas keeps its store, its scene
    /// and every scrap's text alive for the life of the app.
    func test_releasingTheRecorderDropsWhatItsClosuresCaptured() {
        weak var leaked: Box?
        let m = manager()
        let undo = CanvasUndo(undoManager: m)

        autoreleasepool {
            let box = boxWithScrap()
            leaked = box
            wire(undo, to: box)
            undo.mutate("Move Scrap") {
                box.scene.move(CanvasNodeID("a"), to: CGPoint(x: 900, y: 900))
            }
            XCTAssertTrue(m.canUndo, "precondition: the stack holds a step, so the "
                          + "manager is holding the recorder")
        }
        XCTAssertNotNil(leaked, "precondition: the closures are what keep it alive")

        undo.release()
        XCTAssertNil(leaked,
                     "release() left the canvas's whole scene and every scrap's text "
                     + "alive behind a closed window")
        XCTAssertFalse(m.canUndo)
    }
}
