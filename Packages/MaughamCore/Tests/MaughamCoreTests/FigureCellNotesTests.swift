import XCTest
@testable import MaughamCore

/// Report plan 9c-2 Task 2: one judged read of a figure's open cell notes,
/// cached beside `FigureCache`'s state, and the marks it puts on the figure's
/// card. Rulings: a range marks its top-left cell only; marks and presence
/// count live anchors only; resolved and withdrawn notes count for nothing.
@MainActor
final class FigureCellNotesTests: XCTestCase {

    private let figureId = "fig-k3m9q2zt"
    private let r1 = RowID("r1aaaaaa"), r2 = RowID("r2bbbbbb"), r3 = RowID("r3cccccc")
    private let c1 = ColumnID("c1dddddd"), c2 = ColumnID("c2eeeeee"), c3 = ColumnID("c3ffffff")
    private var counter = 0
    private let en = TableLocale(languageTag: "en-GB", fallbackRegion: "GB")

    private func op(
        _ kind: OpKind, figure: FigureOpPayload? = nil, provenance: Op.Provenance? = nil
    ) -> Op {
        counter += 1
        return Op(opId: String(format: "op%04d", counter), docId: figureId,
                  at: Date(timeIntervalSince1970: TimeInterval(1_000 + counter)),
                  device: "macA", session: "s", kind: kind, changes: [],
                  provenance: provenance, figure: figure)
    }

    private func structure(_ change: FigureStructureChange, removed: FigureRemovedSlice? = nil) -> Op {
        op(.figureStructure, figure: FigureOpPayload(structure: change, removed: removed))
    }

    /// A 3×3 table: rows r1 r2 r3, columns c1 c2 c3.
    private func base() -> [Op] {
        [op(.figureCreate, figure: FigureOpPayload(kind: .table)),
         structure(.insertRow(r1, after: nil)), structure(.insertRow(r2, after: r1)),
         structure(.insertRow(r3, after: r2)),
         structure(.insertColumn(c1, after: nil)), structure(.insertColumn(c2, after: c1)),
         structure(.insertColumn(c3, after: c2))]
    }

    private func comment(
        row: RowID? = nil, rowEnd: RowID? = nil, column: ColumnID? = nil, columnEnd: ColumnID? = nil
    ) -> Op {
        op(.claudeComment, provenance: Op.Provenance(
            annotationBody: "Check this",
            figureRowId: row?.raw, figureRowEndId: rowEnd?.raw,
            figureColId: column?.raw, figureColEndId: columnEnd?.raw))
    }

    private func lifecycle(_ kind: OpKind, of note: Op) -> Op {
        op(kind, provenance: Op.Provenance(sourceAnnotationId: note.opId))
    }

    private func cellNotes(_ ops: [Op]) -> FigureCellNotes {
        let table = AnnotationAggregation.figureTable(in: ops)
        return FigureCellNotes(
            notes: AnnotationAggregation.allAnnotations(ops: ops, paragraphs: [:], figureTable: table),
            table: table)
    }

    private func key(_ r: RowID, _ c: ColumnID) -> CellKey { CellKey(row: r, column: c) }

    // MARK: - The value

    func test_aRangeMarksOnlyItsTopLeftCell_evenWrittenCornerToCorner() {
        let forward = comment(row: r2, rowEnd: r3, column: c2, columnEnd: c3)
        let reversed = comment(row: r3, rowEnd: r2, column: c3, columnEnd: c2)
        for note in [forward, reversed] {
            let notes = cellNotes(base() + [note])
            XCTAssertEqual(notes.marked, [key(r2, c2)], "the range's top-left cell, B2, and no other")
            XCTAssertEqual(notes.byAnchor[key(r2, c2)]?.map(\.id), [note.opId])
            XCTAssertTrue(notes.hasLive)
        }
    }

