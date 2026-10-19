import XCTest
@testable import MaughamCore

/// The inline scanner: footnote references, citations and cross-references
/// inside sentences, and the ordinary prose that must not read as any of them.
final class ManuscriptInlineScannerTests: XCTestCase {

    private func markers(_ text: String) -> [ManuscriptInline] {
        ManuscriptInlineScanner.scan(text).map(\.marker)
    }

    private func label(_ reference: String) -> ManuscriptLabel {
        ManuscriptLabel(reference: reference)!
    }

    /// The substring each marker's NSRange covers.
    private func spans(_ text: String) -> [String] {
        ManuscriptInlineScanner.scan(text).map { (text as NSString).substring(with: $0.range) }
    }

    // MARK: - Each form

    func test_footnoteReference() {
        let text = "A claim.[^1] Another[^note-2]."
        XCTAssertEqual(markers(text), [.footnoteRef(label: "1"), .footnoteRef(label: "note-2")])
        XCTAssertEqual(spans(text), ["[^1]", "[^note-2]"])
    }

    func test_citation_singleAndWithLocator() {
        XCTAssertEqual(markers("As shown [@smith2020]."),
                       [.citation([CitationItem(key: "smith2020", locator: nil)])])
        let text = "As shown [@a, p. 12; @b]."
        XCTAssertEqual(markers(text), [.citation([CitationItem(key: "a", locator: "p. 12"),
                                                  CitationItem(key: "b", locator: nil)])])
        XCTAssertEqual(spans(text), ["[@a, p. 12; @b]"])
    }

    func test_citation_locatorOnTheLastItem() {
        XCTAssertEqual(markers("x [@a; @b, pp. 3–5] y"),
                       [.citation([CitationItem(key: "a", locator: nil),
                                   CitationItem(key: "b", locator: "pp. 3–5")])])
    }

    func test_bareCrossReference_eachKind() {
        let text = "See @fig:revenue, @tbl:q3 and @sec:intro"
        XCTAssertEqual(markers(text), [.crossRef(label("fig:revenue")), .crossRef(label("tbl:q3")),
                                       .crossRef(label("sec:intro"))])
        XCTAssertEqual(spans(text), ["@fig:revenue", "@tbl:q3", "@sec:intro"])
    }

    func test_bracketedLabelIsACrossReferenceNotACitation() {
        let text = "see [@fig:a] here"
        XCTAssertEqual(markers(text), [.crossRef(label("fig:a"))])
        XCTAssertEqual(spans(text), ["[@fig:a]"])
    }

    func test_bracketOfSeveralLabels_eachCoversItsOwnLabel() {
        let text = "[@fig:a; @fig:b]"
        XCTAssertEqual(markers(text), [.crossRef(label("fig:a")), .crossRef(label("fig:b"))])
        XCTAssertEqual(spans(text), ["@fig:a", "@fig:b"])
    }

    // MARK: - Prose that is not a marker

    func test_emailAddressesGiveNothing() {
        XCTAssertEqual(markers("write to bob@fig.com or me@sec:x today"), [])
    }

    func test_aHandleGivesNothing() {
        XCTAssertEqual(markers("thanks @sarah"), [])
        XCTAssertEqual(markers("@eq:x is not a kind"), [])
    }

    func test_insideACodeSpanGivesNothing() {
        XCTAssertEqual(markers("`[^1]`"), [])
        XCTAssertEqual(markers("type ``[@a] and @fig:x`` here"), [])
        // An unclosed backtick is literal, so what follows still scans.
        XCTAssertEqual(markers("a ` b[^1]"), [.footnoteRef(label: "1")])
    }

    func test_backslashEscapesGiveNothing() {
        XCTAssertEqual(markers(#"\[^1]"#), [])
        XCTAssertEqual(markers(#"\@fig:a"#), [])
        XCTAssertEqual(markers(#"\[@a]"#), [])
    }

    func test_trailingSentencePunctuationIsNotPartOfTheName() {
        XCTAssertEqual(markers("see @fig:a."), [.crossRef(label("fig:a"))])
        XCTAssertEqual(spans("see @fig:a."), ["@fig:a"])
        XCTAssertEqual(markers("(@tbl:b), @sec:c;"), [.crossRef(label("tbl:b")),
                                                      .crossRef(label("sec:c"))])
    }

    func test_aFootnoteDefinitionHeadIsNotAReference() {
        XCTAssertEqual(markers("[^1]: The note [^2]."), [.footnoteRef(label: "2")])
        XCTAssertEqual(markers("line\n  [^3]: def"), [])
        // Mid-line, `[^1]:` is a reference followed by a colon.
        XCTAssertEqual(markers("so[^1]: yes"), [.footnoteRef(label: "1")])
    }

    func test_malformedBracketsGiveNoCitation() {
        XCTAssertEqual(markers("[@]"), [])
        XCTAssertEqual(markers("[@a b]"), [])
        XCTAssertEqual(markers("[@a"), [])
        XCTAssertEqual(markers("[@-a]"), [])
        XCTAssertEqual(markers("[^]"), [])
        XCTAssertEqual(markers("[^a b]"), [])
        XCTAssertEqual(markers("[@a\n]"), [])
    }

    func test_aMixedBracketGivesItsCitationAndItsCrossReferences() {
        let text = "[@fig:a; @smith, p. 2; @tbl:b; @jones]"
        XCTAssertEqual(markers(text), [.crossRef(label("fig:a")),
                                       .citation([CitationItem(key: "smith", locator: "p. 2"),
                                                  CitationItem(key: "jones", locator: nil)]),
                                       .crossRef(label("tbl:b"))])
        // Each covers its own item; none overlaps another.
        XCTAssertEqual(spans(text), ["@fig:a", "@smith, p. 2", "@tbl:b"])
    }

    func test_voidBracketsGiveNothing() {
        // A key has no colon, and an empty item voids the bracket.
        XCTAssertEqual(markers("[@a;]"), [])
        XCTAssertEqual(markers("[@eq:1]"), [])
        XCTAssertEqual(markers("[@doe:2020]"), [])
    }

    func test_aBracketInsideALocatorVoidsTheBracket() {
        XCTAssertEqual(markers("[@a, see [x]]"), [])
    }

    func test_trailingUnderscoreAndHyphenAreNotPartOfABareName() {
        XCTAssertEqual(markers("_see @fig:a_"), [.crossRef(label("fig:a"))])
        XCTAssertEqual(spans("_see @fig:a_"), ["@fig:a"])
        XCTAssertEqual(markers("@tbl:b-- and"), [.crossRef(label("tbl:b"))])
        XCTAssertEqual(markers("@sec:a-b"), [.crossRef(label("sec:a-b"))])
    }

    func test_anEscapedBackslashLeavesTheCitationReal() {
        XCTAssertEqual(markers(#"\\[@a]"#), [.citation([CitationItem(key: "a", locator: nil)])])
    }

    // MARK: - Ranges

    func test_rangesAreUTF16AcrossAnEmoji() {
        let text = "🙂🙂 x[^1] [@k] @fig:a"
        let found = ManuscriptInlineScanner.scan(text)
        XCTAssertEqual(found.map(\.range), [NSRange(location: 6, length: 4),
                                            NSRange(location: 11, length: 4),
                                            NSRange(location: 16, length: 6)])
        XCTAssertEqual(spans(text), ["[^1]", "[@k]", "@fig:a"])
    }
}
