import XCTest
@testable import MaughamCore

/// **Coming back from Research** (report plan 6b Task 8, spec §4.2): a changed
/// working copy brings back only its differences, and every row and column it
/// still holds keeps its id — Review Focus 3 is the Excel round trip.
final class FigureReturnDiffTests: XCTestCase {

    private let gb = TableLocale(languageTag: "en-GB")
    private var minted = 0

    private func mintRow() -> RowID { minted += 1; return RowID(String(format: "nr%06d", minted)) }
    private func mintColumn() -> ColumnID { minted += 1; return ColumnID(String(format: "nc%06d", minted)) }

    /// A figure state holding `csv` as `TableCSV.read` reads it.
    private func figure(_ csv: String, names: FormulaNames = .empty) -> FigureState {
        FigureState(kind: .table, table: TableCSV.read(csv, locale: gb, names: names).table)
    }

    /// `state` with `changes` folded on, as the stream would after a resume.
    private func applied(_ changes: [FigureReturnDiff.Change], to state: FigureState) -> FigureState {
        var s = state
        s.parked = nil
        for (i, c) in changes.enumerated() {
            FigureDeriver.fold(Op(opId: String(format: "zz%04d", i), docId: "fig-k3m9q2zt",
                                  at: Date(timeIntervalSince1970: 0), device: "macA", session: "s",
                                  kind: c.kind, changes: [], figure: c.payload), into: &s)
        }
        XCTAssertEqual(s.diagnostics, state.diagnostics, "every change applies")
        return s
    }

    private func row(_ s: FigureState, labelled label: String) -> RowID? {
        let first = s.table.columns[0]
        return s.table.rows.first { s.table[CellKey(row: $0, column: first)]?.content == .value(.text(label)) }
    }

    private func value(_ s: FigureState, _ r: RowID, _ c: Int) -> CellContent? {
        s.table[CellKey(row: r, column: s.table.columns[c])]?.content
    }

    // MARK: - Review Focus 3

    /// A working copy edited in Excel and re-saved — a byte-order mark, CRLF,
    /// `;` separators with decimal commas, a row inserted, one moved, one
    /// deleted — comes back with every matched row keeping its id; only the
    /// deleted row is gone (its anchors orphaned), the new row is fresh, and
    /// the order is the copy's.
    func test_anExcelResavedCopyKeepsEveryMatchedRowsId() throws {
        var parked = figure("Item,Amount\nRent,1200.5\nFood,340\nTravel,99.9\nBooks,45\n")
        let ids = Dictionary(uniqueKeysWithValues: ["Item", "Rent", "Food", "Travel", "Books"].map {
            ($0, row(parked, labelled: $0)!) })
        parked.parked = FigureParking(path: "research/budget.csv", hash: "h")
        XCTAssertEqual(parked.table.headerRows, 1)
        // Books moved to the top, Travel deleted, Phone inserted after Food,
        // and Rent — now between moved rows — edited.
        let excel = "\u{FEFF}Item;Amount\r\nBooks;45\r\nRent;1250,5\r\nFood;340\r\nPhone;25,75\r\n"
        let copy = TableCSV.read(excel, locale: gb, names: .empty)
        XCTAssertEqual(copy.problems, [])

        let changes = FigureReturnDiff.changes(
            from: parked, onto: parked, to: copy.table, sidecar: nil,
            mintRow: mintRow, mintColumn: mintColumn)
        let back = applied(changes.ops, to: parked)

        let phone = try XCTUnwrap(row(back, labelled: "Phone"))
        XCTAssertEqual(back.table.rows, [ids["Item"]!, ids["Books"]!, ids["Rent"]!, ids["Food"]!, phone],
                       "matched rows keep their ids, in the copy's order")
        XCTAssertFalse(ids.values.contains(phone), "the new row has a fresh id")
        XCTAssertNil(back.table.rowIndex(of: ids["Travel"]!), "the deleted row is gone: its anchors orphan")
        XCTAssertNotNil(back.table.rowSlotIndex(of: ids["Travel"]!), "as a tombstone")
        XCTAssertEqual(value(back, ids["Rent"]!, 1), .value(.number(1250.5)), "a decimal comma read as one")
        XCTAssertEqual(value(back, phone, 1), .value(.number(25.75)))
        XCTAssertEqual(back.table.columns, parked.table.columns, "both columns kept")

        // The ops: one delete carrying what it took, one move, one insert, three cells — nothing else.
        let structures = changes.ops.compactMap(\.payload.structure)
        XCTAssertEqual(structures.count, 3, "\(structures)")
        let delete = changes.ops.first { if case .deleteRow? = $0.payload.structure { return true }; return false }
        XCTAssertEqual(delete?.payload.removed?.cells.count, 2, "the delete carries Travel's cells (ruling P-2)")
        XCTAssertEqual(changes.ops.filter { $0.kind == .figureCellSet }.count, 3,
                       "only Rent's amount and Phone's two cells are set")
        XCTAssertEqual(changes.overwritten, [])
    }

