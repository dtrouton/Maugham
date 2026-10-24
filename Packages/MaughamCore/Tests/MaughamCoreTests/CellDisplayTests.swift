import XCTest
@testable import MaughamCore

final class CellDisplayTests: XCTestCase {
    private let gb = TableLocale(languageTag: "en-GB", fallbackRegion: "US")
    private let us = TableLocale(languageTag: "en-US", fallbackRegion: "GB")
    private let es = TableLocale(languageTag: "es-ES", fallbackRegion: "US")

    private func show(_ x: Double, _ n: NumberFormat, _ l: TableLocale, neg: NegativeStyle = .minus, dash: Bool = false) -> String {
        CellDisplay.string(for: .number(x), format: CellFormat(number: n, negatives: neg, zeroAsDash: dash), locale: l)
    }

    func test_localeResolution() {
        XCTAssertEqual(TableLocale(languageTag: "en_us", fallbackRegion: "GB").locale.region?.identifier, "US")
        XCTAssertEqual(TableLocale(languageTag: "en", fallbackRegion: "GB").locale.region?.identifier, "GB")
        XCTAssertEqual(TableLocale(languageTag: "es", fallbackRegion: "ES").currencySymbol, "€")
        XCTAssertTrue(gb.dayFirst)
        XCTAssertFalse(us.dayFirst)
        XCTAssertEqual(es.decimalSeparator, ",")
        XCTAssertEqual(es.groupingSeparator, ".")
    }

    func test_general() {
        XCTAssertEqual(show(0.1 + 0.2, .general, gb), "0.3")
        XCTAssertEqual(show(1234.5, .general, gb), "1234.5")
        XCTAssertEqual(show(1234.5, .general, TableLocale(languageTag: "es", fallbackRegion: "ES")), "1234,5")
        XCTAssertEqual(show(123_456_789_012, .general, gb), "1.23457E+11")
        XCTAssertEqual(show(2.0 / 3.0, .general, gb), "0.6666666667")
        XCTAssertEqual(show(-2.5, .general, gb), "-2.5")
        XCTAssertEqual(show(1e-20, .general, gb), "1E-20")                 // scientific below 1e-9, never "0"
        XCTAssertEqual(show(-1e-200, .general, gb), "-1E-200")
        XCTAssertEqual(show(1.5e-10, .general, gb), "1.5E-10")
    }

    func test_number() {
        XCTAssertEqual(show(1234.567, .number(decimals: 2, grouping: true), gb), "1,234.57")
        // Grouping is each locale's own: Spanish skips a four-digit group (R-P5-14).
        XCTAssertEqual(show(1234.567, .number(decimals: 2, grouping: true), es), "1234,57")
        XCTAssertEqual(show(12345.67, .number(decimals: 2, grouping: true), es), "12.345,67")
        XCTAssertEqual(show(2.675, .number(decimals: 2, grouping: true), gb), "2.68")
        XCTAssertEqual(show(1234567.5, .number(decimals: 0, grouping: false), gb), "1234568")
    }

    func test_percent() {
        XCTAssertEqual(show(0.1234, .percent(decimals: 1), gb), "12.3%")
        let f = NumberFormatter()
        f.locale = es.locale; f.numberStyle = .percent
        f.minimumFractionDigits = 1; f.maximumFractionDigits = 1; f.roundingMode = .halfUp
        XCTAssertEqual(show(0.1234, .percent(decimals: 1), es), f.string(from: NSNumber(value: 0.123)))
    }

    func test_currency() {
        XCTAssertEqual(show(1234, .currency(symbol: nil, decimals: 0), gb), "£1,234")
        XCTAssertEqual(show(1234, .currency(symbol: nil, decimals: 0), us), "$1,234")
        XCTAssertTrue(show(1234, .currency(symbol: nil, decimals: 0), TableLocale(languageTag: "es", fallbackRegion: "ES")).contains("€"))
        XCTAssertEqual(show(1234, .currency(symbol: "$", decimals: 0), gb), "$1,234")
    }

    func test_compact() {
        XCTAssertEqual(show(1234, .compact(decimals: 1), gb), "1.2k")
        XCTAssertEqual(show(3_400_000, .compact(decimals: 1), gb), "3.4m")
        XCTAssertEqual(show(5_600_000_000, .compact(decimals: 1), gb), "5.6bn")
        XCTAssertEqual(show(1234, .compact(decimals: 1), us), "1.2K")
        XCTAssertEqual(show(3_400_000, .compact(decimals: 1), us), "3.4M")
        XCTAssertEqual(show(5_600_000_000, .compact(decimals: 1), us), "5.6B")
        XCTAssertEqual(show(1499.6, .compact(decimals: 0), us), "1K")
        XCTAssertEqual(show(-1500, .compact(decimals: 1), us), "-1.5K")
        XCTAssertEqual(show(-1500, .compact(decimals: 1), us, neg: .parentheses), "(1.5K)")
        XCTAssertEqual(show(3_400_000, .compact(decimals: 1), es),
                       3_400_000.0.formatted(.number.notation(.compactName).precision(.fractionLength(1)).locale(es.locale)))
    }

