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
    /// this view's UNROTATED box while the card beneath is still up to `CanvasMaterial.maximumTiltDegrees` off
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

    /// The canvas's recorder, NOT its bare `UndoManager`. ⌘Z pressed inside a
    /// scrap has to close the gesture holding the run of typing in progress
    /// before the manager is asked to undo anything, and `CanvasUndo.undo()` is
    /// the only thing that does — see its doc. `CanvasEventNSView` vends the bare
    /// manager instead, correctly: nothing is focused there, so no gesture is
    /// open.
    var canvasUndo: CanvasUndo?
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
    /// `undoManagerForTextView:`, and it is the text view's `nextResponder`
    /// vending the canvas manager from an `undoManager` override — and
    /// `textView.undoManager` was still nil. Flipping `allowsUndo` to true makes
    /// the delegate hook work, at the price of the text view registering its own
    /// typing steps on the canvas stack, which is the double-registration Task 3
    /// rejected in full.
    ///
    /// Left unhandled, the action reaches `NSWindow`, which asks the FIRST
    /// RESPONDER for a manager, gets that nil, and falls back to its delegate's —
    /// SwiftUI's, not the canvas's. So ⌘Z inside a scrap would silently drive the
    /// wrong stack. `CanvasUndo` owns undo; these are the four lines that make
    /// its stack reachable from inside an editor, and `validateUserInterfaceItem`
    /// below is what gives the menu item its name once it is.
    ///
    /// There is deliberately no `undoManager` override on this view. It would be
    /// inert, measured twice over: with one in place `window.undoManager` was
    /// still not the canvas manager with either the text view OR the container as
    /// first responder — and this view cannot become first responder in the first
    /// place, since `acceptsFirstResponder` defaults to false here. Nothing reads
    /// `self.undoManager`. These two methods reach `canvasUndo` directly, which is
    /// the whole route.
    ///
    /// `CanvasEventNSView` does have one, and that is NOT because being first
    /// responder makes `NSWindow` ask it — measured 2026-07-27, it does not; see
    /// that file. It has one because `NSResponder.undoManager` is a chain walk
    /// anything under it might make, and because the tests need a handle on the
    /// shipping manager. The route that actually carries ⌘Z is the same one as
    /// here: an explicit `undo:`/`redo:` pair with a validator beside it.
    @objc func undo(_ sender: Any?) {
        canvasUndo?.undo()
    }

    @objc func redo(_ sender: Any?) {
        canvasUndo?.redo()
    }

    /// Claiming an action obliges this view to validate it: AppKit enables a menu
    /// item whose responder merely responds to the selector, so without this the
    /// Edit menu offers a live Undo with an empty stack the moment a scrap takes
    /// focus.
    ///
    /// And it obliges this view to TITLE it. `NSWindow` retitles Undo/Redo from
    /// whichever manager it resolves, but the whole point of the two methods
    /// above is that the action never reaches `NSWindow` — so left alone the item
    /// keeps whatever the nib gave it, and every canvas step reads a bare "Undo"
    /// with no word about what it will take back. `undoMenuItemTitle` is the same
    /// localised string `NSWindow` would have used, and it already reads "Undo"
    /// on an empty stack.
    ///
    /// Guarded on `NSMenuItem` rather than assumed: the protocol is
    /// `NSValidatedUserInterfaceItem`, which a toolbar item or a control also
    /// satisfies, and `title` is not on it.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = canvasUndo?.undoMenuItemTitle
                ?? NSLocalizedString("Undo", comment: "Edit menu item, nothing to undo")
            return canvasUndo?.canUndo ?? false
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = canvasUndo?.redoMenuItemTitle
                ?? NSLocalizedString("Redo", comment: "Edit menu item, nothing to redo")
            return canvasUndo?.canRedo ?? false
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

        // Frame in zoomed (view) space; bounds in unzoomed (content) space. The
        // two together ARE the zoom: AppKit holds a frame→bounds scale, and a
        // frame write on its own moves `bounds.size` to PRESERVE the old scale.
        // So a zoom change needs this explicit bounds write, and it has to come
        // after the frame write rather than before.
        //
        // Nothing outside this method has to defend it, because what has to
        // survive is the SCALE rather than `bounds.size`, and AppKit preserves
        // the scale itself. Measured on macOS 26.5: a reposition, a 500x210
        // write, an aspect-BREAKING 960x100 write, a 1pt nudge, frame → .zero
        // and back, a superview autoresize and two writes in a row all left the
        // container AND the text view at exactly the scale this line set. The
        // scale is the half the drawn/edited agreement rests on: it is what the
        // glyphs are rasterised and positioned at, so they stay on top of the
        // same layout the renderer is drawing.
        //
        // Do NOT "harden" this with a `setFrameSize` override that forces
        // `bounds.size` back to `unscaledSize`. It does not protect the
        // invariant, it breaks it: measured by mutation, that override puts the
        // editor at scale 2.0833 under a 500x210 frame and (2.833, 3.0) under a
        // superview autoresize, while the renderer draws at 2 — sliding the
        // glyphs off the card beneath, which is the §7A.2 text-jumping failure
        // itself. Recomputing bounds as frame/zoom would yield the correct scale,
        // but it hand-derives a value AppKit already holds exactly (`ScrapLayout`
        // requirement 3), which is the wrongness we avoid. Pinned by
        // `test_anExternalFrameWriteLeavesTheEditorAtTheCameraScale`.
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
        // Not in `detachEditor`, which also runs on a rebind — resetting it there
        // would flash the editor visible mid-straighten every time the writer
        // clicks from one scrap to the next. Here it is a full teardown, and
        // leaving the switch where the last straighten put it is a trap: it is
        // guarded on a real change, so a container unmounted while invisible and
        // then reused mounts at alpha 0 and stays there until something writes a
        // DIFFERENT value. Setting it here writes alphaValue = 1 on a view about
        // to be torn down in `dismantleNSView`, which can flash the editor visible
        // for a frame if a display pass lands between the two during a blur — it
        // only arises if the writer blurs *during* the ~120 ms straighten, and
        // the alternative (not resetting here) is worse. Harmless while dismantled.
        isEditorVisible = true
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
/// pinch through here during that window would be off by up to `r·θ` — ≈2.2 pt
/// at the corner of a default 240×80 card at the calibrated
/// `CanvasMaterial.maximumTiltDegrees` (r = 126.5 pt, θ = 1.0°) — from where the
/// writer's fingers are on the card they can see.
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
/// view's rect. Its error is bounded by the same ≈2.2 pt the unrotated hit test
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
    /// The recorder rather than the manager — see `ScrapEditorContainer.canvasUndo`.
    let canvasUndo: CanvasUndo?
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
        c.canvasUndo = canvasUndo
        c.onScroll = onScroll
        c.onMagnify = onMagnify
        c.onTextChanged = onTextChanged
    }
}
