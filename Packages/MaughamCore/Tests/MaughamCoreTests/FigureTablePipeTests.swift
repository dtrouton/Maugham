import XCTest
@testable import MaughamCore

final class FigureTablePipeTests: XCTestCase {
    private let gb = TableLocale(languageTag: "en-GB")

    private func make(_ block: String) throws -> FigureTable {
        let text = try XCTUnwrap(TableText(parsing: block))
        return try FigureTable(pipe: text, locale: gb, names: .empty)
    }

    private func cell(_ t: FigureTable, _ r: Int, _ c: Int) -> Cell? {
        t[CellKey(row: t.rows[r], column: t.columns[c])]
    }

    func test_headerRowAndBodyAreRead() throws {
        let t = try make("| Item | Cost |\n| --- | --- |\n| Tea | 2.5 |\n| Cake | 4 |")
        XCTAssertEqual(t.headerRows, 1)
        XCTAssertEqual(t.rows.count, 3)
        XCTAssertEqual(t.columns.count, 2)
        XCTAssertEqual(cell(t, 0, 0)?.content, .value(.text("Item")))
        XCTAssertEqual(cell(t, 1, 1)?.content, .value(.number(2.5)))
    }

    func test_escapedPipeIsACellCharacter() throws {
        let t = try make("| A | B |\n| --- | --- |\n| x \\| y | 1 |")
        XCTAssertEqual(cell(t, 1, 0)?.content, .value(.text("x | y")))
    }

    func test_equalsCellIsAFormula() throws {
        let t = try make("| A | B |\n| --- | --- |\n| 1 | =A2*2 |")
        guard case .formula = cell(t, 1, 1)?.content else { return XCTFail("expected a formula") }
    }

    func test_unparseableFormulaStaysText() throws {
        let t = try make("| A | B |\n| --- | --- |\n| 1 | =NOSUCH(( |")
        XCTAssertEqual(cell(t, 1, 1)?.content, .value(.text("=NOSUCH((")))
    }

    func test_importingReturnsTheUnparseableFormulaAsAProblem() throws {
        let text = try XCTUnwrap(TableText(parsing: "| A | B |\n| --- | --- |\n| 1 | =NOSUCH(( |"))
        let result = try FigureTable.importing(pipe: text, locale: gb, names: .empty)
        XCTAssertEqual(result.problems.map { [$0.row, $0.column] }, [[1, 1]])
    }

    func test_alignmentsMapToCells() throws {
        let t = try make("| A | B | C | D |\n| :-- | :-: | --: | --- |\n| 1 | 2 | 3 | 4 |")
        XCTAssertEqual(cell(t, 1, 0)?.alignment, .left)
        XCTAssertEqual(cell(t, 1, 1)?.alignment, .center)
        XCTAssertEqual(cell(t, 1, 2)?.alignment, .right)
        XCTAssertEqual(cell(t, 1, 3)?.alignment, .automatic)
        XCTAssertEqual(cell(t, 0, 2)?.alignment, .right)
    }

    func test_captionAndLabelAreIgnored() throws {
        let t = try make("| A | B |\n| --- | --- |\n| 1 | 2 |\nTable: Costs {#tbl:costs}")
        XCTAssertEqual(t.rows.count, 2)
        XCTAssertEqual(t.columns.count, 2)
    }

    func test_cellLimitIsGuarded() {
        let width = 101
        let header = (0..<width).map { "h\($0)" }
        let body = Array(repeating: (0..<width).map { "v\($0)" }, count: 100)
        let text = TableText(header: header, alignments: Array(repeating: .none, count: width), rows: body)
        XCTAssertThrowsError(try FigureTable(pipe: text, locale: gb, names: .empty)) {
            XCTAssertEqual($0 as? FigureTablePipeError, .tooLarge(cells: width * 101))
        }
    }

    func test_csvReadStillSharesTheCellReader() {
        let viaRows = TableCSV.read(rows: [["a", "1"], ["b", "2"]], locale: gb, names: .empty).table
        let viaText = TableCSV.read("a,1\nb,2\n", locale: gb, names: .empty).table
        XCTAssertEqual(viaRows.rows.count, viaText.rows.count)
        XCTAssertEqual(viaRows.headerRows, 0)
    }
}
