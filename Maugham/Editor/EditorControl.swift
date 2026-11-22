import Foundation
import MaughamCore
import Observation

/// First-class model for editor CONTROL state — the configuration the editor
/// needs that is NOT the manuscript text. The data plane (text) is owned by
/// `Document`; this is its control-plane analogue (ADR 0017).
///
/// `ProjectWindow` owns one of these and mirrors its derived control into it;
/// the `EditorCoordinator` observes it via `withObservationTracking`. Control
/// flows one way (sources → model → coordinator). The coordinator writes back
/// only two `@ObservationIgnored` facts nothing observes: which document it
/// has mounted (`editorDidMount`/`editorDidDetach`), and clearing the
/// `pendingPlace` it consumes (shell p1 Task 4b).
///
/// INVARIANT D1: only genuine control state lives here — never text- or
/// cursor-derived values. If a per-keystroke value leaked in, the coordinator's
/// observation would fire on the typing hot path.
@Observable
final class EditorControl {
    // Posture (membrane).
    var isReviewMode: Bool = false
    var lockEditing: Bool = false
    /// **A read-only iCloud share** — one of `lockEditing`'s two inputs, kept
    /// apart because a table figure's grid answers to it on its own (report
    /// plan 7c Task 8, `FigureGridGate`): the cells follow the figure's
    /// posture and the share, never the text's lock. Mirrored with the
    /// membrane (`EditorControlMirror.Membrane`).
    var shareIsReadOnly: Bool = false
    /// **What this window may offer for the document in the editor** (P3c Task
    /// 5) — mirrored from the drawing posture door with the membrane above, so
    /// the margin card's dispositions follow a demotion or a promotion with no
    /// reopen (`ReviewCardActions.actions(for:isOwn:posture:)`). Nil: no
    /// posture known (no manuscript document selected, a research note) — the
    /// card draws the fail-closed set, her own note's Edit and Delete and no
    /// disposition (P3c plan 2 Task 8), and the Document's own door refuses
    /// anyway.
    var posture: Posture? = nil

    /// **The pieces in read-through on this Mac** (`ReadThroughStore`),
    /// mirrored one way by `EditorControlMirrorModifier`. The editor asks it
    /// about the document its buffer holds (`ReadThrough.isOn(documentId, …)`),
    /// never about the window's subject. Moves only at Start or Resume (D1).
    var readThroughDocIds: Set<String> = []

    /// **The pieces in read-through whose checkpoint was not saved**
    /// (`ReadThroughStore.piecesLackingCheckpoint`), mirrored beside
    /// `readThroughDocIds`. Read by `EditorHost`'s line alone; the coordinator
    /// never reads it.
    var readThroughLackingCheckpoint: Set<String> = []

    /// **Whether the review render is drawn for `docId`**: the review forced
    /// where the posture refuses the text, or the piece in read-through. The
    /// one rule the coordinator and `EditorHost`'s open-annotation mirror ask.
    func reviewRenders(docId: String?) -> Bool {
        isReviewMode || ReadThrough.isOn(docId, in: readThroughDocIds)
    }

    /// **The offer the line over the text draws for `docId`**, nil where it
    /// draws nothing: a piece not in read-through, or one read in a
    /// translation (whose own line stands there instead).
    func readThroughLineOffer(docId: String) -> ReadThroughOffer? {
        guard translationLanguage == nil, ReadThrough.isOn(docId, in: readThroughDocIds) else {
            return nil
        }
        return .on(docId: docId, lacksCheckpoint: readThroughLackingCheckpoint.contains(docId),
                   mayTakeCheckpoint: ReadThroughOffer.mayTakeCheckpoint(
                    posture: posture, shareIsReadOnly: shareIsReadOnly))
    }

