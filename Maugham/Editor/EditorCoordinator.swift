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
    private let mode: any WritingMode
    private(set) var theme: Theme
    private(set) var typography: TypographySettings
    private(set) var typewriterScroll: Bool
    private(set) var sentenceFocus: Bool
    private(set) var paragraphFocus: Bool

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
    /// into; this is the floor that the membrane ANDs in so a reviewer's ⌘⌥R can
    /// flip the review render but can NEVER unlock text mutation. Threaded
    /// ONE-WAY from ProjectWindow → EditorHost → EditorSurface (tripwires 2 & 6);
    /// nothing reads it back. Use `setLockEditing(_:)` to flip it.
    private(set) var lockEditing = false

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
    private(set) var lastTokens: [Token] = []

    /// Most recent FountainScript from ScreenplayMode parsing. nil for prose
    /// modes. Updated each time retokenizeAndStyle runs. Source for
    /// the element gutter (3b).
    private(set) var lastParsedScript: FountainScript?

    /// Most recent cycle target on the current blank line. Cleared when:
    /// - cursor moves to a different line
    /// - any non-Tab edit triggers textDidChange
    /// - the active line gains content via the cycle's mutator
    /// Used so that subsequent Tab presses on the same blank line cycle
    /// from the prior target rather than re-computing startingElement.
    private var lastCycleTarget: ScreenplayElement?

    /// Active line's range at the moment lastCycleTarget was set; used to
    /// detect cursor moves to a different line.
    private var lastCycleTargetLineRange: NSRange?

    /// Set to true while cycle(in:direction:) is mutating storage so that
    /// textDidChange knows to leave lastCycleTarget alone.
    private var isApplyingTabCycle = false

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
    private var scriptUpdateNotifyTask: Task<Void, Never>?

    /// Trailing-edge debounce for `onMetricsChanged` on the typing fast path —
    /// the metrics mirror that used to live on `EditorHost`. Coalesced to the
    /// same ~350ms trailing edge as the script broadcast so the footer/inspector
    /// stay live while typing pays only one whitespace split per burst (the page
    /// count is free — it reads the keystroke's own `lastParsedScript`). Whole-
    /// doc callers (attach, applyExternalText, theme) deliver immediately.
    private var metricsNotifyTask: Task<Void, Never>?

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
    private var deferredRestyleTask: Task<Void, Never>?

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
    private var burstBaselineText: String?

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
    private var liveRestyleBaseline: String?

    /// Observer token for `maughamNavigateToScene` notifications.
    private var navigateObserver: NSObjectProtocol?

    /// Observer token for `maughamFindMatchSelected` notifications.
    private var findMatchObserver: NSObjectProtocol?

    /// Observer token for `maughamEffectiveAppearanceChanged` notifications.
    private var appearanceObserver: NSObjectProtocol?

    /// Observer token for `maughamNavigateToParagraph` notifications, used
    /// to scroll the textView to the paragraph an annotation is anchored
    /// to when the user clicks an annotation row.
    private var paragraphNavigateObserver: NSObjectProtocol?

    /// Observer token for `maughamNavigateToAnnotation` — span-precise jump.
    /// Looks the annotation id up in `resolvedReviewMarks`: an `absoluteRange`
    /// selects the exact span; otherwise it falls back to the paragraph (the
    /// legacy scroll-to-paragraph behaviour).
    private var annotationNavigateObserver: NSObjectProtocol?

    /// Observer token for `maughamToggleReviewMode` (⌘⌥R). Flips the membrane
    /// SYNCHRONOUSLY in the key window's coordinator so `isReviewMode` is correct
    /// before the next key event — closing the race where a fast Enter pressed
    /// right after ⌘⌥R slipped a newline through `shouldChangeTextIn` before the
    /// SwiftUI render round-trip pushed the new posture (Bug B). `ProjectWindow`
    /// still toggles `isReviewModeOn` on the SAME notification (source of truth
    /// for the indicator + annotation derive + persistence); `updateNSView`'s
    /// `setReviewMode(isReviewModeOn)` is the no-op-guarded reconciler the two
    /// paths converge through. Both toggle the same boolean from the same value,
    /// so they can't diverge; the reconciler re-converges if state ever drifts.
    private var reviewToggleObserver: NSObjectProtocol?

    /// Observer token for `maughamReviewAnnotationsChanged`. When the
    /// AnnotationsPane edits or withdraws an annotation, the key-window editor
    /// re-pulls the open set and recomputes its crafted marks so the inline
    /// mark + rail card update immediately (no review toggle needed).
    private var reviewAnnotationsChangedObserver: NSObjectProtocol?

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
    /// lagged `setReviewAnnotations` push (off `annotationsVersion`) remains the
    /// reconciler for annotations created elsewhere; the await + provider-pull is
    /// the deterministic path for the LOCAL create.
    var createAnnotationHandler: ((AnnotationKind, String, SpanAnchor, String, String?) async -> Void)?

    /// The inline composer (a small NSTextField) shown when the reviewer clicks
    /// Comment/Query. Minimal by design — Task 5 restyles it into a margin slip.
    private weak var annotationComposer: ReviewAnnotationComposerView?

    // MARK: - Crafted review render (Task 5 / Component F)

    /// Open annotations to render in review mode. Pushed ONE-WAY from
    /// EditorSurface.updateNSView (sourced from the host's `Document`), versioned
    /// so the recompute only fires when the set actually changes. Nothing reads
    /// this back into a binding (tripwires 2 & 6).
    private var reviewAnnotations: [Annotation] = []
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
    private(set) var resolvedReviewMarks: [ResolvedReviewMark] = []
    private let reviewPalette = ReviewPalette()

    /// Inline-mark overlay + right-margin rail, installed lazily on the text
    /// view (like the gutter) and shown only in review mode.
    private weak var markRenderer: AnnotationMarkRenderer?
    private weak var marginRail: ReviewMarginRailView?

    /// The annotation id whose margin card is currently selected (click-to-reveal
    /// actions). nil = nothing selected. Read by `ReviewMarginRailView` to
    /// emphasise the selected card; drives the inline actions row. Lives here (not
    /// on the rail) so a redraw / recompute can reconcile it.
    private(set) var selectedReviewCardId: String?

    /// The annotation id of a just-rejected suggested change whose margin card is
    /// holding the brief "stet" acknowledgement before it resolves out of the open
    /// set. While set, `ReviewMarginRailView.drawCard` paints the STET treatment on
    /// that card and the mark is deliberately NOT refreshed away. Mirrors the
    /// AnnotationsPane `stetIds` dwell so the gesture reads in both surfaces.
    private(set) var stetReviewCardId: String?

    /// Handlers for the interactive margin-card actions, threaded ONE-WAY from
    /// EditorHost (like `createAnnotationHandler`). Each is async so the card can
    /// await the op-log append before refreshing marks. `reply` carries the reply
    /// text; `edit` carries the new body + (suggestion-only) replacement. All
    /// stamp the local author name on the host side where needed. Nothing reads a
    /// binding back (tripwires 6/7) — these are op-log appends, not text writes.
    var reviewAcceptHandler: ((String) async -> Void)?
    var reviewRejectHandler: ((String) async -> Void)?
    var reviewArchiveHandler: ((String) async -> Void)?
    var reviewReplyHandler: ((String, String) async -> Void)?
    var reviewEditHandler: ((String, String, String?) async -> Void)?
    var reviewWithdrawHandler: ((String) async -> Void)?

    /// Number of times applyExternalText has been called. Internal so
    /// @testable importers (EditorIntegrationHarness) can assert invariants
    /// about typing not triggering external-text replacement. Production
    /// never reads this.
    internal private(set) var applyExternalTextCallCount: Int = 0

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
        // NotificationCenter posts these on `.main` so we're on the main
        // thread when the closures fire, but the closure types aren't
        // @MainActor-annotated. `MainActor.assumeIsolated` bridges the gap
        // without an extra Task hop (and asserts in debug if we're wrong
        // about being on the main thread).
        navigateObserver = NotificationCenter.default.addObserver(
            forName: .maughamNavigateToScene,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let location = note.userInfo?["lineLocation"] as? Int,
                      let textView = self.textView else { return }
                self.navigateToLine(at: location, in: textView)
            }
        }
        findMatchObserver = NotificationCenter.default.addObserver(
            forName: .maughamFindMatchSelected,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
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
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .maughamEffectiveAppearanceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Re-run the full appearance pass so background/caret/syntax
                // highlight colors re-resolve against the new effective appearance.
                self.applyAppearance(theme: self.theme, typography: self.typography)
            }
        }
        paragraphNavigateObserver = NotificationCenter.default.addObserver(
            forName: .maughamNavigateToParagraph,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
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
        }
        annotationNavigateObserver = NotificationCenter.default.addObserver(
            forName: .maughamNavigateToAnnotation,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let annId = note.userInfo?["annotation_id"] as? String,
                      let textView = self.textView else { return }
                guard textView.window?.isKeyWindow == true else { return }
                let pid = note.userInfo?["paragraph_id"] as? String
                self.navigateToAnnotation(id: annId, fallbackParagraphId: pid, in: textView)
            }
        }
        reviewToggleObserver = NotificationCenter.default.addObserver(
            forName: .maughamToggleReviewMode,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Mirror FocusPostureModifier's key-window guard: the toggle is
                // posted to every open window, but only the key window's editor
                // (and ProjectWindow) acts. Flip the membrane synchronously to
                // the toggled value so the very next keystroke sees it.
                guard self.textView?.window?.isKeyWindow == true else { return }
                self.setReviewMode(!self.isReviewMode)
            }
        }
        reviewAnnotationsChangedObserver = NotificationCenter.default.addObserver(
            forName: .maughamReviewAnnotationsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only the key window's editor re-pulls (mirrors the review
                // toggle's key-window guard). `refreshReviewMarksFromProvider`
                // is itself a no-op when not in review mode.
                guard self.textView?.window?.isKeyWindow == true else { return }
                self.refreshReviewMarksFromProvider()
            }
        }
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
        if let token = appearanceObserver {
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
        if let token = reviewAnnotationsChangedObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Set the text view from outside (called by EditorSurface.makeNSView).
    func attach(to textView: NSTextView) {
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

    /// External (binding-side) update — replace text without disturbing user.
    func applyExternalText(_ text: String) {
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
        withObservationTracking {
            applyControl(control)            // reads every tracked property
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
    func applyControl(_ c: EditorControl) {
        setLockEditing(c.lockEditing)        // self-guarded
        setReviewMode(c.isReviewMode)        // self-guarded
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
    }

    // MARK: - Crafted review render wiring (Task 5)

    /// Push the open-annotation set for the crafted review render. Called
    /// ONE-WAY from EditorSurface.updateNSView. Recomputes resolved marks (and
    /// redraws the overlays) only when the set actually changed — updateNSView
    /// runs every layout pass, so this is guarded against no-op churn the same
    /// way `setReviewMode` is.
    func setReviewAnnotations(_ annotations: [Annotation]) {
        guard annotations != reviewAnnotations else { return }
        // A reject's annotationsVersion bump can drive this push DURING the stet
        // dwell. Defer it so the held STET card isn't recomputed away early; the
        // dwell completion (`rejectReviewCardWithStet`) re-pulls the fresh set.
        if stetReviewCardId != nil { return }
        reviewAnnotations = annotations
        recomputeReviewMarks()
        refreshReviewOverlays()
    }

    /// Re-pull the current open-annotation set from `reviewAnnotationsProvider`
    /// and recompute marks. Reuses the same pull path as `setReviewMode`'s
    /// entry case so a just-created annotation renders IMMEDIATELY without the
    /// reviewer toggling review off/on (the SwiftUI observation→push chain off
    /// `annotationsVersion` is unreliable for the local-create case). Invoked
    /// from `commitAnnotation` AFTER the create's op-log append has been awaited.
    /// Only acts in review mode with a provider wired, and is no-op-guarded the
    /// same way as the push, so a subsequent `setReviewAnnotations` with the same
    /// set won't double-recompute. The provider is called on entry + after an
    /// explicit create only — never per keystroke.
    func refreshReviewMarksFromProvider() {
        guard isReviewMode, let provider = reviewAnnotationsProvider else { return }
        let pulled = provider()
        guard pulled != reviewAnnotations else { return }
        reviewAnnotations = pulled
        recomputeReviewMarks()
        refreshReviewOverlays()
    }

    /// Resolve every review annotation to absolute UTF-16 coordinates against the
    /// current display string. Span-anchored marks get an `absoluteRange`;
    /// paragraph-level / stale-span ones are rail-only (`absoluteRange == nil`)
    /// but still anchored at the paragraph start. Cached in `resolvedReviewMarks`;
    /// the overlay draws read the cache, never recompute (tripwire 4).
    private func recomputeReviewMarks() {
        let localName = reviewLocalAuthorName?() ?? ""
        var marks: [ResolvedReviewMark] = []
        for ann in reviewAnnotations {
            let color = reviewPalette.color(for: ann.author)
            let authorName = ann.author?.displayName.isEmpty == false
                ? ann.author!.displayName
                : (ann.author?.sourceKind == .claude ? "Claude" : "Reviewer")

            var absolute: NSRange?
            var railAnchor = 0

            if let pid = ann.paragraphId,
               let paraRange = reviewParagraphRangeProvider?(pid) {
                railAnchor = paraRange.location
                if let grapheme = ann.resolvedSpanRange,
                   let paraText = reviewParagraphTextProvider?(pid),
                   let utf16 = ReviewSpanCapture.graphemeRangeToUTF16(grapheme, in: paraText),
                   utf16.length > 0 {
                    let abs = NSRange(
                        location: paraRange.location + utf16.location,
                        length: utf16.length)
                    absolute = abs
                    railAnchor = abs.location
                }
            }

            marks.append(ResolvedReviewMark(
                id: ann.id,
                kind: ann.kind,
                color: color,
                absoluteRange: absolute,
                railAnchorLocation: railAnchor,
                authorName: authorName,
                body: ann.body,
                suggestedText: ann.suggestedText,
                isOwn: AnnotationOwnership.isOwn(ann, localName: localName)))
        }
        resolvedReviewMarks = marks
        // A recompute can drop the currently-selected card (e.g. it was
        // withdrawn / accepted out of the open set). Clear the selection so the
        // actions row doesn't dangle over nothing.
        if let selected = selectedReviewCardId,
           !marks.contains(where: { $0.id == selected }) {
            clearReviewCardSelection()
        }
    }

    /// Install the overlays if missing and reconcile their visibility with the
    /// review posture. Idempotent.
    private func syncReviewOverlays() {
        guard let textView else { return }
        if isReviewMode {
            installReviewOverlaysIfNeeded(in: textView)
        }
        markRenderer?.isHidden = !isReviewMode
        marginRail?.isHidden = !isReviewMode
        layoutReviewOverlays(in: textView)
        refreshReviewOverlays()
    }

    private func installReviewOverlaysIfNeeded(in textView: NSTextView) {
        if markRenderer == nil {
            let r = AnnotationMarkRenderer(frame: textView.bounds)
            r.coordinator = self
            r.associatedTextView = textView
            r.autoresizingMask = [.width, .height]
            textView.addSubview(r)
            markRenderer = r
        }
        if marginRail == nil {
            let rail = ReviewMarginRailView(frame: .zero)
            rail.coordinator = self
            rail.associatedTextView = textView
            rail.autoresizingMask = [.height]
            textView.addSubview(rail)
            marginRail = rail
        }
    }

    /// Frame the overlays: the mark renderer covers the whole text view (it draws
    /// over glyphs); the rail occupies the right inset gutter.
    func layoutReviewOverlays(in textView: NSTextView) {
        markRenderer?.frame = textView.bounds
        if let rail = marginRail {
            let inset = textView.textContainerInset.width
            // Right gutter spans from the column's right edge to the view edge.
            let railWidth = max(0, inset)
            rail.frame = NSRect(
                x: textView.bounds.width - railWidth,
                y: 0,
                width: railWidth,
                height: max(textView.bounds.height, textView.frame.height))
        }
    }

    /// Mark both overlays dirty (cheap — they bound their own work to the visible
    /// range). Called on annotation-change, text-change, scroll, and resize.
    func refreshReviewOverlays() {
        markRenderer?.needsDisplay = true
        marginRail?.needsDisplay = true
    }

    // MARK: - Span-precise navigation (Part 2)

    /// Select an annotation's exact span (and scroll it into view). Looks the id
    /// up in `resolvedReviewMarks`: a resolved `absoluteRange` is selected
    /// directly; a paragraph-level / stale-span annotation (or one not in the
    /// resolved set — e.g. review is off) falls back to scrolling to the
    /// paragraph (the legacy behaviour). Selecting a range in review mode is
    /// fine: the read-only membrane blocks EDITS, not selection.
    func navigateToAnnotation(
        id: String, fallbackParagraphId: String?, in textView: NSTextView
    ) {
        let length = (textView.string as NSString).length
        if let mark = resolvedReviewMarks.first(where: { $0.id == id }),
           let range = mark.absoluteRange,
           range.location >= 0, range.location + range.length <= length {
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
            return
        }
        // Fallback: paragraph start (length-0 cursor), mirroring the legacy
        // `.maughamNavigateToParagraph` handler.
        guard let pid = fallbackParagraphId,
              let provider = paragraphRangeProvider,
              let range = provider(pid),
              range.location >= 0, range.location + range.length <= length
        else { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: - Interactive margin cards (Part 1)

    /// Toggle / set the selected margin card. Selecting also navigates to the
    /// annotation's span (span-precise) and shows the inline actions row;
    /// re-clicking the same card (or `nil`) clears the selection.
    func selectReviewCard(id: String?) {
        if selectedReviewCardId == id {
            clearReviewCardSelection()
            return
        }
        selectedReviewCardId = id
        if let id, let textView {
            // Span-precise select on card click (same path as the pane).
            let pid = resolvedReviewMarks.first(where: { $0.id == id })
                .flatMap { _ in reviewAnnotationParagraphId(id) }
            navigateToAnnotation(id: id, fallbackParagraphId: pid, in: textView)
        }
        marginRail?.reloadCardSelection()
        refreshReviewOverlays()
    }

    func clearReviewCardSelection() {
        guard selectedReviewCardId != nil else { return }
        selectedReviewCardId = nil
        marginRail?.reloadCardSelection()
        refreshReviewOverlays()
    }

    /// The paragraph id for a resolved mark, used as the navigation fallback when
    /// a card is clicked. Pulled from the live annotation set (the resolved mark
    /// doesn't carry the pid). Best-effort; nil is a harmless no-fallback.
    private func reviewAnnotationParagraphId(_ id: String) -> String? {
        reviewAnnotations.first(where: { $0.id == id })?.paragraphId
    }

    /// Perform a margin-card action against the annotation. Dispatches to the
    /// host-threaded handler; Edit / Reply open the inline composer; Delete
    /// confirms via NSAlert first. After a disposition / edit lands, the marks
    /// are refreshed from the provider (same path as the pane's notification),
    /// so the card list updates without a review toggle.
    func performReviewCardAction(_ action: ReviewCardAction, annotationId id: String) {
        guard let mark = resolvedReviewMarks.first(where: { $0.id == id }) else { return }
        switch action {
        case .accept:
            runReviewAction { [weak self] in await self?.reviewAcceptHandler?(id) }
        case .reject:
            rejectReviewCardWithStet(id: id)
        case .archive:
            runReviewAction { [weak self] in await self?.reviewArchiveHandler?(id) }
        case .reply:
            beginCardComposer(
                placeholder: "Reply\u{2026}", initialText: "", for: id
            ) { [weak self] value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self?.runReviewAction {
                    await self?.reviewReplyHandler?(id, trimmed)
                }
            }
        case .edit:
            let isSuggest = (mark.kind == .suggestedChange)
            let initial = isSuggest ? (mark.suggestedText ?? "") : mark.body
            beginCardComposer(
                placeholder: isSuggest ? "Replacement\u{2026}" : "Edit\u{2026}",
                initialText: initial, for: id
            ) { [weak self] value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                // For a suggestion the field edits the replacement, keeping the
                // existing body; for others it edits the body, no replacement.
                if isSuggest {
                    self?.runReviewAction {
                        await self?.reviewEditHandler?(id, mark.body, trimmed)
                    }
                } else {
                    self?.runReviewAction {
                        await self?.reviewEditHandler?(id, trimmed, nil)
                    }
                }
            }
        case .delete:
            confirmDeleteCard(id: id, authorName: mark.authorName)
        }
    }

    /// Reject from the margin card with the proofreader's "stet" acknowledgement.
    /// Records the reject immediately (never blocked), dismisses the actions row,
    /// then holds the card on-screen with a STET treatment for ~2s before
    /// refreshing the marks (which drops the now-rejected annotation out of the
    /// open set). Mirrors the AnnotationsPane dwell so the gesture reads here too.
    private func rejectReviewCardWithStet(id: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reviewRejectHandler?(id)
            // Keep the card present (don't refresh it away yet) and paint STET.
            self.stetReviewCardId = id
            self.clearReviewCardSelection()  // hides the actions row + redraws; card stays
            self.refreshReviewOverlays()     // repaint rail (STET) + inline (strike off)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.stetReviewCardId = nil
            self.refreshReviewMarksFromProvider()
        }
    }

    /// Run a disposition handler, then refresh marks from the provider so the
    /// card list reconciles (the resolved annotation drops out of the open set).
    private func runReviewAction(_ work: @escaping () async -> Void) {
        Task { @MainActor [weak self] in
            await work()
            self?.clearReviewCardSelection()
            self?.refreshReviewMarksFromProvider()
        }
    }

    /// Show the inline `ReviewAnnotationComposerView` near the selected card for
    /// Edit / Reply (re-uses the authoring composer — plain NSView, no popover).
    /// Positioned at the rail's selected-card rect in the scroll-view overlay
    /// parent, mirroring `beginAuthoringAnnotation`.
    private func beginCardComposer(
        placeholder: String, initialText: String, for id: String,
        onCommit: @escaping (String) -> Void
    ) {
        guard let parent = selectionToolbar?.superview else { return }
        annotationComposer?.dismiss()
        let composer = ReviewAnnotationComposerView(
            placeholder: placeholder,
            initialText: initialText,
            onCommit: { [weak self] value in
                self?.annotationComposer?.dismiss()
                self?.annotationComposer = nil
                onCommit(value)
            },
            onCancel: { [weak self] in
                self?.annotationComposer?.dismiss()
                self?.annotationComposer = nil
            })
        parent.addSubview(composer)
        annotationComposer = composer
        // Position next to the selected card. The rail reports the card's rect in
        // its own coords; convert to the overlay parent.
        if let rail = marginRail,
           let cardRect = rail.cardRect(forAnnotationId: id) {
            let inParent = rail.convert(cardRect, to: parent)
            composer.setFrameOrigin(NSPoint(
                x: inParent.minX,
                y: inParent.minY - composer.frame.height - 4))
        } else if let toolbar = selectionToolbar {
            composer.setFrameOrigin(toolbar.frame.origin)
        }
        composer.focus()
    }

    /// Confirm-then-withdraw for the reviewer's own annotation. NSAlert is fine
    /// here — the rail is an AppKit NSView in a real window; the alert sheets off
    /// it. (Reported in the task as a possible friction point; in practice the
    /// alert presents cleanly from the text view's window.)
    private func confirmDeleteCard(id: String, authorName: String) {
        guard let window = textView?.window else {
            // No window (test / detached) — withdraw without a prompt.
            runReviewAction { [weak self] in await self?.reviewWithdrawHandler?(id) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete your annotation"
        alert.informativeText =
            "This removes your annotation. The history is preserved, but the annotation will no longer appear here or in the editor."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runReviewAction { await self?.reviewWithdrawHandler?(id) }
        }
    }

    /// Focus mode settings changed — update and re-dim immediately.
    func applyFocusPrefs(sentence: Bool, paragraph: Bool) {
        self.sentenceFocus = sentence
        self.paragraphFocus = paragraph
        guard let textView else { return }
        retokenizeAndStyle()
        applyFocusDim(in: textView)
    }

    /// Theme/typography changed — re-style without re-text.
    func applyAppearance(theme: Theme, typography: TypographySettings) {
        self.theme = theme
        self.typography = typography
        guard let textView else { return }
        textView.backgroundColor = theme.resolved(
            systemAppearanceIsDark: NSApp.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]) == .darkAqua
        ).palette.background
        textView.insertionPointColor = theme.resolved(
            systemAppearanceIsDark: NSApp.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]) == .darkAqua
        ).palette.caret
        retokenizeAndStyle()
    }

    /// Returns the wiki-link title at the given character index, or nil if
    /// the index is not inside a wiki-link range.
    func wikiLinkTitle(atCharacterIndex index: Int) -> String? {
        for token in lastTokens {
            if NSLocationInRange(index, token.range),
               case .wikiLink(let title) = token.kind {
                return title
            }
        }
        return nil
    }

    /// Returns the (paragraphId, offsetWithinParagraph, kind) for the
    /// bracket glyph at the given character index, or nil if the index
    /// is not on a checkbox bracket. Reads `MaughamCheckboxAttr` from the
    /// text storage so painted bracket regions are recognized without a
    /// fresh tokenization pass. The paragraph mapping uses
    /// `paragraphLocator` (wired by EditorHost via `Document`). The `kind`
    /// flags whether the click landed on a 3-char markdown `[ ]`/`[x]`
    /// glyph or a 5-char Fountain `todo:`/`done:` prefix so the host
    /// dispatches to the correct flipper.
    func checkboxHitTest(
        atCharacterIndex index: Int
    ) -> (paragraphId: String, offsetWithinParagraph: Int, kind: MaughamCheckboxKind)? {
        guard let textView,
              let storage = textView.textStorage,
              index >= 0, index < storage.length else { return nil }
        let raw = storage.attribute(MaughamCheckboxAttr, at: index,
                                    effectiveRange: nil)
        guard let marker = raw as? MaughamCheckboxMarker else { return nil }
        // Use the marker's authoritative bracket location (the stamp time)
        // rather than `index` so a click anywhere within the glyph resolves
        // to the bracket start.
        guard let mapping = paragraphLocator?(marker.bracketLocation) else {
            return nil
        }
        return (paragraphId: mapping.paragraphId,
                offsetWithinParagraph: mapping.offsetWithinParagraph,
                kind: marker.kind)
    }

    /// Re-tokenize the whole document and apply typography.
    ///
    /// `windowedTyping` is set to `true` ONLY from the `textDidChange` typing
    /// path. When true, the structural attribute application is restricted to
    /// the classification-changed window (diffed against `lastTokens` via
    /// `TokenRestyleWindow`) instead of the whole document — the keystroke
    /// fast path (see Editor AREA.md / `WindowedTypographyEquivalenceTests`).
    /// Every other caller (initial attach, `applyExternalText`, theme /
    /// typography / focus changes) leaves it `false` and gets the whole-doc
    /// application, which is the contract those paths rely on. Tokenization
    /// itself is always whole-document either way.
    private func retokenizeAndStyle(windowedTyping: Bool = false,
                                    nativizedText: String? = nil) {
        guard let textView, let storage = textView.textStorage else { return }
        // Bridge the AppKit-backed string to NATIVE Swift storage before any
        // scanning. `textView.string` is NSString-backed ("foreign"): every
        // Character/Substring walk over it pays per-character objc_msgSend —
        // the 2026-06-10 live profile showed FountainTokenizer 5–20× slower
        // on foreign strings than the native ones our headless tests use.
        // One O(N) UTF-8 copy here makes the whole-doc tokenize run at
        // native speed.
        //
        // One nativization per keystroke: textDidChange nativizes once and
        // threads the SAME string here (it is byte-identical to
        // textView.string — assigned in the same MainActor slice with no
        // intervening edit). Other callers (attach, applyExternalText, theme)
        // pass nil and self-nativize. The windowed-diff storageLength guard
        // still falls back to whole-doc on any mismatch.
        var text: String
        if let nativizedText {
            text = nativizedText
        } else {
            text = textView.string
            text.makeContiguousUTF8()
        }
        // P1-editor: parse the Fountain script EXACTLY ONCE per keystroke and
        // thread it through token derivation + styling + the scene-navigator
        // notification, instead of parsing the whole document three times
        // (tokenize, lastParsedScript, applyTypography). O(N²)→O(N) when typing
        // a long screenplay. The prose path doesn't parse Fountain and is
        // unchanged. See Editor AREA.md and the hardening plan task 4.7.
        let tokens: [Token]
        if let screenplay = mode as? ScreenplayMode {
            // Always parse (even empty text → `.empty`) so `lastParsedScript`
            // and the scene-navigator notification keep their prior payload;
            // `tokens(from:text:)` returns `[]` for empty text on its own.
            let script = FountainTokenizer().parse(text)
            lastParsedScript = script
            tokens = screenplay.tokens(from: script, text: text)
        } else {
            tokens = mode.tokenize(text)
            lastParsedScript = nil
        }
        self.lastTokens = tokens
        // Notify subscribers (e.g., scene navigator) that the script changed.
        // On the typing fast path, coalesce to a trailing edge so the scene
        // navigator's per-keystroke deep-compare + per-row walks don't run on
        // every key. Whole-doc callers post immediately. See AREA tripwire 4
        // and `scriptUpdateNotifyTask`.
        if let script = lastParsedScript {
            postScriptDidUpdate(script, debounced: windowedTyping)
        }
        // Deliver precomputed metrics on the SAME timing as the script post:
        // coalesced to the trailing edge while typing, immediate for whole-doc
        // callers. The page count rides `lastParsedScript` (no extra parse); the
        // word count is one whitespace split of the already-nativized `text`.
        // This supersedes EditorHost's `metricsMirrorTask`. See spec §7.
        deliverMetrics(text: text, debounced: windowedTyping)
        // Sync typing attributes so the caret on empty lines matches the
        // body font/paragraph style instead of the system default. Cheap and
        // non-visual-churn, so it stays live on both paths.
        textView.typingAttributes = mode.bodyTypingAttributes(
            theme: theme, typography: typography)
        // The actual visual repaint (applyTypography + focus-dim). On the typing
        // fast path this is DEFERRED to the trailing edge of the burst so the
        // styling doesn't re-render on every keystroke — that's what stops the
        // transient-invalid-state flicker (e.g. `*italic *` while editing the
        // end of an emphasis run). All other callers paint synchronously.
        if windowedTyping {
            if mode.defersRestyleWhileTyping {
                // Prose: the burst baseline text was captured in shouldChangeTextIn
                // on the first edit; the settle paint windows the restyle to the
                // changed paragraphs at the trailing edge of the burst (no paint
                // on the keystroke, so a transient invalid emphasis state can't
                // flicker).
                scheduleDeferredRestyle()
            } else {
                // Screenplay: paint live (windowed) on the keystroke — its
                // element-classification styling would lag visibly behind a
                // settle delay. Windowed, so no whole-doc relayout / scroll snap.
                paintLiveWindowed(text: text, in: storage, tokens: tokens)
            }
        } else {
            // Whole-doc paint: every non-typing caller (attach, applyExternalText,
            // theme/typography/focus changes) repaints the entire document.
            burstBaselineText = nil
            applyModeTypography(in: storage, tokens: tokens, restyleWindow: nil)
            applyFocusDim(in: textView)
            // Re-baseline the live (screenplay) windowed path against the freshly
            // repainted whole-doc text so its next keystroke diffs correctly.
            liveRestyleBaseline = text
        }
        // Fire element callback: text edits can reclassify the line under the
        // cursor without moving the selection, so we must fire here too (not
        // only from textViewDidChangeSelection). Compute stays live on both
        // paths, so the status footer / gutter element stay responsive.
        onElementChanged?(currentElementAbbreviation(in: textView))
    }

    /// Applies the mode's structural typography to `storage`. ProseMode supports
    /// an optional wiki-link resolver for `[[Title]]` styling; other modes use
    /// the protocol's resolver-less call. `restyleWindow == nil` is whole-doc.
    /// Shared by the synchronous restyle path and the deferred settle paint.
    private func applyModeTypography(
        in storage: NSTextStorage,
        tokens: [Token],
        restyleWindow: NSRange?
    ) {
        if let prose = mode as? ProseMode {
            prose.applyTypography(
                in: storage, theme: theme, typography: typography,
                tokens: tokens, wikiLinkResolver: wikiLinkResolver,
                restyleWindow: restyleWindow)
        } else {
            mode.applyTypography(
                in: storage, theme: theme, typography: typography,
                tokens: tokens, parsedScript: lastParsedScript,
                restyleWindow: restyleWindow)
        }
    }

    /// Live (non-deferred) restyle for element-heavy modes (screenplay). Paints
    /// on every keystroke — but WINDOWED to the changed paragraph(s), diffed
    /// against `liveRestyleBaseline` (the text as of the last paint) — so a
    /// local `setAttributes` never invalidates whole-doc layout or snaps the
    /// scroll origin (Editor AREA tripwire 9). The first paint after attach has
    /// no baseline and paints whole-doc. Cursor restore is handled by the caller
    /// (`textDidChange`) after `retokenizeAndStyle` returns, so none is needed
    /// here. `liveRestyleBaseline` is advanced to the new text on the way out.
    private func paintLiveWindowed(
        text: String, in storage: NSTextStorage, tokens: [Token]
    ) {
        guard let textView else { return }
        defer { liveRestyleBaseline = text }
        let window: NSRange?
        if let baseline = liveRestyleBaseline {
            guard let changed = changedParagraphWindow(
                old: baseline as NSString, new: text as NSString) else {
                // Text unchanged (e.g. a no-op smart-typography transform) —
                // nothing structural to repaint; just refresh the focus dim.
                applyFocusDim(in: textView)
                return
            }
            window = changed
        } else {
            window = nil   // first paint since attach: whole-doc
        }
        applyModeTypography(in: storage, tokens: tokens, restyleWindow: window)
        applyFocusDim(in: textView)
    }

    /// Schedule the deferred (settle) repaint for the typing fast path. Cancel-
    /// and-reschedule on every keystroke so it fires once, ~`restyleSettleDelayMs`
    /// after the last key. The paint is whole-document (the burst's window-diff
    /// baseline is stale by settle time) and preserves the caret + scroll
    /// position itself, since a whole-doc `setAttributes` invalidates layout and
    /// would otherwise snap a long scrolled document toward the top (Editor AREA
    /// tripwire 9). During the burst no paint happens, so the existing emphasis
    /// attributes simply shift with the text (NSTextStorage) and nothing flips.
    private func scheduleDeferredRestyle() {
        deferredRestyleTask?.cancel()
        let delay = restyleSettleDelayMs
        deferredRestyleTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            self.deferredRestyleTask = nil
            self.performDeferredRestyle()
        }
    }

    /// The settle paint: restyle from the latest live tokens, scoped to the
    /// paragraph window the burst changed (character-diffed against
    /// `burstBaselineText`). A windowed `setAttributes` leaves the rest of the
    /// document's layout — and the scroll position AppKit settled on while
    /// following the caret — untouched, so no scroll handling is needed. Only
    /// the rare no-baseline fallback paints whole-doc, and only it captures /
    /// restores the scroll origin (the snap-to-top guard, Editor AREA tripwire 9).
    private func performDeferredRestyle() {
        guard let textView, let storage = textView.textStorage else { return }
        let baseline = burstBaselineText
        burstBaselineText = nil
        let selection = textView.selectedRange()

        if let baseline {
            guard let window = changedParagraphWindow(
                old: baseline as NSString, new: storage.string as NSString) else {
                // No textual change (e.g. a transform that produced identical
                // text) — just refresh the dim; scroll/attrs already correct.
                applyFocusDim(in: textView)
                onElementChanged?(currentElementAbbreviation(in: textView))
                return
            }
            applyModeTypography(in: storage, tokens: lastTokens, restyleWindow: window)
            applyFocusDim(in: textView)
            if textView.selectedRange() != selection {
                textView.setSelectedRange(selection)
            }
            if typewriterScroll {
                scrollSelectionToVerticalCenter(in: textView)
            }
            // Typewriter off: a local restyle doesn't move scroll — leave it.
        } else {
            // No baseline (defensive: shouldn't happen on the typing path).
            // Whole-doc relayout snaps the origin toward the top; capture before
            // and restore after (or re-center when typewriter is on).
            let scrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin
            applyModeTypography(in: storage, tokens: lastTokens, restyleWindow: nil)
            applyFocusDim(in: textView)
            if textView.selectedRange() != selection {
                textView.setSelectedRange(selection)
            }
            if typewriterScroll {
                scrollSelectionToVerticalCenter(in: textView)
            } else if let origin = scrollOrigin,
                      let scrollView = textView.enclosingScrollView,
                      scrollView.contentView.bounds.origin != origin {
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        onElementChanged?(currentElementAbbreviation(in: textView))
    }

    /// Smallest paragraph-aligned character range (in NEW-text coordinates)
    /// covering everything that changed between `old` and `new`, via a common-
    /// prefix / common-suffix scan (the divergence is localized near the edit,
    /// so this is cheap even on a long document). Expanded to whole paragraphs so
    /// paragraph-level attributes re-apply cleanly. Returns nil when identical or
    /// the new text is empty. Token-free, so it works for plain prose.
    private func changedParagraphWindow(old: NSString, new: NSString) -> NSRange? {
        let oldLen = old.length, newLen = new.length
        if newLen == 0 { return nil }
        var prefix = 0
        let maxPrefix = min(oldLen, newLen)
        while prefix < maxPrefix,
              old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix == oldLen, prefix == newLen { return nil }  // identical
        var suffix = 0
        let maxSuffix = min(oldLen, newLen) - prefix
        while suffix < maxSuffix,
              old.character(at: oldLen - 1 - suffix)
                == new.character(at: newLen - 1 - suffix) { suffix += 1 }
        let loc = min(prefix, newLen - 1)
        let len = max(0, min(newLen - prefix - suffix, newLen - loc))
        return new.paragraphRange(for: NSRange(location: loc, length: len))
    }

    /// Posts `.maughamScriptDidUpdate` carrying `script`. When `debounced`,
    /// coalesces to a ~350ms trailing edge (cancel-and-reschedule), so the
    /// scene navigator's deep-compare + per-row walks fire once per typing
    /// burst rather than once per keystroke. When not debounced (whole-doc
    /// callers), cancels any in-flight debounced post first — so a stale
    /// script post can't land AFTER an immediate whole-doc one — then posts
    /// synchronously. `deinit` and `applyExternalText`/`attach` cancel the
    /// pending task, so a doc switch mid-debounce never strands a stale
    /// script post on the new document's navigator.
    private func postScriptDidUpdate(_ script: FountainScript, debounced: Bool) {
        guard debounced else {
            scriptUpdateNotifyTask?.cancel()
            scriptUpdateNotifyTask = nil
            NotificationCenter.default.post(
                name: .maughamScriptDidUpdate, object: script)
            return
        }
        scriptUpdateNotifyTask?.cancel()
        scriptUpdateNotifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.scriptUpdateNotifyTask = nil
            NotificationCenter.default.post(
                name: .maughamScriptDidUpdate, object: script)
        }
    }

    /// Compute `EditorMetrics` for `text` WITHOUT a fresh whole-doc parse on
    /// the screenplay path: the page count reads the keystroke's own
    /// `lastParsedScript`, and the word/character counts come from the same
    /// trimmed whitespace split `WritingMode.metrics` uses (so the footer and
    /// the session/word bookkeeping in `DocumentStore.recordEditorTextWrite`
    /// can't drift apart — both go through `WritingMode.wordCount`). Prose mode
    /// is already parse-free, so it delegates to `mode.metrics` unchanged.
    private func computeMetrics(text: String) -> EditorMetrics {
        guard let script = lastParsedScript else {
            // Prose (and any non-Fountain mode): metrics is parse-free already.
            return mode.metrics(text)
        }
        let words = mode.wordCount(text)
        return EditorMetrics(
            wordCount: words,
            characterCount: (text as NSString).length,
            readingMinutes: words / ScreenplayMode.wordsPerMinute,
            pageCount: script.estimatedPageCount)
    }

    /// Delivers precomputed metrics through `onMetricsChanged`, on the same
    /// timing discipline as `postScriptDidUpdate`: coalesced to a ~350ms
    /// trailing edge while typing (so a burst pays one whitespace split), and
    /// immediate for whole-doc callers (attach / applyExternalText / theme).
    /// The metrics are computed at ARM time and captured into the task, so the
    /// trailing edge can't re-read a since-changed `textView.string`.
    private func deliverMetrics(text: String, debounced: Bool) {
        guard onMetricsChanged != nil else { return }
        guard debounced else {
            metricsNotifyTask?.cancel()
            metricsNotifyTask = nil
            onMetricsChanged?(computeMetrics(text: text))
            return
        }
        // Defer the COMPUTATION to the trailing edge too, not just delivery:
        // computeMetrics' word-count split is O(document), and computing at
        // arm time re-paid it on EVERY keystroke — a live-profile regression
        // (2026-06-10 sample 7: ~20 ms/keystroke at 553 KB) that the debounce
        // was supposed to prevent. Capturing the immutable `text` is free; at
        // fire time it is exactly the last arming keystroke's text
        // (cancel-and-rearm), and `lastParsedScript` matches it — every path
        // that changes the script out-of-band (attach, applyExternalText)
        // cancels this task before posting its own immediate delivery.
        metricsNotifyTask?.cancel()
        metricsNotifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.metricsNotifyTask = nil
            self.onMetricsChanged?(self.computeMetrics(text: text))
        }
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
            isReviewMode: isReviewMode, lockEditing: lockEditing) else {
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

    // MARK: - Tab/Shift+Tab cycle

    private func cycleElementForward(in textView: NSTextView) {
        cycle(in: textView, direction: .forward)
    }

    private func cycleElementBackward(in textView: NSTextView) {
        cycle(in: textView, direction: .backward)
    }

    /// Returns the gutter abbreviation (e.g. "CHAR", "SCENE", "DLG") for
    /// the line containing the current cursor position, or nil when no
    /// screenplay is parsed (prose mode) or the cursor isn't on a classified
    /// line with a label.
    private func currentElementAbbreviation(in textView: NSTextView) -> String? {
        guard let script = lastParsedScript else { return nil }
        let cursor = textView.selectedRange().location
        guard let line = script.lines.first(where: { line in
            line.range.contains(cursor) ||
                cursor == NSMaxRange(line.range)
        }) else {
            return nil
        }
        return ElementGutterView.abbreviation(for: line.element)
    }

    private enum CycleDirection { case forward, backward }

    private func cycle(in textView: NSTextView, direction: CycleDirection) {
        guard let storage = textView.textStorage,
              let script = lastParsedScript else { return }

        // Empty document: no lines in script. Treat as a single blank line
        // at position 0 with .action as the preceding context.
        if script.lines.isEmpty {
            let target: ScreenplayElement
            if let cached = lastCycleTarget {
                target = advance(from: cached, direction: direction)
            } else {
                target = ScreenplayCycle.startingElement(after: .action)
            }
            let neighborhood = LineNeighborhood(prevIsBlank: true, nextIsBlank: true)
            let result = ScreenplayLineMutator.mutate(line: "", to: target, neighborhood: neighborhood)
            let replaceRange = NSRange(location: 0, length: 0)
            guard textView.shouldChangeText(in: replaceRange, replacementString: result.text) else { return }
            isApplyingTabCycle = true
            defer { isApplyingTabCycle = false }
            storage.replaceCharacters(in: replaceRange, with: result.text)
            textView.didChangeText()
            let targetCursor = NSRange(location: result.cursorOffset, length: 0)
            textView.setSelectedRange(targetCursor)
            // Defensive reapply on the next runloop in case something
            // (theme refresh, layout pass) moves the cursor.
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                if textView.selectedRange() != targetCursor {
                    textView.setSelectedRange(targetCursor)
                }
            }
            if result.text.isEmpty {
                lastCycleTarget = target
                lastCycleTargetLineRange = NSRange(location: 0, length: 0)
            } else {
                lastCycleTarget = nil
                lastCycleTargetLineRange = nil
            }
            return
        }

        let cursor = textView.selectedRange().location
        guard let activeLine = lineCovering(cursor: cursor, in: script) else { return }
        guard let lineIndex = script.lines.firstIndex(of: activeLine) else { return }

        let prevElement: ScreenplayElement = (lineIndex > 0)
            ? script.lines[lineIndex - 1].element
            : .action
        let isBlank = activeLine.content.isEmpty

        // Choose target.
        let target: ScreenplayElement = chooseTarget(
            activeLine: activeLine,
            prevElement: prevElement,
            isBlank: isBlank,
            direction: direction)

        // Compute neighborhood from script.
        let prevBlank = (lineIndex <= 0)
            || script.lines[lineIndex - 1].content.isEmpty
        let nextBlank = (lineIndex >= script.lines.count - 1)
            || script.lines[lineIndex + 1].content.isEmpty
        let neighborhood = LineNeighborhood(
            prevIsBlank: prevBlank,
            nextIsBlank: nextBlank)

        // Apply mutator. Note: activeLine.content has forced markers stripped,
        // but the mutator works on raw source content. We need the source text
        // of the line (without trailing newline) to pass to the mutator.
        let nsSource = textView.string as NSString
        let lineRangeLength = activeLine.range.length
        // Determine if the line's range includes a trailing newline.
        let hasTrailingNewline: Bool
        if activeLine.range.location + lineRangeLength <= nsSource.length {
            let lastCharRange = NSRange(
                location: activeLine.range.location + lineRangeLength - 1,
                length: 1)
            if lineRangeLength > 0 {
                let lastChar = nsSource.substring(with: lastCharRange)
                hasTrailingNewline = (lastChar == "\n")
            } else {
                hasTrailingNewline = false
            }
        } else {
            hasTrailingNewline = false
        }
        let sourceContentLength = hasTrailingNewline
            ? lineRangeLength - 1
            : lineRangeLength
        let sourceContent = nsSource.substring(
            with: NSRange(location: activeLine.range.location,
                          length: sourceContentLength))

        let result = ScreenplayLineMutator.mutate(
            line: sourceContent,
            to: target,
            neighborhood: neighborhood)

        // Replace only the line's content portion (not trailing newline).
        let replaceRange = NSRange(
            location: activeLine.range.location,
            length: sourceContentLength)

        // Swift undo + delegate notification dance.
        guard textView.shouldChangeText(in: replaceRange, replacementString: result.text) else { return }
        isApplyingTabCycle = true
        defer { isApplyingTabCycle = false }
        storage.replaceCharacters(in: replaceRange, with: result.text)
        textView.didChangeText()

        let cursorLocation = activeLine.range.location + result.cursorOffset
        let targetCursor = NSRange(location: cursorLocation, length: 0)
        textView.setSelectedRange(targetCursor)
        // Defensive reapply on the next runloop.
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            if textView.selectedRange() != targetCursor {
                textView.setSelectedRange(targetCursor)
            }
        }

        // Update lastCycleTarget lifecycle.
        let newContentLength = (result.text as NSString).length
        let newLineRange = NSRange(
            location: activeLine.range.location,
            length: newContentLength)
        if isBlank && result.text.isEmpty {
            // Line stayed empty — preserve target for subsequent Tab.
            lastCycleTarget = target
            lastCycleTargetLineRange = newLineRange
        } else {
            lastCycleTarget = nil
            lastCycleTargetLineRange = nil
        }
    }

    private func chooseTarget(
        activeLine: FountainLine,
        prevElement: ScreenplayElement,
        isBlank: Bool,
        direction: CycleDirection
    ) -> ScreenplayElement {
        if isBlank, let cached = lastCycleTarget {
            return advance(from: cached, direction: direction)
        }
        if isBlank {
            return ScreenplayCycle.startingElement(after: prevElement)
        }
        return advance(from: activeLine.element, direction: direction)
    }

    private func advance(from element: ScreenplayElement,
                         direction: CycleDirection) -> ScreenplayElement {
        switch direction {
        case .forward:  return ScreenplayCycle.cycleForward(from: element)
        case .backward: return ScreenplayCycle.cycleBackward(from: element)
        }
    }

    private func lineCovering(cursor: Int, in script: FountainScript) -> FountainLine? {
        for line in script.lines {
            let end = line.range.location + line.range.length
            // Match if cursor strictly inside non-zero range, OR exactly at the
            // location of a zero-length line (trailing empty line).
            if line.range.length > 0 && line.range.location <= cursor && cursor < end {
                return line
            }
            if line.range.length == 0 && cursor == line.range.location {
                return line
            }
        }
        return script.lines.last
    }

    private func navigateToLine(at location: Int, in textView: NSTextView) {
        let storage = textView.textStorage
        let length = (storage?.string as NSString?)?.length ?? 0
        let clamped = max(0, min(location, length))
        let range = NSRange(location: clamped, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }

    /// SPIKE (collab review): the selection's bounding rect in TEXT-VIEW
    /// coordinates (the same space as `textView.frame` / a subview's frame),
    /// or nil when the selection is empty.
    ///
    /// `boundingRect(forGlyphRange:in:)` returns container-space coordinates.
    /// The text view offsets its container by `textContainerInset` (the column
    /// is centered horizontally via `.width`, and `.height` is the top inset —
    /// 24pt normally, ~half a viewport under typewriter scroll). Adding the
    /// inset to the rect's origin lands it in view space. This mirrors
    /// `scrollSelectionToVerticalCenter`'s `lineRect.midY + inset.height`
    /// correction and `ElementGutterView`'s `lineRect.origin.y + yOffset`.
    func selectionViewRect(in textView: NSTextView) -> NSRect? {
        let selection = textView.selectedRange()
        guard selection.length > 0,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: selection, actualCharacterRange: nil)
        let containerRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: container)
        let inset = textView.textContainerInset
        return NSRect(
            x: containerRect.origin.x + inset.width,
            y: containerRect.origin.y + inset.height,
            width: containerRect.size.width,
            height: containerRect.size.height)
    }

    /// Drive the floating selection toolbar one-way from the AppKit selection
    /// callback. Show + position above a non-empty selection while review
    /// posture is on; hide otherwise. No SwiftUI state round-trip (tripwire 2):
    /// the toolbar is a plain NSView the coordinator owns by weak reference.
    private func updateSelectionToolbar(in textView: NSTextView) {
        guard let toolbar = selectionToolbar,
              let parent = toolbar.superview else { return }
        // Only surface the toolbar in review posture; in normal authoring the
        // editor stays clean.
        guard isReviewMode, let rectInTextView = selectionViewRect(in: textView)
        else {
            toolbar.isHidden = true
            return
        }
        // Convert the selection rect from text-view coords into the overlay
        // parent's coords. `convert(_:to:)` walks the view tree and accounts
        // for the scroll view's clip/scroll offset automatically, so as the
        // document scrolls the toolbar tracks the on-screen selection.
        let rectInParent = textView.convert(rectInTextView, to: parent)
        // The toolbar is pure-frame (no Auto Layout): it sized itself to its
        // content at construction, so read its actual frame size rather than
        // `fittingSize` (which is .zero for an unconstrained NSView).
        let size = toolbar.frame.size
        let gap: CGFloat = 6
        // Position just ABOVE the selection. AppKit's default coordinate system
        // is y-up (flipped == false for the scroll view's superview), so
        // "above" means a HIGHER maxY. Place the toolbar's bottom edge `gap`
        // above the selection's top edge (rectInParent.maxY).
        var originX = rectInParent.midX - size.width / 2
        var originY = rectInParent.maxY + gap
        // Clamp within the parent's bounds so it never clips off-edge.
        originX = max(parent.bounds.minX,
                      min(originX, parent.bounds.maxX - size.width))
        originY = max(parent.bounds.minY,
                      min(originY, parent.bounds.maxY - size.height))
        toolbar.setFrameOrigin(NSPoint(x: originX, y: originY))
        toolbar.isHidden = false
    }

    // MARK: - Review annotation authoring (Task 3)

    /// Map a `SelectionToolbarView.Kind` to the annotation flow. All three open
    /// the inline composer; Suggest pre-fills it with the selected text so the
    /// reviewer edits it into the replacement.
    private func handleToolbarAction(_ kind: SelectionToolbarView.Kind) {
        switch kind {
        case .comment: beginAuthoringAnnotation(kind: .comment)
        case .query:   beginAuthoringAnnotation(kind: .query)
        case .suggest: beginAuthoringAnnotation(kind: .suggestedChange)
        }
    }

    /// Capture the paragraph id + sub-paragraph span for the current selection,
    /// then present a minimal inline composer. Comment/Query collect a body and
    /// start empty; Suggest pre-fills with the selected text and the reviewer
    /// edits it into the replacement (→ a `.suggestedChange` annotation with
    /// `original` = selected text, `suggestedText` = replacement). No-op if the
    /// selection can't be mapped to a paragraph-relative span.
    private func beginAuthoringAnnotation(kind: AnnotationKind) {
        guard let textView,
              let parent = selectionToolbar?.superview,
              let captured = capturedSpanForSelection(in: textView)
        else { return }

        // Tear down any prior composer before showing a new one.
        annotationComposer?.dismiss()

        let isSuggest = (kind == .suggestedChange)
        let placeholder: String
        switch kind {
        case .comment:         placeholder = "Comment…"
        case .query:           placeholder = "Query…"
        case .suggestedChange: placeholder = "Replacement…"
        default:               placeholder = "Note…"
        }

        let composer = ReviewAnnotationComposerView(
            placeholder: placeholder,
            initialText: isSuggest ? captured.selectedText : "",
            onCommit: { [weak self] value in
                self?.commitAnnotation(
                    kind: kind,
                    paragraphId: captured.paragraphId,
                    span: captured.span,
                    originalText: captured.selectedText,
                    composerValue: value)
            },
            onCancel: { [weak self] in
                self?.annotationComposer?.dismiss()
                self?.annotationComposer = nil
            })
        parent.addSubview(composer)
        annotationComposer = composer

        // Position the composer where the toolbar is (just above the selection),
        // then hide the toolbar so they don't overlap.
        if let toolbar = selectionToolbar {
            composer.setFrameOrigin(toolbar.frame.origin)
            toolbar.isHidden = true
        }
        composer.focus()
    }

    /// Compute (paragraphId, SpanAnchor, selectedText) for the current non-empty
    /// selection, clamped to the paragraph at the selection's start. Returns nil
    /// if the selection is empty, can't be located, or yields no usable span.
    /// `selectedText` is the clamped (within-paragraph) display text — the same
    /// substring the span anchors — used to pre-fill Suggest and as the diff's
    /// original.
    private func capturedSpanForSelection(
        in textView: NSTextView
    ) -> (paragraphId: String, span: SpanAnchor, selectedText: String)? {
        let sel = textView.selectedRange()
        guard sel.length > 0,
              let provider = paragraphRangeAtLocation,
              let located = provider(sel.location) else { return nil }
        let paraStart = located.range.location
        let paraEnd = located.range.location + located.range.length
        guard let relative = ReviewSpanCapture.paragraphRelativeRange(
                absolute: sel.location..<(sel.location + sel.length),
                paragraph: paraStart..<paraEnd) else { return nil }
        // Slice the paragraph's display text out of the textView (the stripped
        // display form — the same form `paragraphRange(at:)` measured).
        let ns = textView.string as NSString
        guard located.range.location >= 0,
              located.range.location + located.range.length <= ns.length
        else { return nil }
        let paragraphText = ns.substring(with: located.range)
        guard let span = ReviewSpanCapture.captureSpan(
                in: paragraphText, relativeUTF16: relative) else { return nil }
        // The selected text is the clamped relative range against the paragraph
        // display text (UTF-16, the same unit `relative` is in).
        let paraNS = paragraphText as NSString
        let selectedText = paraNS.substring(
            with: NSRange(location: relative.lowerBound,
                          length: relative.upperBound - relative.lowerBound))
        return (located.id, span, selectedText)
    }

    /// Commit a composed annotation. Comment/Query use `composerValue` as the
    /// body (empty → cancel). Suggest diffs the composer value against the
    /// original selected text via `SuggestedEditDiff`; an unchanged/empty edit
    /// creates nothing (just dismisses).
    private func commitAnnotation(
        kind: AnnotationKind, paragraphId: String,
        span: SpanAnchor, originalText: String, composerValue: String
    ) {
        annotationComposer?.dismiss()
        annotationComposer = nil

        let body: String
        let suggestedText: String?
        if kind == .suggestedChange {
            guard let diff = SuggestedEditDiff.make(
                    original: originalText, edited: composerValue) else {
                // Unchanged / empty → nothing to suggest.
                restoreToolbarAfterDismiss()
                return
            }
            body = diff.body
            suggestedText = diff.suggestedText
        } else {
            let trimmed = composerValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {  // empty body → cancel
                restoreToolbarAfterDismiss()
                return
            }
            body = trimmed
            suggestedText = nil
        }

        // Await the op-log append, THEN re-pull the annotation set so the new
        // annotation's inline mark + rail card render immediately (no review
        // toggle). The lagged SwiftUI push off `annotationsVersion` stays the
        // reconciler for annotations created elsewhere; this is the deterministic
        // local-create path. The toolbar dismiss is synchronous (UI), independent
        // of the persist.
        if let handler = createAnnotationHandler {
            Task { @MainActor [weak self] in
                await handler(kind, paragraphId, span, body, suggestedText)
                self?.refreshReviewMarksFromProvider()
            }
        }
        restoreToolbarAfterDismiss()
    }

    /// Collapse the selection so the toolbar hides on the next selection pass.
    private func restoreToolbarAfterDismiss() {
        textView?.setSelectedRange(
            NSRange(location: textView?.selectedRange().location ?? 0, length: 0))
        if let textView { updateSelectionToolbar(in: textView) }
    }

    private func scrollSelectionToVerticalCenter(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: textView.selectedRange(),
            actualCharacterRange: nil)
        let lineRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: textContainer)
        guard let scrollView = textView.enclosingScrollView else { return }
        let visible = scrollView.contentView.documentVisibleRect
        // `lineRect` is in text-container coordinates; the text view offsets
        // the container by `textContainerInset.height`. The scroll origin /
        // frame / visible rect are all in view coordinates, so add the inset
        // to land the line's midpoint in the same space. With typewriter
        // scroll on, that inset is ~half a viewport (see refreshTypewriterInset),
        // which is exactly the headroom that lets the first and last lines
        // reach center.
        let lineMidY = lineRect.midY + textView.textContainerInset.height
        // Centering computes negative Y near the top of the document and
        // overshoots near the bottom; clamp to the legitimate document
        // range so NSScrollView doesn't round-trip through a clamped value
        // and produce a visible jump on each keystroke.
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maxY = max(0, documentHeight - visible.height)
        let rawTarget = lineMidY - visible.height / 2
        let clampedY = max(0, min(rawTarget, maxY))
        // Skip the call entirely if we're already within a pixel of the
        // target — avoids a no-op scroll that NSScrollView still treats
        // as a relayout event and which can perturb a typing-mid-paragraph
        // cursor's apparent position.
        if abs(clampedY - visible.origin.y) < 0.5 { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyFocusDim(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        // Review posture turns focus-dim off — the reviewer reads the whole
        // crafted draft, not a dimmed sentence/paragraph window.
        guard !isReviewMode else { return }
        let useSentence = sentenceFocus
        let useParagraph = paragraphFocus && !sentenceFocus
        guard useSentence || useParagraph else { return }

        let cursor = textView.selectedRange().location
        let activeRange = useSentence
            ? FocusFinder.sentenceRange(in: textView.string, cursor: cursor)
            : FocusFinder.paragraphRange(in: textView.string, cursor: cursor)

        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }

        storage.beginEditing()
        if activeRange.location > 0 {
            dim(storage,
                in: NSRange(location: 0, length: activeRange.location))
        }
        let afterStart = NSMaxRange(activeRange)
        if afterStart < fullRange.length {
            dim(storage,
                in: NSRange(location: afterStart,
                            length: fullRange.length - afterStart))
        }
        storage.endEditing()
    }

    private func dim(_ storage: NSTextStorage, in range: NSRange) {
        storage.enumerateAttribute(
            .foregroundColor, in: range, options: []
        ) { value, subrange, _ in
            guard let color = value as? NSColor else { return }
            let dimmed = color.withAlphaComponent(0.4)
            storage.addAttribute(.foregroundColor,
                                  value: dimmed, range: subrange)
        }
    }
}