    /// The two-way shape the brief names: the same ops when base and current agree.
    func test_theTwoWayShapeIsTheThreeWayWithOneState() {
        let parked = figure("A,1\nB,2\n")
        let copy = TableCSV.read("A,1\nB,3\n", locale: gb, names: .empty).table
        let ops = FigureReturnDiff.ops(from: parked, to: copy, sidecar: nil,
                                       mintRow: mintRow, mintColumn: mintColumn)
        XCTAssertEqual(ops.map(\.0), [.figureCellSet])
        XCTAssertEqual(ops.first?.1.next?.content, .value(.number(3)))
        XCTAssertEqual(ops.first?.1.prior?.content, .value(.number(2)))
    }

    /// An unchanged copy brings back nothing; an edited row (one cell of two
    /// changed) keeps its id and sets only that cell.
    func test_anUnchangedCopyIsNoChange_andAnEditedRowKeepsItsId() {
        let parked = figure("Name,Total\nNorth,10\nSouth,20\nEast,30\n")
        let csv = TableCSV.renderResearch(parked.table, locale: gb, names: .empty)
        let same = FigureReturnDiff.changes(
            from: parked, onto: parked, to: TableCSV.read(csv, locale: gb, names: .empty).table,
            sidecar: nil, mintRow: mintRow, mintColumn: mintColumn)
        XCTAssertEqual(same.ops, [])

        let south = row(parked, labelled: "South")!
        let edited = FigureReturnDiff.changes(
            from: parked, onto: parked,
            to: TableCSV.read("Name,Total\nNorth,10\nSouth,25\nEast,30\n", locale: gb, names: .empty).table,
            sidecar: nil, mintRow: mintRow, mintColumn: mintColumn)
        XCTAssertEqual(edited.ops.map(\.kind), [.figureCellSet])
        XCTAssertEqual(edited.ops.first?.payload.cell?.row, south)
    }

    /// Columns match by header: swapped columns keep their ids and move; a
    /// new header is a new column; a missing one is deleted.
    func test_columnsMatchByHeader() {
        let parked = figure("Name,Q1,Q2\nNorth,1,2\n")
        let (name, q1, q2) = (parked.table.columns[0], parked.table.columns[1], parked.table.columns[2])
        let changes = FigureReturnDiff.changes(
            from: parked, onto: parked,
            to: TableCSV.read("Name,Q2,Q3\nNorth,2,9\n", locale: gb, names: .empty).table,
            sidecar: nil, mintRow: mintRow, mintColumn: mintColumn)
        let back = applied(changes.ops, to: parked)
        XCTAssertEqual(back.table.columns.prefix(2), [name, q2])
        XCTAssertNil(back.table.columnIndex(of: q1), "Q1 is gone")
        XCTAssertEqual(back.table.columns.count, 3)
        XCTAssertEqual(value(back, back.table.rows[1], 2), .value(.number(9)))
        XCTAssertEqual(back.table.rows, parked.table.rows, "the rows still match over Name and Q2")
    }

    /// A formula Excel re-pointed because a row went in above still matches
    /// its row (its shape relative to its cell is the same), and one whose
    /// range the copy changed is set to the copy's, by the result's ids.
    func test_formulasMatchByShape_andARangeTheCopyChangedIsTheCopys() {
        let parked = figure("Item,Cost,Twice\nA,1,=B2*2\nB,2,=B3*2\nTotal,=SUM(B2:B3),\n")
        let a = row(parked, labelled: "A")!, total = row(parked, labelled: "Total")!
        let copy = TableCSV.read("Item,Cost,Twice\nNew,5,=B2*2\nA,1,=B3*2\nB,2,=B4*2\nTotal,=SUM(B2:B4),\n",
                                 locale: gb, names: .empty)
        let changes = FigureReturnDiff.changes(
            from: parked, onto: parked, to: copy.table, sidecar: nil,
            mintRow: mintRow, mintColumn: mintColumn)
        let back = applied(changes.ops, to: parked)
        XCTAssertEqual(back.table.rows.dropFirst(2).first, a, "A keeps its id below the new row")
        XCTAssertEqual(back.table.rows.last, total)
        let fresh = back.table.rows[1]
        let sum = back.table[CellKey(row: total, column: back.table.columns[1])]
        guard case .formula(let f)? = sum?.content else { return XCTFail("the total is a formula") }
        XCTAssertEqual(FormulaParser.render(f, in: back.table), "SUM(B2:B4)",
                       "the copy's wider range, now spanning the new row")
        XCTAssertNotNil(back.table[CellKey(row: fresh, column: back.table.columns[2])])
        // A's and B's formulas were left alone: only the new row and the total are written.
        let setRows = Set(changes.ops.compactMap(\.payload.cell?.row))
        XCTAssertEqual(setRows, [fresh, total])
    }

