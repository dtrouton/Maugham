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

    private(set) var isApplyingExternalUpdate = false
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

    /// A read-only iCloud share, apart from `lockEditing` (which it is one
    /// input of): the figure grid's gate asks it on its own (report plan 7c
    /// Task 8). Use `setShareIsReadOnly(_:)`.
    private(set) var shareIsReadOnly = false

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
    /// Setting it drops the figure-thumbnail marks derived from it, and
    /// derives, in ONE pass, what the per-keystroke and per-caret-move
    /// questions read (whole-branch review M5): the sorted table blocks
    /// (`tableBlockRange(containing:)`) and whether any figure line exists.
    var lastTokens: [Token] = [] {
        didSet {
            figureThumbnailMarksCache = nil
            figureCaptionLinesCache = nil
            tokensDescribeAnEarlierText = false
            var tables: [NSRange] = []
            var figures = false
            var markers: [NSRange] = []
            for token in lastTokens {
                switch token.kind {
                case .tableBlock: tables.append(token.range)
                case .figureSyntax: figures = true
                case .citation, .crossReference, .footnoteReference: markers.append(token.range)
                default: break
                }
            }
            tableBlockRanges = tables.sorted { $0.location < $1.location }
            hasFigureLines = figures
            referenceMarkerTokens = markers.sorted { $0.location < $1.location }
            figureThumbnailTokensDidChange()
        }
    }

    /// The `.tableBlock` ranges in `lastTokens`, sorted (derived with them).
    private(set) var tableBlockRanges: [NSRange] = []
    /// Whether `lastTokens` holds any figure line (derived with them).
    private(set) var hasFigureLines = false
    /// The citation, cross-reference and footnote-reference token ranges in
    /// `lastTokens`, sorted (derived with them): what the label overlay looks
    /// up the visible range in (plan 3b Task 6).
    private(set) var referenceMarkerTokens: [NSRange] = []

    /// True from a character edit to the text storage until the retokenize
    /// that follows it: `lastTokens` then describe the text BEFORE the edit,
    /// so nothing may place an offset against them (whole-branch review I3 —
    /// AppKit posts a selection change inside `replaceCharacters`, before
    /// `textDidChange` retokenizes). Set by `storageEditObserver`, cleared by
    /// `lastTokens`.
    private(set) var tokensDescribeAnEarlierText = false
    /// Watches this editor's text storage for character edits: marks the
    /// tokens stale and carries the table-tidy anchors through the edit.
    private var storageEditObserver: NSObjectProtocol?

    /// The table block containing `location` (its ends included), by binary
    /// search over `tableBlockRanges` — `MarkdownTokenizer.tableBlockRange`'s
    /// answer without a walk of every token.
    func tableBlockRange(containing location: Int) -> NSRange? {
        var lo = 0, hi = tableBlockRanges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tableBlockRanges[mid].location <= location { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let range = tableBlockRanges[lo - 1]
        return location <= NSMaxRange(range) ? range : nil
    }

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

    /// Tables: where the caret's table is, and the leave-the-table tidy
    /// waiting for the next runloop (`EditorCoordinator+Tables.swift`).
    var tableTidy = TableTidyState()

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
    /// (prose) path. See `paintLiveWindowed` and `Maugham/Editor/AREA.md`,
    /// Rules → "Restyle, scroll and typewriter".
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

    /// Observer tokens for the Insert menu's Table (⌘⇧T) and Footnote (⌘⇧N)
    /// (plan 3a Task 4). Key-window scoped like every observer here, and ALSO
    /// gated on `answersInsertCommands`: a research note is a primary editor
    /// that answers the window's other commands, and must not answer these.
    private var insertTableObserver: NSObjectProtocol?
    private var insertFootnoteObserver: NSObjectProtocol?
    /// Insert ▸ Figure… (⌘⇧I, plan 3a Task 6), gated the same way.
    private var insertFigureObserver: NSObjectProtocol?
    /// Insert ▸ Citation… (⌘⇧C, plan 3b Task 3) and Insert ▸
    /// Cross-Reference… (⌘⇧X, Task 4), gated the same way.
    private var insertCitationObserver: NSObjectProtocol?
    private var insertCrossReferenceObserver: NSObjectProtocol?
    /// Insert ▸ Convert to Table Figure (⌘⌥⇧T, report plan 7b Task 5), gated
    /// the same way.
    private var convertTableObserver: NSObjectProtocol?

    /// Whether this editor answers the Insert menu (plan 3a Task 4): true only
    /// for the manuscript editor of a Markdown piece, which `EditorHost` alone
    /// says, through `EditorSurfaceConfiguration.answersInsertCommands`. A
    /// research note, a statement pane and a screenplay say false (the
    /// default). Fixed for the life of a mount; set in `makeCoordinator`.
    /// `InsertCommandTests` counts the files that may name it.
    var answersInsertCommands = false

    /// The cross-reference labels the project's OTHER manuscript documents
    /// define (plan 3a Task 4 fix round 1). **The one shared source** for a
    /// command that mints a label: Insert Table (`tbl:`) and Insert Figure
    /// (`fig:`, Task 6) make theirs unique against these and the live text's
    /// own, because a Report refuses a label defined twice. Built by
    /// `EditorHost` over `ReferenceIndexHost.labelsDefined(excluding:)`
    /// (publishable pieces only): the cached index, or — before its first
    /// build, when it is empty — a walk of the other pieces, so a command is
    /// never told "no labels" by an index that has not looked yet. Asked once
    /// per command, never per keystroke. Nil on every other surface.
    var projectLabelsElsewhere: (() -> Set<ManuscriptLabel>)?

    /// The window's cached reference index (plan 3b Task 1): the project's
    /// citation sources and cross-reference targets with the editor's numbers.
    /// Returns `ReferenceIndexHost`'s cached value; it never builds one, so it
    /// is cheap to ask, but per keystroke ask it only for this document's
    /// markers. Built by `EditorHost`; nil on every other surface.
    var referenceIndex: (() -> ReferenceIndex)?

    /// The index version last applied from `EditorControl.referenceIndexVersion`.
    private(set) var referenceIndexVersion = 0

    /// **The cached card under a figure line** (report plan 7a Task 4): the
    /// path as written → the window's `FigureCardCache` model, nil on a miss.
    /// Memory only, never a disk or op-log read, so the styler may ask it on
    /// both paints (`figureRoom(forLinePath:at:)`). Its redraw trigger is
    /// `EditorControl.figureCardVersion`. Built by `EditorHost`, which knows
    /// the document's path; nil on every other surface.
    var figureCardModel: ((String) -> FigureCardModel?)?

    /// **What a figure line's path names** (report plan 7b Task 7): the path
    /// as written → its `FigureLineResolution.Status` in the window's
    /// `FigureCardCache`, nil before the first fill. Memory only; the problem
    /// check reads it (`ManuscriptChecks.analyse`) and re-reads it on a new
    /// `figureCardVersion`. Built by `EditorHost`; nil on every other surface.
    var figureLineStatus: ((String) -> FigureLineResolution.Status?)?

    /// The card version last applied from `EditorControl.figureCardVersion`.
    private(set) var figureCardVersion = 0
    /// A card version landed mid-burst: the settle paint re-lays out the
    /// figure lines whose room changed (`setFigureCardVersion`).
    var figureRoomsWaitForTheSettle = false
    /// How many figure lines `refreshFigureRooms` has re-laid out (tests read it).
    var figureRoomRefreshCount = 0
    /// The trailing figure's path, whether the grid was expanded on it, and
    /// the room it was given, as of the last `refreshFigureRooms` or
    /// whole-document paint (`figureTrailingRoom`).
    var trailingFigureRoomMemo: (path: String, expanded: Bool, room: CGFloat)?
    /// **The table figure expanded in place into its grid** (report plan 7c
    /// Task 6, `EditorCoordinator+FigureGrid.swift`), nil while every card is
    /// folded. Not observable (tripwire 6): the room, the overlay and the
    /// panel read it.
    var figureGrid: FigureGridExpansion?
    /// How this surface opens a table figure's grid; nil where it never
    /// expands. Wired by `EditorHost` (`FigureGridOpening.window`).
    var figureGridOpening: FigureGridOpening?
    /// How many times `figureTrailingRoom` asked the cards (tests read it).
    var trailingFigureRoomLookupCount = 0

    // MARK: Labels and problem marks (plan 3b Task 6, `ReferenceLabelOverlay.swift`, `ManuscriptChecks.swift`)

    /// The project's profile, which decides a problem mark's colour
    /// (`PublishProblem.isError`). Asked at each check, never per keystroke.
    /// Built by `EditorHost`; nil elsewhere.
    var projectProfile: (() -> ProjectProfile?)?
    /// The label overlay, installed by `syncReferenceLabelOverlay`.
    weak var referenceLabelOverlay: ReferenceLabelOverlay?

    // MARK: The caption bar (report plan 7b Task 8, `ReferenceLabelOverlay.swift`)

    /// The tables and figures the book numbers before this document's first
    /// (`ReferenceIndex.numbersBefore(docId:)`), read off the cached index;
    /// nil before the index has read this piece, and then no caption number
    /// is drawn. Built by `EditorHost`; nil on every other surface.
    var figureNumbersBefore: (() -> ReferenceIndex.NumbersBefore?)?
    /// The figure lines in `lastTokens` with their syntax ranges and their
    /// ordinals in this document (`FigureCaptionBar.lines`), derived once per
    /// retokenize on first ask (tripwire 4). Cleared by `lastTokens`.
    var figureCaptionLinesCache: [FigureCaptionBar.Line]?
    /// The syntax ranges the caret's figure line is shown at full colour on,
    /// as layout-manager temporaries (`refreshFigureSyntaxUnfade`); empty in
    /// translation review, which owns every temporary foreground colour.
    var unfadedFigureSyntax: [NSRange] = []
    /// True from a character edit while `unfadedFigureSyntax` is held: the
    /// edit may have moved the temporaries, so their next removal clears the
    /// whole text's temporary foreground (exact outside translation review,
    /// where the un-fade is the only one) — at most once per character edit,
    /// never on a caret move (`figureSyntaxUnfadeWholeClears`). Until then,
    /// characters typed right after a shown run may draw in its `shown`
    /// colour; the settle's forced refresh puts the run where it is now
    /// (accepted: transient, display only).
    var unfadedFigureSyntaxIsStale = false
    /// How many times the un-fade cleared the whole text's temporary
    /// foreground after an edit (tests read it).
    var figureSyntaxUnfadeWholeClears = 0
    /// How many times the un-fade actually moved (tests read it: a caret move
    /// along one line moves nothing).
    var figureSyntaxUnfadeMoves = 0
    /// Each footnote's number in this document, from the last check (keyed
    /// by label, so it never drifts while a burst is typed).
    var footnoteNumbers: [String: Int] = [:] {
        didSet { referenceLabelOverlay?.needsDisplay = true }
    }
    /// The marker groups of each block the label overlay has read, keyed by
    /// the block's text, bounded by the total length of those keys
    /// (`referenceGroupCacheBudget`, whole-branch review M5).
    var referenceGroupCache: [String: [ManuscriptChecks.Group]] = [:]
    /// The UTF-16 length of `referenceGroupCache`'s keys.
    var referenceGroupCacheLength = 0
    /// The most text, in UTF-16 units, the group cache keys may hold: 1 MB.
    static let referenceGroupCacheBudget = 512 * 1024
    /// The problems the last check found, underlined.
    var problemMarks: [ManuscriptChecks.Problem] = []
    /// How many times the checks have run (the settle test's counter).
    var problemCheckCount = 0
    /// The problem underlines' tooltips and their owner.
    var problemTooltips: ProblemTooltips?

    // MARK: The completion list (plan 3b Task 2, `EditorCoordinator+Completion.swift`)

    /// The sources that may open the completion list, asked in this order
    /// (citation first, then cross-reference — Tasks 3 and 4 register them).
    /// Empty on every surface that registers none.
    var completionSources: [any CompletionSource] = []
    /// The list view, a scroll-view subview installed by `EditorSurface`.
    weak var completionList: CompletionListView?
    /// The open list's state; nil while closed.
    var completion: CompletionState?
    /// What the edit `shouldChangeTextIn` last let through was; read once by
    /// `textDidChange`.
    var completionEditNote: CompletionEditNote?
    /// True from a keystroke or caret move until the next runloop: a scroll
    /// then follows the caret, and moves the list rather than closing it.
    var completionCaretIsMoving = false
    /// The scroll, resize and resign-key observers, armed while the list is open.
    var completionObservers: [NSObjectProtocol] = []
    /// True while `applyCommandEdit` writes, so its edit is never read as typing.
    var isApplyingCommandEdit = false
    /// True while a paste or a drop is handed to AppKit (`asNotTyping`), so a
    /// pasted `@` is never read as typing.
    var isInsertingNotTyping = false

    /// Makes a picture an image figure of this document and returns the
    /// figure path relative to the document (plan 3a Task 6, report plan 6a
    /// Task 9, `FigureIngest.importImage`). Built by `EditorHost`; nil on every other
    /// surface, which is what keeps their drop and paste unchanged.
    var figureImporter: FigureIngest.Importer?

    /// Makes Insert ▸ Table's and Convert to Table Figure's figures in this
    /// document's piece and answers them (report plan 7b Tasks 4–5,
    /// `FigureIngest.makeTableFigure`). Built by `EditorHost`; nil on every
    /// other surface, where ⌘⇧T and ⌘⌥⇧T do nothing.
    var tableFigureMaker: FigureIngest.TableFigureMaker?

    /// Where a command that could not finish is told — a figure that could
    /// not be made — the host's notice banner, the
    /// channel the editor's other failures use.
    var commandFailureReporter: (@MainActor (String) -> Void)?

    /// The most recent figure ingest, so a caller (a test) can await it
    /// instead of polling.
    var figureIngestTask: Task<Void, Never>?
    /// The most recent Insert ▸ Table or Convert to Table Figure, so a caller (a test) can await it
    /// instead of polling.
    var tableFigureTask: Task<Void, Never>?
    /// The most recent figure-birth undo or redo's store verb
    /// (`figureBirthUndo`), so a caller (a test) can await it.
    var figureBirthUndoTask: Task<Void, Never>?
    /// How a landed figure waits out an input method's composition: a short
    /// sleep, so a composition of a few seconds is outlasted without spinning
    /// (`beginFigureIngest`). A test hands in its own, so nothing waits on a
    /// clock.
    var figureCompositionWait: () async -> Void = {
        try? await Task.sleep(for: .milliseconds(100))
    }
    /// How many waits before the figure gives up: about 30 seconds.
    var figureCompositionWaitLimit = 300

    /// Resolves a figure path as written to its image file, from THIS
    /// document's own path (plan 3a Task 7, `FigureImageResolver`). Built by
    /// `EditorHost`, which knows the document's project-relative path and the
    /// project URL; nil on every other surface, which therefore draws no
    /// thumbnail. Called off the main thread (it stats the disk).
    var figureImageResolver: FigureThumbnailStore.Resolve?
    /// The thumbnail overlay, installed by `syncFigureThumbnailOverlay` when
    /// this surface shows thumbnails (`FigureThumbnailOverlay.swift`).
    weak var figureThumbnailOverlay: FigureThumbnailOverlay?
    /// Decoded thumbnails and what each written path resolved to. Made with
    /// the overlay; the overlay reads it per draw, and it never blocks.
    var figureThumbnailStore: FigureThumbnailStore?
    /// The figure lines in `lastTokens`, derived on the first draw after a
    /// retokenize (never per draw, tripwire 4). Cleared by `lastTokens`.
    var figureThumbnailMarksCache: [FigureThumbnailLayout.Mark]?
    /// The last `figureTrailingRoom` the text view was sized with.
    var lastFigureTrailingRoom: CGFloat = 0

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
    var checkboxToggleHandler: ((String, Int, DocumentFormat) -> Void)?

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
    /// The posture the margin card's dispositions follow (P3c Task 5) —
    /// `EditorControl.posture`, set only through `updateReviewCardVerbs(for:)`.
    var reviewCardPosture: Posture?

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
    /// `maughamToggleReviewMode`, `maughamEnterTranslationReview`,
    /// `maughamExitTranslationReview`, and the Insert menu's
    /// `maughamInsertTable`, `maughamInsertFootnote`, `maughamInsertFigure`,
    /// `maughamInsertCitation`, `maughamInsertCrossReference` and
    /// `maughamConvertTable` (which also ask `answersInsertCommands`) — count the
    /// `MaughamEvent.observe` calls rather than this sentence.
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
                self.selectFindMatch(match.charRangeInDocument, in: textView)
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
            self.forceFoldFigureGrid(.navigation)   // the jump wins over an expanded grid
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
        // The Insert menu (plan 3a Task 4). The context asks the manuscript-
        // surface gate on top of the key-window one, so a research note — a
        // primary editor, `respondsToWindowCommands` true — never answers.
        insertTableObserver = MaughamEvent.observe(
            .maughamInsertTable,
            context: { [weak self] in self?.insertCommandContext() }
        ) { [weak self] _ in
            self?.insertTableFigure()
        }
        insertFootnoteObserver = MaughamEvent.observe(
            .maughamInsertFootnote,
            context: { [weak self] in self?.insertCommandContext() }
        ) { [weak self] _ in
            self?.insertFootnote()
        }
        insertFigureObserver = MaughamEvent.observe(
            .maughamInsertFigure,
            context: { [weak self] in self?.insertCommandContext() }
        ) { [weak self] _ in
            self?.insertFigure()
        }
        insertCitationObserver = MaughamEvent.observe(
            .maughamInsertCitation,
            context: { [weak self] in self?.insertCommandContext() }
        ) { [weak self] _ in
            self?.insertCitation()
        }
        insertCrossReferenceObserver = MaughamEvent.observe(
            .maughamInsertCrossReference,
            context: { [weak self] in self?.insertCommandContext() }
        ) { [weak self] _ in
            self?.insertCrossReference()
        }
        convertTableObserver = MaughamEvent.observe(
            .maughamConvertTable,
            context: { [weak self] in self?.insertCommandContext() }
        ) { [weak self] _ in
            self?.convertTableToFigure()
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
        if let token = insertTableObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = insertFootnoteObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = insertFigureObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = insertCitationObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = insertCrossReferenceObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = convertTableObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = storageEditObserver {
            NotificationCenter.default.removeObserver(token)
        }
        for token in completionObservers {
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
        observeStorageEdits(of: textView)
        retokenizeAndStyle()
        // The figure thumbnails (plan 3a Task 7), on a surface that shows them.
        syncFigureThumbnailOverlay()
        // The resolved labels (plan 3b Task 6), above the thumbnails.
        syncReferenceLabelOverlay()
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
        // An expanded grid folds first, while the text view is still here:
        // its open edit committed, or said as a notice when it will not read.
        forceFoldFigureGrid(.teardown)
        isDetached = true
        scriptUpdateNotifyTask?.cancel(); scriptUpdateNotifyTask = nil
        metricsNotifyTask?.cancel(); metricsNotifyTask = nil
        deferredRestyleTask?.cancel(); deferredRestyleTask = nil
        tableTidy.cancelPending()
        figureThumbnailStore?.cancelAll()
        problemTooltips?.removeAll(from: textView)
        closeCompletion()
        disarmCompletionObservers()
        // Explicit liveness contract (ADR 0021): drop the scoped-event tokens on
        // teardown so a coordinator SwiftUI hasn't yet released stops receiving
        // deliveries. `receiverContext` also returns nil once `isDetached`, so
        // this is belt-and-suspenders with the deinit removal (which stays).
        for token in [navigateObserver, findMatchObserver, paragraphNavigateObserver,
                      annotationNavigateObserver, reviewToggleObserver,
                      translationEnterObserver, translationExitObserver,
                      insertTableObserver, insertFootnoteObserver, insertFigureObserver,
                      insertCitationObserver, insertCrossReferenceObserver, convertTableObserver] {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        navigateObserver = nil; findMatchObserver = nil; paragraphNavigateObserver = nil
        annotationNavigateObserver = nil; reviewToggleObserver = nil
        translationEnterObserver = nil; translationExitObserver = nil
        insertTableObserver = nil; insertFootnoteObserver = nil; insertFigureObserver = nil
        insertCitationObserver = nil; insertCrossReferenceObserver = nil; convertTableObserver = nil
        if let token = storageEditObserver { NotificationCenter.default.removeObserver(token) }
        storageEditObserver = nil
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
        completionList = nil
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
        // A replaced buffer ends any completion the writer was in.
        closeCompletion()
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
        // A sync is not the writer leaving a table: forget the table and any
        // pending tidy, so no tidy follows that the writer didn't cause.
        tableTidy.anchor = nil
        tableTidy.cancelPending()
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
        let gridLine = figureGrid.map { ($0.lineLocation, textView.string) }
        textView.string = text
        // The expanded grid's line, followed through the replace by a line
        // diff (report plan 7c Task 6): kept, rewritten, or gone.
        if let (line, oldText) = gridLine {
            figureGrid?.followReplacement(of: line, old: oldText, new: text)
        }
        let clamped = NSRange(
            location: min(oldSelection.location, text.utf16.count),
            length: 0
        )
        textView.setSelectedRange(clamped)
        retokenizeAndStyle()
        // The clamp is not a move the caret-left fold should see later.
        figureGrid?.textSelection = textView.selectedRange()
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
        // Every line moved: the problem tooltips follow (whole-branch review M1).
        rebuildProblemTooltipsIfTheColumnMoved(in: textView)
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
        closeCompletionIfTheMembraneRefuses()
        refreshFigureGridAccess()
    }

    /// The share's read-only flag (`EditorControl.shareIsReadOnly`).
    /// Self-guarded (D2); only the figure grid's gate reads it.
    func setShareIsReadOnly(_ readOnly: Bool) {
        guard shareIsReadOnly != readOnly else { return }
        shareIsReadOnly = readOnly
        refreshFigureGridAccess()
    }

    /// Whether a checkbox click may flip its bracket: the membrane's answer
    /// for a click (`EditorEditPolicy.allowsCheckboxToggle`), read from the
    /// coordinator's own stored flags — no new state (tripwire 2).
    var allowsCheckboxToggle: Bool {
        EditorEditPolicy.allowsCheckboxToggle(
            lockEditing: lockEditing, isTranslationReview: isTranslationReview)
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
        closeCompletionIfTheMembraneRefuses()
        refreshFigureGridAccess()
        // Translation review shows no caret line's syntax (its dimming owns
        // the temporary foreground); leaving it shows the caret's line again.
        refreshFigureSyntaxUnfade(force: true)
        return true
    }

    func setReviewMode(_ enabled: Bool) {
        guard isReviewMode != enabled else { return }
        isReviewMode = enabled
        closeCompletionIfTheMembraneRefuses()
        refreshFigureGridAccess()
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
            _ = control.shareIsReadOnly
            _ = control.isReviewMode
            _ = control.posture
            _ = control.theme
            _ = control.typography
            _ = control.typewriterScroll
            _ = control.sentenceFocus
            _ = control.paragraphFocus
            _ = control.reviewAnnotations
            _ = control.translationLanguage
            _ = control.translationBadges
            _ = control.referenceIndexVersion
            _ = control.figureCardVersion
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
        setShareIsReadOnly(c.shareIsReadOnly) // self-guarded
        setReviewMode(c.isReviewMode)        // self-guarded
        updateReviewCardVerbs(for: c.posture) // self-guarded
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
        setReferenceIndexVersion(c.referenceIndexVersion)   // self-guarded
        setFigureCardVersion(c.figureCardVersion)           // self-guarded
    }

    /// The reference index changed (a new version arrived through
    /// `EditorControl`). Self-guarded (D2). What the editor draws from the
    /// index repaints from here (Task 6); the index itself is re-read through
    /// `referenceIndex`, never pushed.
    func setReferenceIndexVersion(_ version: Int) {
        guard version != referenceIndexVersion else { return }
        referenceIndexVersion = version
        // Temporaries and the visible labels only, never a restyle (D1).
        refreshProblemMarks()
        referenceLabelOverlay?.needsDisplay = true
        // An open picker's rows follow the new index (whole-branch review M2).
        requeryOpenCompletion()
    }

    /// The window's figure cards changed (a new version arrived through
    /// `EditorControl`). Self-guarded (D2). The cards themselves are re-read
    /// through `figureCardModel`, never pushed.
    ///
    /// The figure lines whose room changed re-lay out here
    /// (`refreshFigureRooms`, report plan 7a Task 5), and the figure-line
    /// diagnostics re-check (`refreshProblemMarks`, plan 7b Task 7: a figure
    /// removed or restored elsewhere) — but never inside a typing burst:
    /// while one is in flight both wait for the burst's settle paint
    /// (`performDeferredRestyle`), which runs each once.
    func setFigureCardVersion(_ version: Int) {
        guard version != figureCardVersion else { return }
        figureCardVersion = version
        // The expanded grid's book and room (report plan 7c Task 6) first,
        // so the re-layout below carries a room that grew.
        figureGridCardsChanged()
        if isInTypingBurst {
            figureRoomsWaitForTheSettle = true   // the settle checks the problems anyway
        } else {
            refreshFigureRooms()
            refreshProblemMarks()
        }
    }

    /// A typing burst is in flight: its settle paint is pending, its baseline
    /// is held, or a character edit has not yet been retokenized. A baseline
    /// held for an edit that never landed parks the work until the next
    /// settle or whole-document paint, which runs or covers it.
    var isInTypingBurst: Bool {
        deferredRestyleTask != nil || burstBaselineText != nil || tokensDescribeAnEarlierText
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

        // The completion trigger (plan 3b Task 2): what this edit is — a typed
        // character, a deletion, or anything else — read by `textDidChange`.
        noteEditForCompletion(in: textView, replacing: affectedCharRange, with: replacementString)

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
        // The completion list's keys come first (plan 3b Task 2): with it open,
        // Tab and Return accept even in a table cell; closed, they fall through
        // to the arms below untouched. `complete:` is swallowed in prose.
        if handleCompletionCommand(commandSelector, in: textView) { return true }
        // Prose: Tab, Shift-Tab and Return move through and grow a table when
        // the caret is in one; anywhere else they fall through to AppKit.
        guard mode is ScreenplayMode else {
            // Return inside a table figure's line expands its grid (R7c-3).
            if handleFigureGridCommand(commandSelector, in: textView) { return true }
            return handleTableCommand(commandSelector, in: textView)
        }

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
        // NOTE: the typing fast path never paints the whole document on the
        // keystroke (prose defers to the burst-settle — `scheduleDeferredRestyle`;
        // screenplay paints live but windowed — `paintLiveWindowed`). With no
        // per-keystroke whole-range setAttributes there is no layout
        // invalidation to snap the scroll origin toward the top, so the old
        // capture-and-restore-the-origin workaround is gone from here — it was
        // actively fighting AppKit's own caret-following autoscroll (the
        // "recoil on the last line" + "caret runs off the bottom" bugs). The
        // settle paint is windowed too; only `performDeferredRestyle`'s
        // no-baseline fallback relayouts the whole document, and it guards the
        // origin itself (`Maugham/Editor/AREA.md`, Rules → "Restyle, scroll and
        // typewriter").
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
        // The selection changes AppKit posted inside the edit were read
        // against stale tokens and ignored (`noteSelectionForTableTidy`); read
        // the caret's table once more now the tokens describe this text.
        noteSelectionForTableTidy(in: textView)
        // The completion list (plan 3b Task 2), with fresh tokens and the
        // caret final: open on a typed trigger, follow, or close.
        completionTextDidChange(in: textView)
    }

    /// One observer per attach on the storage's `didProcessEditing`, which
    /// `NSTextStorage` posts for every character edit, whoever makes it, BEFORE
    /// its layout managers (and so the text view's selection) hear of it.
    private func observeStorageEdits(of textView: NSTextView) {
        if let token = storageEditObserver { NotificationCenter.default.removeObserver(token) }
        storageEditObserver = nil
        guard let storage = textView.textStorage else { return }
        storageEditObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { [weak self] note in
            guard let storage = note.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            let range = storage.editedRange, delta = storage.changeInLength
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tokensDescribeAnEarlierText = true
                if !self.unfadedFigureSyntax.isEmpty { self.unfadedFigureSyntaxIsStale = true }
                self.tableTidy.noteEdit(editedRange: range, changeInLength: delta)
                self.figureGrid?.noteEdit(editedRange: range, changeInLength: delta)
            }
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
        // The caption bar: the caret's figure line shows its syntax, on
        // temporaries over at most two lines — no storage edit, no re-layout.
        refreshFigureSyntaxUnfade()
        onCursorChanged?(textView.selectedRange().location)
        onElementChanged?(currentElementAbbreviation(in: textView))
        // One-way drive of the floating selection toolbar (review posture only).
        // No write-back into SwiftUI state.
        updateSelectionToolbar(in: textView)
        // A caret that leaves a table schedules its tidy for the next runloop.
        noteSelectionForTableTidy(in: textView)
        // An open completion list follows a caret inside its trigger, and
        // closes on one that leaves it.
        completionSelectionDidChange(in: textView)
        // A caret leaving an expanded grid's line folds it, as a navigation.
        figureGridSelectionDidChange(in: textView)
    }

    /// AppKit's own completion (`complete:`, which F5 or a direct call reaches) is never
    /// offered in prose: the completion list is the editor's (plan 3b Task 2).
    func textView(_ textView: NSTextView, completions words: [String],
                  forPartialWordRange charRange: NSRange,
                  indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
        mode is ScreenplayMode ? words : []
    }

}
