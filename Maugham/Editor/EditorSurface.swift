import SwiftUI
import MaughamCore
import AppKit

/// SwiftUI host for an NSTextView-backed editor surface, driven by a
/// WritingMode (ProseMode in 1b).
struct EditorSurface: NSViewRepresentable {
    @Binding var text: String
    /// Retained to seed `makeCoordinator`'s initial state only (the model can't
    /// seed the coordinator before it exists); runtime appearance changes flow
    /// via `control` (ADR 0017).
    let theme: Theme
    let typography: TypographySettings
    let mode: any WritingMode
    let typewriterScroll: Bool
    let sentenceFocus: Bool
    let paragraphFocus: Bool
    /// Control-plane model (ADR 0017). The coordinator observes this directly;
    /// it is the channel for posture/appearance/annotation changes, replacing
    /// the per-prop pushes in updateNSView. Threaded ONE-WAY from the owning
    /// view (ProjectWindow via EditorHost for manuscripts; ResearchNoteEditor
    /// for research notes). Required — all production call sites must pass a
    /// real, populated model; the compiler enforces this (no default).
    var control: EditorControl
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
    /// Origin project id (`ProjectIdentifier.id(for:)`) stamped onto the
    /// coordinator's `.maughamScriptDidUpdate` posts so receivers scope them to
    /// their own window (Channel A). Passed by manuscript hosts (EditorHost);
    /// nil for research notes, which never post scripts.
    var scriptOriginProjectId: String? = nil
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
    /// Maps a doc-wide UTF-16 location to the containing paragraph's id + range.
    /// Wired to `Document.paragraphRange(at:)`. Used by the review toolbar to
    /// capture a paragraph-relative span anchor for the selection.
    var paragraphRangeAtLocation: ((Int) -> (id: String, range: NSRange)?)? = nil
    /// Invoked when the reviewer commits a Comment/Query/Suggest annotation from
    /// the selection toolbar. The trailing `String?` is the replacement text
    /// (Suggest only; nil for Comment/Query). Wired to
    /// `Document.addReviewerAnnotation(...)`.
    var createAnnotationHandler: ((AnnotationKind, String, SpanAnchor, String, String?) async -> Void)? = nil
    /// Resolves a paragraphId → its display text (for grapheme→UTF-16 of spans).
    var reviewParagraphTextProvider: ((String) -> String?)? = nil
    /// Resolves a paragraphId → its UTF-16 NSRange in the full display string.
    var reviewParagraphRangeProvider: ((String) -> NSRange?)? = nil
    /// Pulls the CURRENT open-annotation set on demand — used by the coordinator
    /// to resolve marks synchronously on review entry (first-toggle marks fix).
    var reviewAnnotationsProvider: (() -> [Annotation])? = nil
    /// The local reviewer's display name — gates Edit/Delete on the interactive
    /// margin card (`AnnotationOwnership.isOwn`). Pulled on demand.
    var reviewLocalAuthorName: (() -> String)? = nil
    /// Interactive margin-card action handlers (Part 1). Each maps an annotation
    /// id (+ payload for reply/edit) to the matching `Document` mutation. Threaded
    /// ONE-WAY; wired in make/update like `createAnnotationHandler`.
    var reviewAcceptHandler: ((String) async -> Void)? = nil
    var reviewRejectHandler: ((String) async -> Void)? = nil
    var reviewArchiveHandler: ((String) async -> Void)? = nil
    var reviewReplyHandler: ((String, String) async -> Void)? = nil
    var reviewEditHandler: ((String, String, String?) async -> Void)? = nil
    var reviewWithdrawHandler: ((String) async -> Void)? = nil

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
        coordinator.paragraphRangeAtLocation = paragraphRangeAtLocation
        coordinator.createAnnotationHandler = createAnnotationHandler
        coordinator.reviewParagraphTextProvider = reviewParagraphTextProvider
        coordinator.reviewParagraphRangeProvider = reviewParagraphRangeProvider
        coordinator.reviewAnnotationsProvider = reviewAnnotationsProvider
        coordinator.scriptOriginProjectId = scriptOriginProjectId
        assignReviewCardHandlers(to: coordinator)
        return coordinator
    }

    /// Thread the interactive-card handlers + local-author provider onto the
    /// coordinator. Shared by make/update so the wiring can't drift between them.
    private func assignReviewCardHandlers(to coordinator: EditorCoordinator) {
        coordinator.reviewLocalAuthorName = reviewLocalAuthorName
        coordinator.reviewAcceptHandler = reviewAcceptHandler
        coordinator.reviewRejectHandler = reviewRejectHandler
        coordinator.reviewArchiveHandler = reviewArchiveHandler
        coordinator.reviewReplyHandler = reviewReplyHandler
        coordinator.reviewEditHandler = reviewEditHandler
        coordinator.reviewWithdrawHandler = reviewWithdrawHandler
    }

    func makeNSView(context: Context) -> NSScrollView {
        let columnWidth = mode.textColumnWidth(typography: typography)

        let textView = MaughamTextView()
        // Pin the editor to TextKit 1. On recent macOS a fresh NSTextView is
        // TextKit 2, whose caret is a private `NSTextInsertionIndicator` we can't
        // resize — so the empty-line caret renders at the full line-fragment
        // height (glyph + the ~12pt line spacing) and "shrinks" when you type.
        // Touching `layoutManager` permanently downgrades the view to TextKit 1,
        // where `MaughamTextView.drawInsertionPoint` can clamp the caret. This
        // also makes prose consistent with screenplay/review/typewriter, which
        // already run TK1 (the gutter/overlays touch `layoutManager`) — and the
        // typing-perf work was tuned against that TK1 screenplay path. Do NOT
        // remove this line: it reads as unused but it is what selects the engine.
        _ = textView.layoutManager
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

        // Install the floating selection toolbar. It is added directly to the
        // NSScrollView (NOT to documentView and NOT to contentView), so it
        // floats above the scrolled text and is NOT clipped by the content clip
        // view — the standard place for a scroll-view accessory overlay. The
        // coordinator positions it in this parent's coordinate space via
        // `textView.convert(_:to:)` and only un-hides it while review posture is
        // on (see EditorCoordinator.updateSelectionToolbar).
        //
        // This MUST be assigned BEFORE `attach(to:)`, which wires
        // `selectionToolbar?.onAction`. If the toolbar is nil at attach time the
        // optional-chain no-ops and the entire Comment/Query/Suggest authoring
        // flow goes dead (clicking a toolbar button hits nothing). The toolbar
        // depends only on the already-created scrollView, not on anything attach
        // sets up, so this ordering is safe.
        let toolbar = SelectionToolbarView(frame: .zero)
        toolbar.isHidden = true
        toolbar.translatesAutoresizingMaskIntoConstraints = true
        scrollView.addSubview(toolbar)
        context.coordinator.selectionToolbar = toolbar

        context.coordinator.attach(to: textView)
        // Hand the control-plane model to the coordinator. It observes the model
        // from here on; the per-prop pushes below remain during the parallel
        // migration (ADR 0017) and are removed in later tasks.
        context.coordinator.observeControl(control)
        textView.coordinator = context.coordinator
        if mode is ScreenplayMode && showElementGutter {
            textView.installGutter(coordinator: context.coordinator)
        }

        // Guard the wiring above: `attach` sets `selectionToolbar?.onAction`,
        // so the toolbar MUST already be assigned (it is, four lines up). If
        // this ever regresses to a nil toolbar at attach time the whole
        // Comment/Query/Suggest authoring flow goes dead. This path can't be
        // driven from a unit test (NSViewRepresentable.Context is unsynthesizable);
        // the coordinator-side contract is covered by a test, this is the
        // production-path backstop. (Smoke-only otherwise.)
        #if DEBUG
        assert(context.coordinator.selectionToolbar?.onAction != nil,
               "selection toolbar onAction must be wired after makeNSView")
        #endif

        // The open annotation set is no longer seeded here: it flows through the
        // control model (ADR 0017), applied by `observeControl`/`applyControl`
        // above. A fresh-launch-straight-into-review still shows existing marks
        // because `setReviewMode`'s on-entry `reviewAnnotationsProvider` pull
        // resolves the real set synchronously (Bug A), independent of the model.

        return scrollView
    }

    /// Teardown hook — SwiftUI calls this when the representable leaves the view
    /// tree (piece flip via `.id(path)`, and window close when SwiftUI releases
    /// the scene). Break the coordinator↔text-view graph and cancel its async
    /// work so a coordinator SwiftUI has not yet released holds nothing heavy and
    /// does no work. See `EditorCoordinator.detach()` for why the leak is scene
    /// retention rather than an ARC cycle.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: EditorCoordinator) {
        MainActor.assumeIsolated {
            coordinator.detach()
        }
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
        // Appearance itself flows via EditorControl (ADR 0017); only the
        // text-container width remains a layout concern handled here.
        let columnWidth = mode.textColumnWidth(typography: typography)
        if abs(textView.columnWidth - columnWidth) > 0.5 {
            textView.columnWidth = columnWidth
            textView.textContainer?.size = NSSize(
                width: columnWidth, height: .greatestFiniteMagnitude)
        }
        // Mode-change reconciliation for gutter.
        let needsGutter = (mode is ScreenplayMode) && showElementGutter
        if needsGutter && textView.gutterView == nil {
            textView.installGutter(coordinator: context.coordinator)
        } else if !needsGutter && textView.gutterView != nil {
            textView.removeGutter()
        }
        context.coordinator.imagePasteHandler = imagePasteHandler
        context.coordinator.paragraphRangeProvider = paragraphRangeProvider
        context.coordinator.paragraphLocator = paragraphLocator
        context.coordinator.checkboxToggleHandler = checkboxToggleHandler
        context.coordinator.paragraphRangeAtLocation = paragraphRangeAtLocation
        context.coordinator.createAnnotationHandler = createAnnotationHandler
        // Crafted-render providers — kept current so the model-driven recompute
        // (via `applyControl` → `setReviewAnnotations`) and the on-entry provider
        // pull both read fresh resolvers. The open annotation set itself no longer
        // pushes from here; it flows through the control model (ADR 0017).
        context.coordinator.reviewParagraphTextProvider = reviewParagraphTextProvider
        context.coordinator.reviewParagraphRangeProvider = reviewParagraphRangeProvider
        // Pull-on-entry provider: the coordinator invokes it on review entry to
        // resolve the real annotation set synchronously (first-toggle marks fix).
        context.coordinator.reviewAnnotationsProvider = reviewAnnotationsProvider
        context.coordinator.scriptOriginProjectId = scriptOriginProjectId
        // Interactive-card handlers + local-author provider must be current before
        // the recompute path reads ownership.
        assignReviewCardHandlers(to: context.coordinator)
    }
}

