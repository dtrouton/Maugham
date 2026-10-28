import SwiftUI
import MaughamCore

/// **The queue's rows for one stream of notes, mountable on its own** (#116 F11).
///
/// `AnnotationsPane` mounts it for the centred document and once per piece in
/// project scope. Any other host mounts it the same way: the notes in the
/// order to draw them, a `filter` if it shows fewer, the stream's document
/// (`nil` when the piece is closed — every row's verbs are then disabled, with
/// the reason), and an `AnnotationRowWiring` saying what each verb does.
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
    /// The piece's live document, or `nil` for a closed one.
    let document: Document?
    /// The document's live paragraph ids, for Revert's gate.
    let livePids: Set<String>
    /// The lessons ledger as the host last read it — read once per pass.
    let ledgerText: String?
    /// Selection mode: each row grows its tick.
    var isSelectable: Bool = false
    var selection: Set<String> = []
    let wiring: AnnotationRowWiring

    var body: some View {
        ForEach(annotations.filter(filter)) { ann in
            annotationRow(
                ann, docId: docId, document: document,
                livePids: livePids, ledgerText: ledgerText,
                isSelectable: isSelectable,
                isSelected: selection.contains(ann.id))
            Divider()
        }
    }

    // MARK: - One row, either scope

    /// The one row builder. Document scope passes its own document for every
    /// row; project scope passes the row's, which is `nil` for a closed piece —
    /// and that nil is the whole of the verb gate.
    @ViewBuilder
    private func annotationRow(
        _ ann: Annotation,
        docId: String,
        document rowDocument: Document?,
        livePids: Set<String>,
        ledgerText: String?,
        isSelectable: Bool = false,
        isSelected: Bool = false
    ) -> some View {
        let isOwn = AnnotationOwnership.isOwn(
            ann, localName: wiring.localName)
        AnnotationRow(
            annotation: ann,
            revertIsEnabled: AnnotationRowPolicy.revertEnabled(ann, livePids: livePids),
            showingStet: wiring.stetFlourishIds.contains(ann.id),
            verbs: wiring.rowVerbs(ann, docId, isOwn),
            verbsEnabled: AnnotationScopePolicy.verbsEnabled(
                documentIsOpen: rowDocument != nil),
            verbsDisabledReason: AnnotationScopePolicy.closedPieceReason,
            isSelectable: isSelectable,
            isSelected: isSelected,
            onToggleSelection: { wiring.onToggleSelection(ann.id) },
            onAccept: { withDocument(rowDocument) { wiring.onAccept($0, ann) } },
            onReject: { withDocument(rowDocument) { wiring.onReject($0, ann) } },
            onStet: { withDocument(rowDocument) { wiring.onStet($0, ann) } },
            onTriage: { mark in
                withDocument(rowDocument) { wiring.onTriage($0, ann, mark) } },
            onArchive: { withDocument(rowDocument) { wiring.onArchive($0, ann) } },
            onReply: { withDocument(rowDocument) { wiring.onReply($0, ann) } },
            onAnswerAsRuling: { withDocument(rowDocument) {
                wiring.onAnswerAsRuling($0, ann) } },
            onMakeChoice: { withDocument(rowDocument) { wiring.onMakeChoice($0, ann) } },
            onKeepAsLesson: { withDocument(rowDocument) {
                wiring.onKeepAsLesson($0, ann) } },
            onEdit: { withDocument(rowDocument) { wiring.onEdit($0, ann) } },
            onWithdraw: { withDocument(rowDocument) { wiring.onWithdraw($0, ann) } },
            onRevert: { withDocument(rowDocument) { wiring.onRevert($0, ann) } },
            onReopen: { withDocument(rowDocument) { wiring.onReopen($0, ann) } },
            onJumpToParagraph: { wiring.onJump(docId, ann) },
            ledgerText: ledgerText,
            manifest: wiring.manifest)
    }

    /// Belt behind the disabled verbs: a control that somehow fires with no
    /// live document does nothing, rather than reaching for a transient one
    /// whose ops the writer's ⌘Z could never find.
    private func withDocument(_ document: Document?, _ body: (Document) -> Void) {
        guard let document else { return }
        body(document)
    }
}

/// **What a row needs from its host besides the note** — who the local writer
/// is, which rows wear the stet, the project's identity, which verbs this Mac
/// may offer, and what each verb does.
///
/// Every verb takes the row's OWN document explicitly: in project scope it is
/// not the host's, and a verb that reached for the host's would answer a note
/// about Chapter Nine by editing whatever is centred. `AnnotationsPane.rowWiring`
/// builds the pane's.
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
    let onKeepAsLesson: (Document, Annotation) -> Void
    let onEdit: (Document, Annotation) -> Void
    let onWithdraw: (Document, Annotation) -> Void
    let onRevert: (Document, Annotation) -> Void
    let onReopen: (Document, Annotation) -> Void
    /// A click on the row, `(docId, note)`: jump, travel or stay.
    let onJump: (String, Annotation) -> Void
}
