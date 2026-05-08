import SwiftUI
import AppKit

/// SwiftUI host for an NSTextView-backed editor surface, driven by a
/// WritingMode (ProseMode in 1b).
struct EditorSurface: NSViewRepresentable {
    @Binding var text: String
    let theme: Theme
    let typography: TypographySettings
    let mode: any WritingMode
    let typewriterScroll: Bool
    let sentenceFocus: Bool
    let paragraphFocus: Bool
    /// Cursor location to restore on first attach (nil = leave at 0).
    var initialCursorLocation: Int? = nil
    /// Fired on every selection change with the new caret location.
    var onCursorChanged: ((Int) -> Void)? = nil
    /// Optional resolver for wiki-link titles. When set, ProseMode underlines
    /// `[[Title]]` tokens whose title matches a manuscript document.
    var wikiLinkResolver: ((String) -> Bool)? = nil
    /// Optional id-returning resolver used by mouseDown click routing.
    /// Returns the doc id if the title resolves, nil otherwise.
    var wikiLinkClickResolver: ((String) -> String?)? = nil

    func makeCoordinator() -> EditorCoordinator {
        let coordinator = EditorCoordinator(
            text: $text, mode: mode,
            theme: theme, typography: typography,
            typewriterScroll: typewriterScroll,
            sentenceFocus: sentenceFocus,
            paragraphFocus: paragraphFocus,
            wikiLinkResolver: wikiLinkResolver)
        coordinator.initialCursorLocation = initialCursorLocation
        coordinator.onCursorChanged = onCursorChanged
        coordinator.wikiLinkResolverForClick = wikiLinkClickResolver
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let columnWidth = mode.textColumnWidth(typography: typography)

        let textView = MaughamTextView()
        textView.columnWidth = columnWidth
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
        // Let the text view fill the scroll view's width; centering happens
        // via textContainerInset, recomputed on every resize.
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 24)

        if let container = textView.textContainer {
            container.widthTracksTextView = false
            container.size = NSSize(width: columnWidth,
                                    height: .greatestFiniteMagnitude)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        context.coordinator.attach(to: textView)
        textView.coordinator = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MaughamTextView else { return }
        // SwiftUI's NSViewRepresentable doesn't always propagate scroll-view
        // size changes through AppKit autoresizing the way a pure-AppKit
        // window would. Force-track the content width here so MaughamTextView's
        // setFrameSize override fires and recenters the column gutters on
        // every layout pass.
        let targetWidth = scrollView.contentSize.width
        if targetWidth > 0, abs(textView.frame.width - targetWidth) > 0.5 {
            textView.frame.size.width = targetWidth
        }
        if textView.string != text {
            context.coordinator.applyExternalText(text)
        }
        if context.coordinator.theme != theme
            || context.coordinator.typography != typography {
            context.coordinator.applyAppearance(
                theme: theme, typography: typography)

            let columnWidth = mode.textColumnWidth(typography: typography)
            textView.columnWidth = columnWidth
            if let container = textView.textContainer {
                container.size = NSSize(width: columnWidth,
                                        height: .greatestFiniteMagnitude)
            }
        }
        if context.coordinator.typewriterScroll != typewriterScroll {
            context.coordinator.applyTypewriterScroll(typewriterScroll)
        }
        if context.coordinator.sentenceFocus != sentenceFocus
            || context.coordinator.paragraphFocus != paragraphFocus {
            context.coordinator.applyFocusPrefs(
                sentence: sentenceFocus, paragraph: paragraphFocus)
        }
    }
}

/// NSTextView subclass that fills the scroll view's width and uses
/// `textContainerInset` to center the column. The container itself is fixed
/// at `columnWidth`; the inset on each side absorbs the gutters and updates
/// whenever the text view resizes (which happens automatically when the
/// scroll view's clip view changes size due to `autoresizingMask = [.width]`).
private final class MaughamTextView: NSTextView {
    var columnWidth: CGFloat = 0 {
        didSet { updateColumnInset() }
    }

    weak var coordinator: EditorCoordinator?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        if let title = coordinator?.wikiLinkTitle(atCharacterIndex: charIndex),
           let resolver = coordinator?.wikiLinkResolverForClick,
           let id = resolver(title) {
            NotificationCenter.default.post(
                name: .maughamNavigateToDocument,
                object: nil,
                userInfo: ["id": id])
            return
        }
        super.mouseDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateColumnInset()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI may set the scroll-view geometry only after the text view
        // has already been mounted, so the initial setFrameSize sees a
        // pre-layout width. Recompute once we're attached to a window.
        DispatchQueue.main.async { [weak self] in
            self?.updateColumnInset()
        }
    }

    private func updateColumnInset() {
        guard columnWidth > 0, bounds.width > 0 else { return }
        // When the available width is wider than the configured column,
        // center the column with gutters on each side. When the pane is
        // narrower than the column (e.g. squeezed by binder + inspector),
        // shrink the container to match so text wraps at the visible edge
        // rather than overflowing.
        let effectiveColumn = min(columnWidth, bounds.width)
        let horizontal = max(0, (bounds.width - effectiveColumn) / 2)
        if let container = textContainer,
           abs(container.size.width - effectiveColumn) > 0.5 {
            container.size = NSSize(
                width: effectiveColumn,
                height: .greatestFiniteMagnitude)
        }
        if abs(textContainerInset.width - horizontal) > 0.5 {
            textContainerInset = NSSize(
                width: horizontal,
                height: textContainerInset.height)
        }
    }
}
