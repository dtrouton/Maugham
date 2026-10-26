import XCTest
@testable import MaughamCore

/// `FigurePaste` (report plan 7d Task 1, rulings R7d-2 and R7d-3): a paste as
/// ops — the table grows past its edge, a same-table copy's formulas move,
/// and a paste past `TableCSV.figureCellLimit` is refused.
final class FigurePasteTests: XCTestCase {

    private struct NotAPaste: Error {}

    private func num(_ x: Double) -> Cell { Cell(content: .value(.number(x))) }
    private func text(_ t: String) -> Cell { Cell(content: .value(.text(t))) }

    private func state(rows: Int, columns: Int) -> FigureState {
        FigureState(kind: .table, table: FigureTable(rows: rows, columns: columns))
    }

    private func key(_ s: FigureState, _ r: Int, _ c: Int) -> CellKey {
        CellKey(row: s.table.rows[r], column: s.table.columns[c])
    }

    private func plan(_ outcome: FigurePaste.Outcome, file: StaticString = #filePath, line: UInt = #line) throws -> FigurePaste.Plan {
        guard case .paste(let plan) = outcome else {
            XCTFail("expected a paste, got \(outcome)", file: file, line: line)
            throw NotAPaste()
        }
        return plan
    }

    private var counter = 0
    private func applied(_ changes: [FigureReturnDiff.Change], to s: FigureState) -> FigureState {
        applied(changes.map { ($0.kind, $0.payload) }, to: s)
    }
    private func applied(_ steps: [(OpKind, FigureOpPayload)], to s: FigureState) -> FigureState {
        var out = s
        for (kind, payload) in steps {
            counter += 1
            FigureDeriver.fold(Op(opId: "op\(counter)", docId: "fig-a", at: Date(timeIntervalSince1970: TimeInterval(counter)),
                                  device: "d", session: "s", kind: kind, changes: [], figure: payload), into: &out)
        }
        return out
    }

    private func values(_ s: FigureState) -> [[Double?]] {
        s.table.rows.map { r in
            s.table.columns.map { c in
                if case .value(.number(let x))? = s.table[CellKey(row: r, column: c)]?.content { return x }
                return nil
            }
        }
    }

    /// Review Focus 1: a 3×4 block from Excel pasted at C8 of a 10-row,
    /// 4-column table grows it two columns, and one compensating visit (one
    /// ⌘Z) takes the growth and the values back.
    func test_aBlockPastTheRightEdgeGrowsTheTable_andOneVisitUndoesIt() throws {
        let before = state(rows: 10, columns: 4)
        let anchor = key(before, 7, 2)   // C8
        let block = FigurePaste.Block(cells: (0..<3).map { r in (0..<4).map { c in num(Double(r * 10 + c)) } })
        let p = try plan(FigurePaste.changes(state: before, anchor: anchor, block: block))
        XCTAssertEqual(p.insertedColumns.count, 2)
        XCTAssertEqual(p.insertedRows, [], "rows 8–10 are already there")
        XCTAssertEqual(p.changes.prefix(2).map(\.kind), [.figureStructure, .figureStructure], "growth first")
        XCTAssertTrue(FigureReturnDiff.everyChangeApplies(p.changes, onto: before))

        let after = applied(p.changes, to: before)
        XCTAssertEqual(after.table.columns.count, 6)
        XCTAssertEqual(after.table.columns.suffix(2), p.insertedColumns[...], "the new columns follow the last")
        XCTAssertEqual(values(after)[7], [nil, nil, 0, 1, 2, 3])
        XCTAssertEqual(values(after)[9], [nil, nil, 20, 21, 22, 23])
        XCTAssertEqual(p.pasted, FigureGridSelection(anchor: anchor, focus: CellKey(row: after.table.rows[9],
                                                                                 column: after.table.columns[5])))

        let undo = FigureInverse.compensating(visit: p.changes.map { ($0.kind, $0.payload) })
        XCTAssertEqual(undo.count, p.changes.count, "every op of a paste has an inverse")
        let undone = applied(undo, to: after)
        XCTAssertEqual(undone.table.rows, before.table.rows)
        XCTAssertEqual(undone.table.columns, before.table.columns)
        XCTAssertEqual(undone.table.cells, before.table.cells)
    }

