import XCTest
import AppKit
@testable import Maugham

final class CanvasEventViewTests: XCTestCase {

    /// Keep a hosted window alive for the length of the test — a released window
    /// drops first responder and the assertion becomes a coin flip.
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    private func view() -> CanvasEventNSView {
        let v = CanvasEventNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        v.camera = CanvasCamera()
        return v
    }

    func test_scrollPansTheCamera() {
        let v = view()
        v.applyScroll(deltaX: 20, deltaY: -15, precise: true)
        XCTAssertEqual(v.camera.pan, CGPoint(x: 20, y: -15))
        XCTAssertEqual(v.camera.zoom, 1, "scrolling must not zoom")
    }

    func test_coarseWheelTicksAreAmplifiedRelativeToTrackpad() {
        let precise = view(); precise.applyScroll(deltaX: 0, deltaY: 3, precise: true)
        let wheel = view(); wheel.applyScroll(deltaX: 0, deltaY: 3, precise: false)
        XCTAssertGreaterThan(wheel.camera.pan.y, precise.camera.pan.y)
    }

    func test_magnifyZoomsAndHoldsTheAnchor() {
        let v = view()
        let anchor = CGPoint(x: 300, y: 200)
        let before = v.camera.contentPoint(fromView: anchor)
        v.applyMagnify(magnification: 0.5, at: anchor)   // +50%
        XCTAssertEqual(v.camera.zoom, 1.5, accuracy: 0.0001)
        let after = v.camera.contentPoint(fromView: anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 0.0001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001)
    }

    func test_magnifyIsClamped() {
        let v = view()
        for _ in 0..<50 { v.applyMagnify(magnification: 1.0, at: .zero) }
        XCTAssertEqual(v.camera.zoom, CanvasCamera.zoomRange.upperBound)
        for _ in 0..<200 { v.applyMagnify(magnification: -0.5, at: .zero) }
        XCTAssertEqual(v.camera.zoom, CanvasCamera.zoomRange.lowerBound)
    }

    func test_repeatedMagnifyCompoundsRatherThanResets() {
        let v = view()
        v.applyMagnify(magnification: 0.1, at: .zero)
        let once = v.camera.zoom
        v.applyMagnify(magnification: 0.1, at: .zero)
        XCTAssertGreaterThan(v.camera.zoom, once)
    }

    func test_viewAcceptsFirstMouseSoOneClickReachesTheCanvas() {
        XCTAssertTrue(view().acceptsFirstMouse(for: nil),
                      "an inactive window must not eat the writer's first click")
    }

    // MARK: - The one drag vocabulary

    func test_aFullDragEmitsBeganChangedEndedInOrder() {
        let v = view()
        var phases: [CanvasDragPhase] = []
        var points: [CGPoint] = []
        v.onDrag = { p, phase in points.append(p); phases.append(phase) }

        v.applyMouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1)
        v.applyMouseDragged(to: CGPoint(x: 40, y: 20))
        v.applyMouseDragged(to: CGPoint(x: 70, y: 30))
        v.applyMouseUp(at: CGPoint(x: 70, y: 30))

