import Foundation
import MaughamCore
import AppKit
import SwiftUI

/// NSTextViewDelegate that mediates between SwiftUI's @Binding and NSTextView.
/// Handles the isApplyingExternalUpdate guard so that external state changes
/// don't clobber the user's editing context.
@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate {
    private var binding: Binding<String>
    let mode: any WritingMode
    var theme: Theme
    var typography: TypographySettings
    private(set) var typewriterScroll: Bool
    var sentenceFocus: Bool
    var paragraphFocus: Bool

    private var isApplyingExternalUpdate = false
    weak var textView: NSTextView?

    /// Review posture (WF1): when true the manuscript text is read-only —
    /// `textView(_:shouldChangeTextIn:)` rejects every mutation (typing, paste,
    /// delete) via `EditorEditPolicy`, and focus-dim + typewriter centering are
    /// suppressed. Selection, scrolling, and copy are unaffected (they don't go
    /// through shouldChangeTextIn). Plain stored property, no observers, so it
    /// can't drive a SwiftUI↔AppKit loop (tripwire 2). Threaded ONE-WAY down
    /// from ProjectWindow → EditorHost → EditorSurface; nothing reads it back.
    /// Use `setReviewMode(_:)` to flip it so the posture re-applies immediately.
    private(set) var isReviewMode = false

    /// Hard editing lock (WF1 iCloud role): when true the manuscript text is
    /// read-only because the current user is NOT an author of it (an iCloud
    /// reviewer, or the still-resolving `.unknown` role). Distinct from
    /// `isReviewMode`: that is a soft, toggleable render posture an author opts
    /// into; this is the floor that the membrane ANDs in so a reviewer's ⌘⌥⇧R can
    /// flip the review render but can NEVER unlock text mutation. Threaded
    /// ONE-WAY from ProjectWindow → EditorHost → EditorSurface (tripwires 2 & 6);
    /// nothing reads it back. Use `setLockEditing(_:)` to flip it.
    private(set) var lockEditing = false

    /// Translation-review posture (Task 11): when true the editor is displaying a
    /// DERIVED translated surface (`translatedText ?? sourceText`, joined) instead
    /// of the source manuscript, so the buffer is read-only — `shouldChangeTextIn`
    /// rejects every mutation via `EditorEditPolicy`, guaranteeing the translated
    /// view produces zero ops. Independent of `isReviewMode`/`lockEditing`: a
    /// reader can inspect a translation of a manuscript they authored. Plain
    /// stored property, no observers (tripwire 2), threaded ONE-WAY from
    /// ProjectWindow → EditorHost → EditorSurface; nothing reads it back. Use
    /// `setTranslationReview(_:)` to flip it so the membrane sees it immediately.
    private(set) var isTranslationReview = false

    /// Weak handle to the floating selection toolbar overlay so the
    /// selection-change callback can position/show/hide it. Lives in the scroll
    /// view's superview (see EditorSurface), NOT a subview of the clipped
    /// content view, so it can float above the text near the selection. Only
    /// shown while `isReviewMode` is on.
    weak var selectionToolbar: SelectionToolbarView?

    /// Cursor location to restore after the next attach. Set by EditorSurface
    /// when the user revisits a previously-open document.
    var initialCursorLocation: Int?

    /// Fired on every selection change with the new caret location, so the
    /// host can persist per-document cursor positions.
    var onCursorChanged: ((Int) -> Void)?

    /// Fired inside `textDidChange` just before the binding setter writes
    /// the new text. Delivers the post-edit caret position so that
    /// Document's V2 task-anchor alignment can see where the cursor ended
    /// up after the keystroke that produced this change. nil when not
    /// wired (legacy / test surfaces — alignment degrades to per-paragraph
    /// per spec §2.4.3).
    var onPostEditCursor: ((Int) -> Void)?

    /// Fired when the cursor's screenplay element changes. Delivers the gutter
    /// abbreviation ("CHAR", "SCENE", "DLG", etc.) or nil when no script is
    /// parsed (prose mode) or the cursor isn't on a classified line. Mirrors
    /// the same delivery points as onCursorChanged: selection change and after
    /// every retokenize (text edits can change the element under the cursor
    /// without moving the selection).
    var onElementChanged: ((String?) -> Void)?

    /// Fired with precomputed `EditorMetrics` on the same debounced trailing
    /// edge as the script broadcast (typing path), and immediately on attach /
    /// applyExternalText / theme. Consumers (ProjectWindow inspector + goal
    /// indicator) do ZERO parsing — the page count comes from the keystroke's
    /// own parse (`lastParsedScript`), the word count from one whitespace split
    /// of the already-nativized text (spec §7). Supersedes the EditorHost
    /// metrics mirror, which this replaces.
    var onMetricsChanged: ((EditorMetrics) -> Void)?

    /// Optional resolver for wiki-link titles. When set, ProseMode underlines
    /// `[[Title]]` tokens whose title resolves to a manuscript document.
    var wikiLinkResolver: ((String) -> Bool)?

    /// Id-returning resolver used by mouseDown click routing. Returns
    /// the doc id if the title resolves, nil otherwise.
    var wikiLinkResolverForClick: ((String) -> String?)?

    /// Called when the text view receives a paste with image content on the
    /// pasteboard. The handler saves the image and returns the Markdown
    /// reference string to insert at the cursor, or nil if the paste should
    /// fall through to standard NSTextView behavior. Nil for non-research-note
    /// editing (manuscript documents, screenplays — standard paste applies).
    var imagePasteHandler: ((NSImage) -> String?)?

    /// Most recent token list, captured each time we retokenize. Used by
    /// click routing to look up wiki-link ranges hit-tested by mouseDown.
    var lastTokens: [Token] = []

    /// Most recent FountainScript from ScreenplayMode parsing. nil for prose
    /// modes. Updated each time retokenizeAndStyle runs. Source for
    /// the element gutter (3b).
    var lastParsedScript: FountainScript?

    /// Most recent cycle target on the current blank line. Cleared when:
    /// - cursor moves to a different line
    /// - any non-Tab edit triggers textDidChange
    /// - the active line gains content via the cycle's mutator
    /// Used so that subsequent Tab presses on the same blank line cycle
    /// from the prior target rather than re-computing startingElement.
    var lastCycleTarget: ScreenplayElement?

    /// Active line's range at the moment lastCycleTarget was set; used to
    /// detect cursor moves to a different line.
    var lastCycleTargetLineRange: NSRange?

    /// Set to true while cycle(in:direction:) is mutating storage so that
    /// textDidChange knows to leave lastCycleTarget alone.
    var isApplyingTabCycle = false

    /// Trailing-edge debounce for the `.maughamScriptDidUpdate` post on the
    /// typing fast path. Posting the whole parsed `FountainScript` on every
    /// keystroke drove deep SwiftUI `Equatable` deep-compares of the entire
    /// script (and per-row O(document) walks in the scene navigator) — the
    /// 2026-06-10 live profile's dominant Scenes-sidebar cost. We coalesce the
    /// outbound notification to a ~350ms trailing edge while typing; whole-doc
    /// callers (`attach`, `applyExternalText`, theme/typography/focus changes)
    /// still post immediately. `lastParsedScript`/`lastTokens` are updated per
    /// keystroke exactly as before — ONLY the notification is debounced.
    /// Mirrored by `metricsNotifyTask` (the metrics post on the same edge).
    var scriptUpdateNotifyTask: Task<Void, Never>?

    /// Trailing-edge debounce for `onMetricsChanged` on the typing fast path —
    /// the metrics mirror that used to live on `EditorHost`. Coalesced to the
    /// same ~350ms trailing edge as the script broadcast so the footer/inspector
    /// stay live while typing pays only one whitespace split per burst (the page
    /// count is free — it reads the keystroke's own `lastParsedScript`). Whole-
    /// doc callers (attach, applyExternalText, theme) deliver immediately.
    var metricsNotifyTask: Task<Void, Never>?

    /// Trailing-edge debounce for the VISUAL syntax repaint on the typing fast
    /// path (the "settle" behaviour). While typing, the compute stays live
    /// (tokenize, metrics, element, cursor, scroll) but the actual
    /// `applyTypography` paint + focus-dim are deferred to the trailing edge of
    /// the typing burst. This stops transient invalid syntax states (e.g.
    /// editing at the end of an emphasis run momentarily makes `*italic *`,
    /// which is not valid CommonMark) from flipping the styling on every
    /// keystroke — the styling re-renders once, at rest, when typing pauses.
    /// Whole-doc callers (`attach`, `applyExternalText`, theme/typography/focus
    /// changes) paint synchronously and are unaffected. Cancelled in `deinit`,
    /// `attach`, and `applyExternalText` so a stale paint never lands on a torn-
    /// down or replaced document.
    var deferredRestyleTask: Task<Void, Never>?

    /// Settle delay (ms) for `deferredRestyleTask`. ~300ms matches the existing
    /// script/metrics debounce and reads as "styling is secondary to the text".
    /// Overridable so tests can shorten it.
    var restyleSettleDelayMs: Int = 300

    /// The document text from BEFORE the current typing burst began. Captured on
    /// the first edit of a burst (when no settle is pending) and character-diffed
    /// against the post-burst text at settle time so the settle paint restyles
    /// ONLY the paragraph(s) the burst changed — never the whole document. A
    /// whole-doc `setAttributes` invalidates all layout and snaps the scroll
    /// origin toward the top, and the capture/restore that papers over that
    /// mis-lands on the last line; windowing the settle avoids the relayout
    /// entirely. A character diff (not a token diff) is used so it works for
    /// plain prose, which produces no syntax tokens to diff. nil between bursts.
    var burstBaselineText: String?

    /// The document text as of the LAST restyle paint, on the live (non-deferred)
    /// typing path used by element-classification-heavy modes (screenplay, where
    /// `mode.defersRestyleWhileTyping == false`). Each live keystroke character-
    /// diffs the new text against this to window the restyle to just the changed
    /// paragraph(s) — exactly like the deferred settle paint, but applied
    /// synchronously per keystroke instead of once at burst end. Refreshed on
    /// every whole-doc paint (attach / applyExternalText / theme) so the next
    /// live keystroke diffs against the correct baseline. nil until the first
    /// whole-doc paint of a freshly-attached document. Unused on the deferred
    /// (prose) path. See `paintLiveWindowed` and Editor AREA tripwire 9.
    var liveRestyleBaseline: String?

    /// Observer token for `maughamNavigateToScene` notifications.
    private var navigateObserver: NSObjectProtocol?

    /// Observer token for `maughamFindMatchSelected` notifications.
    private var findMatchObserver: NSObjectProtocol?

    /// Observer token for `maughamNavigateToParagraph` notifications, used
    /// to scroll the textView to the paragraph an annotation is anchored
    /// to when the user clicks an annotation row.
    private var paragraphNavigateObserver: NSObjectProtocol?

    /// Observer token for `maughamNavigateToAnnotation` — span-precise jump.
    /// Looks the annotation id up in `resolvedReviewMarks`: an `absoluteRange`
    /// selects the exact span; otherwise it falls back to the paragraph (the
    /// legacy scroll-to-paragraph behaviour).
    private var annotationNavigateObserver: NSObjectProtocol?

    /// Observer token for `maughamToggleReviewMode` (⌘⌥⇧R). Flips the membrane
    /// SYNCHRONOUSLY in the key window's coordinator so `isReviewMode` is correct
    /// before the next key event — closing the race where a fast Enter pressed
    /// right after ⌘⌥⇧R slipped a newline through `shouldChangeTextIn` before the
    /// SwiftUI render round-trip pushed the new posture (Bug B). `ProjectWindow`
    /// still toggles `isReviewModeOn` on the SAME notification (source of truth
    /// for the indicator + annotation derive + persistence); the model-driven
    /// `applyControl → setReviewMode` (observed via `withObservationTracking`) is
    /// the no-op-guarded reconciler the two paths converge through (ADR 0017).
    /// Both toggle the same boolean from the same value, so they can't diverge;
    /// the reconciler re-converges if state ever drifts.
    private var reviewToggleObserver: NSObjectProtocol?

    /// Observer tokens for translation-review entry/exit (Task 13). Same
    /// rationale as `reviewToggleObserver`: flip the read-only membrane
    /// SYNCHRONOUSLY in the key window's coordinator so the very next keystroke
    /// already sees the toggled posture — the `control.translationLanguage`
    /// mirror lands a frame later. `ProjectWindow`'s `TranslationReviewModifier`
    /// still owns the language + the surface swap on the SAME posts; the
    /// model-driven `applyControl → setTranslationReview` is the no-op-guarded
    /// reconciler both paths converge through (ADR 0017), so they can't diverge.
    private var translationEnterObserver: NSObjectProtocol?
    private var translationExitObserver: NSObjectProtocol?

    /// The control-plane model (ADR 0017). Set once at `attach` via
    /// `observeControl`; the coordinator READS it (never writes). nil until
    /// `observeControl` runs.
    private var control: EditorControl?

    /// Closure that maps a paragraph_id to its NSRange in textView.string.
    /// Set by EditorSurface.updateNSView so the coordinator can resolve
    /// ranges against the live Document's `displayRange(forParagraphId:)`.
    var paragraphRangeProvider: ((String) -> NSRange?)?

    /// Resolves a doc-wide UTF-16 location to the containing paragraph_id
    /// and the offset (in the same UTF-16 space) within that paragraph's
    /// text. Wired by EditorHost from `Document.paragraphId(at:)` +
    /// `displayRange(forParagraphId:)`. Used by the checkbox click path.
    var paragraphLocator: ((Int) -> (paragraphId: String, offsetWithinParagraph: Int)?)?

    /// Closure invoked when the user clicks a checkbox glyph — either the
    /// 3-char markdown `- [ ]` / `- [x]` bracket or the 5-char Fountain
    /// `[[todo:]]` / `[[done:]]` prefix. Delivers the paragraph id, the
    /// UTF-16 offset within that paragraph's text, and the marker kind
    /// (so the host can dispatch to `flipBracket` for `.markdown` or
    /// `flipTodoDone` for `.fountain`). The host wires this to
    /// `Document.setParagraph(id:text:)`. Routing the flip through
    /// `setParagraph` keeps the mutation on the standard `.typingBurst`
    /// path and out of the cloud-conflict-only `applyExternalText` channel
    /// (see tripwire #7 / area #2).
    var checkboxToggleHandler: ((String, Int, MaughamCheckboxKind) -> Void)?

    /// Maps a doc-wide UTF-16 location into the containing paragraph's id and
    /// its UTF-16 NSRange in `displayText`. Wired by EditorHost from
    /// `Document.paragraphRange(at:)`. Used by the review toolbar to translate
    /// an absolute selection into a paragraph-relative span anchor.
    var paragraphRangeAtLocation: ((Int) -> (id: String, range: NSRange)?)?

    /// Invoked when the reviewer completes a Comment/Query/Suggest annotation
    /// from the selection toolbar's inline composer. Delivers the annotation
    /// kind, the anchored paragraph id, the sub-paragraph span, the typed body,
    /// and (Suggest only) the replacement text. EditorHost wires this to
    /// `Document.addReviewerAnnotation(...)`. Routing is one-way (no write-back
    /// into a binding) — annotation creation is an op-log append, not a text
    /// mutation, so tripwires 6/7 don't apply.
    /// Async so the commit flow can AWAIT the op-log append before re-pulling the
    /// annotation set — that's what makes a just-created annotation's mark + rail
    /// card appear immediately, without the reviewer toggling review off/on. The
    /// model-driven `setReviewAnnotations` apply (EditorHost mirrors the Document's
    /// open set into `control.reviewAnnotations` off `annotationsVersion`) remains
    /// the reconciler for annotations changed elsewhere; the await + provider-pull
    /// is the deterministic path for the LOCAL create.
    var createAnnotationHandler: ((AnnotationKind, String, SpanAnchor, String, String?) async -> Void)?

    /// The inline composer (a small NSTextField) shown when the reviewer clicks
    /// Comment/Query. Minimal by design — Task 5 restyles it into a margin slip.
    weak var annotationComposer: ReviewAnnotationComposerView?

    /// Open annotations to render in review mode. Applied ONE-WAY via the control
    /// model (ADR 0017): EditorHost mirrors the host `Document`'s open set into
    /// `control.reviewAnnotations`, which `applyControl` → `setReviewAnnotations`
    /// reconciles here. Versioned so the recompute only fires when the set actually
    /// changes. Nothing reads this back into a binding (tripwires 2 & 6).
    var reviewAnnotations: [Annotation] = []
    /// Resolves a paragraphId to its DISPLAY text — used to convert an
    /// annotation's grapheme-offset `resolvedSpanRange` to UTF-16 within the
    /// paragraph. Wired by EditorHost from `Document.paragraph(id:)` stripped.
    var reviewParagraphTextProvider: ((String) -> String?)?
    /// Resolves a paragraphId to its UTF-16 NSRange in the full display string.
    /// Wired by EditorHost from `Document.displayRange(forParagraphId:)`.
    var reviewParagraphRangeProvider: ((String) -> NSRange?)?
    /// Pulls the CURRENT open-annotation set on demand. Wired by EditorHost from
    /// `Document.annotations(filter: .open)` — NOT gated on isReviewMode (it's
    /// only CALLED on review entry, so it never re-derives during authoring).
    /// Used by `setReviewMode(_:)` so entering review resolves marks
    /// synchronously from the real set instead of waiting for the lagged
    /// `setReviewAnnotations` push (which, on the first toggle after launch,
    /// arrives only on the next SwiftUI render). One-way; nothing reads it back
    /// (no tripwire-2 loop).
    var reviewAnnotationsProvider: (() -> [Annotation])?
    /// The local reviewer's display name (`UserPreferences.collaboratorDisplayName`),
    /// pulled on demand so ownership (`AnnotationOwnership.isOwn`) can gate the
    /// Edit / Delete affordances on the interactive margin card. Wired by
    /// EditorHost; one-way (read-only).
    var reviewLocalAuthorName: (() -> String)?
    /// Cached, resolved-to-absolute marks. Recomputed when the annotation set or
    /// the text changes — never per draw (tripwire 4). The overlay views read
    /// this directly.
    var resolvedReviewMarks: [ResolvedReviewMark] = []
    let reviewPalette = ReviewPalette()

    /// Inline-mark overlay + right-margin rail, installed lazily on the text
    /// view (like the gutter) and shown only in review mode.
    weak var markRenderer: AnnotationMarkRenderer?
    weak var marginRail: ReviewMarginRailView?

    /// Staleness-badge overlay for translation review (Task 12): margin dots in
    /// the LEFT inset — amber (stale) / gray-hollow (missing). Installed lazily
    /// on the text view (like the review overlays) and shown only in translation
    /// review. See `EditorCoordinator+TranslationBadges.swift`.
    weak var translationBadgeOverlay: TranslationBadgeOverlayView?
    /// The current per-paragraph badge resolution (¶ → UTF-16 range + status) in
    /// the rendered translated surface. Recomputed only when the pushed model
    /// changes — never per draw (tripwire 4). The overlay reads this directly.
    var resolvedTranslationBadges: [TranslationBadgeLayout.BadgeRange] = []
    /// Last translation-badge model applied, for the per-`applyControl` no-op
    /// guard (the model is pushed on every observation pass, like
    /// `reviewAnnotations`). Nil until the first push.
    var appliedTranslationBadgeModel: EditorControl.TranslationBadgeModel?

    /// The annotation id whose margin card is currently selected (click-to-reveal
    /// actions). nil = nothing selected. Read by `ReviewMarginRailView` to
    /// emphasise the selected card; drives the inline actions row. Lives here (not
    /// on the rail) so a redraw / recompute can reconcile it.
    var selectedReviewCardId: String?

    /// The annotation id of a just-STETTED note whose margin card is holding the
    /// brief "stet" acknowledgement before it resolves out of the open set. While
    /// set, `ReviewMarginRailView.drawCard` paints the STET treatment on that card
    /// and the mark is deliberately NOT refreshed away. Mirrors the
    /// AnnotationsPane `stetFlourishIds` dwell so the gesture reads in both
    /// surfaces. (M3 P2 moved it off reject, where the word was a lie: a rejected
    /// note is exactly the one that did NOT stand.)
    var stetReviewCardId: String?

    /// Handlers for the interactive margin-card actions, threaded ONE-WAY from
    /// EditorHost (like `createAnnotationHandler`). Each is async so the card can
    /// await the op-log append before refreshing marks. `reply` carries the reply
    /// text; `edit` carries the new body + (suggestion-only) replacement. All
    /// stamp the local author name on the host side where needed. Nothing reads a
    /// binding back (tripwires 6/7) — these are op-log appends, not text writes.
    var reviewAcceptHandler: ((String) async -> Void)?
    var reviewRejectHandler: ((String) async -> Void)?
    var reviewStetHandler: ((String) async -> Void)?
    var reviewArchiveHandler: ((String) async -> Void)?
    var reviewReplyHandler: ((String, String) async -> Void)?
    var reviewEditHandler: ((String, String, String?) async -> Void)?
    var reviewWithdrawHandler: ((String) async -> Void)?

    /// Number of times applyExternalText has been called. Internal so
    /// @testable importers (EditorIntegrationHarness) can assert invariants
    /// about typing not triggering external-text replacement. Production
    /// never reads this.
    internal private(set) var applyExternalTextCallCount: Int = 0

    /// Test seam: NSTextView.undoManager is nil without a window; harness
    /// tests inject a manager here. Production always resolves through the
    /// text view (the window's undo manager — the one ⌘Z reaches).
    var undoManagerOverrideForTesting: UndoManager?

    /// Number of times `applyControl` has run. Internal so @testable importers
    /// can assert the control-plane observation is narrowed to `EditorControl`
    /// properties (ADR 0017 D1) — a mutation of a value `applyControl` merely
    /// reads through (Document / UserPreferences) must not increment this.
    /// Production never reads it.
    internal private(set) var applyControlCount: Int = 0

    /// Number of times `applyAppearance` has run (i.e. a whole-doc restyle for a
    /// theme/appearance reason). Internal so @testable importers can assert the
    /// appearance hook is a DIRECT per-view call that no-ops on an unchanged
    /// effective appearance — the piece-flip-stall regression net. Production
    /// never reads it.
    internal var applyAppearanceCount: Int = 0

    /// The effective appearance (NSAppearance.name) as of the last handled
    /// `effectiveAppearanceDidChange()`. AppKit calls
    /// `viewDidChangeEffectiveAppearance` on a view's FIRST mount, not only on an
    /// OS light/dark flip, so this lets the handler no-op the mount-time call when
    /// the appearance hasn't actually changed. `nil` until the first sync.
    var lastEffectiveAppearanceName: NSAppearance.Name?

    /// Set by `detach()` (called from `EditorSurface.dismantleNSView` on
    /// teardown). Once detached the coordinator drops its text-view handle and
    /// refuses restyle work, so a coordinator SwiftUI has not yet released holds
    /// no heavy text-view graph and does nothing on any residual callback.
    private(set) var isDetached = false

    /// Whether this coordinator answers the window's MANUSCRIPT commands —
    /// **every observer this class's `init` registers**, which is what makes the
    /// gating complete rather than a list someone remembered: they all resolve
    /// their scope through `receiverContext(.keyWindow)`, which is where this is
    /// read. Today that is `maughamNavigateToScene`, `maughamFindMatchSelected`,
    /// `maughamNavigateToParagraph`, `maughamNavigateToAnnotation`,
    /// `maughamToggleReviewMode`, `maughamEnterTranslationReview` and
    /// `maughamExitTranslationReview` — count the `MaughamEvent.observe` calls
    /// rather than this sentence.
    ///
    /// True for every editor that IS the window's manuscript surface, which is
    /// every one there has ever been. M1A's statement panes are the first case
    /// of a SECOND `EditorSurface` alive in the same window at the same time,
    /// and every one of those commands is about the document in the centre
    /// column: without this the intent pane flips into review chrome on ⌘⌥⇧R,
    /// moves its caret when the writer clicks a scene in the navigator, and
    /// goes read-only when the manuscript enters translation review.
    var respondsToWindowCommands: Bool = true

    /// Origin project id (`ProjectIdentifier.id(for:)`) stamped onto every
    /// `.maughamScriptDidUpdate` post so receivers can scope it to their own
    /// window (Channel A). Set by `EditorSurface` from `EditorHost`; nil for
    /// non-manuscript surfaces (research notes), which never post scripts.
    var scriptOriginProjectId: String?

    init(text: Binding<String>,
         mode: any WritingMode,
         theme: Theme,
         typography: TypographySettings,
         typewriterScroll: Bool,
         sentenceFocus: Bool,
         paragraphFocus: Bool,
         wikiLinkResolver: ((String) -> Bool)? = nil) {
        self.binding = text
        self.mode = mode
        self.theme = theme
        self.typography = typography
        self.typewriterScroll = typewriterScroll
        self.sentenceFocus = sentenceFocus
        self.paragraphFocus = paragraphFocus
        self.wikiLinkResolver = wikiLinkResolver
        super.init()
        #if MAUGHAM_DEV_BUILD
        // Weakly register with the scene-storage-spike leak probe (ADR 0021).
        // Dev-only; absent from stable. See CoordinatorLeakProbe.
        CoordinatorLeakProbe.register(self)
        #endif
        // NotificationCenter posts these on `.main` so we're on the main
        // thread when the closures fire, but the closure types aren't
        // @MainActor-annotated. `MainActor.assumeIsolated` bridges the gap
        // without an extra Task hop (and asserts in debug if we're wrong
        // about being on the main thread).
        navigateObserver = MaughamEvent.observe(
            .maughamNavigateToScene,
            context: { [weak self] in self?.receiverContext(.keyWindow) }
        ) { [weak self] note in
            guard let self,
                  let location = note.userInfo?["lineLocation"] as? Int,
                  let textView = self.textView else { return }
            self.navigateToLine(at: location, in: textView)
        }
        findMatchObserver = MaughamEvent.observe(
            .maughamFindMatchSelected,
            context: { [weak self] in self?.receiverContext(.keyWindow) }
        ) { [weak self] note in
            guard let self,
                  let match = note.userInfo?["match"] as? SearchMatch,
                  let textView = self.textView else { return }

            // Defer to allow the document load to complete first.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                let range = match.charRangeInDocument
                guard let storage = textView.textStorage,
                      range.location + range.length <= storage.length else { return }
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
            }
        }
        paragraphNavigateObserver = MaughamEvent.observe(
            .maughamNavigateToParagraph,
            context: { [weak self] in self?.receiverContext(.keyWindow) }
        ) { [weak self] note in
            guard let self,
                  let pid = note.userInfo?["paragraph_id"] as? String,
                  let textView = self.textView,
                  let provider = self.paragraphRangeProvider,
                  let range = provider(pid) else { return }
            let length = (textView.string as NSString).length
            guard range.location >= 0,
                  range.location + range.length <= length else { return }
            // Position a cursor (length 0) at paragraph start rather
            // than selecting the whole paragraph. Selecting the entire
            // range was disorienting when navigating from the Tasks
            // pane — the writer's "jump to this task" became "select
            // the whole containing paragraph including unrelated
            // text." A future refinement could thread an
            // intra-paragraph offset through the notification to land
            // exactly on the task line; for now, paragraph start is
            // close enough and avoids the surprising selection.
            let cursor = NSRange(location: range.location, length: 0)
            textView.setSelectedRange(cursor)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
        }
        // Key-window scoped via the helper (ADR 0021) — the former inline
        // `textView.window?.isKeyWindow` guard is deleted; the `.keyWindow`
        // context owns it now.
        annotationNavigateObserver = MaughamEvent.observe(
            .maughamNavigateToAnnotation,
            context: { [weak self] in self?.receiverContext(.keyWindow) }
        ) { [weak self] note in
            guard let self,
                  let annId = note.userInfo?["annotation_id"] as? String,
                  let textView = self.textView else { return }
            let pid = note.userInfo?["paragraph_id"] as? String
            self.navigateToAnnotation(id: annId, fallbackParagraphId: pid, in: textView)
        }
        // This NC receiver exists deliberately (Editor AREA.md, Bug B): ⌘⌥⇧R
        // flips the review membrane SYNCHRONOUSLY on the coordinator so the very
        // next keystroke already sees the toggled value — a `control.*` mirror
        // would land a frame later. Key-window scoping is now the helper's
        // `.keyWindow` context (ADR 0021); the former inline `isKeyWindow` guard
        // is deleted (it, and FocusPostureModifier, both act only when key).
        reviewToggleObserver = MaughamEvent.observe(
            .maughamToggleReviewMode,
            context: { [weak self] in self?.receiverContext(.keyWindow) }
        ) { [weak self] _ in
            guard let self else { return }
            self.setReviewMode(!self.isReviewMode)
        }
        // Translation review (Task 13): flip the read-only membrane
        // synchronously on the key window's coordinator, exactly as ⌘⌥⇧R does
        // above. Language + surface swap stay EditorHost's; this only governs
        // the membrane so the next keystroke is already blocked (or unblocked).
        translationEnterObserver = MaughamEvent.observe(
            .maughamEnterTranslationReview,
            context: { [weak self] in self?.receiverContext(.keyWindow) }
        ) { [weak self] _ in
            self?.setTranslationReview(true)
        }
        translationExitObserver = MaughamEvent.observe(
            .maughamExitTranslationReview,
            context: { [weak self] in self?.receiverContext(.keyWindow) }
        ) { [weak self] _ in
            self?.setTranslationReview(false)
        }
        // The former annotation-set-changed notification observer is gone (ADR
        // 0017): an AnnotationsPane edit/withdraw bumps `annotationsVersion` on the shared
        // Document, which EditorHost mirrors into `control.reviewAnnotations` →
        // `applyControl` → `setReviewAnnotations`, recomputing the crafted marks
        // without a notification. The local in-editor create flow still uses
        // `refreshReviewMarksFromProvider` (awaited, deterministic).
    }

    deinit {
        scriptUpdateNotifyTask?.cancel()
        metricsNotifyTask?.cancel()
        deferredRestyleTask?.cancel()
        if let token = navigateObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = findMatchObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = paragraphNavigateObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = annotationNavigateObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = reviewToggleObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = translationEnterObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = translationExitObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Set the text view from outside (called by EditorSurface.makeNSView).
    func attach(to textView: NSTextView) {
        isDetached = false
        self.textView = textView
        // Wire the review selection toolbar's button actions to the annotation
        // flow (Suggest is Task 4; for now it falls through to nothing).
        selectionToolbar?.onAction = { [weak self] kind in
            self?.handleToolbarAction(kind)
        }
        // Drop any debounced script post still pending from a prior text so a
        // stale script can't land on the freshly-attached doc's navigator.
        scriptUpdateNotifyTask?.cancel()
        scriptUpdateNotifyTask = nil
        // Same for a pending metrics mirror — the immediate post below carries
        // the freshly-attached doc's metrics; a stale debounced one must not
        // land after it.
        metricsNotifyTask?.cancel()
        metricsNotifyTask = nil
        // Drop any pending settle paint from a prior text — `retokenizeAndStyle`
        // below paints the freshly-attached doc synchronously.
        deferredRestyleTask?.cancel()
        deferredRestyleTask = nil
        burstBaselineText = nil
        applyAppearance(theme: theme, typography: typography)
        // Seed the appearance baseline so the FIRST-mount
        // `viewDidChangeEffectiveAppearance` (same appearance) is a no-op; only a
        // genuine light/dark flip afterwards restyles.
        lastEffectiveAppearanceName = textView.effectiveAppearance.name
        retokenizeAndStyle()
        if let location = initialCursorLocation {
            let length = (textView.string as NSString).length
            let clamped = max(0, min(location, length))
            let range = NSRange(location: clamped, length: 0)
            textView.setSelectedRange(range)
            // Defer scroll + first-responder acquisition until the textView
            // is actually in a window (it's not yet during attach).
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.scrollRangeToVisible(range)
                textView.window?.makeFirstResponder(textView)
            }
            initialCursorLocation = nil
        }
    }

    /// Release the text-view graph and silence the coordinator. Called from
    /// `EditorSurface.dismantleNSView` when SwiftUI tears the representable down
    /// (piece flip via `.id(path)`, and window close when SwiftUI cooperates).
    ///
    /// The coordinator itself holds no ARC cycle — the delegate, `textView`,
    /// overlay/gutter back-pointers and all NC observers are `weak`/`[weak self]`,
    /// so the only strong owner is SwiftUI's per-scene storage. When a `WindowGroup`
    /// window closes, SwiftUI does not deterministically release that storage, so
    /// the coordinator (and the `NSScrollView`→`NSTextView`→`NSTextStorage` graph
    /// its documentView chain retains) can outlive the window. `detach()` breaks
    /// that graph proactively on every teardown SwiftUI DOES perform and flips
    /// `isDetached`, so any residual callback (a leaked coordinator's own OS
    /// appearance flip) does no whole-doc restyle work.
    func detach() {
        // Explicitly idempotent: on a piece flip BOTH `dismantleNSView` AND
        // `MaughamTextView.viewWillMove(toWindow: nil)` fire, so detach runs
        // twice on the same coordinator. The body below already tolerates a
        // second pass (textView/tokens are nil'd), but the early return makes
        // the contract explicit and skips the redundant work.
        guard !isDetached else { return }
        isDetached = true
        scriptUpdateNotifyTask?.cancel(); scriptUpdateNotifyTask = nil
        metricsNotifyTask?.cancel(); metricsNotifyTask = nil
        deferredRestyleTask?.cancel(); deferredRestyleTask = nil
        // Explicit liveness contract (ADR 0021): drop the scoped-event tokens on
        // teardown so a coordinator SwiftUI hasn't yet released stops receiving
        // deliveries. `receiverContext` also returns nil once `isDetached`, so
        // this is belt-and-suspenders with the deinit removal (which stays).
        for token in [navigateObserver, findMatchObserver, paragraphNavigateObserver,
                      annotationNavigateObserver, reviewToggleObserver,
                      translationEnterObserver, translationExitObserver] {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        navigateObserver = nil; findMatchObserver = nil; paragraphNavigateObserver = nil
        annotationNavigateObserver = nil; reviewToggleObserver = nil
        translationEnterObserver = nil; translationExitObserver = nil
        // Clear the native undo stack before the text-view reference is
        // dropped: a doc switch recreates the EditorSurface via `.id(path)`,
        // and the NEW text view is seeded in `makeNSView` — no
        // `applyExternalText` fires, so nothing else clears the WINDOW's undo
        // manager. Stale typing actions referencing the dismantled text view
        // would stay poppable (the ⌘Z crash family's residual). Cross-doc
        // undo is not a thing: text edits are per-doc, and op-log-level
        // accept actions target the by-then-husked Document anyway.
        (undoManagerOverrideForTesting ?? textView?.undoManager)?.removeAllActions()
        if let tv = textView, tv.delegate === self {
            tv.delegate = nil
        }
        (textView as? MaughamTextView)?.coordinator = nil
        textView = nil
        selectionToolbar = nil
    }

    /// The non-View `MaughamEvent.observe` liveness contract (ADR 0021): the
    /// scope context the scene/find/paragraph/annotation/review observers filter
    /// each delivery against. `nil` — once detached or before attach — drops the
    /// delivery. `.keyWindow` also excludes closed/background windows (a closed
    /// window is never key), fixing cross-window navigation: previously every
    /// live editor moved its cursor on another window's scene/find/history jump.
    /// Internal (not private) so MaughamEventLivenessTests can pin the positive
    /// path deterministically — the negative-path zombie tests alone can't
    /// distinguish correct scoping from a context that always returns nil.
    func receiverContext(_ kind: EventReceiverContext.Kind) -> EventReceiverContext? {
        guard !isDetached, respondsToWindowCommands, let tv = textView else { return nil }
        return .forWindow(tv.window, kind: kind)
    }

    /// External (binding-side) update — replace text without disturbing user.
    func applyExternalText(_ text: String, preserveUndoStack: Bool = false) {
        applyExternalTextCallCount += 1
        // Cloud-conflict resolution replaces the whole buffer — drop any
        // debounced typing-path script post so it can't land after the
        // immediate whole-doc post this call's retokenizeAndStyle emits.
        scriptUpdateNotifyTask?.cancel()
        scriptUpdateNotifyTask = nil
        metricsNotifyTask?.cancel()
        metricsNotifyTask = nil
        // A cloud-conflict replace repaints the whole buffer synchronously via
        // retokenizeAndStyle below; cancel any pending typing settle paint so it
        // can't land afterwards on the replaced text.
        deferredRestyleTask?.cancel()
        deferredRestyleTask = nil
        burstBaselineText = nil
        guard let textView, textView.string != text else { return }
        // Replacing the buffer out from under NSTextView invalidates every
        // native typing-undo action (they capture text-storage state; popping
        // one afterwards is the ⌘Z EXC_BAD_ACCESS in _NSUndoStack
        // popAndInvoke — crash 2026-07-08). Drop them — unless this apply was
        // flagged undo-coherent by the Document (accept/revert registered its
        // own action and already cleared the stale ones; wiping here would
        // kill that registration).
        if !preserveUndoStack {
            (undoManagerOverrideForTesting ?? textView.undoManager)?
                .removeAllActions()
        }
        isApplyingExternalUpdate = true
        defer { isApplyingExternalUpdate = false }

        // Preserve cursor where possible
        let oldSelection = textView.selectedRange()
        textView.string = text
        let clamped = NSRange(
            location: min(oldSelection.location, text.utf16.count),
            length: 0
        )
        textView.setSelectedRange(clamped)
        retokenizeAndStyle()
    }

    /// Default vertical text inset (matches EditorSurface.makeNSView). Restored
    /// when typewriter scroll is off.
    private static let defaultVerticalInset: CGFloat = 24

    /// Typewriter scroll setting changed — update and apply immediately.
    func applyTypewriterScroll(_ enabled: Bool) {
        self.typewriterScroll = enabled
        guard let textView else { return }
        refreshTypewriterInset(in: textView)
        if enabled && !isReviewMode {
            scrollSelectionToVerticalCenter(in: textView)
        } else {
            // Inset shrank back to default; keep the caret on screen.
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    /// Reserve half a viewport of padding above and below the text when
    /// typewriter scroll is on, so the active line can always reach the
    /// vertical center — including at the very start and very end of the
    /// document, where there'd otherwise be no content to scroll into and the
    /// line would pin to the top/bottom edge. Restores the default inset when
    /// typewriter scroll is off. Idempotent and guarded against no-op churn;
    /// safe to call on every resize. The matching coordinate correction lives
    /// in `scrollSelectionToVerticalCenter` (line rects are in container space,
    /// so the inset must be added back to land in view space).
    func refreshTypewriterInset(in textView: NSTextView) {
        let clipHeight = textView.enclosingScrollView?
            .contentView.bounds.height ?? 0
        // Review posture suppresses typewriter centering — restore the default
        // inset so the active line isn't pinned to the viewport center.
        let target = (typewriterScroll && !isReviewMode && clipHeight > 0)
            ? max(Self.defaultVerticalInset, clipHeight / 2)
            : Self.defaultVerticalInset
        guard abs(textView.textContainerInset.height - target) > 0.5 else { return }
        textView.textContainerInset = NSSize(
            width: textView.textContainerInset.width, height: target)
    }

    /// Review posture changed — flip the membrane and re-apply the posture.
    ///
    /// Threaded ONE-WAY from EditorSurface.updateNSView (tripwires 2 & 6). When
    /// review turns ON: typing/paste/delete are rejected (via `EditorEditPolicy`
    /// in `shouldChangeTextIn`), focus-dim and typewriter centering are
    /// suppressed, and the selection toolbar becomes eligible to show. When it
    /// turns OFF the prior focus/typewriter behavior is restored. Idempotent and
    /// guarded against no-op churn (updateNSView calls every layout pass).
    /// Hard editing lock changed (WF1 iCloud role). Plain stored-property flip
    /// threaded ONE-WAY from EditorSurface.updateNSView (tripwires 2 & 6). The
    /// membrane reads `lockEditing` live in `shouldChangeTextIn`, so no restyle
    /// is needed — the next keystroke sees the new value. Idempotent / no-op
    /// guarded (updateNSView runs every layout pass).
    func setLockEditing(_ locked: Bool) {
        guard lockEditing != locked else { return }
        lockEditing = locked
    }

    /// Translation-review posture changed (Task 11). Plain stored-property flip
    /// threaded ONE-WAY from EditorSurface (tripwires 2 & 6). The membrane reads
    /// `isTranslationReview` live in `shouldChangeTextIn`, so no restyle is needed
    /// — the next keystroke sees the new value (mirrors `setLockEditing`). The
    /// translated-surface buffer swap itself is EditorHost's job (the text binding
    /// value changes, flowing through the single `applyExternalText` site in
    /// `updateNSView`); this setter only governs the membrane. Idempotent /
    /// no-op guarded (updateNSView / applyControl run every layout pass).
    ///
    /// Returns `true` when the flag actually flipped (used by
    /// `EditorSurface.reconcileTextBuffer` to detect a translation entry/exit
    /// swap in the same layout pass, so it can force a non-undo-coherent buffer
    /// replace regardless of any one-shot undo-coherent flag).
    @discardableResult
    func setTranslationReview(_ enabled: Bool) -> Bool {
        guard isTranslationReview != enabled else { return false }
        isTranslationReview = enabled
        return true
    }

    func setReviewMode(_ enabled: Bool) {
        guard isReviewMode != enabled else { return }
        isReviewMode = enabled
        guard let textView else { return }
        // Re-style from scratch so any focus-dim attributes from the prior
        // posture are cleared, then re-apply focus-dim only when not in review.
        retokenizeAndStyle()
        applyFocusDim(in: textView)
        refreshTypewriterInset(in: textView)
        if !enabled {
            // Leaving review: keep the caret on screen with the restored inset.
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        // Hide the toolbar when leaving review; show-on-selection resumes via
        // textViewDidChangeSelection while review is on.
        updateSelectionToolbar(in: textView)
        // Entering review must show existing open annotations' marks + rail
        // PROMPTLY, not only after some later unrelated update (Bug A). PULL the
        // current set directly from the provider so this never depends on the
        // lagged `setReviewAnnotations` push: on the first toggle after launch
        // the coordinator's stored `reviewAnnotations` is still empty (review was
        // off, so EditorHost gated its derivation to []) and the real set only
        // arrives on the NEXT SwiftUI render — pulling here resolves marks from
        // the real set immediately. The assignment mirrors `setReviewAnnotations`'
        // no-op guard, so a subsequent push with the same set no-ops and there's
        // no double recompute. (The provider is only invoked here, on entry, so
        // it never re-derives annotations during authoring.)
        if enabled {
            if let provider = reviewAnnotationsProvider {
                let pulled = provider()
                if pulled != reviewAnnotations {
                    reviewAnnotations = pulled
                }
            }
            recomputeReviewMarks()
        }
        // Crafted-render overlays follow the review posture.
        syncReviewOverlays()
    }

    /// Begin observing the control-plane model. Runs an initial apply, then
    /// re-arms on every change via Observation. Pure AppKit-side — independent
    /// of SwiftUI's layout cadence, which is the whole point (ADR 0017): a
    /// control change that doesn't trigger a layout pass (e.g. the async iCloud
    /// role resolve) still reaches the membrane here.
    func observeControl(_ control: EditorControl) {
        self.control = control
        armControlObservation()
    }

    private func armControlObservation() {
        guard let control else { return }
        // Apply OUTSIDE the tracking closure (ADR 0017 D1). `applyControl` reads
        // through Document/UserPreferences providers (recomputeReviewMarks,
        // reviewLocalAuthorName) in review posture; if that ran inside
        // `withObservationTracking`, those reads would be tracked and any shared
        // UserPreferences / Document mutation would re-fire the whole-doc restyle
        // in every review-mode window. Keeping the apply outside means the
        // tracked set is EXACTLY the EditorControl properties touched below.
        applyControl(control)
        withObservationTracking {
            // Establish the observation set: read ONLY EditorControl's own
            // properties — the exact set `applyControl` consumes. Touch each
            // explicitly so the tracked set never silently widens.
            _ = control.lockEditing
            _ = control.isReviewMode
            _ = control.theme
            _ = control.typography
            _ = control.typewriterScroll
            _ = control.sentenceFocus
            _ = control.paragraphFocus
            _ = control.reviewAnnotations
            _ = control.translationLanguage
            _ = control.translationBadges
        } onChange: { [weak self] in
            // onChange fires once (pre-change). Re-arm on the next main-actor
            // turn — after the mutation commits — so the re-applied values are
            // current. Re-entering withObservationTracking synchronously inside
            // onChange is unsafe, hence the hop.
            Task { @MainActor [weak self] in self?.armControlObservation() }
        }
    }

    /// Apply the full control model through the existing setters. INVARIANT D2:
    /// every sub-area is no-op-guarded, so a single property change re-applies
    /// only the area that changed (the setters that aren't self-guarding —
    /// appearance/typewriter/focus — are guarded here at the call site, exactly
    /// as `updateNSView` did).
    ///
    /// D1 safety: `setReviewAnnotations` early-returns on its `annotations ==
    /// reviewAnnotations` guard when `reviewAnnotations` is empty (normal
    /// authoring), so `recomputeReviewMarks()` and its `doc`-reading provider
    /// closures never run inside `withObservationTracking`'s tracking closure —
    /// `Document`'s observable state stays untracked. A future unconditional
    /// `Document` read in this path would cause observation to fire every keystroke.
    func applyControl(_ c: EditorControl) {
        applyControlCount += 1
        setLockEditing(c.lockEditing)        // self-guarded
        setReviewMode(c.isReviewMode)        // self-guarded
        // Translation review is a pure membrane flip driven off language
        // presence; the surface buffer swap is EditorHost's (the text binding).
        setTranslationReview(c.translationLanguage != nil)   // self-guarded
        if theme != c.theme || typography != c.typography {
            applyAppearance(theme: c.theme, typography: c.typography)
        }
        if typewriterScroll != c.typewriterScroll {
            applyTypewriterScroll(c.typewriterScroll)
        }
        if sentenceFocus != c.sentenceFocus || paragraphFocus != c.paragraphFocus {
            applyFocusPrefs(sentence: c.sentenceFocus, paragraph: c.paragraphFocus)
        }
        setReviewAnnotations(c.reviewAnnotations)   // self-guarded
        setTranslationBadges(c.translationBadges)   // self-guarded
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView,
                  shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        // Review posture (WF1): annotate-only read-only membrane. When review
        // mode is on, the manuscript text cannot be mutated through the editor.
        // This is the single choke point for every text mutation (typing, paste,
        // delete, drag-drop, smart-typography re-insert) because AppKit funnels
        // them all through shouldChangeTextIn. Selection / scroll / copy do NOT
        // pass through here, so they keep working. Returning false here also
        // stops the smart-typography path below from running its insertText, so
        // no mutation leaks. Placed at the very top, before the existing guard.
        guard EditorEditPolicy.allowsTextMutation(
            isReviewMode: isReviewMode, lockEditing: lockEditing,
            isTranslationReview: isTranslationReview) else {
            return false
        }
        guard let replacementString,
              !isApplyingExternalUpdate else { return true }

        // Remember the pre-burst text on the first edit of a new typing burst
        // (no settle pending) so `performDeferredRestyle` can character-diff it
        // against the post-burst text and window the restyle to just the changed
        // paragraph(s). Captured here — before the edit lands — because this is
        // the one choke point that still sees the pre-edit string.
        if deferredRestyleTask == nil, burstBaselineText == nil {
            burstBaselineText = textView.string
        }

        // Smart typography handling.
        // `transform` returns the substitute glyph AND the full replacement range
        // (including any preceding ASCII run to consume). The coordinator uses
        // the range directly — it never back-computes how many chars to eat.
        if let result = mode.smartTypographyTransform(
            currentText: textView.string,
            replacementRange: affectedCharRange,
            replacement: replacementString,
            settings: typography
        ) {
            textView.insertText(result.substitute, replacementRange: result.range)
            return false
        }
        return true
    }

    func textView(_ textView: NSTextView,
                  doCommandBy commandSelector: Selector) -> Bool {
        guard mode is ScreenplayMode else { return false }

        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            cycleElementForward(in: textView)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            cycleElementBackward(in: textView)
            return true
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              !isApplyingExternalUpdate else { return }
        if !isApplyingTabCycle {
            lastCycleTarget = nil
            lastCycleTargetLineRange = nil
        }
        // Capture the post-edit cursor position. retokenizeAndStyle mutates
        // storage attributes which can jostle NSTextView's selection (most
        // visibly after paste of a multi-char string). We restore the
        // captured range both synchronously (in case the move is in
        // retokenizeAndStyle) and on the next runloop tick (in case it's an
        // async layout-pass effect from storage.endEditing).
        // Skip the cursor-restore when a Tab cycle is in flight — the cycle
        // method sets the cursor explicitly AFTER didChangeText (e.g.,
        // inside the opening paren on Parenthetical wrap), and the restore
        // would clobber that intent. Capture the flag now since `defer` in
        // cycle() will reset it before the async block fires.
        let skipCursorRestore = isApplyingTabCycle
        let postEditSelection = textView.selectedRange()
        // NOTE: the typing fast path no longer paints on the keystroke (the
        // structural restyle is deferred to the burst-settle — see
        // `scheduleDeferredRestyle`). With no per-keystroke whole-range
        // setAttributes there is no layout invalidation to snap the scroll
        // origin toward the top, so the old capture-and-restore-the-origin
        // workaround (Editor AREA tripwire 9) is gone from here — it was
        // actively fighting AppKit's own caret-following autoscroll (the
        // "recoil on the last line" + "caret runs off the bottom" bugs). The
        // origin is now preserved by `performDeferredRestyle` around the settle
        // paint instead, which is the only place a whole-doc relayout happens
        // on the typing path.
        // Notify the host of the post-edit caret position so Document's
        // V2 task-anchor alignment can read it inside the immediately-
        // following setFullText call. Must fire BEFORE binding-set so the
        // host has a chance to stash the value on the Document.
        onPostEditCursor?(postEditSelection.location)
        // Nativize before handing the text to the Swift pipeline (setFullText
        // parse, word counting): NSString-backed strings pay per-character
        // objc dispatch on every scan — see the matching note in
        // retokenizeAndStyle. One O(N) copy per keystroke, 5–20× faster scans.
        var editedText = textView.string
        editedText.makeContiguousUTF8()
        binding.wrappedValue = editedText
        // Typing fast path: window the structural restyle to the
        // classification-changed region. All other restyle callers stay
        // whole-document. Thread the already-nativized `editedText` so the
        // keystroke nativizes exactly once (it is byte-identical to
        // textView.string here — same MainActor slice, no intervening edit).
        retokenizeAndStyle(windowedTyping: true, nativizedText: editedText)
        // Autocomplete trigger deferred — see milestone-3b notes.
        if !skipCursorRestore {
            // Sync restore covers paste-induced cursor jostle from
            // storage.endEditing() — that happens during retokenizeAndStyle
            // synchronously, so the cursor is at its final position by the
            // time we check here. Any earlier async restore was racy under
            // rapid typing: queued main.async blocks vs queued key events
            // don't have guaranteed order on the next runloop tick, so the
            // restore could fire BEFORE the next textDidChange and force
            // the cursor back into the middle of a word the user just typed
            // forward through. The sync check below is sufficient for the
            // jostle case and has no race because it runs on the same
            // dispatch as the keystroke that triggered it.
            if textView.selectedRange() != postEditSelection {
                textView.setSelectedRange(postEditSelection)
                textView.scrollRangeToVisible(postEditSelection)
            }
        }
        if typewriterScroll {
            scrollSelectionToVerticalCenter(in: textView)
        }
        // Typewriter off: rely on AppKit's native caret-following autoscroll.
        // The deferred settle paint preserves the scroll origin itself.
        // Text edits shift every absolute mark position; recompute + redraw the
        // crafted-render overlays. (In review posture text is read-only, so this
        // is a no-op there; it keeps the cache honest on the rare edit path.)
        if isReviewMode {
            recomputeReviewMarks()
            refreshReviewOverlays()
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              !isApplyingExternalUpdate else { return }
        // Clear lastCycleTarget when cursor moves to a different line.
        if let lineRange = lastCycleTargetLineRange {
            let cursor = textView.selectedRange().location
            if cursor < lineRange.location || cursor > NSMaxRange(lineRange) {
                lastCycleTarget = nil
                lastCycleTargetLineRange = nil
            }
        }
        if typewriterScroll && !isReviewMode {
            scrollSelectionToVerticalCenter(in: textView)
        }
        // Cursor-only selection changes (arrow keys, click) don't go through
        // retokenizeAndStyle. Re-dim here (no-op in review posture).
        applyFocusDim(in: textView)
        onCursorChanged?(textView.selectedRange().location)
        onElementChanged?(currentElementAbbreviation(in: textView))
        // One-way drive of the floating selection toolbar (review posture only).
        // No write-back into SwiftUI state.
        updateSelectionToolbar(in: textView)
    }

}