/// NSTextView subclass that fills the scroll view's width and uses
/// `textContainerInset` to center the column. The container itself is fixed
/// at `columnWidth`; the inset on each side absorbs the gutters and updates
/// whenever the text view resizes (which happens automatically when the
/// scroll view's clip view changes size due to `autoresizingMask = [.width]`).
final class MaughamTextView: NSTextView {
    var columnWidth: CGFloat = 0 {
        didSet { updateColumnInset() }
    }

    weak var coordinator: EditorCoordinator?

    var gutterView: ElementGutterView?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
    }

    // MARK: - Insertion point height

    /// The natural glyph line height for `font` — the height AppKit uses for the
    /// caret on a line that contains text. Empty lines instead get the full
    /// line-fragment height, which includes the body paragraph style's inter-line
    /// `lineSpacing` (≈12pt at the default 1.7 line-height), so the empty-line
    /// caret stands taller than the text and visibly "shrinks" the moment you
    /// type. `clampedCaretRect` brings the empty-line caret back to this height.
    static func caretLineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender + abs(font.descender) + font.leading)
    }

    /// Clamp a caret rect's height to `lineHeight` (top-aligned) when it exceeds
    /// it. Shrinks only — never grows — so AppKit's invalidation of the original
    /// (taller) rect always covers what we draw and the blink leaves no artifact.
    static func clampedCaretRect(_ rect: NSRect, toLineHeight lineHeight: CGFloat) -> NSRect {
        guard rect.height > lineHeight + 0.5 else { return rect }
        var r = rect
        r.size.height = lineHeight
        return r
    }

    override func drawInsertionPoint(
        in rect: NSRect, color: NSColor, turnedOn flag: Bool
    ) {
        let font = (typingAttributes[.font] as? NSFont)
            ?? self.font
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        super.drawInsertionPoint(
            in: Self.clampedCaretRect(rect, toLineHeight: Self.caretLineHeight(for: font)),
            color: color, turnedOn: flag)
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
        // Tell THIS view's coordinator directly — one delegate hop. AppKit calls
        // this on a view's FIRST mount too (every EditorSurface build = every
        // piece flip), so a NotificationCenter broadcast (object: nil) fanned a
        // full whole-doc restyle out to every live coordinator, including leaked
        // ones from closed windows. The direct call touches only our own
        // coordinator, which further no-ops when the appearance is unchanged.
        coordinator?.effectiveAppearanceDidChange()
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

        // Re-frame the crafted-render overlays (mark layer covers the view; rail
        // sits in the right inset) on every resize, like the gutter above.
        coordinator?.layoutReviewOverlays(in: self)
        coordinator?.refreshReviewOverlays()
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
