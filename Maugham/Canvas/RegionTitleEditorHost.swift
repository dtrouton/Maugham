import AppKit
import SwiftUI

/// What the writer has typed into a region's title so far, and which region's
/// field it was typed into. `CanvasRegionTitleEditing.commitIfOpen` writes it
/// only into the region it names.
struct CanvasRegionTitleDraft: Equatable {
    let region: CanvasRegionID
    let text: String
}

/// The text field a region's title is typed into on the canvas. A plain
/// `NSTextField`: it edits through the window's field editor, not through
/// `ScrapLayout`'s shared TextKit stack, so tripwires 26 and 28 do not apply.
final class RegionTitleField: NSTextField {}

/// Holds the one `RegionTitleField` and is its delegate: Return commits,
/// Escape cancels, and losing the keyboard any other way commits what was
/// typed. Each of the three reports once per opening.
///
/// **Focus is requested, not taken** (tripwire 27's rule, as
/// `ScrapEditorContainer` keeps it): `makeNSView` runs with no window, so the
/// claim waits for `viewDidMoveToWindow`.
///
/// **Zoom is the font size**, scaled by the camera; never `.scaleEffect`
/// (tripwire 25). The field is level over the region's ≤1° tilt, and the
/// renderer stops drawing that region's label while it is open.
final class RegionTitleEditorContainer: NSView, NSTextFieldDelegate {

    let field = RegionTitleField(string: "")

    /// The region this field is naming. A change rebinds: new text, a fresh
    /// claim on the keyboard, and a new chance to report.
    private(set) var regionID: CanvasRegionID?

    /// Set once Return, Escape or a lost focus has reported. Set BEFORE the
    /// report, so the `controlTextDidEndEditing` that follows a Return or an
    /// Escape (the field resigning as it is torn down) commits nothing — and
    /// cleared again when the report comes back refused (`false`), so a field
    /// whose write was refused still takes Return and Escape.
    private(set) var hasReported = false

    private var wantsFocus = false

    var onTextChanged: ((String) -> Void)?
    var onCommit: ((String) -> Bool)?
    var onCancel: (() -> Bool)?
    var onLostFocus: ((String) -> Bool)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = CanvasRegion.untitledLabel
        field.delegate = self
        field.autoresizingMask = [.width, .height]
        field.frame = bounds
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Bind to `id` showing `label`. Re-binding to the same region changes
    /// nothing the writer typed; a different region is a fresh opening.
    /// Returns whether it rebound.
    @discardableResult
    func bind(to id: CanvasRegionID, label: String) -> Bool {
        guard regionID != id else { return false }
        regionID = id
        hasReported = false
        field.stringValue = label
        return true
    }

    /// The label's size at this zoom — 11 pt medium, as the renderer draws it.
    func setZoom(_ zoom: CGFloat) {
        let size = CanvasRenderer.regionLabelPointSize * zoom
        guard field.font?.pointSize != size else { return }
        field.font = NSFont.systemFont(ofSize: size, weight: .medium)
    }

    func requestFocus() {
        wantsFocus = true
        claimFocusIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimFocusIfPossible()
    }

    private func claimFocusIfPossible() {
        guard wantsFocus, let window else { return }
        wantsFocus = false
        // Selects the whole name, as Finder does on a rename.
        window.makeFirstResponder(field)
    }

    /// Torn down: nothing reports after this.
    func unmount() {
        hasReported = true
        wantsFocus = false
        onTextChanged = nil
        onCommit = nil
        onCancel = nil
        onLostFocus = nil
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        onTextChanged?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            guard !hasReported else { return true }
            hasReported = true
            if onCommit?(field.stringValue) == false { hasReported = false }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard !hasReported else { return true }
            hasReported = true
            if onCancel?() == false { hasReported = false }
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !hasReported else { return }
        hasReported = true
        if onLostFocus?(field.stringValue) == false { hasReported = false }
    }
}

/// Bridges `RegionTitleEditorContainer` into `CanvasView.mountedEditor`'s
/// second branch. Built only there.
struct RegionTitleEditorHost: NSViewRepresentable {
    let regionID: CanvasRegionID
    let label: String
    let zoom: CGFloat
    let onTextChanged: (String) -> Void
    let onCommit: (String) -> Bool
    let onCancel: () -> Bool
    let onLostFocus: (String) -> Bool

    func makeNSView(context: Context) -> RegionTitleEditorContainer {
        let c = RegionTitleEditorContainer(frame: .zero)
        wire(c)
        c.bind(to: regionID, label: label)
        // A REQUEST: there is no window yet.
        c.requestFocus()
        return c
    }

    func updateNSView(_ c: RegionTitleEditorContainer, context: Context) {
        wire(c)
        // Only a different region re-claims the keyboard and resets the text;
        // anything else (a camera nudge, a redraw) leaves the writer's typing.
        if c.bind(to: regionID, label: label) {
            c.requestFocus()
        }
    }

    static func dismantleNSView(_ c: RegionTitleEditorContainer, coordinator: ()) {
        c.unmount()
    }

    private func wire(_ c: RegionTitleEditorContainer) {
        c.setZoom(zoom)
        c.onTextChanged = onTextChanged
        c.onCommit = onCommit
        c.onCancel = onCancel
        c.onLostFocus = onLostFocus
    }
}