    // MARK: - Three-way (late edits)

    /// The state the copy was written from is the stream folded as far as the
    /// parker had read, per device.
    func test_theBaseIsTheStreamAsFarAsTheParkerHadRead() {
        let r = RowID("r1aaaaaa"), c = ColumnID("c1dddddd")
        func op(_ id: String, _ device: String, _ kind: OpKind, _ p: FigureOpPayload) -> Op {
            Op(opId: id, docId: "fig-k3m9q2zt", at: Date(timeIntervalSince1970: 0), device: device,
               session: "s", kind: kind, changes: [], figure: p)
        }
        let key = CellKey(row: r, column: c)
        let ops = [
            op("a1", "macA", .figureCreate, FigureOpPayload(kind: .table)),
            op("a2", "macA", .figureStructure, FigureOpPayload(structure: .insertRow(r, after: nil))),
            op("a3", "macA", .figureStructure, FigureOpPayload(structure: .insertColumn(c, after: nil))),
            op("a4", "macA", .figureCellSet, FigureOpPayload(cell: key, next: Cell(content: .value(.number(1))))),
            op("a5", "macB", .figureCellSet, FigureOpPayload(cell: key, next: Cell(content: .value(.number(2))))),
            op("a6", "macA", .figureParked, FigureOpPayload(parkedPath: "p", parkedHash: "h")),
        ]
        let base = FigureReturnDiff.base(of: ops, frontier: ["macA": "a4"])
        XCTAssertEqual(base.table[key]?.content, .value(.number(1)), "macB's edit was never read")
        XCTAssertNil(base.parked)
        XCTAssertEqual(FigureDeriver.derive(ops).table[key]?.content, .value(.number(2)),
                       "the parked state holds the late edit")
    }

    /// A late edit the copy did not touch survives a changed copy coming back;
    /// one the copy also changed takes the copy's value and is reported.
    func test_aLateEditSurvivesUnlessTheCopyChangedThatCell() {
        let base = figure("Name,Q1,Q2\nNorth,1,2\nSouth,3,4\n")
        let north = row(base, labelled: "North")!, south = row(base, labelled: "South")!
        let q1 = base.table.columns[1], q2 = base.table.columns[2]
        var current = base
        for (k, v) in [(CellKey(row: north, column: q1), 100.0), (CellKey(row: south, column: q2), 400.0)] {
            current.table.setCell(Cell(content: .value(.number(v))), at: k)
        }
        // The copy changed South's Q2 (late-edited too) and North's Q2 (not late-edited).
        let copy = TableCSV.read("Name,Q1,Q2\nNorth,1,7\nSouth,3,8\n", locale: gb, names: .empty).table
        let changes = FigureReturnDiff.changes(
            from: base, onto: current, to: copy, sidecar: nil, mintRow: mintRow, mintColumn: mintColumn)
        let back = applied(changes.ops, to: current)
        XCTAssertEqual(value(back, north, 1), .value(.number(100)), "the late edit the copy left alone stands")
        XCTAssertEqual(value(back, north, 2), .value(.number(7)))
        XCTAssertEqual(value(back, south, 2), .value(.number(8)), "the copy wins a cell both changed")
        XCTAssertEqual(changes.overwritten, [CellKey(row: south, column: q2)], "and says which")
        XCTAssertEqual(changes.ops.first { $0.payload.cell == CellKey(row: south, column: q2) }?.payload.prior?.content,
                       .value(.number(400)), "the prior is what the stream held")
    }

