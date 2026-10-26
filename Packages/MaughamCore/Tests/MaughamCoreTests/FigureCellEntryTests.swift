import XCTest
@testable import MaughamCore

/// Typing into a grid cell (report plan 7c Task 3): text → `Cell`, and the formula bar's text back.
final class FigureCellEntryTests: XCTestCase {
    private let gb = TableLocale(languageTag: "en-GB", fallbackRegion: "GB")
    private let us = TableLocale(languageTag: "en-US", fallbackRegion: "US")
    private let de = TableLocale(languageTag: "de-DE", fallbackRegion: "DE")

    private let table = FigureTable(rows: 6, columns: 4)

    private func key(_ a1: String) -> CellKey {
        let p = A1.parse(a1)!
        return CellKey(row: table.rows[p.row], column: table.columns[p.column])
    }

    private func entry(_ text: String, prior: Cell? = nil, locale: TableLocale? = nil,
                       names: FormulaNames = .empty) -> Result<Cell?, FormulaParseError> {
        FigureCellEntry.cell(from: text, prior: prior, table: table, names: names, locale: locale ?? gb)
    }

    private func cell(_ text: String, prior: Cell? = nil, locale: TableLocale? = nil,
                      file: StaticString = #filePath, line: UInt = #line) -> Cell? {
        switch entry(text, prior: prior, locale: locale) {
        case .success(let c): return c
        case .failure(let e): XCTFail("refused \(text): \(e.message)", file: file, line: line); return nil
        }
    }

    // MARK: Entry

    func test_aPlainNumberIsANumberInGeneral() {
        XCTAssertEqual(cell("42.5"), Cell(content: .value(.number(42.5))))
    }

    func test_aGroupedNumberSuggestsGroupedNumberFormat() {
        XCTAssertEqual(cell("1,234.50"),
                       Cell(content: .value(.number(1234.5)), format: CellFormat(number: .number(decimals: 2, grouping: true))))
    }

    func test_aPercentIsAFractionInPercentFormat() {
        XCTAssertEqual(cell("15%"), Cell(content: .value(.number(0.15)), format: CellFormat(number: .percent(decimals: 0))))
    }

    func test_currencyInTheBooksSymbolTakesTheLocalesCurrency() {
        XCTAssertEqual(cell("£1,200"),
                       Cell(content: .value(.number(1200)), format: CellFormat(number: .currency(symbol: nil, decimals: 0))))
        XCTAssertEqual(cell("$3.50"),
                       Cell(content: .value(.number(3.5)), format: CellFormat(number: .currency(symbol: "$", decimals: 2))))
    }

    func test_aDateReadsInTheBooksDayOrder() {
        let serial = DateSerial.serial(year: 2026, month: 3, day: 4)!
        XCTAssertEqual(cell("4/3/2026"), Cell(content: .value(.date(serial)), format: CellFormat(number: .date(.day))))
        XCTAssertEqual(cell("3/4/2026", locale: us), Cell(content: .value(.date(serial)), format: CellFormat(number: .date(.day))))
    }

    func test_textIsText_andAnApostropheForcesText() {
        XCTAssertEqual(cell("Revenue"), Cell(content: .value(.text("Revenue"))))
        XCTAssertEqual(cell("'123"), Cell(content: .value(.text("123"))))
        XCTAssertEqual(cell("'=A1"), Cell(content: .value(.text("=A1"))))
    }

    func test_aFormulaParsesAgainstTheTablesIds() {
        guard case .formula(let f)? = cell("=SUM(B1:B3)")?.content else { return XCTFail("not a formula") }
        XCTAssertEqual(FormulaParser.render(f, in: table), "SUM(B1:B3)")
    }

    func test_aFormulaThatWillNotParseReturnsTheErrorAtItsOffsetInTheTypedText() {
        guard case .failure(let e) = entry("=SUM(B1:") else { return XCTFail("parsed") }
        guard case .failure(let inner) = FormulaParser.parse("SUM(B1:", in: table) else { return XCTFail("parsed") }
        XCTAssertEqual(e.message, inner.message)
        XCTAssertEqual(e.offset, inner.offset + 1, "the offset counts the \"=\"")
        guard case .failure(let padded) = entry("  =SUM(B1:") else { return XCTFail("parsed") }
        XCTAssertEqual(padded.offset, inner.offset + 3, "and any leading space before it")
    }

    func test_emptyTextClearsTheCell() {
        XCTAssertEqual(cell(""), Cell?.none)
        XCTAssertEqual(cell("   ", prior: Cell(content: .value(.number(3)))), Cell?.none)
    }

    func test_emptyTextKeepsAPriorFormatOrAlignmentOnAnEmptyCell() {
        let prior = Cell(content: .value(.number(3)), format: CellFormat(number: .percent(decimals: 1)), alignment: .right)
        XCTAssertEqual(cell("", prior: prior),
                       Cell(content: .value(.empty), format: CellFormat(number: .percent(decimals: 1)), alignment: .right))
    }

