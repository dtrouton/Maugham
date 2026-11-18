import SwiftUI
import MaughamCore

/// **One note's row and its wiring** — extracted from `AnnotationListView`
/// (shell plan 2 Task 4) so To resolve's list and the old queue mount the same
/// row the same way.
///
/// A note on a document offers what its posture decides only where the
/// window may act on its piece: `document` is non-nil exactly there
/// (`actingDocument`, over `ResolveVerbGate.mayAct`). Anywhere else the row
/// reads, offers Keep as lesson alone (it needs no `Document`), and its click
/// is the host's. Hidden, never disabled.
///
/// A note on a figure keeps `FigureRowGate` unchanged: always actable, its
/// verbs routed to the figure's own host through `wiring.figure`.
@MainActor
struct AnnotationRowHost: View {
    let annotation: Annotation
    /// The piece (or figure) the note belongs to.
    let docId: String
    /// The live document a verb acts through — non-nil only where this
    /// window may act on `docId` (`actingDocument`).
    let document: Document?
    /// The document's live paragraph ids, for Revert's gate.
    let livePids: Set<String>
    /// The lessons ledger as the host last read it — read once per pass.
    let ledgerText: String?
    var isSelectable: Bool = false
    var isSelected: Bool = false
    /// A figure's registry title, when `docId` is a figure's stream.
    var figureTitle: String? = nil
    /// A figure suggestion's cells as text, from the walk.
    var figureCells: SuggestionDisplay.FigureCells? = nil
    let wiring: AnnotationRowWiring

    /// **The one door from the gate to a row's document**: the editor's live
    /// `Document` for `docId` where `ResolveVerbGate.mayAct` says this window
    /// may act on it, else `nil`. Never loads one.
    static func actingDocument(docId: String, openDocId: String?,
                               documentStore: DocumentStore) -> Document? {
        let mayAct = ResolveVerbGate.mayAct(
            onDocId: docId, openDocId: openDocId,
            isRegistered: { documentStore.document(forDocId: $0) != nil })
        return mayAct ? documentStore.document(forDocId: docId) : nil
    }

    var body: some View {
        if DocumentClass.isFigureDocId(docId) {
            figureRow(isOwn: AnnotationOwnership.isOwn(annotation, localName: wiring.localName))
        } else {
            documentRow
        }
    }

    // MARK: - A note on a figure (report plan 9c-1 Task 7)

    /// A figure note's row: always actable (no `Document` gate — its verbs
    /// act through the figure's own host), its verbs narrowed to what a
    /// figure stream can write and routed to `wiring.figure`. A suggestion's
    /// Accept is the row's click — the figure opened at its cell, whose strip
    /// accepts it (report plan 9c-2 Task 7) — or disabled with the reason
    /// when the cell is gone (`FigureRowGate`).
    @ViewBuilder
    private func figureRow(isOwn: Bool) -> some View {
        let ann = annotation
        let figureId = docId
        let figure = wiring.figure
        let gate = FigureRowGate(
            annotation: ann, figureId: figureId,
            figureTitle: figureTitle ?? figureId, cells: figureCells,
            reachable: figure.reachable(figureId))
        AnnotationRow(
            annotation: ann,
            revertIsEnabled: false,
            showingStet: wiring.stetFlourishIds.contains(ann.id),
            verbs: FigureRowGate.verbs(wiring.rowVerbs(ann, figureId, isOwn)),
            figure: gate,
            onAccept: { gate.acceptTravels ? wiring.onJump(figureId, ann) : figure.onAccept(figureId, ann) },
            onReject: { figure.onReject(figureId, ann) },
            onStet: { figure.onStet(figureId, ann) },
            onArchive: { figure.onArchive(figureId, ann) },
            onReply: { figure.onReply(figureId, ann) },
            onReopen: { figure.onReopen(figureId, ann) },
            onJumpToParagraph: { wiring.onJump(figureId, ann) },
            ledgerText: ledgerText,
            manifest: wiring.manifest)
    }

    // MARK: - A note on a document

    /// The posture's verbs, through the gate: on the open piece every verb it
    /// decided, acting through `document`; anywhere else Keep as lesson alone.
    @ViewBuilder
    private var documentRow: some View {
        let ann = annotation
        let isOwn = AnnotationOwnership.isOwn(ann, localName: wiring.localName)
        let rowDocument = document
        AnnotationRow(
            annotation: ann,
            revertIsEnabled: AnnotationRowPolicy.revertEnabled(ann, livePids: livePids),
            showingStet: wiring.stetFlourishIds.contains(ann.id),
            verbs: ResolveVerbGate.noteVerbs(
                wiring.rowVerbs(ann, docId, isOwn), mayAct: rowDocument != nil),
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
            onKeepAsLesson: { wiring.onKeepAsLesson(docId, ann) },
            onEdit: { withDocument(rowDocument) { wiring.onEdit($0, ann) } },
            onWithdraw: { withDocument(rowDocument) { wiring.onWithdraw($0, ann) } },
            onRevert: { withDocument(rowDocument) { wiring.onRevert($0, ann) } },
            onReopen: { withDocument(rowDocument) { wiring.onReopen($0, ann) } },
            onJumpToParagraph: { wiring.onJump(docId, ann) },
            ledgerText: ledgerText,
            manifest: wiring.manifest)
    }

    /// Belt behind the hidden verbs: a control that somehow fires with no
    /// live document does nothing, rather than reaching for a transient one
    /// whose ops the writer's ⌘Z could never find.
    private func withDocument(_ document: Document?, _ body: (Document) -> Void) {
        guard let document else { return }
        body(document)
    }
}