    /// The language the open piece is read in, or nil when the editor shows
    /// the source manuscript (shell p4 Task 8: the toolbar's language switch,
    /// View ▸ Read In, ⌃⌘L and a reveal write it; nothing writes back).
    /// Non-nil ⇒ the editor shows the read-only translated surface: the
    /// coordinator flips its membrane (via `applyControl` →
    /// `setReadingTranslation`) and EditorHost swaps in the derived surface.
    /// One-way (sources → model → coordinator). Genuine control state —
    /// never text-/cursor-derived (D1).
    var translationLanguage: String? = nil

    /// **Whether a translation is drawn with its source under each
    /// paragraph** (shell p4 Task 8; View ▸ Show Source Under Translation, on
    /// by default, remembered per project in `UIState`). Read by EditorHost
    /// alone, which re-derives the surface when it changes; the coordinator
    /// never reads it — the surface's ranges carry the source.
    var showsSourceUnder: Bool = true

    /// **Moves on each translation write heard for the open piece** (shell p4
    /// Task 8 fix I4): EditorHost's trailing-edge refresh of a translated
    /// surface is keyed on it with the document's `annotationsVersion`.
    /// Written by EditorHost alone; the coordinator never reads it. D1-safe:
    /// a translation write, never a keystroke.
    var translationRevision: Int = 0

    // Appearance.
    var theme: Theme = .light
    var typography: TypographySettings = .defaults
    var typewriterScroll: Bool = false
    var sentenceFocus: Bool = false
    var paragraphFocus: Bool = false

    // Review render set (open annotations shown in review posture).
    var reviewAnnotations: [Annotation] = []

    /// **The margin's marks for the open piece** (shell p5 Task 2, View ▸
    /// Margin): built by the window's `MarginMirrorModifier` once per key —
    /// the piece's `annotationsVersion`, the sidecar's version, the setting,
    /// To resolve's selection, focus mode, the language, the review render —
    /// never per keystroke (D1). `.none` while the setting is Off.
    var margin: MarginMarks = .none

    /// Ordered per-paragraph translation freshness for the staleness-badge
    /// overlay + the dimmed-missing treatment (Task 12). Each entry carries its
    /// own rendered TEXT (`translatedText ?? sourceText`), the same string
    /// EditorHost joins to build the translated buffer — so this is the same
    /// bytes as that joined surface, just chunked per paragraph rather than
    /// pushed as one flat string; not new text-derived control state. `.empty`
    /// when no translation is read. Threaded ONE-WAY (sources → model →
    /// coordinator) on EXPLICIT translation events only — a language change, an
    /// `annotationsVersion` tick while in the posture, or a re-mount — never off
    /// `displayText`. D1-safe for the same reason `translationLanguage` /
    /// `reviewAnnotations` are: the translation-review surface is READ-ONLY, so
    /// this never changes on the typing hot path. The coordinator's
    /// `TranslationBadgeLayout.ranges` accumulates offsets directly over these
    /// entries' texts, so it maps cleanly onto the live surface without
    /// re-splitting a joined string.
    var translationBadges: TranslationBadgeModel = .empty

    /// **The version of the window's reference index** (plan 3b Task 1): the
    /// redraw trigger for what the editor draws from the project's sources
    /// and targets (the faint labels and problem marks, Task 6). The index
    /// itself is read through `EditorSurface.ParagraphProviders.referenceIndex`;
    /// this only says it changed. Written one-way by the window's
    /// `ReferenceIndexWiring` alone, off `ReferenceIndexHost.onVersionChange`; the research note and statement
    /// hosts have no index and leave it 0. D1-safe: it moves on a research
    /// edit, a binder change, another piece's sync or the open document's
    /// settle (the 350 ms metrics edge), and only when a source or target
    /// actually changed — never per keystroke.
    var referenceIndexVersion: Int = 0

    /// **The version of the window's figure cards** (report plan 7a Task 4):
    /// the re-layout trigger for the room under each table figure line. The
    /// cards themselves are read through `EditorSurface.ParagraphProviders.figureCardModel`;
    /// this only says one changed. Written one-way by `EditorHost` alone, off
    /// `FigureCardCache.onVersionChange`; `ProjectWindow`'s mirror, the
    /// research note and the statement hosts have no cards and leave it 0.
    /// D1-safe: it moves when a fill lands (a figure's host appending, a
    /// remote figure change, the registry or trust changing), off the typing
    /// path — never per keystroke.
    var figureCardVersion: Int = 0

