import XCTest
@testable import MaughamCore

final class FigureTableLayoutTests: XCTestCase {
    private struct NoPins: ResearchPinSource {
        func pinnedValue(home: String, research: String, row: Int, column: Int) -> CellValue? { nil }
    }
    private let en = TableLocale(languageTag: "en-US", fallbackRegion: "US")
    private let es = TableLocale(languageTag: "es-ES", fallbackRegion: "ES")

    private func table(rows: Int, columns: Int = 2, header: Int = 0, total: Bool = false,
                       cell: (Int, Int) -> Cell? = { r, c in Cell(content: .value(.text("r\(r)c\(c)"))) }) -> FigureTable {
        var t = FigureTable(rows: rows, columns: columns)
        t.headerRows = header; t.hasTotalRow = total
        for (r, rid) in t.rows.enumerated() {
            for (c, cid) in t.columns.enumerated() { t.setCell(cell(r, c), at: CellKey(row: rid, column: cid)) }
        }
        return t
    }

    private func make(_ t: FigureTable, _ locale: TableLocale? = nil) -> FigureTableLayout {
        FigureTableLayout.make(table: t, value: { key in
            if case .value(let v)? = t[key]?.content { return v }
            return .empty
        }, locale: locale ?? en)
    }

    func test_everyRowPrintsWithItsFormat() {
        let fmt = CellFormat(number: .currency(symbol: "$", decimals: 2))
        let t = table(rows: 40, columns: 1) { _, _ in Cell(content: .value(.number(1234.5)), format: fmt) }
        let l = make(t)
        XCTAssertEqual(l.body.count, 40)
        XCTAssertTrue(l.body.allSatisfy { $0 == ["$1,234.50"] })
    }

