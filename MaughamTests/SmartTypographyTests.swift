import XCTest
import MaughamCore
@testable import Maugham

final class SmartTypographyTests: XCTestCase {

    func test_emDash_doubleHyphenBecomesEmDash() {
        let result = SmartTypography.transform(
            currentText: "He said-",
            replacementRange: NSRange(location: 8, length: 0),
            replacement: "-",
            settings: .defaults
        )
        XCTAssertEqual(result, "—")
    }

    func test_emDash_singleHyphenIsNotTransformed() {
        let result = SmartTypography.transform(
            currentText: "He said",
            replacementRange: NSRange(location: 7, length: 0),
            replacement: "-",
            settings: .defaults
        )
        XCTAssertNil(result)
    }

    func test_emDash_disabledByFlag() {
        var settings = TypographySettings.defaults
        settings.emDashAutoReplace = false
        let result = SmartTypography.transform(
            currentText: "He said-",
            replacementRange: NSRange(location: 8, length: 0),
            replacement: "-",
            settings: settings
        )
        XCTAssertNil(result)
    }

    func test_ellipsis_threeDotsBecomesEllipsis() {
        let result = SmartTypography.transform(
            currentText: "Wait..",
            replacementRange: NSRange(location: 6, length: 0),
            replacement: ".",
            settings: .defaults
        )
        XCTAssertEqual(result, "…")
    }

    func test_ellipsis_dotFollowedByDigitIsNotTransformed() {
        // Don't ruin "version 1.0.." typing
        let result = SmartTypography.transform(
            currentText: "v1.0.",
            replacementRange: NSRange(location: 5, length: 0),
            replacement: "0",
            settings: .defaults
        )
        XCTAssertNil(result)
    }

    func test_smartQuote_openingDoubleQuote() {
        let result = SmartTypography.transform(
            currentText: "He said ",
            replacementRange: NSRange(location: 8, length: 0),
            replacement: "\"",
            settings: .defaults
        )
        XCTAssertEqual(result, "\u{201C}") // "
    }

    func test_smartQuote_closingDoubleQuote() {
        let result = SmartTypography.transform(
            currentText: "He said \u{201C}hi",
            replacementRange: NSRange(location: 11, length: 0),
            replacement: "\"",
            settings: .defaults
        )
        XCTAssertEqual(result, "\u{201D}") // "
    }

    func test_smartQuote_disabledByFlag() {
        var settings = TypographySettings.defaults
        settings.smartQuotes = false
        let result = SmartTypography.transform(
            currentText: "",
            replacementRange: NSRange(location: 0, length: 0),
            replacement: "\"",
            settings: settings
        )
        XCTAssertNil(result)
    }
}
