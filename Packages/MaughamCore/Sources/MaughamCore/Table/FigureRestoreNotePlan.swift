import Foundation

/// **What a figure restore did to its notes** (RULING-28, RULING-57): the
/// accepted suggestions it reopened, those it put back to accepted (its cell
/// written back to the value they accepted), and those it archived, by note id.
public struct FigureRestoreNotes: Equatable, Sendable {
    public var reopened: [String] = []
    public var reaccepted: [String] = []
    public var archived: [String] = []
    public init(reopened: [String] = [], reaccepted: [String] = [], archived: [String] = []) {
        self.reopened = reopened; self.reaccepted = reaccepted; self.archived = archived
    }
    public var isEmpty: Bool { reopened.isEmpty && reaccepted.isEmpty && archived.isEmpty }
}

/// **The lifecycle kinds a note's disposition appends to a figure's stream.**
public enum FigureNoteLifecycle {
    public static let kinds: Set<OpKind> = [
        .claudeAccept, .claudeAcceptRevert, .claudeReject, .claudeArchive,
        .annotationStet, .annotationReopen,
    ]
}

/// **How a figure restore answers the suggestions whose status it would
/// contradict** (RULING-28, RULING-57; hardening 11-11 ruling R-A): a restore
/// changes a suggestion only where it rewrites that suggestion's cell, and a
/// figure-only arm archives one whose cell is gone then. Three classes, one
/// walk — the figure twin of the manuscript's
/// `RewindImpact.travelStatusChanges` (`strandedAccepts(_:revertedBy:)`,
/// `returningAccepts`); the two rules are kept in step by tests that name
/// each other, not by shared code.
///
/// A cell the restore **writes** is one a `figureCellSet` sets, or one a
/// row or column revive puts back (the revive's cells ride in its `removed`
/// slice, with no cell set of their own) — written to the value the pointer
/// held there. Values are compared by content, never format.
///
/// - **Stranded**: accepted now, not accepted at the pointer, its newest
///   cell-carrying accept past the pointer, and the restore writes its cell
///   to a value other than its own accepted content — that cell's change
///   becomes the note's `claudeAcceptRevert` (cell and note in one op). Two
///   such notes on one cell set: the change carries the one whose
///   cell-carrying accept is newest; the other is reverted status only (its
///   cell WAS written). A revived cell has no cell set to carry the note:
///   reverted status only.
/// - **Returning**: open now, its latest honoured line a `claudeAcceptRevert`
///   past the pointer, accepted at the pointer, and the restore writes its
///   cell back to the content it accepted — that cell's change becomes the
///   note's `claudeAccept`, or, on a revived cell, a status-only
///   `claudeAccept`. It takes the change before any stranded note on that
///   cell, since the value written is its own.
/// - **Gone**: stranded but for the cell, whose row or column does not exist
///   at the pointer — archived status only, or, where this hand may not
///   dispose of a note (`mayDispose: false`), reverted status only: open over
///   a deleted cell is honest, and the author can archive it.
///
/// Everything else is left alone — in particular a note accepted at the
/// pointer and now ("however many Reverts and re-accepts came since"), a
/// stranded note on a cell the restore does not write (R-A), and a stranded
/// note whose cell the restore writes to its OWN accepted content (Goal 1: a
/// note is never reopened over its own value; it stays accepted, no line).
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

    /// **Does acting on this plan answer a note?** — a status line, or a cell
    /// change carrying a note (a stranded accept's revert or a returning
    /// one's accept). The restore asks `.acceptOrReject` of exactly this, and
    /// announces the figure's notes changed on it.
    public var answersANote: Bool {
        !statusLines.isEmpty || changes.contains { $0.sourceAnnotationId != nil }
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
        let shown = AnnotationAggregation.allAnnotations(
            ops: ops, paragraphs: [:], amendments: amendments, figureTable: table)
        let accepted = Set(shown.filter { $0.status == .accepted }.map(\.id))
        let open = Set(shown.filter { $0.status == .open }.map(\.id))
        // Per note: the latest HONOURED lifecycle line, now and at the pointer
        // (final review M3: a reopen the fold does not honour never happened
        // as far as the note's status goes, so it must not stand as the latest
        // line and hide the accept it follows), and the newest accept that
        // carries a cell, now and at the pointer. The pointer is the raw op
        // id: the figure walk does not adopt the manuscript's `momentEnd`.
        var latest: [String: Op] = [:], latestAtPointer: [String: Op] = [:]
        var cellAccept: [String: Op] = [:], cellAcceptAtPointer: [String: Op] = [:]
        func newer(_ op: Op, than held: Op?) -> Bool { held.map { op.opId > $0.opId } ?? true }
        for op in ops {
            guard let id = op.provenance?.sourceAnnotationId,
                  accepted.contains(id) || open.contains(id) else { continue }
            let atPointer = op.opId <= pointer
            if op.kind == .claudeAccept, op.figure?.cell != nil {
                if newer(op, than: cellAccept[id]) { cellAccept[id] = op }
                if atPointer, newer(op, than: cellAcceptAtPointer[id]) { cellAcceptAtPointer[id] = op }
            }
            if FigureNoteLifecycle.kinds.contains(op.kind),
               AnnotationDeriver.isHonouredLifecycleOp(op, amendments: amendments) {
                if newer(op, than: latest[id]) { latest[id] = op }
                if atPointer, newer(op, than: latestAtPointer[id]) { latestAtPointer[id] = op }
            }
        }
        var stranded: [(id: String, cell: CellKey, value: CellContent?, acceptOpId: String)] = []
        var returning: [(id: String, cell: CellKey, value: CellContent?)] = []
        for id in latest.keys.sorted() {
            guard let now = latest[id] else { continue }
            // Accepted with its cell at the pointer: the restore keeps the
            // cell it accepted, so there is nothing to strand — however many
            // Reverts and re-accepts came since (the manuscript's
            // `acceptedAtTarget`, `RewindImpact.travelStatusChanges`).
            let acceptedAtPointer = latestAtPointer[id]?.kind == .claudeAccept
                && cellAcceptAtPointer[id] != nil
            // Stranded: the latest line is ANY accept — a status-only
            // re-accept (a stet's or archive's ⌘Z) included, standing in for
            // the cell-writing accept it put back — judged against the newest
            // accept for that note that CARRIES a cell (N1).
            if accepted.contains(id), now.kind == .claudeAccept, !acceptedAtPointer,
               let written = cellAccept[id], written.opId > pointer, let cell = written.figure?.cell {
                stranded.append((id, cell, written.figure?.next?.content, written.opId))
            }
            // Returning: the line that took the accepted cell out — the
            // writer's Revert, or a restore's own status-only revert — is
            // past the pointer, and the pointer held the accept. (The
            // manuscript's second "took the change out" arm, a `.rewind`
            // `annotationReopen`, is left out on purpose: a figure has no
            // rewind, so no such line is ever written on its stream.)
            if open.contains(id), now.kind == .claudeAcceptRevert, now.opId > pointer, acceptedAtPointer,
               let then = cellAcceptAtPointer[id], let cell = then.figure?.cell {
                returning.append((id, cell, then.figure?.next?.content))
            }
        }
        // The cells a revive puts back, at the value the pointer held: every
        // live cell of a revived row or column, read from `target`.
        var revived: [CellKey: CellContent?] = [:]
        for change in changes where change.kind == .figureStructure {
            switch change.payload.structure {
            case let .reviveRow(row)?:
                for column in target.table.columns {
                    let key = CellKey(row: row, column: column)
                    revived[key] = target.table[key]?.content
                }
            case let .reviveColumn(column)?:
                for row in target.table.rows {
                    let key = CellKey(row: row, column: column)
                    revived[key] = target.table[key]?.content
                }
            default: break
            }
        }
        // A stranded note whose cell the restore writes to its OWN accepted
        // content keeps its status and gets no line (Goal 1): the content it
        // accepted is what the cell holds afterwards.
        let cellSets = Dictionary(changes.compactMap { change -> (CellKey, CellContent?)? in
            guard change.kind == .figureCellSet, let cell = change.payload.cell else { return nil }
            return (cell, change.payload.next?.content)
        }, uniquingKeysWith: { _, last in last })
        func writtenValue(_ cell: CellKey) -> CellContent?? { cellSets[cell] ?? revived[cell] }
        stranded.removeAll { note in writtenValue(note.cell).map { $0 == note.value } ?? false }
        var notes = FigureRestoreNotes()
        let answered = changes.map { change -> FigureReturnDiff.Change in
            guard change.kind == .figureCellSet, let cell = change.payload.cell else { return change }
            // The value written back is the one a returning note accepted.
            if let i = returning.firstIndex(where: { $0.cell == cell && $0.value == change.payload.next?.content }) {
                let id = returning.remove(at: i).id
                notes.reaccepted.append(id)
                return FigureReturnDiff.Change(kind: .claudeAccept, payload: change.payload, sourceAnnotationId: id)
            }
            // Of the stranded notes on this cell, the newest cell-carrying accept.
            guard let i = stranded.indices.filter({ stranded[$0].cell == cell })
                .max(by: { stranded[$0].acceptOpId < stranded[$1].acceptOpId }) else { return change }
            let id = stranded.remove(at: i).id
            notes.reopened.append(id)
            return FigureReturnDiff.Change(kind: .claudeAcceptRevert, payload: change.payload, sourceAnnotationId: id)
        }
        // Status only, after the changes: a returning note whose revived cell
        // holds its accepted content again is accepted; a stranded note on a
        // cell the restore wrote (for another note, or by a revive) is
        // reverted; one whose cell is gone then is archived; one on a live
        // cell the restore does not write keeps its status (R-A).
        var lines: [StatusLine] = []
        for note in returning {
            guard let value = revived[note.cell], value == note.value else { continue }
            notes.reaccepted.append(note.id)
            lines.append(StatusLine(kind: .claudeAccept, annotationId: note.id))
        }
        for note in stranded {
            let live = target.table.rowIndex(of: note.cell.row) != nil
                && target.table.columnIndex(of: note.cell.column) != nil
            guard writtenValue(note.cell) != nil || !live else { continue }
            let kind: OpKind = live || !mayDispose ? .claudeAcceptRevert : .claudeArchive
            if kind == .claudeArchive { notes.archived.append(note.id) } else { notes.reopened.append(note.id) }
            lines.append(StatusLine(kind: kind, annotationId: note.id))
        }
        return FigureRestoreNotePlan(changes: answered, statusLines: lines, notes: notes)
    }
}