    /// The controller's ruling on R7d-2: a total row is never pasted over.
    /// Review Focus 1 with a total row: the block's three rows land in rows 8
    /// and 9 and one new body row inserted before the total, which stays last
    /// with its cells; one compensating visit restores the table.
    func test_withATotalRow_growthGoesAboveIt_andItsCellsAreNeverWritten() throws {
        var before = state(rows: 10, columns: 4)
        before.table.headerRows = 1
        before.table.hasTotalRow = true
        let total = before.table.rows[9]
        for c in 0..<4 { before.table.setCell(text("Σ"), at: key(before, 9, c)) }
        let anchor = key(before, 7, 2)   // C8
        let block = FigurePaste.Block(cells: (0..<3).map { r in (0..<4).map { c in num(Double(r * 10 + c)) } })
        let p = try plan(FigurePaste.changes(state: before, anchor: anchor, block: block))
        XCTAssertEqual(p.insertedRows.count, 1, "rows 8 and 9 hold two; one more goes in")
        XCTAssertEqual(p.insertedColumns.count, 2)
        let after = applied(p.changes, to: before)
        XCTAssertEqual(after.diagnostics, [])
        XCTAssertEqual(after.table.rows.last, total, "the total row stays last")
        XCTAssertEqual(after.table.rows[9], p.insertedRows[0], "the new row sits just above it")
        XCTAssertEqual(values(after)[9], [nil, nil, 20, 21, 22, 23])
        for c in 0..<4 { XCTAssertEqual(after.table[CellKey(row: total, column: after.table.columns[c])], text("Σ")) }
        XCTAssertNil(after.table[CellKey(row: total, column: after.table.columns[4])], "nor written in a grown column")
        XCTAssertEqual(p.pasted, FigureGridSelection(anchor: anchor, focus: CellKey(row: p.insertedRows[0],
                                                                                 column: after.table.columns[5])))

        let undone = applied(FigureInverse.compensating(visit: p.changes.map { ($0.kind, $0.payload) }), to: after)
        XCTAssertEqual(undone.table.rows, before.table.rows)
        XCTAssertEqual(undone.table.columns, before.table.columns)
        XCTAssertEqual(undone.table.cells, before.table.cells)
    }

    /// Anchored ON the total row, the block goes into new body rows just
    /// above it — the paste begins there, and a same-table formula moves to
    /// where it landed.
    func test_anchoredOnTheTotalRow_theBlockGoesIntoNewBodyRowsAboveIt() throws {
        var before = state(rows: 3, columns: 2)
        before.table.hasTotalRow = true
        let total = before.table.rows[2]
        before.table.setCell(text("total"), at: key(before, 2, 0))
        let f = try FormulaParser.parse("A1", in: before.table).get()      // as it sat in B1
        let block = FigurePaste.Block(cells: [[num(1), Cell(content: .formula(f))], [num(2), nil]],
                                      copiedFrom: FigurePaste.Position(row: 0, column: 0))
        let p = try plan(FigurePaste.changes(state: before, anchor: CellKey(row: total, column: before.table.columns[0]),
                                             block: block))
        XCTAssertEqual(p.insertedRows.count, 2)
        let after = applied(p.changes, to: before)
        XCTAssertEqual(after.table.rows, [before.table.rows[0], before.table.rows[1]] + p.insertedRows + [total])
        XCTAssertEqual(values(after).map { $0[0] }, [nil, nil, 1, 2, nil])
        XCTAssertEqual(after.table[key(after, 4, 0)], text("total"), "the total row is untouched")
        XCTAssertEqual(p.pasted.anchor, CellKey(row: p.insertedRows[0], column: before.table.columns[0]),
                       "the paste starts at the first new row, not the total row")
        guard case .formula(let moved)? = after.table[key(after, 2, 1)]?.content else { return XCTFail("no formula") }
        XCTAssertEqual(FormulaParser.render(moved, in: after.table), "A3", "moved two rows down, to where it landed")
    }