        XCTAssertEqual(phases, [.began, .changed, .changed, .ended])
        XCTAssertEqual(points.first, CGPoint(x: 10, y: 10))
        XCTAssertEqual(points.last, CGPoint(x: 70, y: 30))
    }

    func test_draggedWithoutAMouseDownEmitsNothing() {
        let v = view()
        var phases: [CanvasDragPhase] = []
        v.onDrag = { _, phase in phases.append(phase) }
        v.applyMouseDragged(to: CGPoint(x: 40, y: 20))
        v.applyMouseUp(at: CGPoint(x: 40, y: 20))
        XCTAssertTrue(phases.isEmpty, "a drag that never began must not end")
    }

    func test_clickReportsItsClickCountSoDoubleClickIsDistinguishable() {
        let v = view()
        var counts: [Int] = []
        v.onClick = { _, count in counts.append(count) }
        v.applyMouseDown(at: .zero, clickCount: 1)
        v.applyMouseUp(at: .zero)
        v.applyMouseDown(at: .zero, clickCount: 2)
        v.applyMouseUp(at: .zero)
        XCTAssertEqual(counts, [1, 2])
    }

    func test_onClickFiresBeforeOnDragBegan() {
        let v = view()
        var events: [String] = []
        v.onClick = { _, _ in events.append("click") }
        v.onDrag = { _, phase in if phase == .began { events.append("dragBegan") } }
        v.applyMouseDown(at: .zero, clickCount: 1)
        XCTAssertEqual(events, ["click", "dragBegan"],
                      "onClick must fire before onDrag(.began) in the same mouseDown; "
                      + "Task 13's gesture state machine depends on onClick setting editingNodeID "
                      + "before onDrag(.began) observes it")
    }

    // MARK: - ⌫

    /// The view's half of delete: a delete key is REPORTED and an ordinary key
    /// is not. What the callback then does is `CanvasView`'s business, and
    /// `CanvasViewMountingTests` is where the two meet on a real surface.
    ///
    /// `charactersIgnoringModifiers` is what `keyDown` switches on, so it is what
    /// these events carry. **Both delete keys are here, and the codes are the
    /// point:** ⌫ is `NSDeleteCharacter` (0x007F) and ⌦ is `NSDeleteFunctionKey`
    /// (0xF728, a function-key code). The first draft of this file paired 0x007F
    /// with `NSBackspaceCharacter` (0x0008) and asserted in a comment that 0x0008
    /// was forward delete — it is **Ctrl-H**, so a writer on a full-size keyboard
    /// pressed ⌦ over a selected card and got a beep. The comment claiming to
    /// warn about that confusion was the confusion.
    ///
    /// The values come from `CanvasEventNSView`'s own constants rather than from
    /// literals here, so this cannot drift into agreeing with itself; the codes
    /// they resolve to are asserted below, against AppKit.
    func test_theDeleteKeyIsReportedAndOtherKeysAreNot() {
        let v = view()
        let beyond = KeyRecorder()
        v.nextResponder = beyond          // or an unhandled key beeps for real
        var deletes = 0
        v.onDeleteKey = { deletes += 1; return true }

        v.keyDown(with: key(CanvasEventNSView.backwardDelete))          // ⌫
        XCTAssertEqual(deletes, 1, "a backspace on the canvas reported nothing, so "
                       + "the writer's ⌫ never reaches the selection")
        v.keyDown(with: key(CanvasEventNSView.forwardDelete))           // ⌦
        XCTAssertEqual(deletes, 2, "⌦ over a selected card does nothing at all — "
                       + "forward delete is NSDeleteFunctionKey (0xF728), not the "
                       + "0x0008 that ASCII calls backspace and macOS gives Ctrl-H")
        v.keyDown(with: key("a"))
        XCTAssertEqual(deletes, 2, "an ordinary key must pass through")
    }

    /// The two constants are the keys AppKit actually sends, asserted against
    /// AppKit's own names rather than against the digits.
    ///
    /// Without this the constants and the test that uses them would be one
    /// closed loop: any pair of characters would satisfy the test above.
    func test_theTwoDeleteKeysAreTheOnesAppKitSends() {
        XCTAssertEqual(CanvasEventNSView.backwardDelete.unicodeScalars.first?.value,
                       UInt32(NSDeleteCharacter), "⌫ is NSDeleteCharacter, 0x007F")
        XCTAssertEqual(CanvasEventNSView.forwardDelete.unicodeScalars.first?.value,
                       UInt32(NSDeleteFunctionKey), "⌦ is NSDeleteFunctionKey, 0xF728")
        XCTAssertNotEqual(CanvasEventNSView.forwardDelete.unicodeScalars.first?.value,
                          UInt32(NSBackspaceCharacter),
                          "0x0008 is NSBackspaceCharacter — Ctrl-H, not ⌦. It is also "
                          + "unreachable here: charactersIgnoringModifiers strips "
                          + "Control, so Ctrl-H arrives as \"h\"")
    }

    /// **The canvas must not claim a key it did not use.** A ⌫ that deleted
    /// nothing carries on up the responder chain, where AppKit's `noResponder`
    /// beeps — the platform's way of saying "that key means nothing here", and
    /// the one signal that separates "nothing was selected" from "delete is
    /// broken". Swallowing it silently reads exactly like a broken app, which is
    /// the failure this whole slice keeps finding in other forms.
    ///
    /// The three cases are one sequence on purpose: an implementation that
    /// always forwarded fails the second, one that never forwards fails the
    /// first, and one that forwards only when the callback is wired fails the
    /// third.
    func test_aDeleteThatDeletedNothingTravelsOnAndOneThatDeletedDoesNot() {
        let v = view()
        let beyond = KeyRecorder()
        v.nextResponder = beyond

        let delete = CanvasEventNSView.backwardDelete
        v.onDeleteKey = { false }
        v.keyDown(with: key(delete))
        XCTAssertEqual(beyond.keys, [delete],
                       "a ⌫ that deleted nothing was swallowed: the writer gets "
                       + "silence where the platform would have beeped, and cannot "
                       + "tell an empty selection from a broken delete")

        v.onDeleteKey = { true }
        v.keyDown(with: key(delete))
        XCTAssertEqual(beyond.keys, [delete],
                       "a ⌫ that DID delete something also travelled on — the "
                       + "canvas took the card and beeped at the writer for it")

        // The state every view is in between `init` and `wire`.
        v.onDeleteKey = nil
        v.keyDown(with: key(delete))
        XCTAssertEqual(beyond.keys, [delete, delete],
                       "an unwired canvas swallows ⌫ rather than passing it on")
    }

    // MARK: - The first link of the delivery chain

    /// **A click on the canvas takes first responder, and nothing asserted that
    /// until this test.**
    ///
    /// `mouseDown(with:)`'s `window?.makeFirstResponder(self)` is what puts the
    /// keyboard on this view, and every mounting test makes that claim FOR it
    /// with a `window.makeFirstResponder(events)` of its own — because the
    /// testable seam `applyMouseDown` does no responder work. So the production
    /// line could be deleted with 3078 tests green, while the writer's ⌫ **and**
    /// the already-shipped bare-canvas ⌘Z both stopped working after a click.
    /// That is 1C-a's defect shape one link upstream, now load-bearing twice.
    ///
    /// The override is called DIRECTLY rather than posted through the window.
    /// This file's "synthesizing AppKit events is unreliable" caveat is about
    /// hit-test delivery through `sendEvent`; constructing an event and invoking
    /// the override is not that, and the override reads only `locationInWindow`
    /// and `clickCount`.
    func test_aClickTakesFirstResponderSoTheKeyboardReachesTheCanvas() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        windows.append(window)
        let v = view()
        v.frame = window.contentLayoutRect
        window.contentView?.addSubview(v)
        window.orderFront(nil)
        // Park focus off the view first. AppKit makes the only
        // `acceptsFirstResponder` subview the initial first responder when the
        // window is shown, so without this the precondition is already satisfied
        // and the click below is asserted to change nothing. Off it is also the
        // real state this line exists for: the writer is in a scrap, the editor
        // holds the keyboard, and the click out has to take it back.
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(window.firstResponder === v,
                       "precondition: the canvas does not already hold first "
                       + "responder, so the assertion below is about the click")

        v.mouseDown(with: mouseDown(in: window, at: CGPoint(x: 60, y: 40)))

        XCTAssertTrue(window.firstResponder === v,
                      "a click on the canvas did not take first responder, so no key "
                      + "the writer presses reaches it: ⌫ deletes nothing and ⌘Z on "
                      + "a bare canvas drives the window's stack instead of the "
                      + "canvas's — both silently, and both after a click that "
                      + "looked like it worked")
    }

    private func mouseDown(in window: NSWindow, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Whatever `super.keyDown(with:)` hands to the next responder. `NSResponder`
    /// walks `nextResponder` and calls `noResponder(for:)` — the beep — when it
    /// runs out, so standing in that slot is how "the key travelled on" is
    /// observable at all.
    private final class KeyRecorder: NSResponder {
        var keys: [String] = []
        override func keyDown(with event: NSEvent) {
            keys.append(event.charactersIgnoringModifiers ?? "")
        }
    }

    private func key(_ character: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil,
                         characters: character, charactersIgnoringModifiers: character,
                         isARepeat: false, keyCode: 51)!
    }

    /// ⌘Z on the canvas reaches `CanvasUndo` through the responder chain:
    /// `NSWindow.undo(_:)` asks the first responder for its `undoManager`.
    func test_theViewVendsTheCanvasUndoManagerToTheResponderChain() {
        let v = view()
        let manager = UndoManager()
        v.canvasUndoManager = manager
        XCTAssertTrue(v.acceptsFirstResponder)
        XCTAssertTrue(v.undoManager === manager)
    }
}
