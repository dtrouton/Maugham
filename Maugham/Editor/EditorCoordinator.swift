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
    var createAnnotationHandler: ((AnnotationKind, String, SpanAnchor, String, String?) -> Void)?

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
    /// Cached, resolved-to-absolute marks. Recomputed when the annotation set or
    /// the text changes — never per draw (tripwire 4). The overlay views read
    /// this directly.
    private(set) var resolvedReviewMarks: [ResolvedReviewMark] = []
    private let reviewPalette = ReviewPalette()

    /// Inline-mark overlay + right-margin rail, installed lazily on the text
    /// view (like the gutter) and shown only in review mode.
    private weak var markRenderer: AnnotationMarkRenderer?
    private weak var marginRail: ReviewMarginRailView?

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
    }

    deinit {
        scriptUpdateNotifyTask?.cancel()
        metricsNotifyTask?.cancel()
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
        if let token = reviewToggleObserver {
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

    // MARK: - Crafted review render wiring (Task 5)

    /// Push the open-annotation set for the crafted review render. Called
    /// ONE-WAY from EditorSurface.updateNSView. Recomputes resolved marks (and
    /// redraws the overlays) only when the set actually changed — updateNSView
    /// runs every layout pass, so this is guarded against no-op churn the same
    /// way `setReviewMode` is.
    func setReviewAnnotations(_ annotations: [Annotation]) {
        guard annotations != reviewAnnotations else { return }
        reviewAnnotations = annotations
        recomputeReviewMarks()
        refreshReviewOverlays()
    }

    /// Resolve every review annotation to absolute UTF-16 coordinates against the
    /// current display string. Span-anchored marks get an `absoluteRange`;
    /// paragraph-level / stale-span ones are rail-only (`absoluteRange == nil`)
    /// but still anchored at the paragraph start. Cached in `resolvedReviewMarks`;
    /// the overlay draws read the cache, never recompute (tripwire 4).
    private func recomputeReviewMarks() {
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
                suggestedText: ann.suggestedText))
        }
        resolvedReviewMarks = marks
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
        // Capture the pre-restyle tokens BEFORE we overwrite `lastTokens`, so
        // the window diff compares old→new. nil when not windowing.
        let priorTokens = lastTokens
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
        // On the typing fast path, restrict structural attribute application to
        // the classification-changed window (diffed old→new tokens). Any
        // structural inconsistency falls back to whole-doc (window == nil).
        // NSTextStorage shifts attributes with the text automatically, so the
        // unchanged head/tail of the document keeps its (already correct)
        // attributes and only the window is re-applied. See TokenRestyleWindow.
        var restyleWindow: NSRange? = nil
        if windowedTyping {
            switch TokenRestyleWindow.decide(
                oldTokens: priorTokens,
                newTokens: tokens,
                storageLength: storage.length) {
            case .noChange:
                // Identical (kind,length) stream: attributes already correct.
                // Apply an empty window so the modes do no structural writes.
                restyleWindow = NSRange(location: 0, length: 0)
            case .window(let range):
                restyleWindow = range
            case .fullDocument:
                restyleWindow = nil
            }
        }
        // ProseMode supports an optional wiki-link resolver for `[[Title]]`
        // styling. Other modes use the protocol's resolver-less call.
        if let prose = mode as? ProseMode {
            prose.applyTypography(
                in: storage,
                theme: theme,
                typography: typography,
                tokens: tokens,
                wikiLinkResolver: wikiLinkResolver,
                restyleWindow: restyleWindow)
        } else {
            mode.applyTypography(
                in: storage,
                theme: theme,
                typography: typography,
                tokens: tokens,
                parsedScript: lastParsedScript,
                restyleWindow: restyleWindow)
        }
        // Sync typing attributes so the caret on empty lines matches the
        // body font/paragraph style instead of the system default.
        textView.typingAttributes = mode.bodyTypingAttributes(
            theme: theme, typography: typography)
        // Text changes require re-dim. The textDidChange path delegates here;
        // no separate dim call needed.
        applyFocusDim(in: textView)
        // Fire element callback: text edits can reclassify the line under the
        // cursor without moving the selection, so we must fire here too (not
        // only from textViewDidChangeSelection).
        onElementChanged?(currentElementAbbreviation(in: textView))
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
        guard EditorEditPolicy.allowsTextMutation(isReviewMode: isReviewMode) else {
            return false
        }
        guard let replacementString,
              !isApplyingExternalUpdate else { return true }

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
        // Capture the scroll origin BEFORE retokenizeAndStyle. NSTextView has
        // already scrolled to keep the just-typed caret visible by the time
        // textDidChange fires, so this origin is the correct, caret-visible
        // position. retokenizeAndStyle's full-range setAttributes invalidates
        // the entire layout, and on a long scrolled document AppKit snaps the
        // origin toward the top during the relayout (visible as a jump-to-top-
        // then-back, most often on space/delete since those change the wrapped
        // line count). When typewriterScroll is on, scrollSelectionToVerticalCenter
        // re-asserts a sane origin below and masks this; when it's off, we
        // restore the captured origin ourselves. Symmetric with the caret
        // capture-and-restore just above.
        let preRestyleScrollOrigin = textView.enclosingScrollView?
            .contentView.bounds.origin
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
        } else if let origin = preRestyleScrollOrigin,
                  let scrollView = textView.enclosingScrollView,
                  scrollView.contentView.bounds.origin != origin {
            // The full-range restyle perturbed the scroll origin; put it back.
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
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

        createAnnotationHandler?(kind, paragraphId, span, body, suggestedText)
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
