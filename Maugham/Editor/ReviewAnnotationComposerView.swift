import AppKit

/// A minimal inline composer for authoring a review annotation's body. A plain
/// AppKit `NSView` wrapping a single-line `NSTextField` — NOT an `NSPopover`
/// (tripwire 5/7: popovers size unreliably, block input, and fight NSTextView
/// focus). It is added to the same overlay parent as `SelectionToolbarView`,
/// positioned where that toolbar sat.
///
/// Throwaway-minimal by intent: Task 5 restyles annotation authoring into a
/// margin slip. For now Enter commits, Escape cancels.
final class ReviewAnnotationComposerView: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let onCommit: (String) -> Void
    private let onCancel: () -> Void

    /// - Parameter initialText: pre-fills the field (e.g. the selected text for
    ///   a Suggest, which the reviewer edits into the replacement). Empty for
    ///   Comment/Query.
    init(placeholder: String,
         initialText: String = "",
         onCommit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        // Background + border are dynamic NSColors; a `.cgColor` captures the
        // colour for the appearance current at construction and never adapts on
        // a later light/dark switch. Resolve them in
        // `viewDidChangeEffectiveAppearance()` (called once on first display and
        // again on every appearance change).
        applyAdaptiveLayerColors()
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            s.shadowBlurRadius = 4
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()

        field.placeholderString = placeholder
        field.stringValue = initialText
        // A standard bezeled/bordered field draws the system field appearance,
        // which is adaptive: dark-on-light in light mode, light-on-dark in dark
        // mode. The previous borderless/no-background field combined with the
        // composer's own layer background produced white-on-white text in dark
        // mode. `.labelColor` keeps the text legible against the field's own
        // (system, adaptive) background.
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.textColor = .labelColor
        field.focusRingType = .none
        field.delegate = self

        // This composer is positioned MANUALLY by the coordinator (its frame
        // origin is set to where the toolbar sat), so it keeps
        // `translatesAutoresizingMaskIntoConstraints == true` and AppKit
        // synthesises a width/height constraint from its frame. To avoid that
        // synthesised size fighting Auto Layout pins on the inner field (the
        // same `width == 0`-class conflict that bit SelectionToolbarView), we
        // size the field with the autoresizing mask instead of constraints:
        // inset 8pt horizontally and centre it vertically, tracking the
        // container's fixed frame. No Auto Layout touches this view.
        let inset: CGFloat = 8
        let fieldHeight = field.fittingSize.height
        field.frame = NSRect(
            x: inset,
            y: (bounds.height - fieldHeight) / 2,
            width: bounds.width - inset * 2,
            height: fieldHeight)
        field.translatesAutoresizingMaskIntoConstraints = true
        field.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Re-resolve the layer's dynamic colours against the current effective
    /// appearance. Layer colours are plain CGColors with no appearance binding,
    /// so they must be re-set here (called on first display and on every
    /// light/dark switch) rather than once in `init`.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAdaptiveLayerColors()
    }

    private func applyAdaptiveLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Make the field first responder so the reviewer can type immediately.
    /// With pre-filled text, place the caret at the end so the reviewer edits
    /// the replacement rather than the whole thing being select-all-overwritten
    /// on the first keystroke.
    func focus() {
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    func dismiss() {
        removeFromSuperview()
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel()
            return true
        default:
            return false
        }
    }
}
