import XCTest
@testable import MaughamCore

final class FigureTableTests: XCTestCase {
    private func rid(_ s: String) -> RowID { RowID(s) }

    /// A table whose rows have the given ids (columns: 1).
    private func table(rowIDs: [String]) -> FigureTable {
        var t = FigureTable(rows: 0, columns: 1)
        var prev: RowID?
        for s in rowIDs { t.insertRow(rid(s), after: prev); prev = rid(s) }
        return t
    }

    func test_mint_isEightCharactersOfTheParagraphAlphabet_andAvoidsUsed() {
        let alphabet = Set("0123456789abcdefghjkmnpqrstvwxyz")
        var used = Set<String>()
        for _ in 0..<1000 {
            let id = TableID.mint(excluding: used)
            XCTAssertEqual(id.count, 8)
            XCTAssertTrue(id.allSatisfy { alphabet.contains($0) })
            XCTAssertTrue(used.insert(id).inserted, "duplicate \(id)")
        }
    }

    func test_init_mintsDistinctIdsInOrder() {
        let t = FigureTable(rows: 3, columns: 2)
        XCTAssertEqual(t.rows.count, 3)
        XCTAssertEqual(t.columns.count, 2)
        let raws = t.rows.map(\.raw) + t.columns.map(\.raw)
        XCTAssertEqual(Set(raws).count, 5)
    }

    func test_insertRow_afterTombstone_landsAfterIt() {
        var t = table(rowIDs: ["a", "b", "c"])
        t.deleteRow(rid("b"))
        t.insertRow(rid("x"), after: rid("b"))
        XCTAssertEqual(t.rows, [rid("a"), rid("x"), rid("c")])
        XCTAssertEqual(t.rowSlotIndex(of: rid("x")), t.rowSlotIndex(of: rid("b"))! + 1)
    }

    func test_insertRow_nilAfter_insertsAtTop() {
        var t = table(rowIDs: ["a"])
        t.insertRow(rid("x"), after: nil)
        XCTAssertEqual(t.rows, [rid("x"), rid("a")])
    }

    func test_insertRow_unknownAfter_appends() {
        var t = table(rowIDs: ["a", "b"])
        t.insertRow(rid("x"), after: rid("zzz"))
        XCTAssertEqual(t.rows, [rid("a"), rid("b"), rid("x")])
    }

    func test_insertRow_replayedID_isIdempotent() {
        var t = table(rowIDs: ["a", "b"])
        t.insertRow(rid("x"), after: rid("a"))
        let once = t
        t.insertRow(rid("x"), after: rid("b"))
        XCTAssertEqual(t, once)
    }

    func test_insertRow_minted_isNewAndPlaced() {
        var t = FigureTable(rows: 2, columns: 1)
        let first = t.rows[0]
        let new = t.insertRow(after: first)
        XCTAssertEqual(t.rowIndex(of: new), 1)
        XCTAssertEqual(t.rows.count, 3)
    }

    func test_insertColumn_afterAndIdempotent() {
        var t = FigureTable(rows: 1, columns: 2)
        let c0 = t.columns[0]
        let n = t.insertColumn(after: c0)
        XCTAssertEqual(t.columnIndex(of: n), 1)
        let before = t
        t.insertColumn(n, after: nil)
        XCTAssertEqual(t, before)
    }

    func test_deleteRow_removesItsCells_keepsSlot() {
        var t = table(rowIDs: ["a", "b"])
        let col = t.columns[0]
        t.setCell(Cell(content: .value(.number(1))), at: CellKey(row: rid("a"), column: col))
        t.setCell(Cell(content: .value(.number(2))), at: CellKey(row: rid("b"), column: col))
        t.deleteRow(rid("b"))
        XCTAssertFalse(t.cells.keys.contains { $0.row == rid("b") })
        XCTAssertEqual(t.cells.count, 1)
        XCTAssertNil(t.rowIndex(of: rid("b")))
        XCTAssertNotNil(t.rowSlotIndex(of: rid("b")))
    }

