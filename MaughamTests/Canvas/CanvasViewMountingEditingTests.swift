import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// The mounted canvas's KEYBOARD: typing into a scrap and the save that
/// follows it, ⌘Z, Escape's route out of the dim, and what ⌫ does to whatever
/// the click before it selected. Harness in `CanvasViewMountingCase`.
final class CanvasViewMountingEditingTests: CanvasViewMountingCase {

    // MARK: - The words are safe

    /// The product constitution's must #1 and the smoke that gates this slice:
    /// type a sentence and quit WITHOUT clicking away first.
    ///
    /// `.onDisappear` does not fire on ⌘Q, so this passes only if this view binds
    /// `CanvasStore.beforeFlush` — the one commit point no other test can reach.
    /// Without it the store writes whatever the last debounce queued, which is
    /// the scrap as it was before the writer typed.
    func test_typingThenQuittingWithoutClickingAwayKeepsTheSentence() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModelOnProductionClocks(),
                                     projectRoot: root, paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)

        editor.insertText(" — and nobody there",
                          replacementRange: NSRange(location: (editor.string as NSString).length,
                                                    length: 0))
        pump(0.05)

        let scrapsURL = root.appendingPathComponent(CanvasStore.scrapsRelativePath)
        XCTAssertFalse(try String(contentsOf: scrapsURL, encoding: .utf8).contains("nobody there"),
                       "precondition: the 750 ms debounce has not fired yet, so what "
                       + "follows tests the quit hook rather than the timer")

        NotificationCenter.default.post(   // adr-0021-ok: AppKit lifecycle notification, not a maugham.* event — this is what CanvasStore observes for quit
            name: NSApplication.willTerminateNotification,
            object: NSApplication.shared)

        XCTAssertTrue(try String(contentsOf: scrapsURL, encoding: .utf8).contains("nobody there"),
                      "quitting mid-sentence lost the sentence — the store wrote the "
                      + "last debounced payload instead of the live editor's text")
    }

    /// The other teardown, and the one the plan flagged for review: closing a
    /// single window relies on `.onDisappear` running before the store dies. ⌘Q
    /// is covered above by the store's own termination hook; this is the path
    /// that has nothing but `.onDisappear`.
    func test_typingThenLeavingTheCanvasKeepsTheSentence() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModelOnProductionClocks(),
                                     projectRoot: root, paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)

        editor.insertText(" — sodium light",
                          replacementRange: NSRange(location: (editor.string as NSString).length,
                                                    length: 0))
        pump(0.05)

        let scrapsURL = root.appendingPathComponent(CanvasStore.scrapsRelativePath)
        XCTAssertFalse(try String(contentsOf: scrapsURL, encoding: .utf8).contains("sodium light"),
                       "precondition: the debounce has not fired yet")

        window.contentView = NSView(frame: .zero)
        pump()

        XCTAssertTrue(try String(contentsOf: scrapsURL, encoding: .utf8).contains("sodium light"),
                      "leaving the canvas mid-sentence lost the sentence — a persona "
                      + "switch or a closed window drops whatever was being typed")
    }

    /// `ScrapUndoBeat`'s sentence rule, running for real. The rule itself is unit
    /// tested in `CanvasUndoTests`; what only this view can show is that anything
    /// ASKS it, and that it is asked AFTER the keystroke is folded in.
    ///
    /// Three sentences typed in one visit must be three ⌘Z steps, and the first
    /// ⌘Z must leave the earlier sentences standing. Every pump here is a
    /// tenth of the suite's idle beat (`testUndoIdle`), so the idle rule cannot
    /// fire and the boundaries under test are the full stops and nothing else.
    ///
    /// ⌘Z is pressed WITHOUT clicking away first, so this also drives the
    /// mid-visit re-baseline and the layout swap: `applySnapshot` rebuilds the
    /// focused scrap's `ScrapLayout`, and the mounted editor has to come back
    /// bound to the new one rather than showing the words the undo discarded.
    func test_undoInsideAScrapTakesBackASentenceAtATime() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        type(".", into: editor)                       // finishes the fixture's line
        pump(0.05)
        type(" Rain on the ponchos.", into: editor)
        pump(0.05)
        type(" Nobody buying them.", into: editor)
        pump(0.05)

        let whole = scrapText + ". Rain on the ponchos. Nobody buying them."
        XCTAssertEqual(try mountedText(in: window), whole,
                       "precondition: all three sentences were typed, so an "
                       + "unchanged string below means ⌘Z did nothing rather than "
                       + "that there was nothing to take back")

        container.undo(nil)
        pump()
        XCTAssertEqual(try mountedText(in: window), scrapText + ". Rain on the ponchos.",
                       "one ⌘Z inside a scrap did not take back exactly one "
                       + "sentence: the whole visit collapsing into one step is the "
                       + "per-visit granularity this task rejected, and a single "
                       + "character is the per-keystroke one")

        container.undo(nil)
        pump()
        XCTAssertEqual(try mountedText(in: window), scrapText + ".")

        container.undo(nil)
        pump()
        XCTAssertEqual(try mountedText(in: window), scrapText,
                       "the third ⌘Z did not reach the text the writer clicked into "
                       + "the scrap with")
    }

    /// The idle rule, running for real — and specifically that it is asked BEFORE
    /// the keystroke is folded in.
    ///
    /// Nothing here ends a sentence, so the full-stop rule cannot fire and the
    /// only thing that can put a boundary between the two runs is the pause. The
    /// step that closes must end exactly where the writer stopped: ask the rule
    /// after the fold instead and it ends one character later, swallowing the
    /// first keystroke of what came next.
    func test_aPauseInsideAScrapEndsTheStepWhereTheWriterStopped() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        type(" and the sodium light", into: editor)
        // `waitOut`, not `pump`: this is the one assertion in the file that turns
        // on WALL CLOCK elapsing. `pump` returns when the loop runs dry — measured
        // 0.76 s for a requested 1.8 — and then the idle beat never passes, one ⌘Z
        // takes back both runs, and the test below fails on a machine that is
        // merely busy.
        waitOut(Self.testUndoIdle + 0.1)               // the writer sits back
        type(" on the wet stone", into: editor)
        pump(0.05)

        XCTAssertEqual(try mountedText(in: window),
                       scrapText + " and the sodium light on the wet stone",
                       "precondition: both runs were typed")

        container.undo(nil)
        pump()
        let afterUndo = try mountedText(in: window)
        XCTAssertEqual(afterUndo, scrapText + " and the sodium light",
                       "a pause mid-sentence did not end the undo step — with no "
                       + "full stop anywhere in this visit, the idle beat is the "
                       + "only thing that can, and without it one ⌘Z takes back "
                       + "everything typed since the writer clicked in")
        XCTAssertFalse(afterUndo.hasSuffix(" "),
                       "the step that closed swallowed the first character of what "
                       + "came after the pause — the idle rule was asked AFTER the "
                       + "keystroke was folded in rather than before it")
    }

    /// The drag bracket, and the decision that the coast lives outside it: one ⌘Z
    /// returns the card to where the writer picked it up, not to where it stopped
    /// skating.
    ///
    /// Read through the debounce rather than by taking the window down, so the
    /// moved position and the restored one can both be asserted — otherwise "the
    /// card is at 20" passes just as well on a drag that never happened.
    func test_undoAfterADragPutsTheCardBackWhereTheWriterPickedItUp() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root, paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 70, y: 40), CGPoint(x: 80, y: 40)])
        pumpUntilSaved()                                   // the coast finishes, then the debounce

        let moved = try XCTUnwrap(sceneOnDisk(root).node(scrapID))
        XCTAssertGreaterThan(moved.origin.x, 60,
                             "precondition: the card really moved, so the assertion "
                             + "below is about the undo rather than about a drag that "
                             + "never took")

        let manager = try XCTUnwrap(events.undoManager,
                                    "the event view vends no undo manager, so ⌘Z with "
                                    + "nothing focused reaches the window's stack")
        XCTAssertTrue(manager.canUndo, "the drag registered no undo step at all")
        manager.undo()
        pumpUntilSaved()

        let restored = try XCTUnwrap(sceneOnDisk(root).node(scrapID))
        XCTAssertEqual(restored.origin.x, 20, accuracy: 0.5,
                       "⌘Z did not put the card back where it was picked up — a drag "
                       + "that scatters an arrangement with no way back is the single "
                       + "most likely way this surface loses a writer's trust")
        XCTAssertEqual(restored.origin.y, 20, accuracy: 0.5)
    }

    /// A press that never became a drag opened a gesture at `.began` all the same.
    /// If that gesture is not closed, the next real drag nests inside it and two
    /// gestures collapse into one ⌘Z; if it IS closed but registers a step, ⌘Z
    /// after a stray click undoes the writer's last real edit while appearing to
    /// do nothing.
    ///
    /// Both are the same assertion from outside: after a press that moved
    /// nothing, there is nothing to undo.
    func test_aPressThatNeverMovedLeavesNothingToUndo() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // On the card, well clear of the resize corner, and released without ever
        // leaving the press point.
        events.applyMouseDown(at: CGPoint(x: 60, y: 40), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 60, y: 40))
        pump()

        let manager = try XCTUnwrap(events.undoManager)
        XCTAssertFalse(manager.canUndo,
                       "a click that moved nothing left a step on the stack: the "
                       + "writer's next ⌘Z appears to do nothing, and the one after "
                       + "it takes back an edit they had forgotten about")

        // And the gesture it opened really did close — a second press that DOES
        // move must be a step of its own rather than a continuation of the first.
        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 65, y: 40), CGPoint(x: 66, y: 40)])
        pump()
        XCTAssertTrue(manager.canUndo,
                      "the drag that followed the stray press registered nothing — "
                      + "it was swallowed by a gesture the press left open")
    }

    /// **The live editor stays usable through the window where its `ScrapLayout`
    /// has been replaced and SwiftUI has not rebound yet.**
    ///
    /// ⌘Z inside a scrap runs `applySnapshot` → `rebuildLayouts()`, which
    /// overwrites `layouts[id]` and releases the `ScrapLayout` the mounted
    /// `NSTextView` was built from — synchronously, a whole update pass before
    /// `ScrapEditorHost.updateNSView` sees the new identity and remounts. A
    /// display or layout pass landing in that window meets whatever the view was
    /// left holding, and `test_undoInsideAScrapTakesBackASentenceAtATime` only
    /// ever looks after a `pump()`, so it says nothing about it.
    ///
    /// `ScrapLayoutTests.test_theMountedEditorOutlivesTheScrapLayoutThatBuiltIt`
    /// is the isolated measurement — an `NSTextView` owns its TextKit 2 stack, so
    /// nothing is dangling. This is the same claim through a real ⌘Z on the real
    /// surface, which is where a SwiftUI or AppKit change would show up first.
    /// Between them they are why `rebuildLayouts` documents this as safe rather
    /// than warning against it.
    func test_anUndoInsideAScrapLeavesItsLiveEditorUsableBeforeTheRebind() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        type(". Rain.", into: editor)
        pump(0.05)
        let textContainer = try XCTUnwrap(editor.textContainer)

        container.undo(nil)
        // NO pump. Everything below is inside the window.

        XCTAssertTrue(container.textView === editor,
                      "precondition: SwiftUI has not rebound yet, so this really is "
                      + "the window between the layout swap and the remount")
        XCTAssertNotNil(textContainer.textLayoutManager,
                        "the mounted view's container lost its layout manager when "
                        + "the undo replaced the scrap's ScrapLayout, so anything "
                        + "that lays this view out in the next moment has nothing "
                        + "to lay it out with")
        XCTAssertNotNil(editor.textStorage,
                        "the storage the writer is typing into was deallocated "
                        + "underneath the live editor")
        XCTAssertEqual(editor.string, scrapText + ". Rain.",
                       "the mounted view cannot read its own text mid-window — it "
                       + "still shows the words the undo discarded, which is right, "
                       + "and the rebind below is what replaces them")

        // A display and a layout pass, which is what would actually arrive here.
        editor.layoutSubtreeIfNeeded()
        editor.needsDisplay = true
        editor.displayIfNeeded()
        _ = editor.selectedRange()

        pump()
        XCTAssertEqual(try mountedText(in: window), scrapText + ".",
                       "the rebind never happened, so the writer is looking at the "
                       + "sentence ⌘Z was supposed to take back")
    }

    /// **Undoing away the focused scrap must take the writer out of it**, which
    /// is the smoke's own three-keystroke sequence: double-click bare canvas,
    /// type, ⌘Z, ⌘Z.
    ///
    /// The second ⌘Z removes the node the writer is standing in. `mountedEditor`
    /// guards on `scene.node(id)`, so the editor unmounts and the strandedness is
    /// invisible — `editingNodeID`, `caretIndex` and `straighten` all go on naming
    /// a node that no longer exists. ⇧⌘Z is where it becomes visible: the card
    /// comes back and that stale focus silently drops the writer inside a text
    /// editor they never clicked into, caret placed, with the next keystroke
    /// going into the scrap rather than to the canvas.
    ///
    /// This is the state `handleClick`'s `.unenterableNode` case already refuses
    /// to leave standing, reached from the undo path instead of the click path.
    func test_undoingAwayTheFocusedScrapTakesTheWriterOutOfIt() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root, paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // Bare canvas, well clear of the fixture's card at (20,20)–(260,80).
        events.applyMouseDown(at: CGPoint(x: 500, y: 400), clickCount: 2)
        pump(0.3)
        let created = try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                                    "a double-click on bare canvas made no scrap, so "
                                    + "there is no New Scrap step to undo past")
        type("Rain.", into: try XCTUnwrap(created.textView))
        pump(0.05)

        // ⌘Z — takes back the typing. The editor is still mounted afterwards, on a
        // rebound text view, so the container is re-found rather than reused.
        try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted)).undo(nil)
        pump()
        XCTAssertEqual(try mountedText(in: window), "",
                       "precondition: the first ⌘Z took back the typing and left the "
                       + "writer in the new, empty scrap")

        // ⌘Z again — takes back the card the writer is standing in.
        try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted)).undo(nil)
        pumpUntilSaved()
        XCTAssertNil(firstDescendant(ScrapEditorContainer.self, in: hosted),
                     "precondition: the second ⌘Z removed the focused scrap, so the "
                     + "editor is gone")
        XCTAssertEqual(sceneOnDisk(root).count, 1,
                       "precondition: the new card really is off the canvas, so the "
                       + "redo below is a real redo")

        // ⇧⌘Z, through the manager the event view vends — there is no editor left
        // to route it, which is the writer's position too.
        let manager = try XCTUnwrap(events.undoManager)
        XCTAssertTrue(manager.canRedo, "precondition: there is something to redo")
        manager.redo()
        pumpUntilSaved()

        XCTAssertEqual(sceneOnDisk(root).count, 2,
                       "precondition: ⇧⌘Z brought the card back")
        XCTAssertNil(firstDescendant(ScrapEditorContainer.self, in: hosted),
                     "⇧⌘Z brought the card back and put the writer inside it, caret "
                     + "and all, without their ever clicking into it: the undo that "
                     + "removed the scrap left `editingNodeID` naming it, so the "
                     + "editor remounts the moment the node exists again and the "
                     + "next keystroke goes into the scrap instead of to the canvas")
    }

    /// The same sequence asked the other way: after undoing away the scrap the
    /// writer was in, the canvas still responds to a drag.
    ///
    /// **This passes with the focus reconciliation removed, and saying so is the
    /// point.** The reconciliation looks, from outside, like the thing that keeps
    /// drags alive — `handleDrag`'s `.began` bails at
    /// `guard editingNodeID == nil`, so a stranded id reads like a canvas that
    /// ignores every drag until the writer clicks. It is not, and measured
    /// against the unfixed code this test was green: `CanvasEventNSView`'s
    /// `applyMouseDown` runs `onClick` strictly before `onDrag(.began)` — a
    /// documented contract in that file — so a drag cannot BEGIN without
    /// `handleClick` having cleared the stale id microseconds earlier, in the
    /// same call. The sibling test above is the one that can fail on the
    /// reconciliation.
    ///
    /// What this pins is that the two defences do not BOTH go. Measured by
    /// mutation: reordering those two callbacks alone leaves it green (the
    /// reconciliation covers it), removing the reconciliation alone leaves it
    /// green (the ordering covers it), and removing both fails it here with
    /// `("20.0") is not equal to ("60.0")` — the card never moved.
    /// The sequence is the hand-smoke's, which is why it is asked at all.
    func test_undoingBackPastANewScrapLeavesTheCanvasRespondingToDrags() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root, paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        events.applyMouseDown(at: CGPoint(x: 500, y: 400), clickCount: 2)
        pump(0.3)
        let created = try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                                    "a double-click on bare canvas made no scrap")
        type("Rain.", into: try XCTUnwrap(created.textView))
        pump(0.05)

        try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted)).undo(nil)
        pump()
        try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted)).undo(nil)
        pump()

        // Drag the fixture's card 40pt right, with the last two samples identical
        // so nothing flicks and the assertion is about the drag alone.
        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 100, y: 40), CGPoint(x: 100, y: 40)])
        pumpUntilSaved()

        let dragged = try XCTUnwrap(sceneOnDisk(root).node(scrapID))
        XCTAssertEqual(dragged.origin.x, 60, accuracy: 0.5,
                       "the card did not move after an undo took away the scrap the "
                       + "writer was in — the likeliest cause is `onClick` no longer "
                       + "running before `onDrag(.began)`, which is what clears the "
                       + "stale `editingNodeID` before the drag guard reads it")
    }

    /// **⌘Z during a coast must not leave the card somewhere the writer never put
    /// it.** The coast steps `scene` directly, frame by frame, outside any
    /// gesture; an undo that restores the pick-up point without stopping it hands
    /// the momentum a fresh starting position and the card skates off from there —
    /// and that resting place is what reaches disk.
    ///
    /// The window is the ~1 s after a flick, which is exactly when a writer who
    /// did not mean that throw reaches for ⌘Z.
    func test_undoDuringACoastLeavesTheCardWhereTheWriterPickedItUp() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root, paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // The flick `test_aFlickCarriesTheCardOnPastWhereThePointerLetGo` measures:
        // 10 pt on the last frame, carrying ≈47.8 pt past the release point.
        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 70, y: 40), CGPoint(x: 80, y: 40)])
        // NO pump: the coast is live and has travelled nothing yet, which is the
        // moment this test is about.
        let manager = try XCTUnwrap(events.undoManager)
        XCTAssertTrue(manager.canUndo, "precondition: the drag registered a step")
        manager.undo()
        pumpUntilSaved()                       // a surviving coast finishes, then the debounce

        let restored = try XCTUnwrap(sceneOnDisk(root).node(scrapID))
        XCTAssertEqual(restored.origin.x, 20, accuracy: 0.5,
                       "⌘Z put the card back and the coast then carried it away "
                       + "again, so it came to rest somewhere the writer never put "
                       + "it — and that is the position that reached disk")
    }

    /// The same rule in the RESIZE branch, where it is easier to get wrong.
    ///
    /// `CanvasScene.setWidth` clears `cachedHeight` on every `.changed`, identical
    /// width or not, so between the press and `rebuildLayouts()` the card has no
    /// height — and `CanvasNode` is `Equatable` including that field. Close the
    /// gesture before the re-measure rather than after and the snapshot diff is
    /// "card with a height" against "card with none", which are different, so a
    /// corner press that never moved leaves a step behind.
    ///
    /// The geometry is `test_aCornerPressThatNeverMovedLeavesTheCardOnTheCanvas`'s,
    /// which is the same gesture asked a different question: that one asks whether
    /// the card survives, this one asks whether ⌘Z was quietly spent on it.
    func test_aCornerPressThatNeverMovedLeavesNothingToUndo() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // Read the corner off the surface rather than writing the font metrics
        // down twice — the mounted editor's box is the card's text box, inset.
        let textBox = swiftUIFrame(of: try doubleClickTheScrap(in: window), in: hosted)
        let cardCorner = CGPoint(x: textBox.maxX + CanvasCardMetrics.inset,
                                 y: textBox.maxY + CanvasCardMetrics.inset)
        events.applyMouseDown(at: CGPoint(x: 600, y: 500), clickCount: 1)   // click away
        events.applyMouseUp(at: CGPoint(x: 600, y: 500))
        pump()

        let manager = try XCTUnwrap(events.undoManager)
        XCTAssertFalse(manager.canUndo, "precondition: nothing on the stack yet")

        let press = CGPoint(x: cardCorner.x - 2, y: cardCorner.y - 2)
        drag(events, from: press, through: [press])
        pump()

        XCTAssertFalse(manager.canUndo,
                       "a corner press that never moved left a step on the stack — "
                       + "⌘Z is spent on it and appears to do nothing, and its redo "
                       + "re-applies a card with no measured height, which has no "
                       + "frame and so vanishes from the canvas entirely")

        // The positive control. Without it a resize path that registered NOTHING
        // EVER — no `beginGesture` in `.began`, say — would satisfy the assertion
        // above and delete ⌘Z from the corner handle in silence. Its sibling
        // `test_aPressThatNeverMovedLeavesNothingToUndo` has had one since it was
        // written; this one did not.
        drag(events, from: press, through: [CGPoint(x: press.x + 40, y: press.y)])
        pump()
        XCTAssertTrue(manager.canUndo,
                      "a resize that really widened the card registered nothing, so "
                      + "the assertion above passes for the wrong reason: the corner "
                      + "handle has no undo at all")
    }

    /// **⌘Z must be reachable with NO scrap focused**, which is the 1C-a
    /// hand-smoke defect: "undo is available but only when a scrap is focussed
    /// and in edit mode".
    ///
    /// Every other undo test in this slice drives the recorder or the manager
    /// directly — `container.undo(nil)`, `manager.undo()` — so twenty-two of them
    /// pass while the writer's ⌘Z does nothing at all. What is untested is the
    /// app's real delivery path: an Edit-menu item with a nil target, resolved
    /// against the responder chain, VALIDATED, and only then sent. All three
    /// steps are asked here, because the failure was in the first two.
    ///
    /// The measured before-state, with the drag below on the stack: the chain
    /// walk found `NSWindow` (nothing nearer responded to `undo:`),
    /// `NSWindow.validateUserInterfaceItem` returned **false**, and performing
    /// the action left the card where the drag had put it. `CanvasEventNSView`
    /// held an `undoManager` override and nothing else, and an `undoManager`
    /// override alone does not put an action in the responder chain.
    func test_undoIsReachableFromTheEditMenuWithNoScrapFocused() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root, paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // A real step on the canvas's own stack: 40pt right, last two samples
        // identical so nothing flicks and the assertion is about the undo.
        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 100, y: 40), CGPoint(x: 100, y: 40)])
        pumpUntilSaved()
        XCTAssertEqual(try XCTUnwrap(sceneOnDisk(root).node(scrapID)).origin.x, 60,
                       accuracy: 0.5,
                       "precondition: the card really moved, so there is something "
                       + "for the menu to take back")
        XCTAssertTrue(try XCTUnwrap(events.undoManager).canUndo,
                      "precondition: the drag left a step on the canvas's own stack, "
                      + "so what follows is about REACHING it rather than about "
                      + "whether it exists")

        // What a click on bare canvas does. `CanvasEventNSView.mouseDown(with:)`
        // claims first responder; the testable seam `drag` goes through does no
        // event-level responder work (synthesizing `NSEvent`s is unreliable — see
        // that file), so the claim is made here in its place.
        XCTAssertTrue(window.makeFirstResponder(events),
                      "the canvas cannot hold first responder, so a writer who "
                      + "clicks out of a scrap has no ⌘Z at all")
        XCTAssertNil(firstDescendant(ScrapEditorContainer.self, in: hosted),
                     "precondition: no scrap is focused — this is exactly the state "
                     + "the writer reported undo greyed out in")

        let undoSelector = #selector(CanvasEventNSView.undo(_:))
        let undo = try editMenuItem(undoSelector, in: window)
        XCTAssertTrue(undo.target === events,
                      "the Edit menu's Undo resolves to \(undo.target) rather "
                      + "than to the canvas: an `undoManager` override does not put "
                      + "`undo:` in the responder chain, so the action walks past the "
                      + "canvas to the window and drives the window's stack instead")
        XCTAssertTrue(undo.isEnabled,
                      "Undo is greyed out on a canvas with a move on its stack — the "
                      + "writer's report, exactly: the feature is built, tested and "
                      + "unreachable unless a scrap happens to be focused")
        XCTAssertTrue(undo.item.title.contains("Move Card"),
                      "the menu item reads \"\(undo.item.title)\" rather than naming the "
                      + "gesture it will take back — the action never reaches "
                      + "NSWindow, so nothing else retitles it")

        // Sent the way the menu sends it, to the target the walk found.
        _ = undo.target.perform(undoSelector, with: undo.item)
        pumpUntilSaved()
        XCTAssertEqual(try XCTUnwrap(sceneOnDisk(root).node(scrapID)).origin.x, 20,
                       accuracy: 0.5,
                       "the Edit menu's Undo was enabled and did nothing to the "
                       + "canvas — it is wired to some other stack")

        // The other half of the pair, which nothing else asks through the menu.
        let redo = try editMenuItem(#selector(CanvasEventNSView.redo(_:)), in: window)
        XCTAssertTrue(redo.target === events,
                      "⇧⌘Z does not resolve to the canvas even though ⌘Z does")
        XCTAssertTrue(redo.isEnabled,
                      "there is nothing to redo straight after an undo, so ⇧⌘Z is "
                      + "greyed out and the writer cannot take the undo back")
        XCTAssertTrue(redo.item.title.contains("Move Card"),
                      "the Redo item reads \"\(redo.item.title)\" rather than naming the "
                      + "gesture it will re-apply")
    }

    /// **The undo stack is bounded.** `UndoManager`'s default `levelsOfUndo` is
    /// 0, meaning unlimited, and every step here retains a whole `CanvasScene`
    /// plus every scrap's text — at one step per SENTENCE typed. Unbounded, a
    /// long session's stack is tens of megabytes that nothing gives back until
    /// the window closes.
    ///
    /// Asked of the manager the surface actually vends, not of a manager the test
    /// built: a cap set on the wrong object bounds nothing.
    func test_theCanvasUndoStackIsBounded() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let manager = try XCTUnwrap(try eventView(in: window).undoManager)
        XCTAssertGreaterThan(manager.levelsOfUndo, 0,
                             "levelsOfUndo is 0 — UndoManager's default, which means "
                             + "UNLIMITED. Every canvas step retains a copy of the "
                             + "whole scene and of every scrap's string, and nothing "
                             + "drops any of it until the window closes")
        XCTAssertFalse(manager.groupsByEvent,
                       "the shipping manager is not the one the unit tests exercise: "
                       + "with groupsByEvent on, two gestures landing in one pass of "
                       + "the event loop collapse into a single ⌘Z")
    }

    /// **`syncActiveEdit`'s `fromKeystroke` default is `false`, and quitting is
    /// what it is for.**
    ///
    /// `CanvasStore.beforeFlush` runs at app quit and folds the live editor's
    /// text in — that is how a sentence typed and never clicked away from reaches
    /// disk. What it must NOT do is move an undo boundary: a writer who paused
    /// for two seconds and then pressed ⌘Q would trip the idle rule there,
    /// closing a step and REOPENING a gesture on a view that is going away.
    ///
    /// **The setup has to make the model STALE, and that is the whole difficulty.**
    /// `syncActiveEdit` returns at its "nothing changed" guard when `scraps[id]`
    /// already equals the live layout's text — which it does after every
    /// keystroke, because `onTextChanged` folds on every one. So the boundary
    /// rules are simply never reached at flush time on the ordinary path, and
    /// that is exactly why flipping the default left the whole suite green: there
    /// was nothing to fold, so nothing to break a step on.
    ///
    /// The state `beforeFlush` is written for is text sitting in the shared
    /// `NSTextStorage` that never came through `onTextChanged`, so this test
    /// constructs it the only honest way — by detaching the delegate for the
    /// duration of the edit, which is what "the model is behind the storage"
    /// means in one line. Everything after that is the production path.
    ///
    /// The ORDER of the two waits is load-bearing and was measured, not guessed.
    /// `CanvasStore`'s 750 ms save debounce calls the same `beforeFlush` hook, and
    /// 750 ms is inside `ScrapUndoBeat.idleSeconds` — so a stale edit made before
    /// the debounce fires is folded at 0.75 s, with the beat not yet elapsed, and
    /// the rule under test is never reached. Let the debounce go first; the stale
    /// edit that follows schedules none of its own, so the next fold is the quit.
    func test_quittingAfterAPauseFoldsTheTextInWithoutMovingAnUndoBoundary() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root, paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        // One run, no terminator anywhere, so only a pause could ever close it.
        type(" and the sodium light", into: editor)
        // Past the debounce, still inside the idle beat — the same slot the
        // production constants give this wait (0.75 < 1.0 < 1.5, here
        // 0.05 < 0.1 < 0.5). The save debounce goes first; see the doc above.
        waitOut(0.1)
        let manager = try XCTUnwrap(try eventView(in: window).undoManager)
        XCTAssertFalse(manager.canUndo,
                       "precondition: the whole visit is still inside the open "
                       + "gesture, so the manager's stack is empty")

        // Behind the delegate's back, so the model is left holding the text as it
        // was — the condition the quit hook exists to fold in.
        let delegate = editor.delegate
        editor.delegate = nil
        editor.insertText(" on the wet stone",
                          replacementRange: NSRange(
                            location: (editor.string as NSString).length, length: 0))
        editor.delegate = delegate
        waitOut(Self.testUndoIdle + 0.1)               // the writer sits back
        XCTAssertFalse(manager.canUndo, "precondition: still nothing registered")

        NotificationCenter.default.post(   // adr-0021-ok: AppKit lifecycle notification, not a maugham.* event — this is what CanvasStore observes for quit
            name: NSApplication.willTerminateNotification,
            object: NSApplication.shared)

        let scrapsURL = root.appendingPathComponent(CanvasStore.scrapsRelativePath)
        XCTAssertTrue(try String(contentsOf: scrapsURL, encoding: .utf8).contains("wet stone"),
                      "precondition: the quit hook really did fold the text in, so "
                      + "the assertion below is about what it did NOT do")
        XCTAssertFalse(manager.canUndo,
                       "quitting after a pause closed an undo step and reopened a "
                       + "gesture on a view that is going away — `beforeFlush` took "
                       + "`fromKeystroke: true`, and only a real keystroke may move "
                       + "an undo boundary")
    }

    // MARK: - Escape, the keyboard spelling of the project row (§4.1)

    /// **Escape belongs to the mounted editor, and this is the case that had to
    /// be driven rather than reasoned about.**
    ///
    /// §4.1: *"If the writer is typing in a card, Escape belongs to the text
    /// view; the canvas may only see it when no editor is mounted. Breaking
    /// editing to add a shortcut is not a trade this slice makes."* The key is
    /// posted through `window.sendEvent(_:)` — the real routing — with the canvas
    /// deliberately given first responder first, so the test starts from the state
    /// where Escape WOULD have reached the canvas and shows that entering a scrap
    /// takes it away again.
    ///
    /// **Delivered through `NSApp.sendEvent(_:)` since 2026-08-04, and the change
    /// is not cosmetic.** Escape now runs through `CanvasEscapeMonitor`, and a
    /// local monitor is invoked from the APPLICATION's dispatch — `window
    /// .sendEvent(_:)` bypasses it entirely, so the old spelling of this test
    /// would pass against a canvas that ate every Escape in the app.
    func test_escapeInsideAMountedScrapNeverReachesTheDim() throws {
        var asked = 0
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1"),
                                     selectTheProjectRow: { asked += 1 }))
        let events = try eventView(in: window)
        clickAndFocusTheCanvas(events, at: CGPoint(x: 600, y: 500), in: window)
        XCTAssertTrue(window.firstResponder === events,
                      "precondition: the canvas holds the keyboard, so an Escape "
                      + "now would reach it")

        _ = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(
            firstDescendant(NSTextView.self, in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.firstResponder === editor,
                      "precondition: the editor holds first responder")

        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.3)

        XCTAssertEqual(window.escapesDelivered, 1,
                       "the canvas SWALLOWED the writer's Escape instead of "
                       + "declining it. The dim not lifting is not enough — a key "
                       + "eaten silently and a key passed on look identical from "
                       + "the subject, and this one has to reach the editor")
        XCTAssertEqual(asked, 0,
                       "Escape inside a scrap cleared the dim: the writer pressed "
                       + "the key that cancels what they are typing and the window's "
                       + "subject changed under them instead")
        XCTAssertTrue(window.firstResponder === editor,
                      "the editor lost first responder to an Escape it should have "
                      + "handled itself")
        XCTAssertEqual(editor.string, scrapText, "the words are untouched")
    }

    /// The same refusal at the one moment the responder chain does NOT protect
    /// it: a scrap is open while the event view still holds the keyboard.
    ///
    /// That window is real and this file's own source records it — a press opens
    /// a gesture at `.began` and holds it, and the turn after a double-click has
    /// "Edit Scrap" open while this view is still first responder (see the
    /// `undoManager:` note in `CanvasView.body`, and `deleteSelection`'s
    /// `isInGesture` guard, which exists because ⌫ found exactly this).
    ///
    /// **The guard is what this test is about, and since 2026-08-04 it is the
    /// SECOND of the two things that would have to fail.** The monitor declines a
    /// text responder before it ever asks the canvas, so the assertion on
    /// `onEscape()` below is the one that reaches the guard — it calls the
    /// canvas's own answer directly, with a scrap genuinely open.
    func test_escapeIsRefusedWhileAScrapIsOpenEvenIfTheCanvasStillHoldsTheKey() throws {
        var asked = 0
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1"),
                                     selectTheProjectRow: { asked += 1 }))
        let events = try eventView(in: window)
        _ = try doubleClickTheScrap(in: window)

        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.2)

        XCTAssertEqual(window.escapesDelivered, 1,
                       "the Escape was swallowed with a scrap open — the writer "
                       + "pressed the key that cancels what they are typing and "
                       + "nothing at all received it")
        XCTAssertEqual(asked, 0,
                       "the canvas cleared the dim while a scrap was open — Escape "
                       + "is the writer cancelling what they are typing, and it must "
                       + "lose to the editor by a guard as well as by the responder "
                       + "chain")
        XCTAssertEqual(events.onEscape?(), false,
                       "the canvas refused the Escape and CLAIMED it anyway, so the "
                       + "key stops here instead of travelling on to whatever the "
                       + "writer was actually cancelling")
    }

    /// **Escape on a dimmed board asks for the project row**, which is §4.1's
    /// whole ruling: it is the keyboard spelling of that row, not a second state
    /// that resembles it. What the window then DOES with the ask is
    /// `ProjectWindow`'s — and that it writes the same value the row's own `.tag`
    /// carries is pinned in `PromotionCommandTests`' wiring census.
    func test_escapeOnADimmedBoardAsksForTheProjectRow() throws {
        var asked = 0
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1"),
                                     selectTheProjectRow: { asked += 1 }))
        let events = try eventView(in: window)
        clickAndFocusTheCanvas(events, at: CGPoint(x: 600, y: 500), in: window)

        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.3)

        XCTAssertEqual(asked, 1,
                       "Escape on a dimmed board did nothing — the dim is a state "
                       + "the writer deliberately enters and must be able to leave "
                       + "(Denver: \"I like the ability to keep sweeping but it "
                       + "needs a way out\")")
    }

    /// **THE SMOKE FIND (2026-08-04), and the only test in this file that starts
    /// from the state the writer is actually in.**
    ///
    /// The ordinary way into the dim is clicking a chapter in Plan's tree, which
    /// leaves the keyboard in the SIDEBAR. Every other Escape test above focuses
    /// the canvas first, so all of them pass against a canvas that can only hear
    /// Escape when it already holds the keyboard — which is exactly the defect:
    /// in full screen the first Escape left full screen and only the second lifted
    /// the dim, because the key travelled up the responder chain unhandled and
    /// `NSWindow` was the first thing on it that wanted Escape. Full screen was
    /// never the culprit; outside it the same press was equally lost and merely
    /// looked like nothing happening.
    ///
    /// So the canvas has NOTHING focused here, and the event goes through
    /// `NSApp.sendEvent(_:)` rather than `window.sendEvent(_:)` — measured
    /// 2026-08-04, a local monitor is invoked from the APPLICATION's dispatch and
    /// `window.sendEvent` bypasses it entirely, so the window-level spelling every
    /// other test in this section uses cannot see this mechanism at all.
    func test_escapeLeavesTheDimWithTheKeyboardSomewhereElseEntirely() throws {
        var asked = 0
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1"),
                                     selectTheProjectRow: { asked += 1 }))
        let events = try eventView(in: window)
        // `nil` makes the WINDOW first responder — the canvas has never been
        // clicked, which is the state clicking a chapter in the tree leaves.
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(window.firstResponder === events,
                       "precondition: the canvas must NOT hold the keyboard, or "
                       + "this test measures the path that already worked")

        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.3)

        XCTAssertEqual(asked, 1,
                       "Escape did not lift the dim with the keyboard in the "
                       + "sidebar — the writer clicks a chapter, the board dims, "
                       + "and the key that leaves it reaches nothing")
        XCTAssertEqual(window.escapesDelivered, 0,
                       "the dim lifted but the key travelled on to the window as "
                       + "well, which is the smoke find itself: in full screen "
                       + "NSWindow takes it and the writer leaves full screen at "
                       + "the same moment their board undims")
    }

    /// A GROUP dims the board too, so Escape is its way out as well — the dim is
    /// what Escape answers, not the kind of thing selected.
    func test_escapeLeavesTheDimAGroupPutTheBoardIn() throws {
        var asked = 0
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .group(["ch1", "ch2"]),
                                     selectTheProjectRow: { asked += 1 }))
        let events = try eventView(in: window)
        clickAndFocusTheCanvas(events, at: CGPoint(x: 600, y: 500), in: window)

        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.3)
        XCTAssertEqual(asked, 1, "a group dims the board and Escape did not lift it")
    }

    /// **On an undimmed board Escape is a no-op, not an error**, and it must not
    /// be claimed: there is nothing to leave, and Escape means something to
    /// plenty of responders above this one.
    func test_escapeOnAnUndimmedBoardIsANoOp() throws {
        var asked = 0
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .wholeProject,
                                     selectTheProjectRow: { asked += 1 }))
        let events = try eventView(in: window)
        clickAndFocusTheCanvas(events, at: CGPoint(x: 600, y: 500), in: window)

        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.3)
        XCTAssertEqual(asked, 0,
                       "Escape on a board that is not dimmed asked the window to "
                       + "change its subject — a keystroke that does something "
                       + "invisible is worse than one that does nothing")
        XCTAssertEqual(events.onEscape?(), false,
                       "the canvas claimed an Escape it did nothing with. Nothing on "
                       + "screen can show that, and every responder above the canvas "
                       + "that wanted the key — a sheet, a find bar — stops getting "
                       + "it")
    }

    // MARK: - What a monitor can break (2026-08-04)

    /// **THE SHARPEST HAZARD THE MONITOR CREATES, driven rather than reasoned
    /// about.**
    ///
    /// The binder's inline rename (tripwire 16) uses Escape to CANCEL the rename,
    /// and a writer can be renaming a chapter while the board is dimmed — indeed
    /// that is the ordinary state, since clicking the chapter is what dimmed it.
    /// A monitor eats the key wherever the keyboard is, so a monitor without a
    /// text-responder guard takes the cancel away from every rename in the window.
    ///
    /// A real SwiftUI `TextField` beside a real canvas in one window, focused for
    /// real. What holds first responder afterwards is the window's FIELD EDITOR
    /// rather than the field — which is why the production guard tests `NSText`
    /// and not `NSTextView`, and why that was measured here instead of read off
    /// the hierarchy.
    func test_theMonitorDoesNotEatTheEscapeThatCancelsAnInlineRename() throws {
        var asked = 0
        let root = try projectRoot()
        let window = hostBesideARenameField(
            CanvasView(model: makeModel(), projectRoot: root,
                       paletteSwatchHexes: { [] },
                       subject: .piece("ch1"),
                       selectTheProjectRow: { asked += 1 }))
        let events = try eventView(in: window)
        XCTAssertTrue(events.hasEscapeMonitorInstalled,
                      "precondition: the monitor is installed. Without this the "
                      + "assertions below pass against a canvas that never watched "
                      + "for Escape at all")
        let field = try XCTUnwrap(
            firstDescendant(NSTextField.self, in: try XCTUnwrap(window.contentView)),
            "the rename field never reached the hierarchy, so this test would "
            + "measure a canvas standing on its own")
        XCTAssertTrue(window.makeFirstResponder(field),
                      "precondition: the writer is renaming a chapter")
        pump()
        XCTAssertTrue(CanvasEscapeMonitor.isEditingText(window.firstResponder),
                      "precondition: the thing holding the keyboard must be one the "
                      + "production predicate recognises as text — if this fails the "
                      + "predicate is wrong about the responder AppKit really "
                      + "installs, which is the whole point of driving it")

        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.3)

        XCTAssertEqual(window.escapesDelivered, 1,
                       "the dimmed board ate the Escape that cancels an inline "
                       + "rename — the writer is renaming a chapter, presses the key "
                       + "that takes it back, and nothing happens")
        XCTAssertEqual(asked, 0,
                       "the dim lifted out from under a rename: the writer cancelled "
                       + "a title and the window changed its subject instead")

        // **The offender, planted and driven down the same wire.** A monitor
        // without the text-responder guard, installed after the probe so it runs
        // before it. If this does not eat the Escape the assertion above is not
        // measuring the guard at all.
        plantAMonitor { _ in nil }
        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.3)
        XCTAssertEqual(window.escapesDelivered, 1,
                       "the planted guardless monitor did NOT eat the rename's "
                       + "Escape, so this test cannot tell a guarded monitor from "
                       + "an unguarded one and proves nothing about either")
    }

    /// **Scope: one window's dim must not reach into another's.**
    ///
    /// A local monitor is APP-global, which is the whole reason tripwire 21 exists
    /// on this codebase — an unscoped delivery has shipped the same defect three
    /// times. With two projects open, an Escape addressed to the other window must
    /// travel on untouched.
    func test_aDimmedBoardDoesNotEatEscapeInAnotherWindow() throws {
        var asked = 0
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1"),
                                     selectTheProjectRow: { asked += 1 }))
        let events = try eventView(in: window)
        XCTAssertTrue(events.hasEscapeMonitorInstalled,
                      "precondition: the monitor is installed, or nothing below is "
                      + "about scope")
        // The OTHER window is the key one — the writer clicked into their second
        // project and pressed Escape there, which is the whole scenario.
        let other = TestWindow.make(CanvasHostWindow.self,
                                    contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                                    present: .key)
        windows.append(other)

        NSApp.sendEvent(escapeKeyEvent(for: other))
        pump(0.3)

        XCTAssertEqual(other.escapesDelivered, 1,
                       "the canvas in ONE window swallowed an Escape addressed to "
                       + "ANOTHER — with two projects open, every sheet, find bar "
                       + "and rename in the second window loses its Escape")
        XCTAssertEqual(asked, 0,
                       "the other window's Escape changed this window's subject")

        // **The offender, planted and driven down the same wire**: the monitor
        // without its window check, which is what an app-global monitor is if
        // nobody scopes it (tripwire 21). It must eat this one.
        plantAMonitor { _ in nil }
        NSApp.sendEvent(escapeKeyEvent(for: other))
        pump(0.3)
        XCTAssertEqual(other.escapesDelivered, 1,
                       "the planted unscoped monitor let the other window's Escape "
                       + "through, so the assertion above would pass whether the "
                       + "production monitor were scoped or not")
    }

    /// **The monitor exists only while the board is dimmed, and going undimmed
    /// takes it away.**
    ///
    /// Driven through a real subject change rather than by reading
    /// `hasEscapeMonitorInstalled` alone: the flag says a monitor is installed,
    /// the probe says whether it is still eating keys, and only the pair rules out
    /// a `remove()` that clears the token while leaving AppKit's block behind.
    func test_theMonitorIsInstalledOnlyWhileTheBoardIsDimmed() throws {
        var asked = 0
        let root = try projectRoot()
        let subject = MutableSubject()
        let window = hostSwitchable(subject: subject, root: root,
                                    selectTheProjectRow: { asked += 1 })
        let events = try eventView(in: window)
        XCTAssertTrue(events.hasEscapeMonitorInstalled,
                      "precondition: a dimmed board installs the monitor")

        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.3)
        XCTAssertEqual(asked, 1, "precondition: the dimmed board answers Escape")
        XCTAssertEqual(window.escapesDelivered, 0, "precondition: and consumes it")

        subject.value = .wholeProject
        pump(0.3)
        XCTAssertFalse(events.hasEscapeMonitorInstalled,
                       "the monitor outlived the dim — an app-global key eater with "
                       + "nothing left to do")

        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.3)
        XCTAssertEqual(asked, 1, "an undimmed board answered Escape anyway")
        XCTAssertEqual(window.escapesDelivered, 1,
                       "the removed monitor is still consuming keys, so `remove()` "
                       + "cleared its token and left AppKit holding the block")
    }

    /// **And it does not outlive the VIEW.** A leaked monitor is invisible until
    /// it eats a key in a window that no longer has a canvas — the failure mode
    /// with no symptom on the surface that caused it.
    func test_theMonitorDoesNotOutliveTheCanvas() throws {
        var asked = 0
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1"),
                                     selectTheProjectRow: { asked += 1 }))
        let events = try eventView(in: window)
        XCTAssertTrue(events.hasEscapeMonitorInstalled, "precondition")

        // The canvas leaves the window — the pane swap, the persona switch, the
        // window closing. SwiftUI dismantles the representable and AppKit pulls
        // the view out of its window.
        window.contentView = NSView(frame: window.frame)
        pump(0.3)
        XCTAssertFalse(events.hasEscapeMonitorInstalled,
                       "the monitor survived the canvas leaving the window")

        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.3)
        XCTAssertEqual(window.escapesDelivered, 1,
                       "a canvas that is no longer on screen is still eating the "
                       + "writer's Escape")
        XCTAssertEqual(asked, 0)
    }

    /// **Exactly one mechanism runs, and this names which.**
    ///
    /// `CanvasEventNSView.keyDown` had an Escape arm and it is gone: on a dimmed
    /// board the monitor consumes the key one layer above the responder chain, so
    /// the arm could never run. This test drives the key STRAIGHT into the event
    /// view — the delivery the arm existed for, with the canvas holding first
    /// responder on a dimmed board — and shows nothing happens. Paired with
    /// `test_escapeLeavesTheDimWithTheKeyboardSomewhereElseEntirely`, which shows
    /// the monitor doing the work, the pair is what a comment claiming "the arm is
    /// redundant" cannot be.
    func test_theEventViewNoLongerHandlesEscapeItselfBecauseTheMonitorDoes() throws {
        var asked = 0
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1"),
                                     selectTheProjectRow: { asked += 1 }))
        let events = try eventView(in: window)
        clickAndFocusTheCanvas(events, at: CGPoint(x: 600, y: 500), in: window)
        XCTAssertEqual(events.onEscape?(), true,
                       "precondition: the board IS dimmed and the canvas WOULD "
                       + "answer, so a still-live keyDown arm would lift the dim "
                       + "below and this test would be measuring nothing")
        asked = 0

        events.keyDown(with: escapeKeyEvent(for: window))
        pump(0.3)

        XCTAssertEqual(asked, 0,
                       "`keyDown` still handles Escape. Two mechanisms answer the "
                       + "same key under the same condition and only one of them "
                       + "can ever run — see the argument on `keyDown`")
    }

    /// **What a single click selects**, which nothing pinned until this test:
    /// replacing `selectionTarget`'s body with `return nil` left the whole suite
    /// green. The one existing assertion on `model.selection` pins the *create*
    /// branch's assignment, which is a different line.
    ///
    /// It matters beyond the accent stroke: this value is what the region
    /// inspector reads and what ⌫ will act on, so a selection that names the
    /// wrong thing is an edit to the wrong thing.
    ///
    /// The four presses are one sequence on purpose. Each asserts a different
    /// answer, so an implementation that always returned `nil` fails the first
    /// two and one that never cleared fails the last two.
    func test_aSingleClickSelectsTheThingUnderIt() throws {
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: try regionProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        func click(at point: CGPoint) {
            events.applyMouseDown(at: point, clickCount: 1)
            events.applyMouseUp(at: point)
            pump(0.05)
        }

        // On the card at (60,60)–(300,98), clear of its resize corner.
        click(at: CGPoint(x: 100, y: 80))
        XCTAssertEqual(model.selection, .node(scrapID),
                       "clicking a card does not select it")

        // On the region's chrome bar, (20,20)–(420,44).
        click(at: CGPoint(x: 200, y: 30))
        XCTAssertEqual(model.selection, .region(CanvasRegionID("r1")),
                       "clicking a region's label bar does not select the region — "
                       + "which is the only way to reach one, since its interior "
                       + "deliberately belongs to the cards in it")

        // The region's INTERIOR, below the card.
        click(at: CGPoint(x: 200, y: 200))
        XCTAssertNil(model.selection,
                     "clicking inside a region selected it: the interior is not a "
                     + "handle, and a click there that selects the region is the "
                     + "same rule the drag refuses, arriving from the click path")

        click(at: CGPoint(x: 200, y: 30))
        XCTAssertEqual(model.selection, .region(CanvasRegionID("r1")),
                       "precondition: something is selected again, so the clear "
                       + "below is a real clear")
        // Bare canvas, outside everything.
        click(at: CGPoint(x: 700, y: 500))
        XCTAssertNil(model.selection, "clicking bare canvas does not clear the "
                     + "selection, so the accent stays on a thing the writer has "
                     + "clicked away from")
    }

    /// **A single click on bare canvas opens a `.drawingRegion` gesture on every
    /// press, including the first of every double-click**, because
    /// `applyMouseDown` fires `onClick` and `onDrag(.began)` together. It ends
    /// immediately with a zero-size rect, which `createRegion` refuses — so the
    /// double-click that makes a scrap must still make exactly one scrap and no
    /// region, and must leave exactly one thing on the undo stack.
    ///
    /// This is the path point 2 of the task brief asks to be traced. It is
    /// asserted rather than reasoned about because the failure is silent: a
    /// `createRegion` with no minimum, or an `endGesture` that registered an
    /// unchanged scene, leaves the writer pressing ⌘Z twice to take back one
    /// card.
    func test_aDoubleClickOnBareCanvasStillMakesOneScrapAndNoRegion() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // The first press of the double-click, released — the whole of the
        // zero-size sweep, on its own.
        events.applyMouseDown(at: CGPoint(x: 500, y: 400), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 500, y: 400))
        pump()
        XCTAssertFalse(try XCTUnwrap(events.undoManager).canUndo,
                       "a single click on bare canvas left a step on the stack: the "
                       + "sweep it opened registered a scene that never moved")

        events.applyMouseDown(at: CGPoint(x: 500, y: 400), clickCount: 2)
        pump(0.3)
        type("Rain.", into: try XCTUnwrap(
            try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                          "the double-click made no scrap").textView))
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 0,
                       "the zero-size sweep that every press opens minted a region: "
                       + "double-clicking bare canvas now leaves a stray region "
                       + "behind every new scrap")
        XCTAssertEqual(onDisk.count, 2, "precondition: the new scrap is on the canvas")
    }

    // MARK: - ⌫, through the real responder chain

    /// **The delivery path, end to end, and it is the point of this task.**
    ///
    /// 1C-a built `CanvasScene.remove`, its inverse and the "Delete Scrap" undo
    /// step, exercised all three, and shipped no production caller — the same
    /// shape as its undo defect, which was twenty-two green tests deep on a ⌘Z
    /// that could not reach the canvas stack at all, because every one of those
    /// tests drove the recorder directly. So this one presses a real key: an
    /// `NSEvent` handed to `window.sendEvent(_:)`, routed by AppKit to whatever
    /// holds first responder, and asserted on what reached DISK.
    ///
    /// A `deleteSelection()` called by hand would pass this task's model-level
    /// tests and do nothing whatsoever for the writer.
    func test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain() throws {
        let root = try projectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Single click on the card: selects it and takes first responder.
        clickAndFocusTheCanvas(events, at: CGPoint(x: 60, y: 40), in: window)
        XCTAssertEqual(model.selection, .node(scrapID), "precondition: it is selected")
        XCTAssertTrue(window.firstResponder === events,
                      "precondition: the key will actually arrive here")
        XCTAssertTrue(try axTree(in: window)
            .compactMap { axString($0, "accessibilityValue") }.contains(scrapText),
                      "precondition: the card is in the published accessibility "
                      + "tree, so its absence below is a removal rather than a "
                      + "tree that never had it")

        window.sendEvent(deleteKeyEvent(for: window))
        pumpUntilSaved()

        XCTAssertNil(sceneOnDisk(root).node(scrapID),
                     "⌫ with a card selected did not delete it. The likeliest cause "
                     + "is that the key never reached CanvasEventNSView at all — "
                     + "which is exactly the defect this test exists for, and which "
                     + "every model-level assertion in this task is blind to")
        XCTAssertNil(scrapsOnDisk(root)[scrapID],
                     "the words go with the card — canvas.md is the only place "
                     + "they live, so a scrap left behind is an orphan paragraph in "
                     + "the writer's own file")
        XCTAssertFalse(try axTree(in: window)
            .compactMap { axString($0, "accessibilityValue") }.contains(scrapText),
                       "the deleted card is still in the accessibility tree: the "
                       + "structural bump never arrived, so a VoiceOver user goes on "
                       + "meeting a card that is not on the canvas until some "
                       + "unrelated change happens to rebuild the tree")
    }

    /// ⌫ over an empty selection is a no-op, not a guess.
    ///
    /// The control the assertion needs is the test above: the same key, the same
    /// window, the same first responder, and there it removes the card. So a
    /// scrap still on disk here can only be the empty selection.
    func test_backspaceWithNothingSelectedChangesNothing() throws {
        let root = try projectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Bare canvas, far from the fixture scrap at (20,20).
        clickAndFocusTheCanvas(events, at: CGPoint(x: 500, y: 400), in: window)
        XCTAssertNil(model.selection, "precondition: clicking nothing selects nothing")

        window.sendEvent(deleteKeyEvent(for: window))
        pumpUntilSaved()
        XCTAssertNotNil(sceneOnDisk(root).node(scrapID),
                        "⌫ over an empty selection must be a no-op, not a guess — "
                        + "a canvas that deletes the topmost card when nothing is "
                        + "selected loses the writer's work to a stray keystroke")
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], scrapText)
        XCTAssertFalse(try XCTUnwrap(events.undoManager).canUndo,
                       "a ⌫ that deleted nothing still pushed a step: the writer's "
                       + "next ⌘Z appears to do nothing, and the one after it takes "
                       + "back an edit they had stopped thinking about")
    }

    /// **⌫ never fights the editor.** While a scrap is focused the mounted text
    /// view is frontmost and first responder, so the key deletes a character —
    /// which is what the writer meant. If the event view ever won that race, a
    /// backspace mid-sentence would delete the whole card.
    ///
    /// Pinned rather than assumed, because the two ways it could break are both
    /// invisible from the model: an event view that took first responder back, or
    /// a `keyDown` moved onto a responder the editor's chain walks through.
    ///
    /// **The scrap is SELECTED before it is entered, and that is what makes this
    /// test about the race at all.** A double-click on its own leaves
    /// `model.selection` nil, so the card would survive ⌫ however the key was
    /// routed — the assertion would be vacuous and would stay green with the
    /// editor removed from in front of the event view entirely. Clicking once
    /// first leaves the selection standing through the visit, so this is a canvas
    /// where the event view has something to delete and does not get the chance.
    func test_backspaceInsideAScrapDeletesACharacterAndNotTheCard() throws {
        let root = try projectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        clickAndFocusTheCanvas(events, at: CGPoint(x: 60, y: 40), in: window)

        // The helper's own settle already outlasts the straighten, so the editor
        // is level, visible and first responder by the time it returns.
        _ = try doubleClickTheScrap(in: window)
        XCTAssertEqual(model.selection, .node(scrapID),
                       "precondition: the card is still SELECTED while the writer "
                       + "is inside it, so ⌫ reaching the event view would take the "
                       + "whole card")
        let editor = try XCTUnwrap(
            firstDescendant(NSTextView.self, in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.firstResponder === editor,
                      "precondition: the editor holds first responder, so the key "
                      + "never reaches CanvasEventNSView at all")

        editor.setSelectedRange(NSRange(location: (scrapText as NSString).length, length: 0))
        window.sendEvent(deleteKeyEvent(for: window))
        pumpUntilSaved()

        XCTAssertNotNil(sceneOnDisk(root).node(scrapID),
                        "a backspace mid-sentence deleted the whole card: the event "
                        + "view won the race with the mounted editor")
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], String(scrapText.dropLast()),
                       "exactly one character, and it reached disk")
    }

    /// The undo layer has been waiting for this caller since 1C-a. One ⌘Z brings
    /// the card back **with its words** — the scene and the scrap text are one
    /// snapshot, which is why they cannot be restored out of step.
    ///
    /// Driven through the Edit menu's own resolve → validate → send, because that
    /// is the path the 1C-a defect was in.
    func test_undoBringsBackADeletedScrapWithItsWords() throws {
        let root = try projectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        clickAndFocusTheCanvas(events, at: CGPoint(x: 60, y: 40), in: window)
        window.sendEvent(deleteKeyEvent(for: window))
        pumpUntilSaved()
        XCTAssertNil(sceneOnDisk(root).node(scrapID), "precondition: it is gone")

        let undoSelector = #selector(CanvasEventNSView.undo(_:))
        let undo = try editMenuItem(undoSelector, in: window)
        XCTAssertTrue(undo.target === events,
                      "the Edit menu's Undo does not resolve to the canvas after a "
                      + "delete")
        XCTAssertTrue(undo.isEnabled,
                      "a delete left nothing on the undo stack, so the stray ⌫ that "
                      + "takes a card away is permanent")
        XCTAssertTrue(undo.item.title.contains("Delete Card"),
                      "the menu item reads \"\(undo.item.title)\" rather than naming "
                      + "what it will take back")
        _ = undo.target.perform(undoSelector, with: undo.item)
        pumpUntilSaved()

        XCTAssertNotNil(sceneOnDisk(root).node(scrapID))
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], scrapText,
                       "the words come back with the card — the scene and the "
                       + "scrap text are one snapshot, which is why they cannot "
                       + "be restored out of step")
    }

    /// **A ⌫ pressed while a gesture is open must delete nothing**, because a
    /// delete that happens inside somebody else's bracket cannot be taken back
    /// on its own.
    ///
    /// `CanvasUndo.beginGesture` takes NO snapshot when it nests, and
    /// `endGesture` registers nothing until depth reaches zero — so a delete
    /// opened inside an outer gesture disappears into it. Here the outer gesture
    /// is the "Move Card" that `handleDrag(.began)` opens on every press over a
    /// card: press and hold, press ⌫, and the card goes while the Edit menu has
    /// nothing to offer. Release, and it offers **"Undo Move Card"** — a move
    /// and a delete collapsed into one step under the wrong name.
    ///
    /// This is the reachable half. The lossy half is the test below.
    func test_backspaceDuringAnOpenDragDeletesNothing() throws {
        let root = try projectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Press on the card and DO NOT release: `onClick` selects it and
        // `onDrag(.began)` opens "Move Card" in the same mouse-down.
        events.applyMouseDown(at: CGPoint(x: 60, y: 40), clickCount: 1)
        XCTAssertTrue(window.makeFirstResponder(events))
        pump()
        XCTAssertEqual(model.selection, .node(scrapID),
                       "precondition: the press selected the card, so there is "
                       + "something for ⌫ to take")
        XCTAssertTrue(model.isInGesture,
                      "precondition: the press opened a gesture that is still open")

        window.sendEvent(deleteKeyEvent(for: window))
        pumpUntilSaved()

        XCTAssertNotNil(sceneOnDisk(root).node(scrapID),
                        "⌫ mid-drag deleted the card from inside the drag's own "
                        + "undo bracket: the delete registers no step of its own, "
                        + "so one ⌘Z takes back the move AND the delete together, "
                        + "named after the move")
        events.applyMouseUp(at: CGPoint(x: 60, y: 40))
        pumpUntilSaved()
        XCTAssertNotNil(sceneOnDisk(root).node(scrapID),
                        "the card came back only to go again when the drag ended")
    }

    /// **The lossy half, and the reason the guard is not merely tidy.**
    ///
    /// The editor claims first responder from `viewDidMoveToWindow`, so for the
    /// runloop turn after a double-click the EVENT VIEW still holds it, with
    /// "Edit Scrap" open and a live selection behind it. A ⌫ there deletes the
    /// card, registers nothing — and `scheduleSave()` writes it. If the writer
    /// then quits before the gesture closes, `detach()` calls `undo.release()`
    /// and drops the stack whole: **the card is gone from disk and no step was
    /// ever registered.** That is the product constitution's must #1.
    ///
    /// The window is narrow — this test reaches it by not turning the runloop,
    /// which is the only way to stand in it deliberately. It is a real state
    /// rather than a contrived one: the same bracket is open for the whole visit,
    /// and only the editor holding first responder keeps ⌫ away from the canvas.
    func test_backspaceBeforeTheEditorTakesFocusCannotLoseTheCardUnrecoverably() throws {
        let root = try projectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Click once to select, then enter the scrap — and do NOT pump, so the
        // editor has not yet claimed first responder.
        clickAndFocusTheCanvas(events, at: CGPoint(x: 60, y: 40), in: window)
        events.applyMouseDown(at: CGPoint(x: 60, y: 40), clickCount: 2)
        XCTAssertTrue(window.firstResponder === events,
                      "precondition: the editor has not taken first responder yet, "
                      + "so the canvas is still the one holding the keyboard")
        XCTAssertTrue(model.isInGesture,
                      "precondition: entering the scrap opened \"Edit Scrap\" and it "
                      + "is still open")

        window.sendEvent(deleteKeyEvent(for: window))
        pumpUntilSaved()

        // Quit the way ⌘Q does: flush, then let go of the undo stack.
        let saved = savedScene(after: window, root: root)
        XCTAssertNotNil(saved.node(scrapID),
                        "the card was deleted inside an undo bracket that never "
                        + "closed, and quitting dropped the stack — the writer's "
                        + "words are gone from disk with nothing that could ever "
                        + "have brought them back")
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], scrapText)
    }

    /// Spec §3.1, generalised: the canvas owns arrangement, not existence.
    ///
    /// Deleting a region takes its membership records and nothing else. The card
    /// it held stays exactly where it was — asserted at its coordinates rather
    /// than merely as "still present", because a region delete that dragged its
    /// residents somewhere would satisfy the weaker question.
    func test_deletingARegionLeavesItsCardsWhereTheyWere() throws {
        let root = try regionProjectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // The region's label bar: frame starts at (20,20), so y=30 is inside the
        // 24pt chrome, and x=200 is clear of the card at (60,60)…(300,120).
        clickAndFocusTheCanvas(events, at: CGPoint(x: 200, y: 30), in: window)
        XCTAssertEqual(model.selection, .region(CanvasRegionID("r1")),
                       "precondition: the label bar selected the region")
        XCTAssertEqual(sceneOnDisk(root).regionCount, 1,
                       "precondition: the region is on disk, so the zero below is a "
                       + "removal")

        window.sendEvent(deleteKeyEvent(for: window))
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 0, "⌫ with a region selected left it there")
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 60, y: 60),
                       "deleting a region never deletes cards, and never moves them")
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], scrapText,
                       "the resident's words went with the region that merely held it")

        // The undo half. It runs a DIFFERENT path from the scrap branch —
        // `CanvasModel.mutate` rather than a hand-rolled bracket — so the scrap
        // half's coverage says nothing about it, and what vanishes here is a
        // container full of cards.
        let undoSelector = #selector(CanvasEventNSView.undo(_:))
        let undo = try editMenuItem(undoSelector, in: window)
        XCTAssertTrue(undo.isEnabled,
                      "deleting a region left nothing on the undo stack: a whole "
                      + "arrangement goes on one keystroke and does not come back")
        XCTAssertTrue(undo.item.title.contains("Delete Region"),
                      "the menu item reads \"\(undo.item.title)\" rather than naming "
                      + "what it will take back")
        _ = undo.target.perform(undoSelector, with: undo.item)
        pumpUntilSaved()

        let restored = sceneOnDisk(root)
        XCTAssertEqual(restored.regionCount, 1, "⌘Z did not bring the region back")
        XCTAssertEqual(restored.region(CanvasRegionID("r1"))?.livesHere(scrapID), true,
                       "the region came back without the card it held — a snapshot "
                       + "carries membership, so a region restored empty means the "
                       + "undo restored something other than what was deleted")
    }

    /// **Deleting a card that lives in a region takes its membership with it.**
    ///
    /// `CanvasScene.remove` scrubs the node from every region, and a ghost member
    /// would resurface in the inspector's "lives here" list and in
    /// `RegionBinding.references(forPiece:)` long after the card was gone. Pinned
    /// at the model level and, until this test, nowhere on the real surface —
    /// where the scrub has to survive the save, the reload and the codec.
    func test_deletingACardThatLivesInARegionLeavesNoGhostMember() throws {
        let root = try regionProjectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        XCTAssertEqual(sceneOnDisk(root).region(CanvasRegionID("r1"))?.livesHere(scrapID),
                       true, "precondition: the fixture's card lives in the region")

        // On the card at (60,60)–(300,120), clear of its resize corner.
        clickAndFocusTheCanvas(events, at: CGPoint(x: 100, y: 80), in: window)
        XCTAssertEqual(model.selection, .node(scrapID), "precondition: the card is selected")

        window.sendEvent(deleteKeyEvent(for: window))
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertNil(onDisk.node(scrapID), "precondition: the card went")
        XCTAssertEqual(onDisk.regionCount, 1,
                       "deleting a card took its region with it — the card belongs "
                       + "to the region, not the other way round")
        XCTAssertEqual(onDisk.region(CanvasRegionID("r1"))?.mentions(scrapID), false,
                       "the region still remembers a card that no longer exists: a "
                       + "ghost member survives the save and the reload, and shows "
                       + "up in the inspector's \"lives here\" list for a card the "
                       + "writer deleted")
    }

    // MARK: - The inspector edits a scene whose gesture is still open

    /// **The repro for `CanvasUndo.mutateFromOutsideTheCanvas`, driven through
    /// the real click path.**
    ///
    /// Both of the unit tests for that method hand-open the bracket with
    /// `model.beginGesture("Edit Scrap")`, which is the 1C-a lesson in
    /// miniature — a mechanism exercised only by the test that drives it
    /// directly. This one reaches the state the way a writer does, and it is the
    /// test that says the documented repro is real.
    ///
    /// The chrome bar is load-bearing: click 1 selects the region, click 2 finds
    /// no node under the point, takes the `.emptyCanvas` branch, mints a scrap
    /// and opens "Edit Scrap" — and `handleClick`'s `guard clickCount >= 2`
    /// returns before the selection is ever reassigned.
    func test_aRegionStaysSelectedWhileADoubleClickOpensAScrap() throws {
        let root = try regionProjectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let region = CanvasRegionID("r1")

        // The chrome bar runs y 20..44; the fixture's card starts at y 60.
        let onTheChrome = CGPoint(x: 200, y: 30)
        events.applyMouseDown(at: onTheChrome, clickCount: 1)
        events.applyMouseUp(at: onTheChrome)
        events.applyMouseDown(at: onTheChrome, clickCount: 2)
        events.applyMouseUp(at: onTheChrome)
        pump()

        XCTAssertEqual(model.selection, .region(region),
                       "click 1 selected the region and the double-click never "
                       + "reassigned it — so the inspector is showing this region")
        XCTAssertTrue(model.isInGesture,
                      "and click 2 minted a scrap and opened \"Edit Scrap\" — the "
                      + "bracket an inspector edit must not nest inside")

        // The inspector, in the other column, renames the region while that
        // bracket is open. Through `mutate` this would register nothing at all.
        RegionInspector(model: model, regionID: region, pieces: [],
                        artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                        onOpenResearchItem: { _ in })
            .commitLabel("Falls at night")
        XCTAssertEqual(model.scene.region(region)?.label, "Falls at night")

        // **This is the assertion that sees the nesting, and the scene is not.**
        // Measured (mutation, 2026-07-28): with `mutateFromInspector` swapped for
        // `mutate`, the rename nests, registers nothing of its own, and rides
        // into the open "Edit Scrap" bracket — which the ⌘Z below then closes and
        // undoes, leaving the label back at "Act II fog" and the card in place.
        // Every scene assertion here is satisfied by that coincidence. What
        // differs is the NAME, and the name is what the writer reads off the Edit
        // menu.
        XCTAssertTrue(model.undo.undoMenuItemTitle.contains("Rename Region"),
                      "the rename must be its own named step. Got: "
                      + model.undo.undoMenuItemTitle)

        model.undo.undo()
        XCTAssertEqual(model.scene.region(region)?.label, "Act II fog",
                       "one ⌘Z takes the rename back, which it cannot do if the "
                       + "rename never became a step")
        XCTAssertEqual(model.scene.count, 2,
                       "and the scrap the double-click minted is untouched — the "
                       + "⌘Z landed on the rename, not on the card")
    }

    /// The other half, and the reason the doc says CHROME BAR rather than card:
    /// **a double-click on a CARD cannot reach that state.** AppKit delivers
    /// `clickCount: 1` on the first mouse-down of a double-click, and that click
    /// selects the card — so the region is deselected before the bracket opens
    /// and the inspector is showing its empty state.
    ///
    /// Pinned because the first draft of this slice documented the card version
    /// in four places. A repro nobody can reproduce is worse than none: the next
    /// author tries it, fails, and concludes the rule is stale.
    func test_aDoubleClickOnACardDeselectsTheRegion() throws {
        let root = try regionProjectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let region = CanvasRegionID("r1")

        let onTheChrome = CGPoint(x: 200, y: 30)
        events.applyMouseDown(at: onTheChrome, clickCount: 1)
        events.applyMouseUp(at: onTheChrome)
        pump()
        XCTAssertEqual(model.selection, .region(region), "the control: it starts selected")

        // The fixture's card sits at (60, 60); its measured height is well under
        // 40pt, so this point is inside it.
        let onTheCard = CGPoint(x: 100, y: 75)
        events.applyMouseDown(at: onTheCard, clickCount: 1)
        events.applyMouseUp(at: onTheCard)
        events.applyMouseDown(at: onTheCard, clickCount: 2)
        events.applyMouseUp(at: onTheCard)
        pump()

        XCTAssertEqual(model.selection, .node(scrapID),
                       "clickCount 1 arrives first and selects the card")
        XCTAssertNil(model.selectedRegion,
                     "so `selectedRegion` is nil, the inspector is showing \"Select "
                     + "a region\", and there is no label field to type into")
    }
}
