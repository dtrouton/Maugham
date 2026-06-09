import XCTest
@testable import MaughamCore

final class InlineEmphasisScannerTests: XCTestCase {
    func testTraitsSetSemantics() {
        let both: EmphasisTraits = [.bold, .italic]
        XCTAssertTrue(both.contains(.bold))
        XCTAssertTrue(both.contains(.italic))
        XCTAssertEqual(EmphasisTraits.bold.union(.italic), both)
        XCTAssertTrue(EmphasisTraits().isEmpty)
    }

    // Helper: turn runs into (substring, traits) for readable assertions.
    private func runs(_ s: String) -> [(String, EmphasisTraits)] {
        let ns = s as NSString
        return InlineEmphasisScanner.scan(ns).runs.map {
            (ns.substring(with: $0.range), $0.traits)
        }
    }
    private func markers(_ s: String) -> [String] {
        let ns = s as NSString
        return InlineEmphasisScanner.scan(ns).markers.map { ns.substring(with: $0) }
    }

    func testPlainText() {
        XCTAssertTrue(runs("just words").isEmpty)
        XCTAssertTrue(markers("just words").isEmpty)
    }

    func testItalic() {
        XCTAssertEqual(runs("*x*").map(\.1), [.italic])
        XCTAssertEqual(runs("*x*").map(\.0), ["x"])
        XCTAssertEqual(markers("*x*"), ["*", "*"])
    }

    func testBold() {
        XCTAssertEqual(runs("**x**").map(\.1), [[.bold]])
        XCTAssertEqual(markers("**x**"), ["**", "**"])
    }

    func testBoldItalicCombined() {
        let r = runs("***x***")
        XCTAssertEqual(r.map(\.0), ["x"])
        XCTAssertEqual(r.map(\.1), [[.bold, .italic]])
        XCTAssertEqual(markers("***x***"), ["***", "***"])
    }

    func testBoldNestedInsideItalic() {
        // *a **b** a*  ->  "a "(italic) "b"(both) " a"(italic)
        let r = runs("*a **b** a*")
        XCTAssertEqual(r.map(\.0), ["a ", "b", " a"])
        XCTAssertEqual(r.map(\.1), [[.italic], [.italic, .bold], [.italic]])
    }

    func testItalicNestedInsideBold() {
        let r = runs("**a *b* a**")
        XCTAssertEqual(r.map(\.0), ["a ", "b", " a"])
        XCTAssertEqual(r.map(\.1), [[.bold], [.bold, .italic], [.bold]])
    }

    func testUnbalancedRendersLiteral() {
        XCTAssertTrue(runs("**x").isEmpty)     // no closer
        XCTAssertTrue(markers("**x").isEmpty)  // nothing consumed -> not faded
        XCTAssertTrue(runs("no *stars here").isEmpty)
    }

    // MARK: - CommonMark parity / divergence edge cases (task 4.8 / test gap #13)
    //
    // These tests pin the scanner's ACTUAL output for inputs that probe corners
    // of the CommonMark spec. Where the scanner diverges from strict CommonMark,
    // the divergence is documented as the INTENDED CONTRACT — do not "fix" the
    // scanner to match CommonMark without updating these tests and the
    // cross-surface contract (ScreenplayEmphasisContractTests).

    /// Unclosed run: `*foo` has no closer → no emphasis.
    /// Aligns with CommonMark §6.1 (opener without a matching closer renders literal).
    func testUnclosedRunRendersLiteral() {
        XCTAssertTrue(runs("*foo").isEmpty, "unclosed '*foo' must render literal")
        XCTAssertTrue(markers("*foo").isEmpty, "unclosed '*foo' must produce no markers")
    }

    /// Spaced delimiters: `* foo *` — the opener is followed by a space and the
    /// closer is preceded by a space, so neither is flanking. No emphasis produced.
    /// Aligns with CommonMark §6.1 (space-flanked delimiter is not a left-flanking
    /// delimiter run).
    func testSpacedDelimitersNotEmphasis() {
        XCTAssertTrue(runs("* foo *").isEmpty,
            "'* foo *' (space after opener, space before closer) must not be emphasis")
        XCTAssertTrue(markers("* foo *").isEmpty)
    }

