import AppKit
import SwiftUI

/// Holds the one real `NSTextView` the canvas ever mounts, and scales it to the
/// camera's zoom by BOUNDS SCALING: the frame grows, the bounds do not.
///
/// This is what `NSScrollView.magnification` does internally, and the
/// 2026-07-25 spike verified it: coordinates round-trip exactly at zoom 1, 1.5,
/// 2 and 3, and ink area grows as zoom², which means AppKit genuinely
/// re-rasterises rather than upscaling a blurry bitmap.
///
/// The decisive property is that it involves **no re-layout**. The alternative —
/// laying the editor out at font×zoom and width×zoom — also reproduces the same
/// line breaks (measured, four fonts, 0.5x–3x), but it re-runs layout, and every
/// re-layout is a chance for drawn and edited to diverge. Bounds scaling keeps
/// that door shut. Do NOT replace this with `.scaleEffect`: it scales rendered
/// output, so the text blurs, and it breaks `NSCursor` tracking (spec §7A.1).
///
/// This view is the FRONTMOST layer of the canvas, so the writer gets AppKit's
/// own caret placement, drag-select and double-click-word. The cost is that it
/// also receives scroll and magnify while a scrap is focused, so it forwards
/// both back to the camera.
final class ScrapEditorContainer: NSView, NSTextViewDelegate, NSUserInterfaceValidations {

    private(set) var textView: NSTextView?

    /// The layout the current text view is bound to. Rebinding is keyed on THIS,
    /// not on `textView == nil`: clicking from scrap A to scrap B must rebuild,
    /// and a subview count cannot tell the difference.
    ///
    /// It is the layout itself rather than an `ObjectIdentifier` for two reasons.
    /// Blur has to call `releaseEditor()` on the layout being left — the only
    /// real detach — and that needs the object, not its address. And an
    /// `ObjectIdentifier` held past its object's lifetime can be matched by a
    /// *different* layout allocated at the same address, which would skip the
    /// rebuild and leave the writer typing into the scrap they just left. Weak,
    /// because the layouts are owned by `CanvasView`.
    private weak var mountedLayout: ScrapLayout?

    private var wantsFocus = false
    private var pendingCaretIndex: Int?

    /// Whether the editor is the VISIBLE text of its scrap.
    ///
    /// It is mounted, focused and taking keystrokes long before this goes true:
    /// `CanvasView` mounts on the click so nothing the writer types is lost, and
    /// flips this at `CanvasFocusStraighten.isLevel(_:)`, on the same frame the
    /// renderer stops drawing that card's own text. While it is `false` the
    /// words on screen are the drawn ones — the same shared `NSTextStorage`,
    /// rotating with the card.
    ///
    /// It drives TWO things and both are required. `alphaValue` stops the
    /// double-draw. `hitTest(_:)` stops an invisible frontmost view owning the
    /// mouse: a click or a pinch inside that window would be resolved against
    /// this view's UNROTATED box while the card beneath is still up to 0.6° off
    /// level, so the pointer belongs to `CanvasEventNSView` — whose space is
    /// canvas space — until the handover is complete.
    ///
    /// **Not `isHidden`, and not SwiftUI's `.hidden()`.** AppKit moves first
    /// responder off a hidden view, which loses exactly the keystrokes mounting
    /// early exists to keep. `alphaValue` and `hitTest` leave the responder
    /// chain alone.
    ///
    /// Guarded on a real change: `updateNSView` re-wires this on every body
    /// pass, and `revision` ticks at frame rate through every straighten, coast
    /// and drag — an unguarded `alphaValue` write would dirty the layer 60–120
    /// times a second to set it to the value it already had.
    var isEditorVisible: Bool = true {
        didSet {
            guard isEditorVisible != oldValue else { return }
            alphaValue = isEditorVisible ? 1 : 0
        }
    }