    func test_spanishSeparatorsAndMonths() {
        let serial = 44927   // 2023-01-01: "ene" vs "Jan"
        let t = table(rows: 1, columns: 2) { _, c in
            c == 0 ? Cell(content: .value(.number(12345.5)), format: CellFormat(number: .number(decimals: 1, grouping: true)))
                   : Cell(content: .value(.date(serial)), format: CellFormat(number: .date(.month)))
        }
        let l = make(t, es)
        XCTAssertEqual(l.body[0][0], "12.345,5")
        let f = DateFormatter(); f.locale = Locale(identifier: "es-ES"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM"
        let month = f.string(from: Date(timeIntervalSince1970: Double(serial - 25569) * 86400))
        XCTAssertTrue(l.body[0][1].localizedCaseInsensitiveContains(month), "\(l.body[0][1]) vs \(month)")
        XCTAssertFalse(l.body[0][1].localizedCaseInsensitiveContains("Jan"), "Spanish, not English: \(l.body[0][1])")
    }

    func test_headerAndTotalRows() {
        let none = make(table(rows: 3))
        XCTAssertNil(none.header); XCTAssertNil(none.total); XCTAssertEqual(none.body.count, 3)

        let headerOnly = make(table(rows: 1, header: 1, total: true))
        XCTAssertEqual(headerOnly.header, ["r0c0", "r0c1"])
        XCTAssertEqual(headerOnly.body, []); XCTAssertNil(headerOnly.total)

        let totalOnly = make(table(rows: 3, total: true))
        XCTAssertNil(totalOnly.header)
        XCTAssertEqual(totalOnly.total, ["r2c0", "r2c1"])
        XCTAssertEqual(totalOnly.body, [["r0c0", "r0c1"], ["r1c0", "r1c1"]])

        let all = make(table(rows: 4, header: 1, total: true))
        XCTAssertEqual(all.header, ["r0c0", "r0c1"])
        XCTAssertEqual(all.body, [["r1c0", "r1c1"], ["r2c0", "r2c1"]])
        XCTAssertEqual(all.total, ["r3c0", "r3c1"])

        let headerPlusTotalOnly = make(table(rows: 2, header: 1, total: true))
        XCTAssertEqual(headerPlusTotalOnly.body, [])
        XCTAssertEqual(headerPlusTotalOnly.total, ["r1c0", "r1c1"])
    }

    func test_errorCellsAreNamedA1() {
        var t = FigureTable(rows: 4, columns: 3)
        let names = FormulaNames(figures: [], research: [])
        let k = CellKey(row: t.rows[2], column: t.columns[1])
        guard case .success(let f) = FormulaParser.parse("1/0", in: t, names: names) else { return XCTFail("parse") }
        t.setCell(Cell(content: .formula(f)), at: k)
        var book = Workbook(pins: NoPins())
        _ = book.setTable(t, id: "t1")
        let l = FigureTableLayout.make(table: t, value: { book.value(at: CellAddress(table: "t1", key: $0)) }, locale: en)
        XCTAssertEqual(l.errorCells, ["B3"])
        XCTAssertEqual(l.body[2][1], "#DIV/0!")
    }

    func test_errorCellsUseLivePositions() {
        var t = table(rows: 3, columns: 3) { _, _ in nil }
        t.deleteColumn(t.columns[0]); t.deleteRow(t.rows[0])
        let bad = CellKey(row: t.rows[0], column: t.columns[0])
        let l = FigureTableLayout.make(table: t, value: { $0 == bad ? .error(.ref) : .empty }, locale: en)
        XCTAssertEqual(l.errorCells, ["A1"])
    }

    func test_alignmentMatchesTheCard() {
        let t = table(rows: 4, columns: 4, header: 1, total: true) { r, c in
            switch c {
            case 0: return Cell(content: .value(.text("t")))
            case 1: return Cell(content: .value(.number(Double(r))))
            case 2: return r == 0 ? nil : Cell(content: .value(.text("x")), alignment: .center)
            default: return nil
            }
        }
        let value: (CellKey) -> CellValue = { key in
            if case .value(let v)? = t[key]?.content { return v }
            return .empty
        }
        let card = FigureCardModel.build(figureId: "f", state: FigureState(kind: .table, table: t),
                                         values: value, locale: en, language: nil)
        let l = FigureTableLayout.make(table: t, value: value, locale: en)
        XCTAssertEqual(l.alignments, card.columnAlignments)
        XCTAssertEqual(l.alignments, [.left, .right, .center, .left])
    }

    /// Report plan 9e-1 Task 5: a body's translated labels replace stored-literal text cells
    /// only — never a number, a formula (even one whose result is text) or a blank — and a
    /// cell the lookup has no label for prints its source.
    func test_labelsReplaceStoredTextCellsOnly() throws {
        var t = FigureTable(rows: 3, columns: 2)
        t.headerRows = 1
        let k = { (r: Int, c: Int) in CellKey(row: t.rows[r], column: t.columns[c]) }
        t.setCell(Cell(content: .value(.text("Item"))), at: k(0, 0))
        t.setCell(Cell(content: .value(.text("Amount"))), at: k(0, 1))
        t.setCell(Cell(content: .value(.text("Rent"))), at: k(1, 0))
        t.setCell(Cell(content: .value(.number(100))), at: k(1, 1))
        guard case .success(let f) = FormulaParser.parse("\"Fees\"", in: t) else { return XCTFail("parse") }
        t.setCell(Cell(content: .formula(f)), at: k(2, 0))
        t.setCell(Cell(content: .value(.number(5))), at: k(2, 1))
        let labels: [CellKey: String] = [
            k(0, 0): "Concepto", k(1, 0): "Alquiler",
            k(1, 1): "cien", k(2, 0): "Tasas",   // a number and a formula: never relabelled
        ]
        let value: (CellKey) -> CellValue = { key in
            if key == k(2, 0) { return .text("Fees") }
            if case .value(let v)? = t[key]?.content { return v }
            return .empty
        }
        let l = FigureTableLayout.make(table: t, value: value, locale: en, label: { labels[$0] })
        XCTAssertEqual(l.header, ["Concepto", "Amount"], "no label for Amount: the source prints")
        XCTAssertEqual(l.body, [["Alquiler", "100"], ["Fees", "5"]])
        XCTAssertEqual(l, FigureTableLayout.make(table: t, value: value, locale: en, label: { labels[$0] }))
        XCTAssertEqual(FigureTableLayout.make(table: t, value: value, locale: en).header, ["Item", "Amount"],
                       "no lookup: the source")
    }
}
