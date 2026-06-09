import XCTest
import MaughamCore
@testable import Maugham

final class SmartTypographyTests: XCTestCase {

    // MARK: - Em dash (caret insert — must still work)

    func test_emDash_doubleHyphenBecomesEmDash() {
        let result = SmartTypography.transform(
            currentText: "He said-",
            replacementRange: NSRange(location: 8, length: 0),
            replacement: "-",
            settings: .defaults
        )
        XCTAssertEqual(result?.substitute, "—")
    }

    func test_emDash_rangeConsumesLeadingHyphen() {
        // The returned range must eat the preceding "-" so the coordinator
        // doesn't have to back-compute it.
        let result = SmartTypography.transform(
            currentText: "He said-",
            replacementRange: NSRange(location: 8, length: 0),
            replacement: "-",
            settings: .defaults
        )
        // Full replacement: location=7 (the preceding "-"), length=2 (that "-" + typed "-")
        XCTAssertEqual(result?.range, NSRange(location: 7, length: 2))
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

    // MARK: - Em dash over selection — MUST NOT corrupt

    func test_emDash_doesNotFireOverSelection() {
        // Typing "-" to replace a word that follows a "-" in the document.
        // The selection ("hello") must NOT be silently consumed.
        let result = SmartTypography.transform(
            currentText: "He said-hello",
            replacementRange: NSRange(location: 8, length: 5), // "hello" selected
            replacement: "-",
            settings: .defaults
        )
        XCTAssertNil(result, "Em-dash transform must not fire when replacementRange.length > 0")
    }

    func test_emDash_doesNotFireOverSingleCharSelection() {
        // Even replacing exactly one character positioned right after "-"
        let result = SmartTypography.transform(
            currentText: "He said-x",
            replacementRange: NSRange(location: 8, length: 1),
            replacement: "-",
            settings: .defaults
        )
        XCTAssertNil(result, "Em-dash transform must not fire when a character is selected")
    }

    // MARK: - Ellipsis (caret insert — must still work)

    func test_ellipsis_threeDotsBecomesEllipsis() {
        let result = SmartTypography.transform(
            currentText: "Wait..",
            replacementRange: NSRange(location: 6, length: 0),
            replacement: ".",
            settings: .defaults
        )
        XCTAssertEqual(result?.substitute, "…")
    }

    func test_ellipsis_rangeConsumesBothLeadingDots() {
        // The returned range must cover both preceding dots.
        let result = SmartTypography.transform(
            currentText: "Wait..",
            replacementRange: NSRange(location: 6, length: 0),
            replacement: ".",
            settings: .defaults
        )
        // Full replacement: location=4 (the first "."), length=3 (".."+typed ".")
        XCTAssertEqual(result?.range, NSRange(location: 4, length: 3))
    }

    // MARK: - Ellipsis digit-guard (the REAL guard: don't collapse inside a version/number)

    func test_ellipsis_precededByDigitIsNotTransformed() {
        // The guard fires when the character BEFORE the ".." is a digit —
        // "1.0.." + "." would produce "1.0…" which looks wrong in a version string.
        // Text: "1.0.." (length 5), typing "." at location 5.
        let result = SmartTypography.transform(
            currentText: "1.0..",
            replacementRange: NSRange(location: 5, length: 0),
            replacement: ".",
            settings: .defaults
        )
        XCTAssertNil(result, "Ellipsis must not collapse when preceded by a digit (version number guard)")
    }

    func test_ellipsis_precededByLetterTransforms() {
        // Letter before ".." is NOT a digit, so collapse is fine.
        let result = SmartTypography.transform(
            currentText: "OK..",
            replacementRange: NSRange(location: 4, length: 0),
            replacement: ".",
            settings: .defaults
        )
        XCTAssertEqual(result?.substitute, "…")
    }

    // MARK: - Ellipsis over selection — MUST NOT corrupt

    func test_ellipsis_doesNotFireOverSelection() {
        // Typing "." to replace a word after ".." — the selected text must survive.
        let result = SmartTypography.transform(
            currentText: "Wait..done",
            replacementRange: NSRange(location: 6, length: 4), // "done" selected
            replacement: ".",
            settings: .defaults
        )
        XCTAssertNil(result, "Ellipsis transform must not fire when replacementRange.length > 0")
    }

    func test_ellipsis_doesNotFireOverSingleCharSelection() {
        let result = SmartTypography.transform(
            currentText: "Wait..x",
            replacementRange: NSRange(location: 6, length: 1),
            replacement: ".",
            settings: .defaults
        )
        XCTAssertNil(result, "Ellipsis transform must not fire when a character is selected")
    }

    // MARK: - Smart quotes (caret — must still work; quotes may still replace a selection)

    func test_smartQuote_openingDoubleQuote() {
        let result = SmartTypography.transform(
            currentText: "He said ",
            replacementRange: NSRange(location: 8, length: 0),
            replacement: "\"",
            settings: .defaults
        )
        XCTAssertEqual(result?.substitute, "\u{201C}") // "
    }

    func test_smartQuote_closingDoubleQuote() {
        let result = SmartTypography.transform(
            currentText: "He said \u{201C}hi",
            replacementRange: NSRange(location: 11, length: 0),
            replacement: "\"",
            settings: .defaults
        )
        XCTAssertEqual(result?.substitute, "\u{201D}") // "
    }

    func test_smartQuote_rangeMatchesInput() {
        // Quotes do NOT expand backward — range equals the input replacementRange.
        let inputRange = NSRange(location: 8, length: 0)
        let result = SmartTypography.transform(
            currentText: "He said ",
            replacementRange: inputRange,
            replacement: "\"",
            settings: .defaults
        )
        XCTAssertEqual(result?.range, inputRange)
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