    var canvasUndoManager: UndoManager?
    var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
    /// (magnification delta, point in THIS view's own unzoomed space). NOT
    /// canvas space — see `applyMagnify`.
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    /// Fired on every change the writer makes. The canvas folds the text into
    /// its model on the spot; without this the words live only in the shared
    /// `NSTextStorage` and are lost on quit (C5).
    var onTextChanged: (() -> Void)?

    override var isFlipped: Bool { true }

    /// See `isEditorVisible`. Returning `nil` takes this view out of the hit
    /// chain entirely, so the click reaches `CanvasEventNSView` beneath it — and
    /// leaves first responder, and therefore every keystroke, untouched.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEditorVisible else { return nil }
        return super.hitTest(point)
    }

    override var undoManager: UndoManager? { canvasUndoManager ?? super.undoManager }

    // MARK: - ⌘Z while a scrap is focused

    /// `NSTextView` does not implement `undo:`, so the menu action walks past it
    /// to here — and this is the ONLY thing that puts ⌘Z-while-editing on the
    /// canvas stack.
    ///
    /// The obvious route does not exist. `NSTextView` gates its `undoManager` on
    /// `allowsUndo` and returns **nil** before consulting anything else, and ours
    /// is deliberately false (`ScrapLayout.makeEditor`: one change, one step).
    /// Measured on macOS 26.5, all three candidate paths in one run: the
    /// container is the text view's delegate AND responds to
    /// `undoManagerForTextView:`, and it is the text view's `nextResponder` with
    /// `undoManager` above correctly vending the canvas manager — and
    /// `textView.undoManager` was still nil. Flipping `allowsUndo` to true makes
    /// the delegate hook work, at the price of the text view registering its own
    /// typing steps on the canvas stack, which is the double-registration Task 3
    /// rejected in full.
    ///
    /// Left unhandled, the action reaches `NSWindow`, which asks the FIRST
    /// RESPONDER for a manager, gets that nil, and falls back to its delegate's —
    /// SwiftUI's, not the canvas's. So ⌘Z inside a scrap would silently drive the
    /// wrong stack. Task 15 owns undo; this is the four lines that make its stack
    /// reachable from inside an editor, and menu-item titling is still its.
    @objc func undo(_ sender: Any?) {
        canvasUndoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        canvasUndoManager?.redo()
    }

    /// Claiming an action obliges this view to validate it: AppKit enables a menu
    /// item whose responder merely responds to the selector, so without this the
    /// Edit menu offers a live Undo with an empty stack the moment a scrap takes
    /// focus. Enablement only — the item's TITLE ("Undo Typing") is Task 15's,
    /// along with the rest of undo.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return canvasUndoManager?.canUndo ?? false
        case #selector(redo(_:)): return canvasUndoManager?.canRedo ?? false
        // AppKit only asks the responder that will handle the action, so
        // anything else reaching here is not this view's to veto.
        default: return true
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        onTextChanged?()
    }

    /// Returns `true` when the editor was built or rebuilt.
    @discardableResult
    func mount(layout: ScrapLayout, unscaledSize: CGSize, zoom: CGFloat) -> Bool {
        var rebuilt = false
        if mountedLayout !== layout {
            detachEditor()
            let tv = layout.makeEditor(frame: CGRect(origin: .zero, size: unscaledSize))
            // Without this there is no `textDidChange`, and the writer's words
            // never reach the model (C5).
            tv.delegate = self
            addSubview(tv)
            textView = tv
            mountedLayout = layout
            rebuilt = true
        }
        // The text view lives in this view's UNZOOMED space, so it is sized to
        // the text box at every zoom. It is also the TEXT box, never the card:
        // `CanvasCardMetrics` insets 10pt a side, and mounting at card width is
        // survivable only because `widthTracksTextView` is false.
        textView?.frame = CGRect(origin: .zero, size: unscaledSize)

        // Frame in zoomed (view) space; bounds in unzoomed (content) space.
        // Order matters: setting `frame` resets the bounds size, so `bounds` is
        // restored after it rather than before.
        frame = CGRect(origin: frame.origin,
                       size: CGSize(width: unscaledSize.width * zoom,
                                    height: unscaledSize.height * zoom))
        bounds = CGRect(origin: .zero, size: unscaledSize)
        return rebuilt
    }

    /// Focus is REQUESTED, never taken on the spot.
    ///
    /// `NSViewRepresentable.makeNSView` runs BEFORE the view is in a window, so
    /// `textView.window` is nil and `window?.makeFirstResponder(_:)` is a silent
    /// no-op. The scrap then mounts, looks perfect, and refuses every keystroke —
    /// which reads as "typing does nothing", the headline interaction failing.
    /// So record the wish and claim it again from `viewDidMoveToWindow`.
    func requestFocus(caretIndex: Int?) {
        wantsFocus = true
        pendingCaretIndex = caretIndex
        claimFocusIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimFocusIfPossible()
    }

    private func claimFocusIfPossible() {
        guard wantsFocus, let tv = textView, let window else { return }
        if let index = pendingCaretIndex {
            // UTF-16 units, matching both `NSRange` and the offsets
            // `ScrapLayout.characterIndex(at:)` returns. Clamping against
            // `String.count` would drag a valid caret backwards in any scrap
            // holding an emoji.
            let length = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: min(index, length), length: 0))
        }
        window.makeFirstResponder(tv)
        wantsFocus = false
        pendingCaretIndex = nil
    }

    func unmount() {
        detachEditor()
        wantsFocus = false
        pendingCaretIndex = nil
    }

    /// Blur, in full. `removeFromSuperview()` alone is NOT a detach: the shared
    /// `NSTextContainer` goes on pointing at the view and the layout manager is
    /// untouched, so whatever the mount did to that scrap's layout stays done and
    /// the next `makeEditor` on the same layout silently orphans this view.
    /// `ScrapLayout.releaseEditor()` is the counterpart that actually unbinds it.
    private func detachEditor() {
        textView?.delegate = nil
        textView?.removeFromSuperview()
        mountedLayout?.releaseEditor()
        textView = nil
        mountedLayout = nil
    }

    // MARK: - Camera forwarding (testable seams, as in CanvasEventNSView)

    func applyScroll(deltaX: CGFloat, deltaY: CGFloat, precise: Bool) {
        onScroll?(deltaX, deltaY, precise)
    }

    /// `editorPoint` is in THIS view's own coordinate space — the scrap's
    /// unzoomed text box, because bounds scaling holds `bounds` at the unzoomed
    /// size. It is NOT canvas space, and handing it straight to
    /// `CanvasCamera.zoom(to:anchoringViewPoint:)` — which expects canvas space
    /// — zooms about a point the writer never touched. `CanvasEventNSView` gets
    /// away with the identical code only because ITS space is canvas space. The
    /// one place that maps between them is `ScrapEditorGeometry.viewPoint`.
    func applyMagnify(magnification: CGFloat, atEditorPoint point: CGPoint) {
        onMagnify?(magnification, point)
    }

    override func scrollWheel(with event: NSEvent) {
        applyScroll(deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas)
    }

    override func magnify(with event: NSEvent) {
        applyMagnify(magnification: event.magnification,
                     atEditorPoint: convert(event.locationInWindow, from: nil))
    }
}

