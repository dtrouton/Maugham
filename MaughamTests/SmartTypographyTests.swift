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

    func test_emDash_rangeCoversOnlyExistingHyphen() {
        // transform runs in `shouldChangeTextIn` — BEFORE the just-typed "-" is
        // in `currentText` — so the range covers ONLY the existing preceding
        // "-" (length 1), NOT the not-yet-inserted new one. Length 2 would eat
        // the character after the caret.
        let result = SmartTypography.transform(
            currentText: "He said-",
            replacementRange: NSRange(location: 8, length: 0),
            replacement: "-",
            settings: .defaults
        )
        XCTAssertEqual(result?.range, NSRange(location: 7, length: 1))
    }

    /// Regression net for the "deletes a character in front" bug: model the real
    /// `insertText(substitute, replacementRange:)` apply against a PRE-insert
    /// string with a char AFTER the caret, and assert that char survives.
    func test_emDash_appliedMidText_doesNotEatFollowingChar() {
        // Pre-insert "a-b", caret between "-" and "b" (location 2); user types "-".
        let result = SmartTypography.transform(
            currentText: "a-b",
            replacementRange: NSRange(location: 2, length: 0),
            replacement: "-",
            settings: .defaults
        )
        let applied = ("a-b" as NSString).replacingCharacters(
            in: result!.range, with: result!.substitute)
        XCTAssertEqual(applied, "a—b", "the following 'b' must not be consumed")
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

    func test_ellipsis_rangeCoversOnlyExistingDots() {
        // Pre-insert: the just-typed "." isn't in `currentText` yet, so the range
        // covers ONLY the two existing dots (length 2). Length 3 would eat the
        // character after the caret.
        let result = SmartTypography.transform(
            currentText: "Wait..",
            replacementRange: NSRange(location: 6, length: 0),
            replacement: ".",
            settings: .defaults
        )
        XCTAssertEqual(result?.range, NSRange(location: 4, length: 2))
    }

    /// Regression net: applied mid-text, the char after the caret survives.
    func test_ellipsis_appliedMidText_doesNotEatFollowingChar() {
        // Pre-insert "a..b", caret between the 2nd "." and "b" (location 3).
        let result = SmartTypography.transform(
            currentText: "a..b",
            replacementRange: NSRange(location: 3, length: 0),
            replacement: ".",
            settings: .defaults
        )
        let applied = ("a..b" as NSString).replacingCharacters(
            in: result!.range, with: result!.substitute)
        XCTAssertEqual(applied, "a…b", "the following 'b' must not be consumed")
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

    // MARK: - Report syntax is left alone (R-3a-8)

    /// Types `typed` one character at a time through `transform`, applying the
    /// result as the coordinator would, and returns the final text.
    private func typeThrough(_ typed: String, prefix: String = "") -> String {
        var text = prefix
        for ch in typed {
            let loc = (text as NSString).length
            if let r = SmartTypography.transform(
                currentText: text,
                replacementRange: NSRange(location: loc, length: 0),
                replacement: String(ch),
                settings: .defaults) {
                text = (text as NSString).replacingCharacters(in: r.range, with: r.substitute)
            } else {
                text += String(ch)
            }
        }
        return text
    }

    func test_reportSyntax_tableDelimiterRowsStayLiteral() {
        for row in ["|---|", "| :-- | --: |", "|:-:|", "| a -- b | c... |"] {
            XCTAssertEqual(typeThrough(row), row)
        }
    }

    func test_reportSyntax_indentedTableRowStaysLiteral() {
        XCTAssertEqual(typeThrough("  |---|"), "  |---|")
    }

    func test_reportSyntax_labelBlockAndCrossRefStayLiteral() {
        XCTAssertEqual(typeThrough("{#fig:a--b}"), "{#fig:a--b}")
        XCTAssertEqual(typeThrough("See @fig:a--b."), "See @fig:a--b.")
        XCTAssertEqual(typeThrough("@tbl:x--y"), "@tbl:x--y")
        XCTAssertEqual(typeThrough("@sec:x--y"), "@sec:x--y")
    }

    func test_reportSyntax_proseAfterLabelStillTransforms() {
        XCTAssertEqual(typeThrough("{#fig:a} and--"), "{#fig:a} and—")
        XCTAssertEqual(typeThrough("@fig:a and--"), "@fig:a and—")
        XCTAssertEqual(typeThrough("Wait--"), "Wait—")
    }

    func test_reportSyntax_tripleHyphenOnProseLineUnchanged() {
        // Today's behaviour, pinned: the second hyphen becomes an em dash and
        // the third is typed after it.
        XCTAssertEqual(typeThrough("---"), "—-")
    }

    func test_reportSyntax_onlyTheCurrentLineMatters() {
        XCTAssertEqual(typeThrough("a--", prefix: "|x|\n"), "|x|\na—")
    }

    func test_reportSyntax_smartQuotesInATableCellStillCurl() {
        XCTAssertEqual(typeThrough("| \"hi\" |"), "| \u{201C}hi\u{201D} |")
    }
}