    /// **A place waiting for its document** (shell p1 Task 4b): the one
    /// pending "go to a paragraph" (or a slugline's line) whose piece the
    /// mounted editor does not have yet. The first click from the canvas, an
    /// edition or another piece opens the piece; the editor that then mounts
    /// on it lands here.
    ///
    /// Last act wins: the window's paragraph receiver (`ParagraphNavModifier`,
    /// through `ManuscriptNavigation.holdingThePlace`) writes it whenever the
    /// mounted manuscript editor is not on the place's document
    /// (`mountedDocumentId`), replacing any unconsumed one. The next
    /// manuscript load takes it, whatever its document
    /// (`EditorCoordinator.documentDidMount(control:)`, called from
    /// `EditorSurface.makeNSView`): it lands only when it names that document
    /// and a paragraph the document has, and is dropped otherwise — never
    /// landed on a different document. It is also dropped when the window's
    /// `open` stops naming its document before the load
    /// (`ManuscriptNavigation.openChanged`) and when the load is refused
    /// (`dropPendingPlace(naming:)`, `EditorHost`), so a place nothing took
    /// never lands on a later, ordinary open of the piece.
    ///
    /// `@ObservationIgnored` on purpose: a request, not control state, so no
    /// observer (the coordinator's `applyControl` chain, a SwiftUI body) ever
    /// re-runs when it is written or taken (D1, tripwire 6).
    @ObservationIgnored var pendingPlace: PendingPlace? = nil

    /// **The document the window's manuscript editor has loaded**, nil when
    /// none is mounted. Recorded by that editor's coordinator alone, at its
    /// mount and its detach (`EditorCoordinator.documentDidMount(control:)`,
    /// `detach()`); read only by `ManuscriptNavigation.holdingThePlace` to
    /// decide whether a place must wait for a load. `@ObservationIgnored`: a
    /// fact the coordinator records, never control state anything observes.
    @ObservationIgnored private(set) var mountedDocumentId: String? = nil
    /// Which editor recorded it: a detach clears only its own record, so an
    /// old surface dismantled after its successor mounted (a `.id(path)`
    /// swap, a rename) never erases the successor's.
    @ObservationIgnored private var mountedEditor: ObjectIdentifier? = nil

    func editorDidMount(_ editor: AnyObject, documentId: String) {
        mountedEditor = ObjectIdentifier(editor)
        mountedDocumentId = documentId
    }

    func editorDidDetach(_ editor: AnyObject) {
        guard mountedEditor == ObjectIdentifier(editor) else { return }
        mountedEditor = nil
        mountedDocumentId = nil
    }

    /// **A load of `docId` was refused** (a waiting piece, a recovery
    /// refusal): a place waiting for it is dropped, so it never lands on a
    /// later open. A place for any other document is left alone.
    func dropPendingPlace(naming docId: String) {
        if pendingPlace?.docId == docId { pendingPlace = nil }
    }

    /// A place in one document: a paragraph (with an optional UTF-16 offset
    /// into it, `MaughamEvent.paragraphOffsetKey`) or a slugline's line.
    struct PendingPlace: Equatable {
        enum Target: Equatable {
            case paragraph(id: String, offset: Int?)
            case line(location: Int)
        }
        let docId: String
        let target: Target
    }

    /// The ordered translation-freshness entries (each carrying its own block
    /// text), plus the resolved orphan records for the same derivation — a
    /// translation whose paragraph no longer exists in the manuscript (Task 5).
    /// Equatable so the coordinator can no-op-guard the per-`applyControl`
    /// push (like `reviewAnnotations`).
    struct TranslationBadgeModel: Equatable {
        var entries: [TranslationBadgeLayout.Entry]
        var orphans: [TranslationRecord] = []
        static let empty = TranslationBadgeModel(entries: [])
    }

    init() {}
}
