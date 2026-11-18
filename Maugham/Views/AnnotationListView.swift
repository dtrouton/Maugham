import SwiftUI
import MaughamCore

/// **The queue's rows for one stream of notes, mountable on its own** (#116 F11).
///
/// `AnnotationsPane` mounts it for the centred document and once per piece in
/// project scope. Any other host mounts it the same way: the notes in the
/// order to draw them, a `filter` if it shows fewer, the stream's document
/// to act through (`nil` unless the piece is the one open in the window's
/// centre — `AnnotationRowHost.actingDocument`; every row then offers no
/// `Document` verb), and an `AnnotationRowWiring` saying what each verb does.
/// Each row is an `AnnotationRowHost`.
///
/// A `ForEach` of rows and dividers, not a scroll view: the host supplies the
/// container, so the rows lay out in the host's own stack.
@MainActor
struct AnnotationListView: View {
    /// The notes, in the order to draw them.
    let annotations: [Annotation]
    /// Which of `annotations` to draw. The pane's own rows arrive already
    /// filtered, so it passes none.
    var filter: (Annotation) -> Bool = { _ in true }
    /// The piece these notes belong to — what a click jumps within or travels to.
    let docId: String
    /// The piece's live document where this window may act on it, else `nil`.
    let document: Document?
    /// The document's live paragraph ids, for Revert's gate.
    let livePids: Set<String>
    /// The lessons ledger as the host last read it — read once per pass.
    let ledgerText: String?
    /// Selection mode: each row grows its tick.
    var isSelectable: Bool = false
    var selection: Set<String> = []
    /// **The figure these notes are on, when `docId` is a figure's stream**
    /// (report plan 9c-1 Task 7): its registry title for the anchor line.
    /// Nil for a document's notes.
    var figureTitle: String? = nil
    /// A figure suggestion's cells as text, by note id — the walk's
    /// `ProjectAnnotationsSnapshot.figureCells`, looked up, never computed here.
    var figureCells: [String: SuggestionDisplay.FigureCells] = [:]
    let wiring: AnnotationRowWiring

    var body: some View {
        ForEach(annotations.filter(filter)) { ann in
            AnnotationRowHost(
                annotation: ann, docId: docId, document: document,
                livePids: livePids, ledgerText: ledgerText,
                isSelectable: isSelectable,
                isSelected: selection.contains(ann.id),
                figureTitle: figureTitle, figureCells: figureCells[ann.id],
                wiring: wiring)
            Divider()
        }
    }
}

/// **What a row needs from its host besides the note** — who the local writer
/// is, which rows wear the stet, the project's identity, which verbs this Mac
/// may offer, and what each verb does.
///
/// Every verb takes the row's OWN document explicitly: a verb that reached for
/// the host's would answer a note about Chapter Nine by editing whatever is
/// centred. Keep as lesson takes the row's piece and no document — it files
/// into the ledger, so it is offered on a piece that is not open too
/// (`ResolveVerbGate`). `AnnotationsPane.rowWiring` builds the pane's.
///
/// A host that only SHOWS a stream's notes takes `readOnly(manifest:onJump:)`:
///
/// ```swift
/// LazyVStack(spacing: 0) {
///     AnnotationListView(
///         annotations: notes, docId: docId, document: document,
///         livePids: Set(document?.sequence ?? []), ledgerText: nil,
///         wiring: .readOnly(manifest: store.manifest))
/// }
/// ```
struct AnnotationRowWiring {
    /// The local writer's display name, for `AnnotationOwnership.isOwn`.
    let localName: String
    /// Rows wearing the transient stet flourish.
    let stetFlourishIds: Set<String>
    /// `AnnotationRow.manifest` — the identity *Answer as ruling…* needs.
    let manifest: ProjectManifest?
    /// Which verbs this Mac may offer on a row: `(note, docId, isOwn)`.
    let rowVerbs: (Annotation, String, Bool) -> AnnotationRowVerbs
    let onToggleSelection: (String) -> Void
    let onAccept: (Document, Annotation) -> Void
    let onReject: (Document, Annotation) -> Void
    let onStet: (Document, Annotation) -> Void
    let onTriage: (Document, Annotation, TriageMark?) -> Void
    let onArchive: (Document, Annotation) -> Void
    let onReply: (Document, Annotation) -> Void
    let onAnswerAsRuling: (Document, Annotation) -> Void
    let onMakeChoice: (Document, Annotation) -> Void
    /// `(docId, note)` — no `Document`.
    let onKeepAsLesson: (String, Annotation) -> Void
    let onEdit: (Document, Annotation) -> Void
    let onWithdraw: (Document, Annotation) -> Void
    let onRevert: (Document, Annotation) -> Void
    let onReopen: (Document, Annotation) -> Void
    /// A click on the row, `(docId, note)`: jump, travel or stay.
    let onJump: (String, Annotation) -> Void
    /// What a figure note's verbs do (report plan 9c-1 Task 7). Inert unless
    /// the host passes its own.
    var figure: FigureRowWiring = .inert
}

