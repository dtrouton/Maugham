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
final class CanvasEventNSView: NSView {

    var camera = CanvasCamera()
    var canvasUndoManager: UndoManager?
    var onCameraChange: ((CanvasCamera) -> Void)?
    /// (view point, click count). Click count 2 is "enter the scrap under this
    /// point, or make a new one here".
    var onClick: ((CGPoint, Int) -> Void)?
    var onDrag: ((CGPoint, CanvasDragPhase) -> Void)?

    private var isDragging = false

    override var isFlipped: Bool { true }

    /// Without this, the first click into an unfocused window is spent
    /// activating it — on a canvas that is a lost thought.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ⌘Z with nothing being edited must reach the canvas's own undo stack.
    /// `NSWindow.undo(_:)` asks the first responder for its `undoManager`, so
    /// this view has to be able to hold first responder and vend it.
    override var acceptsFirstResponder: Bool { true }

    override var undoManager: UndoManager? { canvasUndoManager ?? super.undoManager }

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

    func applyMouseDown(at point: CGPoint, clickCount: Int) {
        isDragging = true
        onClick?(point, clickCount)
        onDrag?(point, .began)
    }

    func applyMouseDragged(to point: CGPoint) {
        guard isDragging else { return }
        onDrag?(point, .changed)
    }

    func applyMouseUp(at point: CGPoint) {
        guard isDragging else { return }
        isDragging = false
        onDrag?(point, .ended)
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
        applyMouseDown(at: convert(event.locationInWindow, from: nil),
                       clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        applyMouseDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        applyMouseUp(at: convert(event.locationInWindow, from: nil))
    }
}

/// Bridges `CanvasEventNSView` into SwiftUI. Transparent — it contributes no
/// drawing, only events.
struct CanvasEventView: NSViewRepresentable {
    @Binding var camera: CanvasCamera
    var onClick: (CGPoint, Int) -> Void
    var onDrag: (CGPoint, CanvasDragPhase) -> Void
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
        v.canvasUndoManager = undoManager
    }
}
