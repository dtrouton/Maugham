import SwiftUI
import MaughamCore
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
    /// Review posture (WF1): when true the manuscript is annotate-only
    /// (read-only text) and focus-dim + typewriter are suppressed. Threaded
    /// ONE-WAY from ProjectWindow → EditorHost; pushed onto the coordinator in
    /// updateNSView. Nothing reads it back into a binding (tripwires 2 & 6).
    var isReviewMode: Bool = false
    /// Cursor location to restore on first attach (nil = leave at 0).
    var initialCursorLocation: Int? = nil
    /// Fired on every selection change with the new caret location.
    var onCursorChanged: ((Int) -> Void)? = nil
    /// Fired inside `textDidChange` just before the binding setter writes
    /// new text. Delivers the post-edit caret position so the host can
    /// thread it into Document's V2 task-anchor alignment.
    var onPostEditCursor: ((Int) -> Void)? = nil
    /// Fired when the cursor's screenplay element changes (or after retokenize).
    /// Delivers a gutter abbreviation ("CHAR", "SCENE", "DLG", etc.) or nil
    /// in prose mode. Omit at call sites that don't need element tracking.
    var onElementChanged: ((String?) -> Void)? = nil
    /// Fired with precomputed `EditorMetrics` on the coordinator's debounced
    /// trailing edge (typing) and immediately on attach / external replace.
    /// Replaces the old `onTextChange` text mirror: the consumer (ProjectWindow)
    /// now does zero parsing — the page count comes from the keystroke's own
    /// parse. Omit at call sites that don't surface metrics.
    var onMetricsChanged: ((EditorMetrics) -> Void)? = nil
    /// Optional resolver for wiki-link titles. When set, ProseMode underlines
    /// `[[Title]]` tokens whose title matches a manuscript document.
    var wikiLinkResolver: ((String) -> Bool)? = nil
    /// Optional id-returning resolver used by mouseDown click routing.
    /// Returns the doc id if the title resolves, nil otherwise.
    var wikiLinkClickResolver: ((String) -> String?)? = nil
    var showElementGutter: Bool = true
    /// When set, the text view's paste(_:) routes pasteboard images to this
    /// handler instead of pasting them as text. Used for research notes to
    /// save images to a sibling _assets/ folder and insert a Markdown ref.
    /// The handler returns the Markdown ref string; the text view inserts it
    /// at the current cursor position.
    var imagePasteHandler: ((NSImage) -> String?)? = nil
    /// Resolves a paragraph_id to its NSRange in the current displayText.
    /// Wired through to the coordinator's paragraphRangeProvider so that
    /// `.maughamNavigateToParagraph` notifications (fired by clicking an
    /// annotation row) scroll the textView to the right paragraph.
    var paragraphRangeProvider: ((String) -> NSRange?)? = nil
    /// Resolves a doc-wide UTF-16 location to (paragraphId, offset) within
    /// that paragraph. Used by the markdown-checkbox click path.
    var paragraphLocator: ((Int) -> (paragraphId: String, offsetWithinParagraph: Int)?)? = nil
    /// Invoked when the user clicks a checkbox bracket — markdown `- [ ]`
    /// or Fountain `[[todo:]]`. The host wires this to
    /// `Document.setParagraph(id:text:)` with the flipped bracket text,
    /// dispatching by `MaughamCheckboxKind` to `MarkdownCheckboxScanner.flipBracket`
    /// or `FountainBoneyardScanner.flipTodoDone`.
    var checkboxToggleHandler: ((String, Int, MaughamCheckboxKind) -> Void)? = nil

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
        coordinator.onPostEditCursor = onPostEditCursor
        coordinator.onElementChanged = onElementChanged
        coordinator.onMetricsChanged = onMetricsChanged
        coordinator.wikiLinkResolverForClick = wikiLinkClickResolver
        coordinator.imagePasteHandler = imagePasteHandler
        coordinator.paragraphRangeProvider = paragraphRangeProvider
        coordinator.paragraphLocator = paragraphLocator
        coordinator.checkboxToggleHandler = checkboxToggleHandler
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
        textView.usesFindBar = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        // Inline prediction (macOS Sonoma+) rewrites text behind the scenes
        // via marked-text ranges. It races with our paragraph-anchor parsing
        // and produces "deleted text after cursor" symptoms when the user
        // edits in a way that contradicts a pending prediction — AppKit
        // reverts the user's edit, then we replay our shorter displayText
        // through applyExternalText and wipe the full content. Turn it off;
        // focused-writing users want their own words, not an OS-suggested
        // completion.
        if #available(macOS 14.0, *) {
            textView.inlinePredictionType = .no
        }
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
        if mode is ScreenplayMode && showElementGutter {
            textView.installGutter(coordinator: context.coordinator)
        }

        // Install the floating selection toolbar. It is added directly to the
        // NSScrollView (NOT to documentView and NOT to contentView), so it
        // floats above the scrolled text and is NOT clipped by the content clip
        // view — the standard place for a scroll-view accessory overlay. The
        // coordinator positions it in this parent's coordinate space via
        // `textView.convert(_:to:)` and only un-hides it while review posture is
        // on (see EditorCoordinator.updateSelectionToolbar).
        let toolbar = SelectionToolbarView(frame: .zero)
        toolbar.isHidden = true
        toolbar.translatesAutoresizingMaskIntoConstraints = true
        scrollView.addSubview(toolbar)
        context.coordinator.selectionToolbar = toolbar

        // Push the initial review posture before the surface goes live.
        context.coordinator.setReviewMode(isReviewMode)

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
        // Mode-change reconciliation for gutter.
        let needsGutter = (mode is ScreenplayMode) && showElementGutter
        if needsGutter && textView.gutterView == nil {
            textView.installGutter(coordinator: context.coordinator)
        } else if !needsGutter && textView.gutterView != nil {
            textView.removeGutter()
        }
        // Review posture is threaded ONE-WAY: push it onto the coordinator
        // (setReviewMode is guarded against no-op churn). Nothing reads it back.
        context.coordinator.setReviewMode(isReviewMode)
        context.coordinator.imagePasteHandler = imagePasteHandler
        context.coordinator.paragraphRangeProvider = paragraphRangeProvider
        context.coordinator.paragraphLocator = paragraphLocator
        context.coordinator.checkboxToggleHandler = checkboxToggleHandler
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

    var gutterView: ElementGutterView?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        // Checkbox click (markdown `- [ ]` or Fountain `[[todo:]]`) → flip
        // the bracket. Routed through the host's wiring of
        // Document.setParagraph (standard typing-burst path), NOT through
        // applyExternalText — see tripwire #7.
        if let hit = coordinator?.checkboxHitTest(atCharacterIndex: charIndex),
           let toggle = coordinator?.checkboxToggleHandler {
            toggle(hit.paragraphId, hit.offsetWithinParagraph, hit.kind)
            return
        }
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

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        if coordinator?.imagePasteHandler != nil {
            // AppKit's menu-item validation for Edit→Paste checks
            // readablePasteboardTypes; include image types so Paste is
            // enabled when image content is on the clipboard.
            let imageTypes: [NSPasteboard.PasteboardType] = [
                .init("public.png"),
                .init("public.tiff"),
                .tiff
            ]
            for t in imageTypes where !types.contains(t) {
                types.append(t)
            }
        }
        return types
    }

    override func paste(_ sender: Any?) {
        if let handler = coordinator?.imagePasteHandler,
           NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil),
           let image = NSImage(pasteboard: .general),
           let ref = handler(image) {
            let range = selectedRange()
            insertText(ref, replacementRange: range)
            return
        }
        super.paste(sender)
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // OS appearance flipped (or app appearance changed under Follow System).
        // Re-render so syntax highlighting and theme colors re-resolve.
        needsDisplay = true
        // Notify the coordinator so it can re-run the full styling pipeline
        // (background color, caret color, syntax highlighting attributes).
        NotificationCenter.default.post(
            name: .maughamEffectiveAppearanceChanged, object: nil)
    }

    fileprivate func updateColumnInset() {
        guard columnWidth > 0, bounds.width > 0 else { return }
        // Always reserve a minimum gutter on each side so text never runs
        // edge-to-edge against the binder/inspector dividers. When the
        // pane is wider than columnWidth the natural centering produces
        // generous gutters; when it's narrower we shrink the column to
        // bounds.width − 2·minGutter so the breathing room is preserved.
        let minGutter: CGFloat = 16
        let availableForColumn = max(40, bounds.width - 2 * minGutter)
        let effectiveColumn = min(columnWidth, availableForColumn)
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

        // Update gutter frame if present.
        if let gutter = gutterView {
            let gutterWidth = max(0, horizontal)
            gutter.frame = NSRect(
                x: 0,
                y: 0,
                width: gutterWidth,
                height: max(bounds.height, frame.height))
            gutter.needsDisplay = true
        }

        // Typewriter scroll reserves a viewport-relative vertical inset so the
        // active line can reach center even at the document's start/end. The
        // viewport height changes on resize, so recompute here. The method is
        // guarded against no-op churn, so this won't loop with setFrameSize.
        coordinator?.refreshTypewriterInset(in: self)
    }

    func installGutter(coordinator: EditorCoordinator) {
        guard gutterView == nil else { return }
        let gutter = ElementGutterView(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
        gutter.coordinator = coordinator
        gutter.associatedTextView = self
        gutter.autoresizingMask = [.height]
        addSubview(gutter)
        gutterView = gutter
        updateColumnInset()
    }

    func removeGutter() {
        gutterView?.removeFromSuperview()
        gutterView = nil
    }
}