/// **What a figure note's row verbs do** (report plan 9c-1 Task 7) — each
/// takes the figure's id and the note, and the host acts through the
/// figure's own host (`DocumentStore.withFigureHost`), never a `Document`.
/// Accept here is a note that writes no cell (*Got it*, a craft note's
/// Accept): a figure suggestion's Accept is the row's click (`onJump`,
/// travel to its cell), and never reaches it.
struct FigureRowWiring {
    let onAccept: (String, Annotation) -> Void
    /// Opens the reason sheet; the answer reaches the figure's reject.
    let onReject: (String, Annotation) -> Void
    let onStet: (String, Annotation) -> Void
    let onArchive: (String, Annotation) -> Void
    /// Opens the reply sheet; the answer is a status-only accept carrying it.
    let onReply: (String, Annotation) -> Void
    let onReopen: (String, Annotation) -> Void
    /// Can the queue travel to this figure (the tree draws its row)? A
    /// suggestion's Accept travels only to one (`FigureRowGate`).
    var reachable: (String) -> Bool = { _ in true }

    /// Does nothing — a read-only host's.
    static let inert = FigureRowWiring(
        onAccept: { _, _ in }, onReject: { _, _ in }, onStet: { _, _ in },
        onArchive: { _, _ in }, onReply: { _, _ in }, onReopen: { _, _ in })
}

extension AnnotationRowWiring {
    /// **A wiring that offers nothing**: every row verb is hidden
    /// (`rowVerbs` answers no verb, the local writer's own note included) and
    /// every verb closure does nothing, so a row draws no control a press
    /// would waste. `manifest` must be given, as `AnnotationRow` requires;
    /// `onJump` is the host's click, a no-op unless it passes one.
    static func readOnly(
        manifest: ProjectManifest?,
        onJump: @escaping (String, Annotation) -> Void = { _, _ in }
    ) -> AnnotationRowWiring {
        let nothing = AnnotationRowVerbs(
            acceptOrReject: false, dispose: false, answerAsRuling: false,
            makeChoice: false, keepAsLesson: false, ownNote: false)
        let ignore: (Document, Annotation) -> Void = { _, _ in }
        return AnnotationRowWiring(
            localName: "", stetFlourishIds: [], manifest: manifest,
            rowVerbs: { _, _, _ in nothing },
            onToggleSelection: { _ in },
            onAccept: ignore, onReject: ignore, onStet: ignore,
            onTriage: { _, _, _ in },
            onArchive: ignore, onReply: ignore, onAnswerAsRuling: ignore,
            onMakeChoice: ignore, onKeepAsLesson: { _, _ in }, onEdit: ignore,
            onWithdraw: ignore, onRevert: ignore, onReopen: ignore,
            onJump: onJump)
    }
}
