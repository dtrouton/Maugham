import AppKit
import SwiftUI

/// The three phases of a canvas drag. ONE vocabulary, used by the event view,
/// `CanvasView` and `CanvasInteraction`.
enum CanvasDragPhase: Equatable, Sendable {
    case began
    case changed
    case ended
}

/// Where the canvas gets its camera and pointer input.
///
/// SwiftUI cannot supply any of this on macOS: there is no scroll-wheel API,
/// `MagnificationGesture` provides no centre point (so zoom-to-cursor is
/// impossible), and `.simultaneousGesture(DragGesture())` never fires at all
/// (spec §7A.1). So a transparent `NSView` sits in the canvas stack and
/// overrides the AppKit entry points.
///
/// It sits BENEATH the mounted scrap editor (see `CanvasView`), so while a scrap
/// is being edited the editor gets the mouse and the writer gets AppKit's own
/// caret placement, drag-select and double-click-word for free. That is why
/// `mouseDown` does not call `super`: nothing behind this view wants the event,
/// and `NSResponder`'s default would hand canvas clicks to the window.
///
/// The event LOGIC is in plain methods, not inside the `NSEvent` overrides,
/// because synthesizing AppKit events in tests is unreliable — the 2026-07-25
/// spike had two synthetic-event harnesses fail their own control cases, and
/// discovered that `NSTextView.mouseDown` runs a modal tracking loop that
/// deadlocks a post-then-pump harness.
final class CanvasEventNSView: NSView, NSUserInterfaceValidations {

    var camera = CanvasCamera()
    var canvasUndoManager: UndoManager?
    var onCameraChange: ((CanvasCamera) -> Void)?
    /// (view point, click count). Click count 2 is "enter the scrap under this
    /// point, or make a new one here".
    var onClick: ((CGPoint, Int) -> Void)?
    /// (content-space point, phase, ⇧ held). The modifier is THREADED through
    /// here rather than read off `NSEvent.modifierFlags` where it is used: a
    /// static global read is untestable except by faking it, and this callback is
    /// the one place a real event's flags can reach the gesture through
    /// production code — `window.sendEvent(_:)` with a ⇧-flagged `NSEvent` runs
    /// the whole route end to end.
    var onDrag: ((CGPoint, CanvasDragPhase, Bool) -> Void)?
    /// ⌫ / ⌦, with the canvas holding first responder. What it does with the
    /// selection is `CanvasView.deleteSelection()`'s business, not this view's.
    ///
    /// **It returns whether anything was actually deleted**, and that return
    /// value is the whole of `keyDown`'s decision below — see it for why the
    /// canvas must not claim a key it did not use.
    var onDeleteKey: (() -> Bool)?

    private var isDragging = false

    override var isFlipped: Bool { true }

    /// Without this, the first click into an unfocused window is spent
    /// activating it — on a canvas that is a lost thought.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ⌘Z with nothing being edited must reach the canvas's own undo stack, and
    /// holding first responder is half of what that takes. The other half is the
    /// `undo:`/`redo:` pair below — being first responder is not, on its own,
    /// enough for the Edit menu to reach anything here.
    override var acceptsFirstResponder: Bool { true }

    /// The canvas's manager, vended to anything that walks the responder chain
    /// asking for one — `NSResponder.undoManager` walks `nextResponder` upward,
    /// so this is the honest answer for this view and everything under it. It is
    /// also the only handle the tests have on the manager production ships.
    ///
    /// **It is not what makes ⌘Z work, and the Edit menu never reads it.**
    /// Measured 2026-07-27 on macOS 26.5, with this view genuinely first
    /// responder inside the real SwiftUI hosting hierarchy: `window.undoManager`
    /// was a DIFFERENT manager, because `NSWindow` does not ask its first
    /// responder — it asks its delegate for `windowWillReturnUndoManager:` and
    /// otherwise vends one of its own. This comment used to assert the opposite,
    /// which is the same responder-chain theory Task 9 measured false one file
    /// away in `ScrapLayout.makeEditor`; the container there got the explicit
    /// `undo:`/`redo:` treatment and this view kept the disproven belief, so the
    /// 1C-a hand-smoke found undo greyed out on a bare canvas — a whole feature,
    /// twenty-two tests deep, reachable only from inside a scrap.
    override var undoManager: UndoManager? { canvasUndoManager ?? super.undoManager }

