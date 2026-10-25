import XCTest
@testable import MaughamCore

final class FigureCardModelTests: XCTestCase {
    private let en = TableLocale(languageTag: "en-GB", fallbackRegion: "GB")
    private let de = TableLocale(languageTag: "de-DE", fallbackRegion: "DE")

    private func state(rows: Int, columns: Int = 2, header: Int = 0, total: Bool = false,
                       cell: (Int, Int) -> Cell? = { r, c in Cell(content: .value(.text("r\(r)c\(c)"))) }) -> FigureState {
        var t = FigureTable(rows: rows, columns: columns)
        t.headerRows = header; t.hasTotalRow = total
        for (r, rid) in t.rows.enumerated() {
            for (c, cid) in t.columns.enumerated() { t.setCell(cell(r, c), at: CellKey(row: rid, column: cid)) }
        }
        return FigureState(kind: .table, table: t)
    }

    private func build(_ s: FigureState, locale: TableLocale? = nil, language: String? = nil,
                       lookup: ((String, RowID, ColumnID, String?) -> String?)? = nil) -> FigureCardModel {
        FigureCardModel.build(figureId: "f1", state: s, values: { key in
            if case .value(let v)? = s.table[key]?.content { return v }
            return .empty
        }, locale: locale ?? en, language: language, labelLookup: lookup)
    }

    private func height(_ m: FigureCardModel) -> CGFloat {
        FigureCardLayout.height(for: m, columnWidth: 400, rowHeight: 20, moreLineHeight: 16, verticalPadding: 4, placeholderHeight: 90)
    }

    func test_threeRowTable() {
        let m = build(state(rows: 3))
        XCTAssertEqual(m.kind, .table)
        XCTAssertEqual(m.bodyRows, [["r0c0", "r0c1"], ["r1c0", "r1c1"], ["r2c0", "r2c1"]])
        XCTAssertEqual(m.headerRows, [])
        XCTAssertEqual(m.moreRows, 0)
        XCTAssertFalse(m.hasTotalRow)
        XCTAssertEqual(m.columnAlignments, [.left, .left])
    }

    func test_fortyRowTableShowsTwelveAndCountsTheRest() {
        let m = build(state(rows: 40))
        XCTAssertEqual(m.shownRowCount, 12)
        XCTAssertEqual(m.moreRows, 28)
        XCTAssertEqual(m.bodyRows.last, ["r11c0", "r11c1"])
    }

    func test_headerCountsTowardTheTwelve() {
        let m = build(state(rows: 40, header: 1))
        XCTAssertEqual(m.headerRows, [["r0c0", "r0c1"]])
        XCTAssertEqual(m.bodyRows.count, 11)
        XCTAssertEqual(m.moreRows, 28)
    }

    func test_totalRowSurvivesTruncation() {
        let m = build(state(rows: 40, header: 1, total: true))
        XCTAssertTrue(m.hasTotalRow)
        XCTAssertEqual(m.bodyRows.last, ["r39c0", "r39c1"])
        XCTAssertEqual(m.shownRowCount, 12)
        XCTAssertEqual(m.moreRows, 28)
        let short = build(state(rows: 4, header: 1, total: true))
        XCTAssertTrue(short.hasTotalRow)
        XCTAssertEqual(short.bodyRows.last, ["r3c0", "r3c1"])
    }

    func test_errorCellShowsItsErrorText() {
        let m = build(state(rows: 1, columns: 1) { _, _ in Cell(content: .value(.error(.divideByZero))) })
        XCTAssertEqual(m.bodyRows, [["#DIV/0!"]])
    }

    func test_formatsFollowTheLocale() {
        let formats: [CellFormat] = [
            CellFormat(number: .currency(symbol: nil, decimals: 2)),
            CellFormat(number: .percent(decimals: 1)),
            CellFormat(number: .date(.iso)),
        ]
        let values: [CellValue] = [.number(1234.5), .number(0.256), .date(45000)]
        let s = state(rows: 1, columns: 3) { _, c in Cell(content: .value(values[c]), format: formats[c]) }
        let uk = build(s, locale: en).bodyRows[0], de = build(s, locale: de).bodyRows[0]
        XCTAssertEqual(uk[0], "£1,234.50")
        XCTAssertEqual(uk[1], "25.6%")
        XCTAssertEqual(uk[2], "2023-03-15")
        XCTAssertTrue(de[0].contains("1.234,50"), de[0])
        XCTAssertTrue(de[0].contains("€"), de[0])
        XCTAssertTrue(de[1].contains("25,6"), de[1])
        XCTAssertEqual(de[2], "2023-03-15")
    }

    func test_alignmentsResolveFromCellsThenValues() {
        let s = state(rows: 2, columns: 3) { _, c in
            switch c {
            case 0: return Cell(content: .value(.number(1)))
            case 1: return Cell(content: .value(.text("a")))
            default: return Cell(content: .value(.number(2)), alignment: .center)
            }
        }
        XCTAssertEqual(build(s).columnAlignments, [.right, .left, .center])
    }

    func test_labelLookupAppliesToTextCellsOnly() {
        let s = state(rows: 1) { _, c in c == 0 ? Cell(content: .value(.text("Cash"))) : Cell(content: .value(.number(5))) }
        var seen: [String?] = []
        let m = build(s, language: "es") { id, _, _, lang in seen.append(lang); return id == "f1" ? "Caja" : nil }
        XCTAssertEqual(m.bodyRows, [["Caja", "5"]])
        XCTAssertEqual(seen, ["es"])
        XCTAssertEqual(build(s).bodyRows, [["Cash", "5"]])
    }

    func test_nonTableKinds() {
        var p = state(rows: 2); p.parked = FigureParking(path: "p", hash: "h")
        XCTAssertEqual(build(p).kind, .parked)
        XCTAssertEqual(build(FigureState(kind: .image)).kind, .image)
        XCTAssertEqual(FigureCardModel.placeholder(.removed).kind, .removed)
        for k: FigureCardModel.Kind in [.image, .removed, .ambiguous, .parked] {
            XCTAssertEqual(height(.placeholder(k)), 90)
        }
    }

    func test_flags() {
        var s = state(rows: 1)
        XCTAssertFalse(build(s).readsResearch); XCTAssertFalse(build(s).fromResearchSource)
        s.pins[CellKey(row: s.table.rows[0], column: s.table.columns[0])] = [FigureResearchPin(research: "i", row: 0, column: 0, value: .number(1), sourceHash: "h", at: Date())]
        s.source = FigureSource(researchItemId: "i", path: "p", contentHash: "h")
        XCTAssertTrue(build(s).readsResearch); XCTAssertTrue(build(s).fromResearchSource)
    }

    func test_heightGrowsWithShownRowsAndIsConstantPastTwelve() {
        let hs = [1, 2, 5, 12, 13, 40].map { height(build(state(rows: $0))) }
        XCTAssertEqual(hs[0], 28)
        XCTAssertLessThan(hs[0], hs[1]); XCTAssertLessThan(hs[1], hs[2]); XCTAssertLessThan(hs[2], hs[3])
        XCTAssertEqual(hs[3], 12 * 20 + 8)
        XCTAssertEqual(hs[4], 12 * 20 + 16 + 8)          // the "more" line appears once
        XCTAssertEqual(hs[4], hs[5])
        XCTAssertEqual(height(build(state(rows: 0))), 90)  // nothing to show: the placeholder
    }
}
