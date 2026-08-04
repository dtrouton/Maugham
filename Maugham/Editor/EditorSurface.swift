import SwiftUI
import MaughamCore
import AppKit

/// SwiftUI host for an NSTextView-backed editor surface, driven by a
/// WritingMode (ProseMode in 1b).
/// Concern-grouped packaging of every `EditorSurface` input EXCEPT the `text`
/// Binding. This is pure parameter packaging (hardening Task 2): each field keeps
/// its original name, type, and wiring — nothing about the binding contract or the
/// applyExternalText / undo-coherent machinery changes shape. The fragile data-plane
/// seam (`@Binding var text`, tripwires 2/3/6/7) stays a direct member of
/// `EditorSurface`; this struct carries the ~40 closures/values that used to be a
/// call-site init wall, so the host builds it in one dedicated function.
struct EditorSurfaceConfiguration {
    /// How the surface first renders — seeds `makeCoordinator` and drives the
    /// column-width / gutter reconciliation in make/updateNSView. Runtime
    /// appearance changes flow via `control` (ADR 0017); these are seed values.
    struct Presentation {
        var theme: Theme
        var typography: TypographySettings
        var mode: any WritingMode
        var typewriterScroll: Bool
        var sentenceFocus: Bool
        var paragraphFocus: Bool
        var showElementGutter: Bool = true
    }

    /// Coordinator → host callbacks plus the first-attach cursor seed.
    struct EditingCallbacks {
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
        /// The consumer (ProjectWindow) does zero parsing — the page count comes
        /// from the keystroke's own parse. Omit at call sites without metrics.
        var onMetricsChanged: ((EditorMetrics) -> Void)? = nil
    }

    /// Resolvers that map paragraphs / locations / links for click routing,
    /// image paste, checkbox toggling, and script-scope stamping.
    struct ParagraphProviders {
        /// Optional resolver for wiki-link titles. When set, ProseMode underlines
        /// `[[Title]]` tokens whose title matches a manuscript document.
        var wikiLinkResolver: ((String) -> Bool)? = nil
        /// Optional id-returning resolver used by mouseDown click routing.
        /// Returns the doc id if the title resolves, nil otherwise.
        var wikiLinkClickResolver: ((String) -> String?)? = nil
        /// Origin project id (`ProjectIdentifier.id(for:)`) stamped onto the
        /// coordinator's `.maughamScriptDidUpdate` posts so receivers scope them
        /// to their own window (Channel A). Passed by manuscript hosts
        /// (EditorHost); nil for research notes, which never post scripts.
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
    }

    /// Review-mode annotation authoring plus the resolvers the crafted render
    /// uses to place marks. (Interactive card *actions* live in `annotationActions`.)
    struct ReviewProviders {
        /// Invoked when the reviewer commits a Comment/Query/Suggest annotation
        /// from the selection toolbar. The trailing `String?` is the replacement
        /// text (Suggest only; nil for Comment/Query). Wired to
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
    }

    /// Interactive margin-card action handlers (Part 1). Each maps an annotation
    /// id (+ payload for reply/edit) to the matching `Document` mutation. Threaded
    /// ONE-WAY; wired in make/update like `createAnnotationHandler`.
    struct AnnotationActions {
        var reviewAcceptHandler: ((String) async -> Void)? = nil
        var reviewRejectHandler: ((String) async -> Void)? = nil
        var reviewArchiveHandler: ((String) async -> Void)? = nil
        var reviewReplyHandler: ((String, String) async -> Void)? = nil
        var reviewEditHandler: ((String, String, String?) async -> Void)? = nil
        var reviewWithdrawHandler: ((String) async -> Void)? = nil
    }