    /// A total row that is the table's only row below the header: the body is
    /// empty, so everything pasted goes in above it.
    func test_aTotalRowWithNoBodyAboveIt() throws {
        var before = state(rows: 1, columns: 1)
        before.table.hasTotalRow = true
        let total = before.table.rows[0]
        let p = try plan(FigurePaste.changes(state: before, anchor: key(before, 0, 0),
                                             block: FigurePaste.Block(cells: [[num(1)]])))
        let after = applied(p.changes, to: before)
        XCTAssertEqual(after.table.rows, p.insertedRows + [total])
        XCTAssertEqual(values(after).map { $0[0] }, [1, nil])
    }

    func test_aBlockPastTheBottomGrowsRows_afterTheLastRow_withFreshIds() throws {
        var before = state(rows: 2, columns: 2)
        before.table.deleteRow(before.table.rows[1])        // a tombstone the mint must avoid
        let tombstone = before.table.rowSlots[1].id
        var minted = [tombstone, RowID("newrow01"), RowID("newrow02")]
        let p = try plan(FigurePaste.changes(
            state: before, anchor: key(before, 0, 0),
            block: FigurePaste.Block(cells: [[num(1)], [num(2)], [num(3)]]),
            mintRow: { minted.removeFirst() }))
        XCTAssertEqual(p.insertedRows, [RowID("newrow01"), RowID("newrow02")], "never an id the table has held")
        let after = applied(p.changes, to: before)
        XCTAssertEqual(values(after).map { $0[0] }, [1, 2, 3])
        XCTAssertEqual(after.diagnostics, [])
    }

    /// R7d-3: Maugham's own copy carries formulas; pasted they move by how
    /// far each cell moved, against the grown table.
    func test_aSameTableCopyTranslatesItsFormulas_intoGrownRows() throws {
        var before = state(rows: 3, columns: 2)
        let f = try FormulaParser.parse("A1+$A$1", in: before.table).get()   // as it sat in B1
        before.table.setCell(num(5), at: key(before, 0, 0))
        let block = FigurePaste.Block(cells: [[Cell(content: .formula(f))]],
                                      copiedFrom: FigurePaste.Position(row: 0, column: 1))
        let p = try plan(FigurePaste.changes(state: before, anchor: key(before, 3 - 1, 1), block: block))
        var after = applied(p.changes, to: before)
        guard case .formula(let pasted)? = after.table[key(after, 2, 1)]?.content else { return XCTFail("no formula") }
        XCTAssertEqual(FormulaParser.render(pasted, in: after.table), "A3+$A$1")

        // Into a row the paste itself adds: a ref two rows down lands in it.
        let g = try FormulaParser.parse("A2", in: before.table).get()   // as it sat in B2: the cell to its left
        let p2 = try plan(FigurePaste.changes(
            state: before, anchor: key(before, 2, 1),
            block: FigurePaste.Block(cells: [[nil], [Cell(content: .formula(g))]],
                                     copiedFrom: FigurePaste.Position(row: 0, column: 1))))
        after = applied(p2.changes, to: before)
        XCTAssertEqual(after.table.rows.count, 4, "one row grown")
        guard case .formula(let moved)? = after.table[key(after, 3, 1)]?.content else { return XCTFail("no formula") }
        XCTAssertEqual(FormulaParser.render(moved, in: after.table), "A4", "copied from B2 (A2), pasted at B4")
    }

    /// Text from another app pastes formulas as given (no `copiedFrom`).
    func test_withoutACopyOrigin_formulasPasteAsGiven() throws {
        let before = state(rows: 3, columns: 2)
        let f = try FormulaParser.parse("A1", in: before.table).get()
        let p = try plan(FigurePaste.changes(
            state: before, anchor: key(before, 2, 1), block: FigurePaste.Block(cells: [[Cell(content: .formula(f))]])))
        let after = applied(p.changes, to: before)
        XCTAssertEqual(after.table[key(after, 2, 1)]?.content, .formula(f))
    }