    // MARK: - ⌘Z with nothing focused

    /// **These two methods are the whole of ⌘Z on a bare canvas.**
    ///
    /// AppKit resolves a nil-targeted menu action by walking the responder chain
    /// for the first object that RESPONDS to the selector, then validates against
    /// that object and sends to it. Without these, the walk out of this view
    /// reached `NSWindow`, whose own `undo:` runs the manager above — the
    /// window's, not the canvas's. Measured in that state, with a real "Move
    /// Scrap" step on the canvas stack: the Edit item validated **false**, so ⌘Z
    /// was greyed out, and performing `undo:` on the window left the card exactly
    /// where the drag had put it.
    ///
    /// The BARE manager rather than `CanvasUndo`, and deliberately — see the
    /// `undoManager:` argument in `CanvasView`. This path is only reachable with
    /// no scrap focused, every route out of a scrap runs `commitActiveEdit`, and
    /// a drag's gesture closes at `.ended`, so there is never an open gesture
    /// here for `CanvasUndo.undo()` to close first.
    @objc func undo(_ sender: Any?) {
        canvasUndoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        canvasUndoManager?.redo()
    }

    /// Claiming an action obliges this view to validate it — AppKit enables a
    /// menu item whose responder merely responds to the selector, so without this
    /// the Edit menu offers a live Undo over an empty canvas stack.
    ///
    /// And it obliges this view to TITLE it. `NSWindow` retitles Undo/Redo from
    /// whichever manager it resolves, and the whole point of the two methods
    /// above is that the action never reaches `NSWindow` — so left alone the item
    /// keeps whatever the nib gave it and every canvas step reads a bare "Undo".
    /// `CanvasUndo` names every gesture through `setActionName`, so
    /// `undoMenuItemTitle` reads "Undo Move Scrap" here without this file knowing
    /// any of those names, and it already reads a plain "Undo" on an empty stack.
    ///
    /// Guarded on `NSMenuItem` rather than assumed: the protocol is
    /// `NSValidatedUserInterfaceItem`, which a toolbar item or a control also
    /// satisfies, and `title` is not on it.
    ///
    /// The same shape as `ScrapEditorContainer.validateUserInterfaceItem`, asked
    /// of the bare manager instead of the recorder. There is no pending-gesture
    /// term here and there must not be one: the recorder's `canUndo` carries one
    /// for the run of typing inside a focused scrap, and nothing is focused on
    /// this path.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = canvasUndoManager?.undoMenuItemTitle
                ?? NSLocalizedString("Undo", comment: "Edit menu item, nothing to undo")
            return canvasUndoManager?.canUndo ?? false
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = canvasUndoManager?.redoMenuItemTitle
                ?? NSLocalizedString("Redo", comment: "Edit menu item, nothing to redo")
            return canvasUndoManager?.canRedo ?? false
        // AppKit only asks the responder that will handle the action, so
        // anything else reaching here is not this view's to veto.
        default: return true
        }
    }

    // MARK: - Testable seams

    func applyScroll(deltaX: CGFloat, deltaY: CGFloat, precise: Bool) {
        // A non-precise (mouse wheel) tick is coarse; scale it so a wheel and a
        // trackpad move the canvas by comparable amounts.
        let factor: CGFloat = precise ? 1 : 8
        camera.panBy(CGSize(width: deltaX * factor, height: deltaY * factor))
        onCameraChange?(camera)
    }

    /// `NSEvent.magnification` is a DELTA fraction, so the new zoom compounds
    /// off the current one.
    func applyMagnify(magnification: CGFloat, at anchor: CGPoint) {
        camera.zoom(to: camera.zoom * (1 + magnification), anchoringViewPoint: anchor)
        onCameraChange?(camera)
    }

    /// - Parameter shiftHeld: whether ⇧ was down for this press — a ⇧-drag from a
    ///   card draws a line. Defaulted at this SEAM and nowhere below it: the one
    ///   production caller (`mouseDown(with:)`) always passes the real flag, and
    ///   `CanvasInteraction.begin` takes its `connecting:` with no default at all
    ///   so the single call site there has to say what it means. The default is
    ///   here only so the many tests that are not about ⇧ do not have to.
    func applyMouseDown(at point: CGPoint, clickCount: Int, shiftHeld: Bool = false) {
        // Both callbacks fire on every mouse-down, with onClick strictly before onDrag(.began).
        // A zero-distance drag (mouseDown → mouseUp with no mouseDragged) emits .began then .ended
        // with no .changed. AppKit delivers clickCount: 1 on the first mouse-down of a double-click,
        // so a drag session opens before the second click arrives. Task 13's gesture state machine
        // and Task 15's undo grouping depend on this ordering: onClick sets state that onDrag(.began)
        // observes within the same call, so Task 13's guard on editingNodeID sees the updated value
        // (set by onClick's handleClick) before .began fires for that same mouseDown. This is a
        // contract, not an incidental detail — do not reorder these calls.
        isDragging = true
        onClick?(point, clickCount)
        onDrag?(point, .began, shiftHeld)
    }

    /// **`false`, and not the live modifier state — deliberately.** Only `.began`
    /// reads the flag, because what the gesture IS is decided by the press. A
    /// writer who lets ⇧ go halfway through drawing a line must not have the line
    /// abandoned under them, and one who presses it late has not started a
    /// different gesture. This is exactly the kind of thing a later "consistency"
    /// edit removes, so it is written down rather than left to be inferred.
    func applyMouseDragged(to point: CGPoint) {
        guard isDragging else { return }
        onDrag?(point, .changed, false)
    }

    /// `false` for the same reason as `applyMouseDragged` — see it.
    func applyMouseUp(at point: CGPoint) {
        guard isDragging else { return }
        isDragging = false
        onDrag?(point, .ended, false)
    }

    // MARK: - AppKit entry points

    override func scrollWheel(with event: NSEvent) {
        applyScroll(deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas)
    }

    override func magnify(with event: NSEvent) {
        applyMagnify(magnification: event.magnification,
                     at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        // Take first responder so ⌘Z lands on the canvas undo stack once the
        // writer has clicked out of a scrap.
        window?.makeFirstResponder(self)
        // `modifierFlags` and nothing else. `charactersIgnoringModifiers` — the
        // property `keyDown` two screens down switches on — belongs to keys and
        // says nothing about a mouse press; the note there about which modifiers
        // it strips is about that method, not this one.
        applyMouseDown(at: convert(event.locationInWindow, from: nil),
                       clickCount: event.clickCount,
                       shiftHeld: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        applyMouseDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        applyMouseUp(at: convert(event.locationInWindow, from: nil))
    }

    /// **This is the whole of ⌫ on the canvas**, and it is deliberately a
    /// `keyDown` rather than `deleteBackward(_:)`: this view is not a text
    /// responder, does not call `interpretKeyEvents`, and so would never receive
    /// the action message.
    ///
    /// It only ever reaches here with NO scrap focused — the mounted editor is
    /// frontmost and first responder while the writer is in a scrap, so ⌫ there
    /// deletes a character, which is what they meant.
    /// `CanvasViewMountingTests.test_backspaceInsideAScrapDeletesACharacterAndNotTheCard`
    /// pins that rather than assuming it.
    ///
    /// **A ⌫ that deleted nothing goes to `super` — the canvas does not claim a
    /// key it did not use**, and this is a rule rather than a tidiness. A key
    /// that does nothing *and* suppresses the beep is indistinguishable from a
    /// broken app: `super.keyDown` beeping is the platform saying "that key
    /// means nothing here", and it is the one signal that separates "nothing was
    /// selected" from "delete is broken". Which is why `onDeleteKey` reports
    /// back instead of returning `Void` — the first draft of this method
    /// swallowed every ⌫ unconditionally and read identically at the call site.
    ///
    /// **The two characters are ⌫ and ⌦, and the second one is not what it
    /// looks like.** Measured against AppKit on 2026-07-28:
    /// `NSDeleteCharacter` is **0x007F** (⌫), `NSDeleteFunctionKey` is **0xF728**
    /// (⌦ — a function-key code, not an ASCII one), and `NSBackspaceCharacter`
    /// is 0x0008, which is **Ctrl-H**. The first draft paired 0x7F with 0x0008
    /// on the stated belief that 0x0008 was forward delete; it is the confusion
    /// that belief warned about. 0x0008 is not merely the wrong key, it is an
    /// unreachable one here — `charactersIgnoringModifiers` strips Control, so
    /// Ctrl-H arrives as `"h"` and this case could never have matched a
    /// keystroke at all. Wanting Ctrl-H would mean switching on `characters` and
    /// testing `modifierFlags`, which is a different design; it is not wanted.
    ///
    /// Spelled with an `if` inside the case rather than a `where` on it: a
    /// `where` clause binds to the LAST pattern of a multi-pattern case only, so
    /// `case "\u{7F}", "\u{F728}" where …` would take the ⌫ branch without ever
    /// asking the condition. The compiler warns — *"'where' only applies to the
    /// second pattern match in this 'case'"* — and
    /// `CanvasEventViewTests.test_aDeleteThatDeletedNothingTravelsOnAndOneThatDeletedDoesNot`
    /// goes red, which is what actually stops a tidy-up: a warning in a file this
    /// size is easy to walk past.
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case Self.backwardDelete, Self.forwardDelete:
            if onDeleteKey?() == true { return }
            super.keyDown(with: event)
        default:
            super.keyDown(with: event)
        }
    }

    /// `NSDeleteCharacter` and `NSDeleteFunctionKey` as the strings
    /// `charactersIgnoringModifiers` reports. Named rather than spelled at the
    /// switch so the tests can assert against the same two values the production
    /// switch reads — a test carrying its own literal is a test that agrees with
    /// itself.
    static let backwardDelete = String(UnicodeScalar(UInt8(NSDeleteCharacter)))
    static let forwardDelete = String(UnicodeScalar(UInt32(NSDeleteFunctionKey))!)
}

/// Bridges `CanvasEventNSView` into SwiftUI. Transparent — it contributes no
/// drawing, only events.
struct CanvasEventView: NSViewRepresentable {
    @Binding var camera: CanvasCamera
    var onClick: (CGPoint, Int) -> Void
    /// (point, phase, ⇧ held) — see `CanvasEventNSView.onDrag`.
    var onDrag: (CGPoint, CanvasDragPhase, Bool) -> Void
    /// Returns whether anything was deleted — see `CanvasEventNSView.keyDown`.
    var onDeleteKey: () -> Bool
    var undoManager: UndoManager?

    func makeNSView(context: Context) -> CanvasEventNSView {
        let v = CanvasEventNSView(frame: .zero)
        v.camera = camera
        wire(v)
        return v
    }

    func updateNSView(_ v: CanvasEventNSView, context: Context) {
        // Only push a camera the view did not itself originate, or a drag
        // fights its own updates.
        if v.camera != camera { v.camera = camera }
        wire(v)
    }

    private func wire(_ v: CanvasEventNSView) {
        v.onCameraChange = { camera = $0 }
        v.onClick = onClick
        v.onDrag = onDrag
        v.onDeleteKey = onDeleteKey
        v.canvasUndoManager = undoManager
    }
}