    var presentation: Presentation
    /// Control-plane model (ADR 0017). The coordinator observes this directly;
    /// it is the channel for posture/appearance/annotation changes, replacing
    /// the per-prop pushes in updateNSView. Threaded ONE-WAY from the owning
    /// view (ProjectWindow via EditorHost for manuscripts; ResearchNoteEditor
    /// for research notes). Required — all production call sites must pass a
    /// real, populated model.
    var control: EditorControl
    var callbacks: EditingCallbacks = .init()
    var paragraphProviders: ParagraphProviders = .init()
    var reviewProviders: ReviewProviders = .init()
    var annotationActions: AnnotationActions = .init()
    /// One-shot pull from the Document: was the pending displayText change
    /// produced by an undo-registered mutation (accept/revert)? Consumed ONLY
    /// when a buffer replace actually happens. TRIPWIRE-SENSITIVE (applyExternalText /
    /// _undoCoherentApplyPending) — packaged here 1:1; its shape and its
    /// consume-on-every-pass semantics in `updateNSView` are unchanged. See the
    /// tripwire discussion in EditorCoordinator.applyExternalText.
    var consumeUndoCoherentApplyFlag: (() -> Bool)? = nil
    /// Whether this surface is a SECOND editor alive in a window that already
    /// has one. False for every surface there has ever been; M1A's statement
    /// panes are the first true, and they sit in the right column beside the
    /// manuscript editor in the centre.
    ///
    /// Two things follow, and both are defects if left undone — see
    /// `StatementEditorMountTests`:
    ///
    /// - **It answers no window commands.** Every observer
    ///   `EditorCoordinator`'s init registers — the ⌘⌥⇧R review membrane, scene /
    ///   find-match / paragraph / annotation navigation, the translation
    ///   membrane — is about the manuscript, and all of them are gated at the
    ///   one funnel they share (`EditorCoordinator.respondsToWindowCommands`).
    /// - **It owns its undo stack.** Every text view in a window shares the
    ///   window's `UndoManager`, and `EditorCoordinator.detach()` calls
    ///   `removeAllActions()` on the one it can reach — so a second editor being
    ///   taken down (a pane switch) wiped the manuscript's ⌘Z history. Measured,
    ///   not reasoned: the test asserting it fails without
    ///   `MaughamTextView.usesPrivateUndoManager`.
    ///
    /// Fixed for the lifetime of a mount, so it is applied in
    /// `makeCoordinator`/`makeNSView` and nowhere else.
    var isSecondEditorInItsWindow: Bool = false
}

struct EditorSurface: NSViewRepresentable {
    @Binding var text: String
    /// Everything else that used to be an init parameter, grouped by concern so
    /// the host call site is a handful of labelled groups instead of a ~40-line
    /// wall (built in a dedicated `makeSurfaceConfiguration`, ProjectWindow pattern).
    var configuration: EditorSurfaceConfiguration

    func makeCoordinator() -> EditorCoordinator {
        let p = configuration.presentation
        let cb = configuration.callbacks
        let pp = configuration.paragraphProviders
        let rp = configuration.reviewProviders
        let coordinator = EditorCoordinator(
            text: $text, mode: p.mode,
            theme: p.theme, typography: p.typography,
            typewriterScroll: p.typewriterScroll,
            sentenceFocus: p.sentenceFocus,
            paragraphFocus: p.paragraphFocus,
            wikiLinkResolver: pp.wikiLinkResolver)
        coordinator.initialCursorLocation = cb.initialCursorLocation
        coordinator.onCursorChanged = cb.onCursorChanged
        coordinator.onPostEditCursor = cb.onPostEditCursor
        coordinator.onElementChanged = cb.onElementChanged
        coordinator.onMetricsChanged = cb.onMetricsChanged
        coordinator.wikiLinkResolverForClick = pp.wikiLinkClickResolver
        coordinator.imagePasteHandler = pp.imagePasteHandler
        coordinator.paragraphRangeProvider = pp.paragraphRangeProvider
        coordinator.paragraphLocator = pp.paragraphLocator
        coordinator.checkboxToggleHandler = pp.checkboxToggleHandler
        coordinator.paragraphRangeAtLocation = pp.paragraphRangeAtLocation
        coordinator.createAnnotationHandler = rp.createAnnotationHandler
        coordinator.reviewParagraphTextProvider = rp.reviewParagraphTextProvider
        coordinator.reviewParagraphRangeProvider = rp.reviewParagraphRangeProvider
        coordinator.reviewAnnotationsProvider = rp.reviewAnnotationsProvider
        coordinator.scriptOriginProjectId = pp.scriptOriginProjectId
        coordinator.respondsToWindowCommands = !configuration.isSecondEditorInItsWindow
        assignReviewCardHandlers(to: coordinator)
        return coordinator
    }