    /// Intraword emphasis: `foo*bar*baz` — the `*` runs are flanked by word chars on
    /// both sides, so both can open and close. The scanner's whitespace-only flanking
    /// rule produces italic `bar`.
    ///
    /// ALIGNS with CommonMark §6.1 (intraword emphasis with `*` is allowed).
    /// Note: the scanner uses whitespace-only flanking, not the full CommonMark
    /// punctuation-context rules — but for pure alphanumeric intraword context the
    /// result is the same.
    func testIntrawordEmphasis() {
        let r = runs("foo*bar*baz")
        XCTAssertEqual(r.map(\.0), ["bar"])
        XCTAssertEqual(r.map(\.1), [.italic])
        XCTAssertEqual(markers("foo*bar*baz"), ["*", "*"])
    }

    /// Quad asterisks: `****` — at the string boundary both flanking checks return
    /// false (string edge counts as whitespace), so neither opener nor closer fires.
    /// No emphasis, no markers.
    ///
    /// Aligns with CommonMark §6.1 (empty-span emphasis not valid; `****` at the
    /// boundary is not a valid opener or closer).
    func testQuadAsterisksLiteral() {
        XCTAssertTrue(runs("****").isEmpty, "'****' at boundary must render literal")
        XCTAssertTrue(markers("****").isEmpty)
    }

    /// Escaped asterisk: `\*foo\*` — DIVERGENCE FROM COMMONMARK.
    ///
    /// CommonMark: `\*` is a backslash escape, so `\*foo\*` renders as the literal
    /// text `*foo*` (no emphasis, asterisks stripped).
    ///
    /// Scanner: backslash is not treated as an escape character — it is a plain
    /// non-space character. The `*` at index 1 has `\` before it (non-space →
    /// canClose=true) and `f` after it (canOpen=true). The `*` at index 6 has `\`
    /// before it (canClose=true) and string-end after it (canOpen=false). The closer
    /// at index 6 matches the opener at index 1, producing italic on `foo\` (the
    /// backslash before the closing `*` is included in the run).
    ///
    /// INTENDED CONTRACT: the scanner is asterisk-only and does not implement
    /// backslash escaping. Callers that need escape handling must pre-process the
    /// string before scanning. This divergence is acceptable for the current use
    /// cases (prose and Fountain emphasis in manuscript text rarely uses `\*`).
    func testEscapedAsteriskDivergesFromCommonMark() {
        // Scanner output (current behavior, pinned as contract):
        // Run "foo\" is italic; the backslash is included in the run content.
        let r = runs("\\*foo\\*")
        XCTAssertEqual(r.map(\.0), ["foo\\"],
            "DIVERGENCE: scanner includes the backslash before '*' in the italic run; "
            + "CommonMark would treat '\\*' as a backslash escape producing literal '*'")
        XCTAssertEqual(r.map(\.1), [.italic])
        XCTAssertEqual(markers("\\*foo\\*"), ["*", "*"])
    }

    /// Mixed nested emphasis: `*a **b** a*` is already covered by
    /// `testBoldNestedInsideItalic`, included here for completeness as a
    /// CommonMark alignment check — the flattened output matches CommonMark §6.4.
    func testNestedBoldInsideItalicAlignedWithCommonMark() {
        // Re-asserts the established case: italic outer, bold+italic inner.
        let r = runs("*a **b** a*")
        XCTAssertEqual(r.map(\.0), ["a ", "b", " a"])
        XCTAssertEqual(r.map(\.1), [[.italic], [.italic, .bold], [.italic]])
    }

    /// Triple asterisks `***x***` — aligns with CommonMark §6.4 (can open both
    /// bold and italic simultaneously). Existing test `testBoldItalicCombined`
    /// already covers this; included here to document the CommonMark alignment.
    func testTripleAsteriskBoldItalicAlignsWithCommonMark() {
        let r = runs("***x***")
        XCTAssertEqual(r.map(\.0), ["x"])
        XCTAssertEqual(r.map(\.1), [[.bold, .italic]])
        // Markers collapse to one contiguous span per side.
        XCTAssertEqual(markers("***x***"), ["***", "***"])
    }
}
