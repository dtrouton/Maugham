import XCTest
@testable import MaughamCore

final class FigureCellTranslationTests: XCTestCase {
    private let r1 = RowID("aaaa1111"), r2 = RowID("bbbb2222")
    private let c1 = ColumnID("cccc3333"), c2 = ColumnID("dddd4444")

    private func table() -> FigureTable {
        var t = FigureTable(rows: 0, columns: 0)
        t.insertRow(r1, after: nil); t.insertRow(r2, after: r1)
        t.insertColumn(c1, after: nil); t.insertColumn(c2, after: c1)
        t.setCell(Cell(content: .value(.text("Rent"))), at: CellKey(row: r1, column: c1))
        t.setCell(Cell(content: .value(.number(5))), at: CellKey(row: r1, column: c2))
        t.setCell(Cell(content: .value(.text("Food"))), at: CellKey(row: r2, column: c1))
        return t
    }

    private func rec(_ key: CellKey, _ text: String?, source: String, op: String = ULID.generate(),
                     verbatim: Bool = false) -> TranslationRecord {
        TranslationRecord(opId: op, paragraphId: FigureCellTranslationKey.paragraphId(for: key),
                          language: "es", text: text, sourceHash: TranslationHash.hash(source),
                          verbatim: verbatim)
    }

    func test_keyRoundTrips_andRejectsMalformed() {
        let k = CellKey(row: r1, column: c1)
        XCTAssertEqual(FigureCellTranslationKey.paragraphId(for: k), "aaaa1111:cccc3333")
        XCTAssertEqual(FigureCellTranslationKey.cellKey(fromParagraphId: "aaaa1111:cccc3333"), k)
        for bad in ["", "aaaa1111", ":cccc3333", "aaaa1111:", "a:b:c", "pxyz"] {
            XCTAssertNil(FigureCellTranslationKey.cellKey(fromParagraphId: bad), bad)
        }
    }

    func test_isTextCell_storedNonBlankLiteralOnly() {
        func c(_ v: CellContent) -> Cell { Cell(content: v) }
        XCTAssertTrue(FigureTextCells.isTextCell(c(.value(.text("Rent")))))
        XCTAssertFalse(FigureTextCells.isTextCell(nil))
        XCTAssertFalse(FigureTextCells.isTextCell(c(.value(.text("  \n")))))
        XCTAssertFalse(FigureTextCells.isTextCell(c(.value(.number(1)))))
        XCTAssertFalse(FigureTextCells.isTextCell(c(.value(.bool(true)))))
        XCTAssertFalse(FigureTextCells.isTextCell(c(.value(.empty))))
        XCTAssertFalse(FigureTextCells.isTextCell(c(.value(.error(.ref)))))
    }

    func test_formulaTextIsExcluded() {
        var t = table()
        t.setCell(Cell(content: .formula(Formula(.text("Total")))), at: CellKey(row: r2, column: c2))
        let d = FigureTranslationDeriver.derive(records: [], table: t, language: "es")
        XCTAssertEqual(d.entries.map(\.key), [CellKey(row: r1, column: c1), CellKey(row: r2, column: c1)])
    }

    func test_freshStaleMissing_andLabels() {
        let t = table()
        let k1 = CellKey(row: r1, column: c1), k2 = CellKey(row: r2, column: c1)
        var d = FigureTranslationDeriver.derive(records: [rec(k1, "Alquiler", source: "Rent")], table: t, language: "es")
        XCTAssertEqual(d.entries.map(\.status), [.fresh, .missing])
        XCTAssertEqual(d.freshLabels, [k1: "Alquiler"])
        XCTAssertEqual(d.freshCount, 1); XCTAssertEqual(d.missingCount, 1)

        var edited = t
        edited.setCell(Cell(content: .value(.text("Rent due"))), at: k1)
        d = FigureTranslationDeriver.derive(records: [rec(k1, "Alquiler", source: "Rent")], table: edited, language: "es")
        XCTAssertEqual(d.entries.first?.status, .stale)
        XCTAssertEqual(d.staleCount, 1)
        XCTAssertTrue(d.freshLabels.isEmpty, "a stale cell falls back to the source")
        _ = k2
    }

    func test_verbatimAndLatestWinsAndTombstone() {
        let t = table(), k1 = CellKey(row: r1, column: c1)
        let a = rec(k1, "Uno", source: "Rent", op: "01A")
        let b = rec(k1, "Dos", source: "Rent", op: "01B", verbatim: true)
        var d = FigureTranslationDeriver.derive(records: [b, a], table: t, language: "es")
        XCTAssertEqual(d.entries.first?.translatedText, "Dos")
        XCTAssertEqual(d.entries.first?.verbatim, true)
        let tomb = rec(k1, nil, source: "Rent", op: "01C")
        d = FigureTranslationDeriver.derive(records: [a, b, tomb], table: t, language: "es")
        XCTAssertEqual(d.entries.first?.status, .missing)
        XCTAssertTrue(d.orphans.isEmpty, "a tombstone is not an orphan")
    }

    func test_deletedRowOrphans_reviveReattaches() {
        var t = table()
        let k2 = CellKey(row: r2, column: c1)
        let record = rec(k2, "Comida", source: "Food")
        t.deleteRow(r2)
        var d = FigureTranslationDeriver.derive(records: [record], table: t, language: "es")
        XCTAssertEqual(d.orphans.map(\.paragraphId), [record.paragraphId])
        XCTAssertEqual(d.entries.count, 1)

        XCTAssertTrue(t.reviveRow(r2))
        t.setCell(Cell(content: .value(.text("Food"))), at: k2)
        d = FigureTranslationDeriver.derive(records: [record], table: t, language: "es")
        XCTAssertTrue(d.orphans.isEmpty)
        XCTAssertEqual(d.freshLabels, [k2: "Comida"])
    }

    func test_deletedColumnOrphans() {
        var t = table()
        let record = rec(CellKey(row: r1, column: c1), "Alquiler", source: "Rent")
        t.deleteColumn(c1)
        let d = FigureTranslationDeriver.derive(records: [record], table: t, language: "es")
        XCTAssertEqual(d.orphans.count, 1)
        XCTAssertTrue(d.entries.isEmpty)
    }

    func test_textTurnedNumberIsAnOrphan_andMalformedKeyToo() {
        var t = table()
        let k1 = CellKey(row: r1, column: c1)
        let record = rec(k1, "Alquiler", source: "Rent")
        t.setCell(Cell(content: .value(.number(3))), at: k1)
        let junk = TranslationRecord(paragraphId: "p123", language: "es", text: "x", sourceHash: "h")
        let d = FigureTranslationDeriver.derive(records: [record, junk], table: t, language: "es")
        XCTAssertEqual(Set(d.orphans.map(\.paragraphId)), [record.paragraphId, "p123"])
    }
}
