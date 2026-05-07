import SwiftUI
import AppKit

/// SwiftUI host for an NSTextView-backed editor surface, driven by a
/// WritingMode (ProseMode in 1b).
struct EditorSurface: NSViewRepresentable {
    @Binding var text: String
    let theme: Theme
    let typography: TypographySettings
    let mode: any WritingMode

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(
            text: $text, mode: mode,
            theme: theme, typography: typography)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MaughamTextView()
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.delegate = context.coordinator
        textView.string = text
        textView.textContainerInset = NSSize(width: 0, height: 24)

        // Constrain text container to a fixed column width so long lines wrap
        // at pageWidthCharacters even when the window is wide.
        if let container = textView.textContainer {
            let columnWidth = mode.textColumnWidth(typography: typography)
            container.widthTracksTextView = false
            container.size = NSSize(width: columnWidth,
                                    height: .greatestFiniteMagnitude)
            textView.frame = NSRect(x: 0, y: 0,
                                    width: columnWidth, height: 0)
        }

        let scrollView = CenteringScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        context.coordinator.attach(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.applyExternalText(text)
        }
        if context.coordinator.theme != theme
            || context.coordinator.typography != typography {
            context.coordinator.applyAppearance(
                theme: theme, typography: typography)

            if let container = textView.textContainer {
                let columnWidth = mode.textColumnWidth(typography: typography)
                container.size = NSSize(width: columnWidth,
                                        height: .greatestFiniteMagnitude)
                textView.frame.size.width = columnWidth
                scrollView.needsLayout = true
            }
        }
    }
}

/// NSTextView subclass that lets us tweak first-responder-only behaviors
/// without subclassing the more invasive parts.
private final class MaughamTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
    }
}

/// NSScrollView subclass that horizontally centers its document view inside
/// the visible area whenever the document is narrower than the clip view.
private final class CenteringScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let documentView else { return }
        let clipBounds = contentView.bounds
        let docFrame = documentView.frame
        if docFrame.size.width < clipBounds.width {
            var origin = documentView.frame.origin
            origin.x = (clipBounds.width - docFrame.size.width) / 2
            documentView.frame.origin = origin
        }
    }
}
