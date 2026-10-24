import XCTest
@testable import MaughamCore

final class CellInputTests: XCTestCase {
    private let gb = TableLocale(languageTag: "en-GB", fallbackRegion: "GB")
    private let us = TableLocale(languageTag: "en-US", fallbackRegion: "US")
    private let es = TableLocale(languageTag: "es-ES", fallbackRegion: "ES")

    private func day(_ y: Int, _ m: Int, _ d: Int) -> CellValue { .date(DateSerial.serial(year: y, month: m, day: d)!) }
    private func p(_ s: String, _ l: TableLocale? = nil) -> CellEntry { CellInput.parse(s, locale: l ?? gb) }

    func test_numbers() {
        XCTAssertEqual(p("1,234.5"), .value(.number(1234.5), suggested: .number(decimals: 1, grouping: true)))
        XCTAssertEqual(p("12%"), .value(.number(0.12), suggested: .percent(decimals: 0)))
        XCTAssertEqual(p("12.5%"), .value(.number(0.125), suggested: .percent(decimals: 1)))
        XCTAssertEqual(p("£1,200"), .value(.number(1200), suggested: .currency(symbol: nil, decimals: 0)))
        XCTAssertEqual(p("$5"), .value(.number(5), suggested: .currency(symbol: "$", decimals: 0)))
        XCTAssertEqual(p("(1,200)"), .value(.number(-1200), suggested: .number(decimals: 0, grouping: true)))
        XCTAssertEqual(p("-3.25"), .value(.number(-3.25), suggested: nil))
        XCTAssertEqual(p("1,23,4"), .value(.text("1,23,4"), suggested: nil))
        XCTAssertEqual(p("1234"), .value(.number(1234), suggested: nil))
    }

    func test_spanish() {
        XCTAssertEqual(p("1.234,5", es), .value(.number(1234.5), suggested: .number(decimals: 1, grouping: true)))
        XCTAssertEqual(p("1.5", es), .value(.number(1.5), suggested: nil))
        XCTAssertEqual(p("1.234", es), .value(.number(1234), suggested: .number(decimals: 0, grouping: true)))
        XCTAssertEqual(p("12 %", es), .value(.number(0.12), suggested: .percent(decimals: 0)))
        XCTAssertEqual(p("12,5 €", es), .value(.number(12.5), suggested: .currency(symbol: nil, decimals: 1)))
        XCTAssertEqual(p("24 oct 2026", es), .value(day(2026, 10, 24), suggested: .date(.day)))
        XCTAssertEqual(p("24 oct. 2026", es), .value(day(2026, 10, 24), suggested: .date(.day)))
        XCTAssertEqual(p("24 de octubre de 2026", es), .value(day(2026, 10, 24), suggested: .date(.day)))
    }

    func test_dates() {
        XCTAssertEqual(p("03/04/2026"), .value(day(2026, 4, 3), suggested: .date(.day)))
        XCTAssertEqual(p("03/04/2026", us), .value(day(2026, 3, 4), suggested: .date(.day)))
        XCTAssertEqual(p("24/10/26"), .value(day(2026, 10, 24), suggested: .date(.day)))
        XCTAssertEqual(p("24.10.99"), .value(day(1999, 10, 24), suggested: .date(.day)))
        XCTAssertEqual(p("31/02/2026"), .value(.text("31/02/2026"), suggested: nil))
        XCTAssertEqual(p("Oct 2026"), .value(day(2026, 10, 1), suggested: .date(.month)))
        XCTAssertEqual(p("Q4 2026"), .value(day(2026, 10, 1), suggested: .date(.quarter)))
        XCTAssertEqual(p("2026-10-24"), .value(day(2026, 10, 24), suggested: .date(.iso)))
        XCTAssertEqual(p("24 Oct 2026"), .value(day(2026, 10, 24), suggested: .date(.day)))
        XCTAssertEqual(p("Oct 24, 2026"), .value(day(2026, 10, 24), suggested: .date(.day)))
        XCTAssertEqual(p("October 24, 2026", es), .value(day(2026, 10, 24), suggested: .date(.day)))
    }

    func test_formulasTextAndBools() {
        XCTAssertEqual(p("=SUM(A1:A3)"), .formula("SUM(A1:A3)"))
        XCTAssertEqual(p("'=not"), .value(.text("=not"), suggested: nil))
        XCTAssertEqual(p("true"), .value(.bool(true), suggested: nil))
        XCTAssertEqual(p("FALSE"), .value(.bool(false), suggested: nil))
        XCTAssertEqual(p("  "), .empty)
        XCTAssertEqual(p("="), .value(.text("="), suggested: nil))
        XCTAssertEqual(p("hello"), .value(.text("hello"), suggested: nil))
    }

    func test_totalOnHostileInput() {
        let long = String(repeating: "9", count: 400)
        XCTAssertEqual(p(long), .value(.text(long), suggested: nil))
        for s in ["(", ")", "()", "%", "£", "--5", "(-5)", "1/1/1/1", "0/0/0000", "Q9 2026", "Oct", ". ", "1e5", "/", "99999999999999999999/1/2026"] {
            _ = p(s); _ = p(s, es)
        }
    }
}