    /// Thread the interactive-card handlers + local-author provider onto the
    /// coordinator. Shared by make/update so the wiring can't drift between them.
    private func assignReviewCardHandlers(to coordinator: EditorCoordinator) {
        let rp = configuration.reviewProviders
        let aa = configuration.annotationActions
        coordinator.reviewLocalAuthorName = rp.reviewLocalAuthorName
        coordinator.reviewAcceptHandler = aa.reviewAcceptHandler
        coordinator.reviewRejectHandler = aa.reviewRejectHandler
        coordinator.reviewArchiveHandler = aa.reviewArchiveHandler
        coordinator.reviewReplyHandler = aa.reviewReplyHandler
        coordinator.reviewEditHandler = aa.reviewEditHandler
        coordinator.reviewWithdrawHandler = aa.reviewWithdrawHandler
    }

    func makeNSView(context: Context) -> NSScrollView {
        let mode = configuration.presentation.mode
        let columnWidth = mode.textColumnWidth(
            typography: configuration.presentation.typography)

        let textView = MaughamTextView()
        // BEFORE anything that could register an undo action (or read the undo
        // manager): a second editor in the window keeps its own stack rather
        // than sharing — and clearing — the manuscript's. See
        // `EditorSurfaceConfiguration.isSecondEditorInItsWindow`.
        textView.usesPrivateUndoManager = configuration.isSecondEditorInItsWindow
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
        // Inline prediction rewrites text behind the scenes via marked-text
        // ranges. It races with our paragraph-anchor parsing and produces
        // "deleted text after cursor" symptoms when the user edits in a way
        // that contradicts a pending prediction — AppKit reverts the user's
        // edit, then we replay our shorter displayText through
        // applyExternalText and wipe the full content. Turn it off; focused-
        // writing users want their own words, not an OS-suggested completion.
        // (Was wrapped in `if #available(macOS 14.0, *)` until the deployment
        // target became macOS 26 on 2026-08-04 — the check was always true.)
        textView.inlinePredictionType = .no
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
        context.coordinator.observeControl(configuration.control)
        textView.coordinator = context.coordinator
        if mode is ScreenplayMode && configuration.presentation.showElementGutter {
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

    /// Reconcile the text buffer for one layout pass: flip the mutation membrane
    /// to reflect the current control value, then swap the buffer if it drifted.
    ///
    /// Extracted from `updateNSView` so the ORDERING is unit-testable without a
    /// synthesizable `NSViewRepresentable.Context` (the closest real-wiring test
    /// the entry/exit race admits — `TranslationReviewPostureTests` hand-pumps
    /// this against the real coordinator).
    ///
    /// Why the membrane flip lives HERE, strictly before the buffer swap: entering
    /// translation review changes `control.translationLanguage`, which drives TWO
    /// independent reactions with no ordering guarantee — (1) the coordinator's
    /// `withObservationTracking` re-arm (`applyControl → setTranslationReview`),
    /// which applies on a LATER main-actor turn, and (2) SwiftUI's
    /// `.onChange → translatedSurfaceText → render → updateNSView`, which swaps the
    /// translated text into the buffer via `applyExternalText`. If (2) wins,
    /// translated text is briefly EDITABLE (membrane still off) and a keystroke
    /// lands in the op log as manuscript text. Flipping the membrane synchronously
    /// here, in the same pass as the swap, closes that window; the async re-arm
    /// stays for genuinely out-of-band control changes (ADR 0017's purpose).
    ///
    /// `setTranslationReview` is a cheap no-op-guarded stored-property flip, so it
    /// is safe on every pass — this does NOT re-introduce the per-keystroke control
    /// bookkeeping ADR 0017 removed (that was the full appearance/posture/focus
    /// compare set; only the translation membrane flag is touched here).
    @MainActor
    static func reconcileTextBuffer(
        textView: NSTextView,
        coordinator: EditorCoordinator,
        translationLanguage: String?,
        text: String,
        undoCoherentApply: Bool
    ) {
        // Membrane BEFORE swap — see the doc-comment above.
        let translationMembraneChanged =
            coordinator.setTranslationReview(translationLanguage != nil)
        guard textView.string != text else { return }
        // The undo stack may be preserved ONLY for an ordinary in-place
        // accept/revert replace on the SOURCE manuscript. Any translation-review
        // buffer replace must drop it: the translated buffer is a different text,
        // and carrying the source's native undo actions across the swap re-opens
        // the ⌘Z EXC_BAD_ACCESS class (EditorUndoStackClearTests). That covers
        // two cases the membrane-changed check alone misses — not just the
        // entry/exit TRANSITION (`translationMembraneChanged`), but also an
        // IN-MODE translated-content refresh (already in translation review, the
        // membrane doesn't flip this pass) where an unrelated accept/revert
        // one-shot flag set in the same pass would otherwise retain a stale undo
        // action across the replace. Gating on `translationLanguage == nil` (the
        // editor is showing the source manuscript) forces the clear in both.
        let preserveUndoStack =
            undoCoherentApply && translationLanguage == nil && !translationMembraneChanged
        coordinator.applyExternalText(text, preserveUndoStack: preserveUndoStack)
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
        // Consume the Document's one-shot undo-coherent flag on EVERY pass, not
        // only when a replace occurs: the setter (accept/revert) changes
        // displayText in the same MainActor turn, so the consuming pass IS the
        // replacing pass in the legitimate flow — but a mutation that happens to
        // leave displayText byte-identical (no-op accept) must still discharge
        // the flag, or it would wrongly mark the NEXT unrelated replace as
        // undo-coherent and skip the stale-undo-stack clear (the ⌘Z crash class).
        let undoCoherentApply = configuration.consumeUndoCoherentApplyFlag?() ?? false
        Self.reconcileTextBuffer(
            textView: textView,
            coordinator: context.coordinator,
            translationLanguage: configuration.control.translationLanguage,
            text: text,
            undoCoherentApply: undoCoherentApply)
        let p = configuration.presentation
        let pp = configuration.paragraphProviders
        let rp = configuration.reviewProviders
        // Appearance itself flows via EditorControl (ADR 0017); only the
        // text-container width remains a layout concern handled here.
        let columnWidth = p.mode.textColumnWidth(typography: p.typography)
        if abs(textView.columnWidth - columnWidth) > 0.5 {
            textView.columnWidth = columnWidth
            textView.textContainer?.size = NSSize(
                width: columnWidth, height: .greatestFiniteMagnitude)
        }
        // Mode-change reconciliation for gutter.
        let needsGutter = (p.mode is ScreenplayMode) && p.showElementGutter
        if needsGutter && textView.gutterView == nil {
            textView.installGutter(coordinator: context.coordinator)
        } else if !needsGutter && textView.gutterView != nil {
            textView.removeGutter()
        }
        context.coordinator.imagePasteHandler = pp.imagePasteHandler
        context.coordinator.paragraphRangeProvider = pp.paragraphRangeProvider
        context.coordinator.paragraphLocator = pp.paragraphLocator
        context.coordinator.checkboxToggleHandler = pp.checkboxToggleHandler
        context.coordinator.paragraphRangeAtLocation = pp.paragraphRangeAtLocation
        context.coordinator.createAnnotationHandler = rp.createAnnotationHandler
        // Crafted-render providers — kept current so the model-driven recompute
        // (via `applyControl` → `setReviewAnnotations`) and the on-entry provider
        // pull both read fresh resolvers. The open annotation set itself no longer
        // pushes from here; it flows through the control model (ADR 0017).
        context.coordinator.reviewParagraphTextProvider = rp.reviewParagraphTextProvider
        context.coordinator.reviewParagraphRangeProvider = rp.reviewParagraphRangeProvider
        // Pull-on-entry provider: the coordinator invokes it on review entry to
        // resolve the real annotation set synchronously (first-toggle marks fix).
        context.coordinator.reviewAnnotationsProvider = rp.reviewAnnotationsProvider
        context.coordinator.scriptOriginProjectId = pp.scriptOriginProjectId
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

    /// Take this view's undo actions off the window's shared `UndoManager` and
    /// onto one of its own. Set once, in `EditorSurface.makeNSView`, before any
    /// edit can register — see
    /// `EditorSurfaceConfiguration.isSecondEditorInItsWindow` for why a second
    /// editor in one window must not share.
    var usesPrivateUndoManager = false

    private lazy var privateUndoManager = UndoManager()

    /// `NSTextView` registers its typing undo with `self.undoManager`, and the
    /// responder chain reads the first responder's — so overriding here covers
    /// both registration and ⌘Z, and leaves the primary editor on exactly the
    /// manager it has always used.
    override var undoManager: UndoManager? {
        usesPrivateUndoManager ? privateUndoManager : super.undoManager
    }

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
           let id = resolver(title),
           // The coordinator's origin project id is wired for ALL manuscript
           // modes (EditorHost → EditorSurface, not screenplay-only), and
           // wiki links only exist in manuscripts, so it's present here.
           // Scope the navigation to this project (ADR 0021).
           let projectId = coordinator?.scriptOriginProjectId {
            MaughamEvent.post(
                .maughamNavigateToDocument,
                to: .project(id: projectId),
                payload: ["id": id])
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

    /// **A surface with an image-paste handler OWNS pasteboard images**, and
    /// falls through to `super` only when there is no handler or no image.
    ///
    /// The `let ref = handler(image)` used to be part of the same condition, so a
    /// handler returning nil fell through to `super.paste` — which, because
    /// `readablePasteboardTypes` above advertises image types whenever a handler
    /// is set, accepts the image and inserts an **attachment character**. Measured
    /// 2026-08-01 on the visual-language pane: pasting a picture into a statement
    /// that had no file yet put `![](./visual-language_assets/…png)\n\n￼` into the
    /// writer's op log — the ref from the handler's own asynchronous path, and a
    /// `U+FFFC` from `super`. A research note whose paste failed to encode got the
    /// same character with no ref at all.
    ///
    /// So nil now means *"handled, with nothing to insert here"* rather than
    /// *"not mine"* — the only two handlers are `ResearchNoteEditor`'s, where nil
    /// is an encoding failure it has already logged, and
    /// `StatementEditorHost`'s, where nil means the ref is arriving by another
    /// route. Neither wants `super` to have a go. What is given up is `super`'s
    /// handling of a mixed pasteboard's TEXT when an image is also present, which
    /// on these two surfaces was never the intent.
    override func paste(_ sender: Any?) {
        if let handler = coordinator?.imagePasteHandler,
           NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil),
           let image = NSImage(pasteboard: .general) {
            if let ref = handler(image) {
                insertText(ref, replacementRange: selectedRange())
            }
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Window close: SwiftUI never calls `EditorSurface.dismantleNSView` for
        // a closed `WindowGroup` scene — `GraphHost.sharedGraph` retains the
        // dead scene's view graph indefinitely (see the scene-storage spike
        // note, "Retain-root trace"). So the coordinator's `detach()`, which
        // rides `dismantleNSView` on IN-window teardowns (the `.id(path)` piece
        // flip), never fires on ⌘W. Catch that path here: when the view is
        // leaving its window, break the coordinator↔text-view graph and cancel
        // its async work so a coordinator SwiftUI has not yet released holds
        // nothing heavy and does no work. `detach()` is idempotent, so the flip
        // path (dismantle + this) is safe.
        if newWindow == nil {
            coordinator?.detach()
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

        // Re-frame the translation-badge overlay (covers the view; dots in the
        // left inset) on resize too (Task 12).
        coordinator?.layoutTranslationBadgeOverlay(in: self)
        coordinator?.translationBadgeOverlay?.needsDisplay = true
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