    /// A row a late edit inserted stays; a late edit in a row the copy deleted
    /// is reported with it.
    func test_aLateRowStays_andALateEditInADeletedRowIsReported() {
        let base = figure("Name,Q1\nNorth,1\nSouth,3\n")
        let north = row(base, labelled: "North")!, south = row(base, labelled: "South")!
        var current = base
        current.table.insertRow(RowID("late0001"), after: north)
        current.table.setCell(Cell(content: .value(.number(30))), at: CellKey(row: south, column: base.table.columns[1]))
        let copy = TableCSV.read("Name,Q1\nNorth,1\n", locale: gb, names: .empty).table
        let changes = FigureReturnDiff.changes(
            from: base, onto: current, to: copy, sidecar: nil, mintRow: mintRow, mintColumn: mintColumn)
        let back = applied(changes.ops, to: current)
        XCTAssertNil(back.table.rowIndex(of: south))
        XCTAssertNotNil(back.table.rowIndex(of: RowID("late0001")), "a row only the late edit knew stays")
        XCTAssertEqual(changes.overwritten, [CellKey(row: south, column: base.table.columns[1])])
    }

    // MARK: - Names, formats

    /// A formula naming a figure renamed while this one was parked reads back
    /// as `=…` text (an unknown name); the return keeps the old formula and the
    /// read's problem for that cell no longer stands.
    func test_aFormulaCitingARenamedFigureKeepsItsFormula() {
        let other = FigureTable(rows: 1, columns: 1)
        let atPark = FormulaNames(figures: [.init(id: "fig-other001", name: "cash", table: other)])
        let now = FormulaNames(figures: [.init(id: "fig-other001", name: "money", table: other)])
        let parked = figure("Label,Value\nCash,=cash!A1*2\n", names: atPark)
        let cash = row(parked, labelled: "Cash")!
        let written = TableCSV.renderResearch(parked.table, locale: gb, names: atPark)
        // The copy was then edited elsewhere: a row added.
        let read = TableCSV.read(written + "More,5\n", locale: gb, names: now)
        XCTAssertEqual(read.problems.count, 1, "the old name no longer reads")
        let changes = FigureReturnDiff.changes(
            from: parked, onto: parked, to: read.table, sidecar: nil, names: now, problems: read.problems,
            mintRow: mintRow, mintColumn: mintColumn)
        XCTAssertFalse(changes.ops.contains { $0.payload.cell?.row == cash }, "the cell is left as it was")
        XCTAssertEqual(changes.problems, [])
        let back = applied(changes.ops, to: parked)
        guard case .formula? = value(back, cash, 1) else { return XCTFail("still a formula") }
    }

    /// Formats come from the sidecar written for the parked CSV; without one a
    /// matched cell keeps its own and a new cell takes its suggested one.
    func test_formatsComeFromTheSidecar() {
        var parked = figure("Name,Rate\nA,0.5\n")
        let a = row(parked, labelled: "A")!, rate = parked.table.columns[1]
        var cell = parked.table[CellKey(row: a, column: rate)]!
        cell.format = CellFormat(number: .percent(decimals: 1))
        parked.table.setCell(cell, at: CellKey(row: a, column: rate))
        let copy = TableCSV.read("Name,Rate\nA,0.6\nB,12%\n", locale: gb, names: .empty).table

        let plain = applied(FigureReturnDiff.changes(
            from: parked, onto: parked, to: copy, sidecar: nil,
            mintRow: mintRow, mintColumn: mintColumn).ops, to: parked)
        XCTAssertEqual(plain.table[CellKey(row: a, column: rate)]?.format.number, .percent(decimals: 1),
                       "a matched cell keeps its format")
        let b = row(plain, labelled: "B")!
        XCTAssertEqual(plain.table[CellKey(row: b, column: rate)]?.format.number, .percent(decimals: 0),
                       "a new cell takes the one its text suggested")

        let sidecar = ResearchTableSidecar(
            headerRows: 1, totalRow: true,
            formats: [.init(row: 1, column: 1, format: CellFormat(number: .number(decimals: 3, grouping: false)))],
            columnWidths: [nil, 80])
        let styled = applied(FigureReturnDiff.changes(
            from: parked, onto: parked, to: copy, sidecar: sidecar,
            mintRow: mintRow, mintColumn: mintColumn).ops, to: parked)
        XCTAssertEqual(styled.table[CellKey(row: a, column: rate)]?.format.number, .number(decimals: 3, grouping: false))
        XCTAssertTrue(styled.table.hasTotalRow)
        XCTAssertEqual(styled.table.columnWidths[rate], 80)
    }

    // MARK: - The helpers

    func test_lcsAndLongestIncreasing() {
        XCTAssertEqual(FigureReturnDiff.lcs(["a", "b", "c", "d"], ["b", "x", "d"]).map { [$0.0, $0.1] },
                       [[1, 0], [3, 2]])
        XCTAssertEqual(FigureReturnDiff.longestIncreasing([3, 0, 1, 4, 2]), [1, 2, 4])
    }
}
