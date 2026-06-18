import AppKit

/// SPIKE (collab review): a small floating toolbar that appears above the
/// current text selection. Pure AppKit NSView — NOT an NSPopover (tripwire 5:
/// popovers size unreliably, block input, and fight NSTextView focus). It is
/// installed as a subview of an ancestor that is NOT clipped by the scroll
/// view's content clip view (the scroll view's superview), so it can float
/// above the text.
///
/// Driven ONE-WAY from `EditorCoordinator.textViewDidChangeSelection`: the
/// coordinator sets the frame origin and `isHidden`. The buttons emit
/// `print("toolbar: <kind>")` for the spike — no SwiftUI state, no write-back,
/// so there is no AppKit↔SwiftUI loop (tripwire 5 / tripwire 2).
///
/// Throwaway. The real review feature replaces the button actions with the
/// Comment / Suggest / Query annotation flows.
final class SelectionToolbarView: NSView {
    enum Kind: String, CaseIterable {
        case comment = "Comment"
        case suggest = "Suggest"
        case query = "Query"
    }

    /// Optional hook the real feature wires; the spike just prints.
    var onAction: ((Kind) -> Void)?

    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        // A subtle shadow lifts it off the text.
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            s.shadowBlurRadius = 4
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        for kind in Kind.allCases {
            let button = NSButton(title: kind.rawValue, target: self,
                                  action: #selector(buttonTapped(_:)))
            button.bezelStyle = .recessed
            button.setButtonType(.momentaryPushIn)
            button.tag = Kind.allCases.firstIndex(of: kind)!
            stack.addArrangedSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func buttonTapped(_ sender: NSButton) {
        let kind = Kind.allCases[sender.tag]
        print("toolbar: \(kind.rawValue.lowercased())")
        onAction?(kind)
    }

    /// The toolbar should not steal first-responder focus from the text view
    /// when the user clicks a button — a button click that ended the selection
    /// would otherwise hide the toolbar before the action fires. NSButton
    /// handles its own click without becoming first responder, so a plain
    /// hit-test is fine; we only override to be explicit for the spike.
    override var acceptsFirstResponder: Bool { false }
}