    /// Excel: one copied cell into a range fills it; a block tiles a range a
    /// whole multiple of its size, and pastes once into any other.
    func test_tilingIntoAWholeMultipleSelection() throws {
        let before = state(rows: 4, columns: 4)
        let one = try plan(FigurePaste.changes(state: before, anchor: key(before, 0, 0),
                                               block: FigurePaste.Block(cells: [[num(7)]]), area: (rows: 2, columns: 3)))
        XCTAssertEqual(values(applied(one.changes, to: before)).prefix(3).map { Array($0) }, [
            [7, 7, 7, nil], [7, 7, 7, nil], [nil, nil, nil, nil],
        ])
        let two = FigurePaste.Block(cells: [[num(1), num(2)]])
        let tiled = try plan(FigurePaste.changes(state: before, anchor: key(before, 0, 0), block: two, area: (rows: 2, columns: 4)))
        XCTAssertEqual(values(applied(tiled.changes, to: before))[1], [1, 2, 1, 2])
        let once = try plan(FigurePaste.changes(state: before, anchor: key(before, 0, 0), block: two, area: (rows: 2, columns: 3)))
        XCTAssertEqual(values(applied(once.changes, to: before)).prefix(2).map { Array($0) },
                       [[1, 2, nil, nil], [nil, nil, nil, nil]], "3 is not a multiple of 2: pasted once")
    }

    func test_nilClears_aRaggedRowLeavesTheRest_andUnchangedCellsAreLeftOut() throws {
        var before = state(rows: 2, columns: 3)
        for c in 0..<3 { before.table.setCell(num(9), at: key(before, 0, c)) }
        before.table.setCell(num(9), at: key(before, 1, 2))
        let p = try plan(FigurePaste.changes(state: before, anchor: key(before, 0, 0),
                                             block: FigurePaste.Block(cells: [[nil, num(9), num(1)], [text("x")]])))
        XCTAssertEqual(p.changes.count, 3, "B1 already holds 9: no op")
        let after = applied(p.changes, to: before)
        XCTAssertNil(after.table[key(after, 0, 0)])
        XCTAssertEqual(after.table[key(after, 1, 0)], text("x"))
        XCTAssertEqual(after.table[key(after, 1, 2)], num(9), "a short row leaves the targets past its end")
    }

    // MARK: - The limit (R7d-2)

    func test_aBlockOverTheLimitIsRefused() {
        let before = state(rows: 1, columns: 1)
        let wide = TableCSV.figureCellLimit / 100 + 1
        let block = FigurePaste.Block(cells: Array(repeating: Array(repeating: nil, count: wide), count: 100))
        XCTAssertEqual(FigurePaste.changes(state: before, anchor: key(before, 0, 0), block: block),
                       .tooLarge(cells: 100 * wide), "even empty cells: a block that size is refused before growth")
    }

    func test_aPasteLeavingTooManyFilledCellsIsRefused_atTheLimitItPastes() throws {
        var before = state(rows: 100, columns: 100)
        for r in 0..<100 { for c in 0..<99 { before.table.setCell(num(1), at: key(before, r, c)) } }   // 9 900 filled
        let fits = FigurePaste.Block(cells: (0..<100).map { _ in [num(2)] })                           // column 100: 10 000
        XCTAssertNoThrow(try plan(FigurePaste.changes(state: before, anchor: key(before, 0, 99), block: fits)))
        let over = FigurePaste.Block(cells: (0..<100).map { _ in [num(2), num(2)] })                    // grows a column
        XCTAssertEqual(FigurePaste.changes(state: before, anchor: key(before, 0, 99), block: over), .tooLarge(cells: 10_100))
        let overwrite = FigurePaste.Block(cells: (0..<100).map { _ in [num(3), num(3)] })
        XCTAssertNoThrow(try plan(FigurePaste.changes(state: before, anchor: key(before, 0, 98), block: overwrite)),
                         "overwriting filled cells adds none")
    }

    func test_aGoneAnchor_andAnEmptyBlock() throws {
        let before = state(rows: 1, columns: 1)
        XCTAssertEqual(FigurePaste.changes(state: before, anchor: CellKey(row: RowID("zzzzzzzz"), column: before.table.columns[0]),
                                           block: FigurePaste.Block(cells: [[num(1)]])), .anchorGone)
        XCTAssertEqual(try plan(FigurePaste.changes(state: before, anchor: key(before, 0, 0), block: FigurePaste.Block(cells: []))).changes, [])
    }
}
