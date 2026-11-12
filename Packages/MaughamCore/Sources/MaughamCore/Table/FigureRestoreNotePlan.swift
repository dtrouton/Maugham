import Foundation

/// **What a figure restore did to its notes** (RULING-28): the accepted
/// suggestions it reopened and those it archived, by note id.
public struct FigureRestoreNotes: Equatable, Sendable {
    public var reopened: [String] = []
    public var archived: [String] = []
    public init(reopened: [String] = [], archived: [String] = []) {
        self.reopened = reopened; self.archived = archived
    }
    public var isEmpty: Bool { reopened.isEmpty && archived.isEmpty }
}

/// **The lifecycle kinds a note's disposition appends to a figure's stream.**
public enum FigureNoteLifecycle {
    public static let kinds: Set<OpKind> = [
        .claudeAccept, .claudeAcceptRevert, .claudeReject, .claudeArchive,
        .annotationStet, .annotationReopen,
    ]
}

/// **How a figure restore answers the notes it would strand** (RULING-28,
/// as the manuscript's restore): a figure suggestion accepted after the
/// checkpoint's pointer, and still accepted, has its cell put back by the
/// restore — so that cell's change becomes the note's `claudeAcceptRevert`
/// (cell and note in one op). Where the restore writes no change to its
/// cell, the note is reopened by a status-only revert; where the cell is
/// gone then, it is archived — or, where this hand may not dispose of a note
/// (`mayDispose: false`), reopened status only: open over a deleted cell is
/// honest, and the author can archive it.
///
/// Pure: `FigureDocument`'s checkpoint restore acts on it
/// (`FigureCheckpointRestore`).
public struct FigureRestoreNotePlan: Equatable, Sendable {

    /// A note's status-only line: written after the changes.
    public struct StatusLine: Equatable, Sendable {
        public var kind: OpKind
        public var annotationId: String
        public init(kind: OpKind, annotationId: String) {
            self.kind = kind; self.annotationId = annotationId
        }
    }

    /// The restore's table changes, with each cell change that answers a note
    /// rewritten to that note's lifecycle kind and carrying its id.
    public var changes: [FigureReturnDiff.Change]
    /// Status-only note lines, written after the changes.
    public var statusLines: [StatusLine]
    /// What acting on this plan will have done, by note id (RULING-28).
    public var notes: FigureRestoreNotes

    public init(changes: [FigureReturnDiff.Change], statusLines: [StatusLine], notes: FigureRestoreNotes) {
        self.changes = changes; self.statusLines = statusLines; self.notes = notes
    }

    /// The plan for a restore whose table `changes` take the figure — whose
    /// stream is `ops`, judged by `amendments`, and whose table stands now as
    /// `table` — back to `target`, the figure at op `pointer`.
    public static func plan(
        changes: [FigureReturnDiff.Change],
        ops: [Op], amendments: AnnotationAmendments,
        table: FigureTable,
        target: FigureState, above pointer: String,
        mayDispose: Bool
    ) -> FigureRestoreNotePlan {
        // The notes as the host shows them: resolved against the table as it
        // stands, withdrawn notes left out (`FigureDocument.annotations()`).
        let accepted = Set(AnnotationAggregation.allAnnotations(
            ops: ops, paragraphs: [:], amendments: amendments, figureTable: table)
            .filter { $0.status == .accepted }.map(\.id))
        var latest: [String: Op] = [:]
        // Honoured lines only (final review M3): a reopen the fold does not
        // honour never happened as far as the note's status goes, so it must
        // not stand as the latest line and hide the accept it follows.
        for op in ops where FigureNoteLifecycle.kinds.contains(op.kind)
            && AnnotationDeriver.isHonouredLifecycleOp(op, amendments: amendments) {
            guard let id = op.provenance?.sourceAnnotationId, accepted.contains(id) else { continue }
            if latest[id].map({ op.opId > $0.opId }) ?? true { latest[id] = op }
        }
        // Stranded = the latest lifecycle line is ANY accept — a status-only
        // re-accept (a stet's or archive's ⌘Z) included, standing in for the
        // cell-writing accept it put back — judged against the newest accept
        // for that note that CARRIES a cell (Document+Rewind's rule).
        var stranded = latest.compactMap { id, op -> (id: String, cell: CellKey)? in
            guard op.kind == .claudeAccept,
                  let written = ops.filter({
                      $0.kind == .claudeAccept && $0.provenance?.sourceAnnotationId == id && $0.figure?.cell != nil
                  }).max(by: { $0.opId < $1.opId }),
                  written.opId > pointer, let cell = written.figure?.cell else { return nil }
            return (id, cell)
        }.sorted { $0.id < $1.id }
        var notes = FigureRestoreNotes()
        let answered = changes.map { change -> FigureReturnDiff.Change in
            guard change.kind == .figureCellSet, let cell = change.payload.cell,
                  let i = stranded.firstIndex(where: { $0.cell == cell }) else { return change }
            let id = stranded.remove(at: i).id
            notes.reopened.append(id)
            return FigureReturnDiff.Change(kind: .claudeAcceptRevert, payload: change.payload, sourceAnnotationId: id)
        }
        let lines = stranded.map { note -> StatusLine in
            let live = target.table.rowIndex(of: note.cell.row) != nil
                && target.table.columnIndex(of: note.cell.column) != nil
            let kind: OpKind = live || !mayDispose ? .claudeAcceptRevert : .claudeArchive
            if kind == .claudeArchive { notes.archived.append(note.id) } else { notes.reopened.append(note.id) }
            return StatusLine(kind: kind, annotationId: note.id)
        }
        return FigureRestoreNotePlan(changes: answered, statusLines: lines, notes: notes)
    }
}
