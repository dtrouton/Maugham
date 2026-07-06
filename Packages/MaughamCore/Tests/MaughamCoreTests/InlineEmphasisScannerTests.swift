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

    /// Escaped asterisk: `\*foo\*` — now ALIGNS with CommonMark (Task 1).
    ///
    /// The scanner's escape pre-pass neutralizes a `*` preceded by `\`, so both
    /// asterisks here are literal: no emphasis, no markers. The two backslashes
    /// are reported in `escapes` (indices 0 and 5) so callers strip them.
    ///
    /// This supersedes the earlier documented divergence, where backslash was a
    /// plain char and `\*foo\*` produced an italic run over `foo\`.
    func testEscapedAsteriskAlignsWithCommonMark() {
        let scan = InlineEmphasisScanner.scan("\\*foo\\*" as NSString)
        XCTAssertTrue(scan.runs.isEmpty,
            "escaped asterisks must not open/close emphasis")
        XCTAssertTrue(scan.markers.isEmpty)
        XCTAssertEqual(scan.escapes, [NSRange(location: 0, length: 1),
                                      NSRange(location: 5, length: 1)])
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

    // MARK: - Task 1: backslash escapes + opt-in strikethrough

    func test_escapedAsterisk_isLiteral() {
        let scan = InlineEmphasisScanner.scan(#"\*not emphasis\*"# as NSString)
        XCTAssertTrue(scan.runs.isEmpty)
        XCTAssertTrue(scan.markers.isEmpty)
        XCTAssertEqual(scan.escapes, [NSRange(location: 0, length: 1),
                                      NSRange(location: 14, length: 1)])
    }
    func test_escapedOpenerOnly_leavesCloserUnpaired_literal() {
        let scan = InlineEmphasisScanner.scan(#"\*x*"# as NSString)
        XCTAssertTrue(scan.runs.isEmpty)   // lone closer degrades to literal
    }
    func test_doubleBackslash_thenEmphasis_stillEmphasizes() {
        // \\ escapes the backslash; the * run is live: \\*x* → literal "\" + em "x"
        let scan = InlineEmphasisScanner.scan(#"\\*x*"# as NSString)
        XCTAssertEqual(scan.runs, [.init(range: NSRange(location: 3, length: 1),
                                         traits: .italic)])
        XCTAssertEqual(scan.escapes, [NSRange(location: 0, length: 1)])
    }
    func test_strikethrough_basic() {
        let scan = InlineEmphasisScanner.scan("a ~~gone~~ b" as NSString,
                                              options: [.strikethrough])
        XCTAssertEqual(scan.runs, [.init(range: NSRange(location: 4, length: 4),
                                         traits: .strikethrough)])
        XCTAssertEqual(scan.markers, [NSRange(location: 2, length: 2),
                                      NSRange(location: 8, length: 2)])
    }
    func test_strikethrough_offByDefault_tildesLiteral() {
        let scan = InlineEmphasisScanner.scan("a ~~x~~ b" as NSString)
        XCTAssertTrue(scan.runs.isEmpty)
    }
    func test_strikethrough_nestsWithEmphasis() {
        // *em ~~struck~~ em* → struck region carries [.italic, .strikethrough]
        let scan = InlineEmphasisScanner.scan("*em ~~st~~ em*" as NSString,
                                              options: [.strikethrough])
        XCTAssertTrue(scan.runs.contains(
            .init(range: NSRange(location: 6, length: 2),
                  traits: [.italic, .strikethrough])))
    }
    func test_singleTilde_neverStrikethrough() {
        let scan = InlineEmphasisScanner.scan("a ~x~ b" as NSString,
                                              options: [.strikethrough])
        XCTAssertTrue(scan.runs.isEmpty)   // GFM requires ~~
    }
}