/// The one place a point in the mounted editor's space becomes a point in canvas
/// VIEW space.
///
/// The editor's space is content space translated to the card's text origin —
/// exactly, and with **no rotation term**, because `CanvasView` places the
/// container at the UNROTATED text origin and the container itself is never
/// rotated. As a mapping of the editor's own box this is unconditionally right.
///
/// What it cannot express is the card's *drawn* angle, and there is now a window
/// in which those differ: the editor is mounted from the click (so no keystroke
/// is lost) while the card spends ~120 ms straightening under it. Anchoring a
/// pinch through here during that window would be off by up to `r·θ` — ≈1.4 pt
/// at the corner of a default card — from where the writer's fingers are on the
/// card they can see.
///
/// **That window is closed by hit testing, not by arithmetic.** This function is
/// only ever reached from an event the container received, and
/// `ScrapEditorContainer.hitTest(_:)` returns `nil` while `isEditorVisible` is
/// false, so the event goes to `CanvasEventNSView` instead — whose space *is*
/// canvas space, with no approximation at all. By the time anything reaches this
/// function the card is level and drawn angle and editor box agree exactly.
///
/// The one thing that can still read the editor's geometry while it is invisible
/// is AppKit's own input-method candidate window, which anchors on the text
/// view's rect. Its error is bounded by the same ≈1.4 pt the unrotated hit test
/// already accepts, and it lasts a tenth of a second; it is accepted, not
/// overlooked.
enum ScrapEditorGeometry {
    static func viewPoint(fromEditorPoint point: CGPoint,
                          textOrigin: CGPoint,
                          camera: CanvasCamera) -> CGPoint {
        camera.viewPoint(fromContent: CGPoint(x: textOrigin.x + point.x,
                                              y: textOrigin.y + point.y))
    }
}

