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

    init(placeholder: String,
         onCommit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            s.shadowBlurRadius = 4
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()

        field.placeholderString = placeholder
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Make the field first responder so the reviewer can type immediately.
    func focus() {
        window?.makeFirstResponder(field)
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