    func test_notesContaining_findsARangeNoteFromAnInnerCell() {
        let range = comment(row: r2, rowEnd: r3, column: c2, columnEnd: c3)
        let single = comment(row: r3, column: c3)
        let notes = cellNotes(base() + [range, single])
        XCTAssertEqual(Set(notes.notes(containing: key(r3, c3)).map(\.id)), [range.opId, single.opId],
                       "C3 is inside B2:C3 and holds its own note")
        XCTAssertEqual(notes.notes(containing: key(r2, c3)).map(\.id), [range.opId], "an inner cell")
        XCTAssertEqual(notes.notes(containing: key(r2, c2)).map(\.id), [range.opId], "the corner itself")
        XCTAssertEqual(notes.notes(containing: key(r1, c1)), [], "outside every range")
        XCTAssertEqual(notes.marked, [key(r2, c2), key(r3, c3)])
    }

    func test_anOrphanedNote_marksNothing_andIsNoPresence() {
        var ops = base() + [op(.figureCellSet, figure: FigureOpPayload(
            cell: key(r3, c3), next: Cell(content: .value(.number(7)))))]
        let slice = FigureDeriver.derive(ops).removedSlice(row: r3)
        ops.append(structure(.deleteRow(r3), removed: slice))
        let notes = cellNotes(ops + [comment(row: r3, column: c3),
                                     comment(row: r1, rowEnd: r3, column: c1)])
        XCTAssertEqual(notes.marked, [], "an orphaned cell, and a range with an orphaned corner")
        XCTAssertFalse(notes.hasLive, "orphaned notes reserve no strip")
        XCTAssertEqual(notes.notes(containing: key(r1, c1)), [])
    }

    func test_resolvedWithdrawnAndWholeFigureNotes_countForNothing() {
        let rejected = comment(row: r1, column: c1)
        let archived = comment(row: r1, column: c2)
        let stetted = comment(row: r1, column: c3)
        let withdrawn = comment(row: r2, column: c1)
        let accepted = comment(row: r2, column: c2)
        let ops = base() + [rejected, archived, stetted, withdrawn, accepted, comment(),
                            lifecycle(.claudeReject, of: rejected), lifecycle(.claudeArchive, of: archived),
                            lifecycle(.annotationStet, of: stetted), lifecycle(.annotationWithdraw, of: withdrawn),
                            lifecycle(.claudeAccept, of: accepted)]
        let notes = cellNotes(ops)
        XCTAssertEqual(notes.marked, [])
        XCTAssertFalse(notes.hasLive)
        XCTAssertEqual(notes, .none)

        let reopened = cellNotes(ops + [lifecycle(.annotationReopen, of: rejected)])
        XCTAssertEqual(reopened.marked, [key(r1, c1)], "a reopened note is open again")
    }

    func test_noTable_noNotes() {
        let ops = base() + [comment(row: r1, column: c1)]
        let notes = FigureCellNotes(notes: AnnotationAggregation.allAnnotations(ops: ops, paragraphs: [:]),
                                    table: nil)
        XCTAssertEqual(notes, .none)
    }

    // MARK: - The cache: one read

    private func newRoot() -> URL { TestTemp.root.appendingPathComponent("fcn-\(UUID().uuidString)") }