    // MARK: Prior format

    func test_aPriorFormatIsKept_aSuggestionOnlyReplacesGeneral() {
        let currency = CellFormat(number: .currency(symbol: nil, decimals: 2), negatives: .parentheses)
        let prior = Cell(content: .value(.number(1)), format: currency, alignment: .center)
        XCTAssertEqual(cell("15%", prior: prior), Cell(content: .value(.number(0.15)), format: currency, alignment: .center))
        XCTAssertEqual(cell("7", prior: prior), Cell(content: .value(.number(7)), format: currency, alignment: .center))

        let general = Cell(content: .value(.number(1)), format: CellFormat(negatives: .parentheses, zeroAsDash: true), alignment: .left)
        XCTAssertEqual(cell("15%", prior: general),
                       Cell(content: .value(.number(0.15)),
                            format: CellFormat(number: .percent(decimals: 0), negatives: .parentheses, zeroAsDash: true),
                            alignment: .left), "the suggestion replaces only the number kind; the rest of the format stays")
    }

    func test_aFormulaKeepsThePriorFormatAndAlignment() {
        let prior = Cell(content: .value(.number(1)), format: CellFormat(number: .percent(decimals: 2)), alignment: .right)
        let made = cell("=B1*2", prior: prior)
        XCTAssertEqual(made?.format, prior.format)
        XCTAssertEqual(made?.alignment, .right)
    }

    // MARK: Formula bar

    private func bar(_ c: Cell?, locale: TableLocale? = nil, names: FormulaNames = .empty) -> String {
        FigureCellEntry.formulaBarText(for: c, table: table, names: names, locale: locale ?? gb)
    }

    func test_formulaBarShowsTheFormulaWithItsEquals() {
        let c = cell("=sum(b1:b3)*2")
        XCTAssertEqual(bar(c), "=SUM(B1:B3)*2")
    }

    func test_formulaBarShowsTheRawNumber_notItsDisplay() {
        XCTAssertEqual(bar(cell("£1,234.567")), "1234.567")
        XCTAssertEqual(bar(Cell(content: .value(.number(0.1 + 0.2)))), "0.3")
        XCTAssertEqual(bar(Cell(content: .value(.number(-2.5)))), "-2.5")
        XCTAssertEqual(bar(Cell(content: .value(.number(1234.5))), locale: de), "1234,5")
    }

    func test_formulaBarShowsAPercentCellAsAPercent() {
        XCTAssertEqual(bar(cell("12.5%")), "12.5%")
    }

    func test_formulaBarShowsADateInTheBooksDayOrder() {
        let serial = DateSerial.serial(year: 2026, month: 3, day: 4)!
        XCTAssertEqual(bar(Cell(content: .value(.date(serial)))), "4/3/2026")
        XCTAssertEqual(bar(Cell(content: .value(.date(serial))), locale: us), "3/4/2026")
    }

    func test_formulaBarQuotesTextThatWouldReadAsSomethingElse() {
        XCTAssertEqual(bar(Cell(content: .value(.text("Revenue")))), "Revenue")
        XCTAssertEqual(bar(Cell(content: .value(.text("123")))), "'123")
        XCTAssertEqual(bar(Cell(content: .value(.text("=A1")))), "'=A1")
        XCTAssertEqual(bar(Cell(content: .value(.text("true")))), "'true")
        XCTAssertEqual(bar(Cell(content: .value(.text("'quoted")))), "''quoted")
    }

    func test_formulaBarShowsBooleansAndEmpty() {
        XCTAssertEqual(bar(Cell(content: .value(.bool(true)))), "TRUE")
        XCTAssertEqual(bar(nil), "")
        XCTAssertEqual(bar(Cell(content: .value(.empty))), "")
    }

    func test_theBarsTextEntersBackAsTheSameCell() {
        let serial = DateSerial.serial(year: 2026, month: 3, day: 4)!
        let cells: [Cell] = [
            Cell(content: .value(.number(1234.567)), format: CellFormat(number: .currency(symbol: nil, decimals: 2))),
            Cell(content: .value(.number(0.125)), format: CellFormat(number: .percent(decimals: 1))),
            Cell(content: .value(.number(1e20))),
            Cell(content: .value(.number(-1.5e-12))),
            Cell(content: .value(.date(serial)), format: CellFormat(number: .date(.day))),
            Cell(content: .value(.text("123"))),
            Cell(content: .value(.text("  spaced"))),
            Cell(content: .value(.bool(false))),
            cell("=SUM(B1:B3)")!,
        ]
        for locale in [gb, us, de] {
            for c in cells {
                let text = bar(c, locale: locale)
                XCTAssertEqual(cell(text, prior: c, locale: locale), c, "\(text) in \(locale.locale.identifier)")
            }
        }
    }
}
