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

    /// **A revive clears the tombstone in place** (report plan 6b Task 4): the
    /// row returns in its own slot, so its own position, even after a
    /// neighbour landed after its tombstone; a live or never-held id is refused.
    func test_reviveRow_returnsInItsOwnSlot_andRefusesALiveOrUnknownId() {
        var t = table(rowIDs: ["a", "b", "c"])
        t.deleteRow(rid("b"))
        t.insertRow(rid("x"), after: rid("b"))
        XCTAssertTrue(t.reviveRow(rid("b")))
        XCTAssertEqual(t.rows, [rid("a"), rid("b"), rid("x"), rid("c")])
        let before = t
        XCTAssertFalse(t.reviveRow(rid("b")), "a live row is refused")
        XCTAssertFalse(t.reviveRow(rid("zzzz")), "a never-held row is refused")
        XCTAssertEqual(t, before, "and a refusal changes nothing")
    }

    func test_reviveColumn_returnsInItsOwnSlot_andRefusesALiveOrUnknownId() {
        var t = FigureTable(rows: 1, columns: 3)
        let c = t.columns
        t.deleteColumn(c[1])
        XCTAssertEqual(t.columns, [c[0], c[2]])
        XCTAssertTrue(t.reviveColumn(c[1]))
        XCTAssertEqual(t.columns, c)
        XCTAssertFalse(t.reviveColumn(c[1]))
        XCTAssertFalse(t.reviveColumn(ColumnID("nowhere0")))
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

    // MARK: the id lookup cache (R-P5-13)

    /// What the lookups answered before the cache: scans over the slots.
    private func assertLookupsMatchScans(_ t: FigureTable, ids: Set<String>, columnIDs: Set<String>,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let liveRows = t.rowSlots.filter { !$0.isDeleted }.map(\.id)
        XCTAssertEqual(t.rows, liveRows, file: file, line: line)
        XCTAssertEqual(t.columns, t.columnSlots.filter { !$0.isDeleted }.map(\.id), file: file, line: line)
        for s in ids.union(["zzzzzzzz"]) {
            let id = RowID(s)
            XCTAssertEqual(t.rowSlotIndex(of: id), t.rowSlots.firstIndex { $0.id == id }, s, file: file, line: line)
            XCTAssertEqual(t.rowIndex(of: id), liveRows.firstIndex(of: id), s, file: file, line: line)
        }
        let liveColumns = t.columnSlots.filter { !$0.isDeleted }.map(\.id)
        for s in columnIDs.union(["zzzzzzzz"]) {
            let id = ColumnID(s)
            XCTAssertEqual(t.columnSlotIndex(of: id), t.columnSlots.firstIndex { $0.id == id }, s, file: file, line: line)
            XCTAssertEqual(t.columnIndex(of: id), liveColumns.firstIndex(of: id), s, file: file, line: line)
        }
    }

    func test_decodeRoundTrip_rebuildsTheLookups_andEncodesNoCache() throws {
        var t = FigureTable(rows: 4, columns: 3)
        let r = t.rows, c = t.columns
        t.deleteRow(r[1])
        t.moveRow(r[3], after: nil)
        t.deleteColumn(c[0])
        let data = try JSONEncoder().encode(t)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["rowSlots", "columnSlots", "cells", "headerRows", "hasTotalRow", "columnWidths"])
        let back = try JSONDecoder().decode(FigureTable.self, from: data)
        XCTAssertEqual(back, t)
        XCTAssertEqual(back.rows, [r[3], r[0], r[2]])
        XCTAssertEqual(back.rowIndex(of: r[3]), 0)
        XCTAssertNil(back.rowIndex(of: r[1]))
        XCTAssertEqual(back.rowSlotIndex(of: r[1]), 2)
        XCTAssertEqual(back.columnIndex(of: c[1]), 0)
        assertLookupsMatchScans(back, ids: Set(r.map(\.raw)), columnIDs: Set(c.map(\.raw)))
    }

    func test_randomisedMutations_keepTheLookupsInStepWithTheSlots() {
        var rng = SplitMix64(seed: 0x5eed_7ab1e)
        var t = FigureTable(rows: 3, columns: 3)
        var rowIDs = Set(t.rows.map(\.raw)), columnIDs = Set(t.columns.map(\.raw))
        func pick<T>(_ xs: [T]) -> T? { xs.isEmpty ? nil : xs[Int(rng.next() % UInt64(xs.count))] }
        for step in 0..<600 {
            let allRows = t.rowSlots.map(\.id), allColumns = t.columnSlots.map(\.id)
            switch rng.next() % 9 {
            case 0: rowIDs.insert(t.insertRow(after: pick(allRows)).raw)
            case 1:                                                       // a replayed insert, sometimes a repeat
                let id = rng.next() % 4 == 0 ? (pick(allRows) ?? RowID("r0000000")) : RowID("r\(step)")
                t.insertRow(id, after: rng.next() % 5 == 0 ? nil : pick(allRows))
                rowIDs.insert(id.raw)
            case 2: if let id = pick(allRows) { t.deleteRow(id) }
            case 3: if let id = pick(allRows) { t.moveRow(id, after: rng.next() % 4 == 0 ? nil : pick(allRows)) }
            case 4: columnIDs.insert(t.insertColumn(after: pick(allColumns)).raw)
            case 5:
                let id = ColumnID("c\(step)")
                t.insertColumn(id, after: pick(allColumns))
                columnIDs.insert(id.raw)
            case 6: if let id = pick(allColumns) { t.deleteColumn(id) }
            case 7: if let id = pick(allColumns) { t.moveColumn(id, after: pick(allColumns)) }
            default:                                                      // a copy mutated apart keeps its own lookups
                var copy = t
                if let id = pick(copy.rows) { copy.deleteRow(id) }
                assertLookupsMatchScans(copy, ids: rowIDs, columnIDs: columnIDs)
            }
            assertLookupsMatchScans(t, ids: rowIDs, columnIDs: columnIDs)
        }
    }
}