    func test_negativeSignFollowsTheLocalePattern() {
        XCTAssertEqual(show(-1234, .currency(symbol: nil, decimals: 0), gb), "-£1,234")
        XCTAssertEqual(show(-0.1234, .percent(decimals: 1), gb), "-12.3%")
        let c = NumberFormatter()
        c.locale = es.locale; c.numberStyle = .currency
        c.minimumFractionDigits = 0; c.maximumFractionDigits = 0; c.roundingMode = .halfUp
        XCTAssertEqual(show(-1234, .currency(symbol: nil, decimals: 0), es), c.string(from: NSNumber(value: -1234)))
        let p = NumberFormatter()
        p.locale = es.locale; p.numberStyle = .percent
        p.minimumFractionDigits = 1; p.maximumFractionDigits = 1; p.roundingMode = .halfUp
        XCTAssertEqual(show(-0.1234, .percent(decimals: 1), es), p.string(from: NSNumber(value: -0.123)))
    }

    func test_negativesAndDash() {
        XCTAssertEqual(show(-1200, .number(decimals: 0, grouping: true), gb, neg: .parentheses), "(1,200)")
        XCTAssertEqual(show(-1200, .currency(symbol: nil, decimals: 0), gb, neg: .parentheses), "(£1,200)")
        XCTAssertEqual(show(-1200, .number(decimals: 0, grouping: true), gb), "-1,200")
        XCTAssertEqual(show(0, .number(decimals: 2, grouping: true), gb, dash: true), "—")
        XCTAssertEqual(show(0.004, .number(decimals: 2, grouping: true), gb, dash: true), "—")
        XCTAssertEqual(show(-0.004, .number(decimals: 2, grouping: true), gb), "0.00")
        XCTAssertEqual(CellDisplay.string(for: .empty, format: CellFormat(zeroAsDash: true), locale: gb), "—")
        XCTAssertEqual(CellDisplay.string(for: .empty, format: CellFormat(), locale: gb), "")
    }

    func test_belowDecimalsRange_showsAsZeroAndDash() {
        let two = NumberFormat.number(decimals: 2, grouping: true)
        XCTAssertEqual(show(-1e-200, two, gb), "0.00")
        XCTAssertEqual(show(-1e-200, two, gb, dash: true), "—")
        XCTAssertEqual(show(-1e-200, two, gb, neg: .parentheses), "0.00")
        XCTAssertEqual(show(-1e-200, .currency(symbol: nil, decimals: 2), gb), "£0.00")
        XCTAssertEqual(show(1e-200, .percent(decimals: 1), gb, dash: true), "—")
    }

    func test_dates() {
        func d(_ style: DateStyle, _ l: TableLocale) -> String {
            CellDisplay.string(for: .date(46319), format: CellFormat(number: .date(style)), locale: l)
        }
        XCTAssertEqual(d(.day, gb), "24 Oct 2026")
        XCTAssertEqual(d(.day, us), "Oct 24, 2026")
        XCTAssertEqual(d(.month, gb), "Oct 2026")
        XCTAssertEqual(d(.iso, gb), "2026-10-24")
        XCTAssertEqual(d(.year, gb), "2026")
        XCTAssertEqual(CellDisplay.string(for: .date(46319), format: CellFormat(), locale: gb), "24 Oct 2026")
        XCTAssertEqual(CellDisplay.string(for: .number(46319), format: CellFormat(number: .date(.iso)), locale: gb), "2026-10-24")
        XCTAssertEqual(CellDisplay.string(for: .date(46319), format: CellFormat(number: .number(decimals: 0, grouping: true)), locale: gb), "46,319")
        func route(_ template: String, _ l: TableLocale) -> String {
            let f = DateFormatter()
            f.locale = l.locale
            f.timeZone = TimeZone(identifier: "GMT")
            f.calendar = Calendar(identifier: .gregorian)
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: Date(timeIntervalSince1970: Double(46319 - 25_569) * 86_400))
        }
        XCTAssertEqual(d(.quarter, gb), route("QQQy", gb))
        XCTAssertEqual(d(.day, es), route("dMMMy", es))
        XCTAssertEqual(d(.month, es), route("MMMy", es))
    }

    func test_financialYear() {
        let fy = TableLocale(languageTag: "en-GB", fallbackRegion: "GB", financialYearStartMonth: 4)
        func d(_ serial: Int, _ style: DateStyle) -> String {
            CellDisplay.string(for: .date(serial), format: CellFormat(number: .date(style)), locale: fy)
        }
        XCTAssertEqual(d(46319, .quarter), "Q3 FY27")
        XCTAssertEqual(d(46319, .year), "FY2027")
        let march31 = DateSerial.serial(year: 2026, month: 3, day: 31)!
        XCTAssertEqual(d(march31, .quarter), "Q4 FY26")
        XCTAssertEqual(d(46319, .day), "24 Oct 2026")
    }

    func test_codesAndWords() {
        XCTAssertEqual(CellDisplay.string(for: .error(.divideByZero), format: CellFormat(), locale: gb), "#DIV/0!")
        XCTAssertEqual(CellDisplay.string(for: .bool(true), format: CellFormat(), locale: gb), "TRUE")
        XCTAssertEqual(CellDisplay.string(for: .bool(false), format: CellFormat(), locale: gb), "FALSE")
        XCTAssertEqual(CellDisplay.string(for: .text("hi"), format: CellFormat(number: .percent(decimals: 1)), locale: gb), "hi")
    }
}