    private func write(_ ops: [Op], to root: URL) throws {
        let dir = root.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        let blob = try ops.map { String(data: try enc.encode($0), encoding: .utf8)! }
            .joined(separator: "\n") + "\n"
        let url = dir.appendingPathComponent("\(figureId).jsonl")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(blob.utf8)); try h.close()
        } else {
            try blob.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func test_theCacheReadsStateAndNotesOnce_andASecondReadDerivesNothing() throws {
        let root = newRoot()
        let note = comment(row: r2, column: c2)
        try write(base() + [note], to: root)
        let cache = FigureCache()
        let facts = DocumentClass.Facts.empty

        let state = try cache.state(forFigureId: figureId, in: root, facts: facts)
        let notes = try cache.cellNotes(forFigureId: figureId, in: root, facts: facts)
        XCTAssertEqual(cache.deriveCount, 1, "state and notes from one read")
        XCTAssertEqual(state.table.rows, [r1, r2, r3])
        XCTAssertEqual(notes.marked, [key(r2, c2)])
        XCTAssertEqual(try cache.cellNotes(forFigureId: figureId, in: root, facts: facts), notes)
        XCTAssertEqual(cache.deriveCount, 1, "a cached second read derives nothing")

        try write([lifecycle(.claudeReject, of: note)], to: root)
        XCTAssertEqual(try cache.cellNotes(forFigureId: figureId, in: root, facts: facts), .none,
                       "the reject moves the token: the note is answered")
        XCTAssertEqual(cache.deriveCount, 2)
    }

    /// The judged read the Mac walk delegates to answers the same notes the
    /// cache's line is built from, and the table they resolve against.
    func test_theJudgedRead_answersNotesAndTheirTable() throws {
        let root = newRoot()
        let note = comment(row: r1, rowEnd: r2, column: c1, columnEnd: c2)
        try write(base() + [note, comment()], to: root)
        let trust = try TrustResolution.resolve(projectURL: root, identities: .current)
        let read = try FigureNotesRead.read(figureId: figureId, in: root, trust: trust, facts: .empty)
        XCTAssertEqual(Set(read.notes.map(\.id)), [note.opId, "op\(String(format: "%04d", counter))"])
        XCTAssertEqual(read.notes.first { $0.id == note.opId }?.figureAddress, "A1:B2")
        XCTAssertEqual(read.table?.rows, [r1, r2, r3])
        XCTAssertEqual(FigureDeriver.derive(read.ops).table.rows, [r1, r2, r3])
    }

    // MARK: - The card

    func test_theCardMarksShownCells_andCarriesPresence() {
        let ops = base() + [comment(row: r2, rowEnd: r3, column: c2, columnEnd: c3)]
        let notes = cellNotes(ops)
        var state = FigureDeriver.derive(ops)
        state.table.headerRows = 1
        let model = FigureCardModel.build(figureId: figureId, state: state, values: { _ in .empty },
                                          locale: en, language: nil, openCellNotes: notes)
        XCTAssertTrue(model.hasOpenCellNotes)
        XCTAssertEqual(model.markedCells, [FigureCardModel.Position(row: 1, column: 1)],
                       "B2 is the first body row (shown row 1), second column")

        let bare = FigureCardModel.build(figureId: figureId, state: state, values: { _ in .empty },
                                         locale: en, language: nil)
        XCTAssertFalse(bare.hasOpenCellNotes)
        XCTAssertEqual(bare.markedCells, [])
        XCTAssertNotEqual(model, bare, "a note's arrival moves the card's version")
    }

    /// A note on a row the card cuts short marks nothing shown, but the
    /// figure still has a live note: the strip's room is the figure's.
    func test_aNoteOnARowTheCardDoesNotShow_marksNothing_butIsPresence() {
        var ops = [op(.figureCreate, figure: FigureOpPayload(kind: .table)),
                   structure(.insertColumn(c1, after: nil))]
        var rows: [RowID] = []
        for i in 0..<(FigureCardModel.maxShownRows + 3) {
            let row = RowID(String(format: "rr%06d", i))
            ops.append(structure(.insertRow(row, after: rows.last)))
            rows.append(row)
        }
        let notes = cellNotes(ops + [comment(row: rows.last!, column: c1)])
        let model = FigureCardModel.build(figureId: figureId, state: FigureDeriver.derive(ops),
                                          values: { _ in .empty }, locale: en, language: nil,
                                          openCellNotes: notes)
        XCTAssertGreaterThan(model.moreRows, 0, "premise: the last row is not shown")
        XCTAssertEqual(model.markedCells, [])
        XCTAssertTrue(model.hasOpenCellNotes)
    }

    func test_theBookPassesEachFiguresNotesToItsCard() {
        let ops = base() + [comment(row: r1, column: c1)]
        let record = FigureRecord(id: figureId, name: "t", kind: .table, piece: nil, path: "figures/t.csv")
        let book = FigureCardBook.build(
            records: [record], states: [figureId: FigureDeriver.derive(ops)], workbook: nil, locale: en,
            pinChanged: [], sourceChanged: [], openCellNotes: [figureId: cellNotes(ops)])
        XCTAssertEqual(book.models[figureId]?.markedCells, [FigureCardModel.Position(row: 0, column: 0)])
        XCTAssertEqual(book.models[figureId]?.hasOpenCellNotes, true)
    }
}