    func test_deleteColumn_removesItsCells_keepsSlot() {
        var t = FigureTable(rows: 1, columns: 2)
        let key = CellKey(row: t.rows[0], column: t.columns[1])
        t.setCell(Cell(content: .value(.text("x"))), at: key)
        let gone = t.columns[1]
        t.deleteColumn(gone)
        XCTAssertTrue(t.cells.isEmpty)
        XCTAssertNil(t.columnIndex(of: gone))
        XCTAssertNotNil(t.columnSlotIndex(of: gone))
    }

    func test_setCell_onDeletedRow_isIgnored() {
        var t = table(rowIDs: ["a", "b"])
        t.deleteRow(rid("b"))
        t.setCell(Cell(content: .value(.number(1))), at: CellKey(row: rid("b"), column: t.columns[0]))
        t.setCell(Cell(content: .value(.number(1))), at: CellKey(row: rid("nope"), column: t.columns[0]))
        XCTAssertTrue(t.cells.isEmpty)
    }

    func test_setCell_nilClears() {
        var t = FigureTable(rows: 1, columns: 1)
        let key = CellKey(row: t.rows[0], column: t.columns[0])
        t.setCell(Cell(content: .value(.bool(true))), at: key)
        XCTAssertNotNil(t[key])
        t.setCell(nil, at: key)
        XCTAssertNil(t[key])
    }

    func test_moveRow_changesLiveOrder() {
        var t = table(rowIDs: ["a", "b", "c"])
        t.moveRow(rid("a"), after: rid("c"))
        XCTAssertEqual(t.rows, [rid("b"), rid("c"), rid("a")])
        t.moveRow(rid("a"), after: nil)
        XCTAssertEqual(t.rows, [rid("a"), rid("b"), rid("c")])
    }

    func test_moveRow_deletedRow_isIgnored() {
        var t = table(rowIDs: ["a", "b", "c"])
        t.deleteRow(rid("a"))
        let before = t
        t.moveRow(rid("a"), after: rid("c"))
        XCTAssertEqual(t, before)
    }

    func test_moveColumn_changesLiveOrder() {
        var t = FigureTable(rows: 0, columns: 3)
        let cs = t.columns
        t.moveColumn(cs[0], after: cs[2])
        XCTAssertEqual(t.columns, [cs[1], cs[2], cs[0]])
    }

    func test_headerRows_clampsToZeroOrOne() {
        var t = FigureTable(rows: 1, columns: 1)
        t.headerRows = 5
        XCTAssertEqual(t.headerRows, 1)
        t.headerRows = -3
        XCTAssertEqual(t.headerRows, 0)
        t.headerRows = 1
        XCTAssertEqual(t.headerRows, 1)
    }

    func test_codableRoundTrip() throws {
        var t = FigureTable(rows: 3, columns: 3)
        let r = t.rows, c = t.columns
        let values: [CellValue] = [.empty, .number(1.5), .date(46000), .text("hi"), .bool(true), .error(.circular)]
        let formats: [CellFormat] = [
            CellFormat(),
            CellFormat(number: .number(decimals: 2, grouping: true), negatives: .parentheses, zeroAsDash: true),
            CellFormat(number: .currency(symbol: nil, decimals: 0)),
            CellFormat(number: .currency(symbol: "€", decimals: 2)),
            CellFormat(number: .percent(decimals: 1)),
            CellFormat(number: .compact(decimals: 1)),
            CellFormat(number: .date(.quarter)),
        ]
        for (i, v) in values.enumerated() {
            t.setCell(Cell(content: .value(v), format: formats[i], alignment: .right),
                      at: CellKey(row: r[i % 3], column: c[(i / 3) % 3]))
        }
        t.setCell(Cell(content: .value(.number(9)), format: formats[6], alignment: .center),
                  at: CellKey(row: r[2], column: c[2]))
        let formula = try FormulaParser.parse("SUM($A$1:B3)*2%", in: t).get()
        t.setCell(Cell(content: .formula(formula)), at: CellKey(row: r[0], column: c[0]))
        t.headerRows = 1
        t.hasTotalRow = true
        t.columnWidths[c[0]] = 120.5
        t.deleteRow(r[1])
        t.deleteColumn(c[2])
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(FigureTable.self, from: data)
        XCTAssertEqual(back, t)
        XCTAssertNotNil(back.rowSlotIndex(of: r[1]))
    }
}