/// SwiftUI wrapper. Exactly one of these is ever in the hierarchy — the scrap
/// currently being edited (spec §7A.1). It is in the hierarchy from the instant
/// the writer clicks; `isEditorVisible` is what waits for the straighten.
struct ScrapEditorHost: NSViewRepresentable {
    let layout: ScrapLayout
    /// The TEXT box size, in content points. `CanvasView` owns the position and
    /// the card inset; this view owns only the editor.
    let unscaledSize: CGSize
    let zoom: CGFloat
    /// Where the writer clicked, so the caret lands where they aimed
    /// (spec §7A.2, the rule borrowed from Miro).
    let caretIndex: Int?
    /// Whether this editor is the visible text yet — see
    /// `ScrapEditorContainer.isEditorVisible`. `CanvasView` derives it from the
    /// same property it hands the renderer, so the editor appearing and the card
    /// ceasing to draw its text happen on one frame.
    let isEditorVisible: Bool
    let undoManager: UndoManager?
    let onScroll: (CGFloat, CGFloat, Bool) -> Void
    /// (magnification delta, point in the EDITOR's own unzoomed space). The
    /// caller maps it with `ScrapEditorGeometry.viewPoint`.
    let onMagnify: (CGFloat, CGPoint) -> Void
    /// Every change the writer makes, so the canvas can fold it into the model
    /// immediately (C5). Not debounced here — the store already debounces.
    let onTextChanged: () -> Void

    func makeNSView(context: Context) -> ScrapEditorContainer {
        let c = ScrapEditorContainer(frame: .zero)
        wire(c)
        c.mount(layout: layout, unscaledSize: unscaledSize, zoom: zoom)
        // Deliberately a REQUEST: there is no window yet.
        c.requestFocus(caretIndex: caretIndex)
        return c
    }

    func updateNSView(_ c: ScrapEditorContainer, context: Context) {
        wire(c)
        // Only re-claim focus when the editor was actually rebound — otherwise
        // every camera nudge would slam the caret back to the click point.
        if c.mount(layout: layout, unscaledSize: unscaledSize, zoom: zoom) {
            c.requestFocus(caretIndex: caretIndex)
        }
    }

    static func dismantleNSView(_ c: ScrapEditorContainer, coordinator: ()) {
        c.unmount()
    }

    private func wire(_ c: ScrapEditorContainer) {
        c.isEditorVisible = isEditorVisible
        c.canvasUndoManager = undoManager
        c.onScroll = onScroll
        c.onMagnify = onMagnify
        c.onTextChanged = onTextChanged
    }
}
