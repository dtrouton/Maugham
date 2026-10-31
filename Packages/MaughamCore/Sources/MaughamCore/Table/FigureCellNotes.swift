import Foundation

/// **A figure's open notes on live cells** (report plan 9c-2), built once from
/// a judged projection of its stream against its table — what the card's
/// dots, the grid's dots and the suggestion strip all read, on the Mac and the
/// phone alike (tripwire 19).
///
/// Rulings: only an `.open` note with a cell anchor that resolves live in the
/// table counts — an orphaned note (a corner's row or column deleted), a
/// whole-figure note, and a resolved or withdrawn one count for nothing, for
/// the marks and for `hasLive`. A range is marked on its top-left cell only,
/// by position in the table it was built against; `notes(containing:)` still
/// finds it from any cell inside.
///
/// A value of the table it was built against: positions move with an insert
/// or a move, so whoever holds one rebuilds it when the table changes.
public struct FigureCellNotes: Equatable, Sendable {

    /// No open live cell notes.
    public static let none = FigureCellNotes()

    /// The open live notes by their anchor's top-left cell, each cell's in
    /// the projection's order.
    public let byAnchor: [CellKey: [Annotation]]

    private struct Entry: Equatable, Sendable {
        let note: Annotation
        let rows: Set<RowID>
        let columns: Set<ColumnID>
    }
    /// Every counted note with the rows and columns its range spans, in the
    /// projection's order.
    private let entries: [Entry]

    private init(byAnchor: [CellKey: [Annotation]] = [:], entries: [Entry] = []) {
        self.byAnchor = byAnchor; self.entries = entries
    }

    /// `notes` as the figure's stream projects them (judged), against the
    /// figure's `table`; nil (no table: a picture, or a stream with no figure
    /// op) counts nothing.
    public init(notes: [Annotation], table: FigureTable?) {
        guard let table else { self.init(); return }
        var entries: [Entry] = []
        var byAnchor: [CellKey: [Annotation]] = [:]
        for note in notes where note.status == .open && !note.figureOrphaned {
            guard let anchor = note.figureAnchor,
                  let r0 = table.rowIndex(of: anchor.row),
                  let r1 = table.rowIndex(of: anchor.rowEnd ?? anchor.row),
                  let c0 = table.columnIndex(of: anchor.column),
                  let c1 = table.columnIndex(of: anchor.columnEnd ?? anchor.column)
            else { continue }
            let top = min(r0, r1), bottom = max(r0, r1), left = min(c0, c1), right = max(c0, c1)
            entries.append(Entry(note: note, rows: Set(table.rows[top...bottom]),
                                 columns: Set(table.columns[left...right])))
            byAnchor[CellKey(row: table.rows[top], column: table.columns[left]), default: []].append(note)
        }
        self.init(byAnchor: byAnchor, entries: entries)
    }

    /// The cells that carry a dot: each counted note's top-left cell.
    public var marked: Set<CellKey> { Set(byAnchor.keys) }

    /// **The figure has at least one open note on a live cell** — the strip's
    /// presence (`FigureCardModel.hasOpenCellNotes`).
    public var hasLive: Bool { !entries.isEmpty }

    /// Every counted note whose cell or range contains `key`, in the
    /// projection's order — what the strip shows for the active cell.
    public func notes(containing key: CellKey) -> [Annotation] {
        entries.filter { $0.rows.contains(key.row) && $0.columns.contains(key.column) }.map(\.note)
    }
}

/// **One figure's notes, judged, from one read of its stream** (report plan
/// 9c-2 Task 2): the Mac's project walk, the figure inspector, `FigureCache`
/// (and through it the Mac's and the phone's cards) all read a figure's notes
/// here, so they are judged one way (tripwire 19).
///
/// The read is `OpLogStore.loadSyncMerged` collecting each amendment line's
/// permit (`AmendmentPermits`), then the projection under
/// `AnnotationAmendments.judged` with the figure's class from `facts`. Each
/// note's cell anchor resolves against the stream's own table
/// (`AnnotationAggregation.figureTable(in:)`). Never reads
/// `figures/<name>.csv` (tripwire 20).
public struct FigureNotesRead: Sendable {
    /// The merged ops the read returned — what a caller folds its state from.
    public let ops: [Op]
    /// Every note on the stream, every status, judged.
    public let notes: [Annotation]
    /// The table the anchors resolved against; nil with no figure op.
    public let table: FigureTable?

    /// Throws as `loadSyncMerged` does (RULING-54: an unreadable file).
    public nonisolated static func read(
        figureId: String, in projectURL: URL, trust: TrustTable, facts: DocumentClass.Facts
    ) throws -> FigureNotesRead {
        let amendmentPermits = AmendmentPermits()
        let ops = try OpLogStore.loadSyncMerged(
            forDocId: figureId, in: projectURL, trust: trust, facts: facts,
            amendmentPermits: amendmentPermits)
        let table = AnnotationAggregation.figureTable(in: ops)
        let notes = AnnotationAggregation.allAnnotations(
            ops: ops, paragraphs: [:],
            amendments: .judged(
                by: trust, permits: amendmentPermits.resolved,
                insideTheUnsignedSnapshot: amendmentPermits.resolvedInsideTheUnsignedSnapshot,
                class: { DocumentClass.resolve(docId: figureId, facts: facts) }),
            figureTable: table)
        return FigureNotesRead(ops: ops, notes: notes, table: table)
    }
}
