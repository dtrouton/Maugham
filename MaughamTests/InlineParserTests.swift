import XCTest
@testable import Maugham

final class InlineParserTests: XCTestCase {

    private func parse(_ s: String) -> [ProjectAST.Inline] {
        InlineParser.parse(s)
    }

    // MARK: - plain

    func testPlainText_isSingleTextRun() {
        XCTAssertEqual(parse("Hello world."), [.text("Hello world.")])
    }

    func testEmpty_isEmpty() {
        XCTAssertEqual(parse(""), [])
    }

    // MARK: - emphasis / strong

    func testEmphasis_asterisk() {
        XCTAssertEqual(parse("*italic*"), [.emphasis([.text("italic")])])
    }

    // Prose underscore is no longer emphasis (spec ledger: prose publish aligns
    // to the editor's asterisk-only rule). `_x_` is literal text.
    func test_underscore_isLiteralInProse() {
        XCTAssertEqual(parse("snake_case_word"),
                       [.text("snake_case_word")])
    }

    func testStrong_doubleAsterisk() {
        XCTAssertEqual(parse("**bold**"), [.strong([.text("bold")])])
    }

    // Prose `***x***` is bold-italic (audit A2: the old hand-rolled parser
    // mangled triple asterisk). Nesting order: strong outermost, emphasis inner.
    func test_tripleAsterisk_boldItalic() {
        XCTAssertEqual(parse("***x***"),
                       [.strong([.emphasis([.text("x")])])])
    }

    func testTextThenEmphasis() {
        XCTAssertEqual(parse("a *b* c"),
                       [.text("a "), .emphasis([.text("b")]), .text(" c")])
    }

    // MARK: - nesting
    //
    // The scanner emits FLATTENED cumulative-trait runs, so a `*em with **bold**
    // inside*` span becomes sibling runs each independently wrapped by its
    // cumulative traits (emitters flatten anyway). This replaces the old
    // recursive-descent parser's nested-tree output. `_italic_` inside a strong
    // run is now literal (prose asterisk-only).
    func testStrongContainingLiteralUnderscore() {
        XCTAssertEqual(parse("**bold _italic_**"),
                       [.strong([.text("bold _italic_")])])
    }

    func testEmphasisContainingStrong_flattened() {
        XCTAssertEqual(parse("*italic with **bold** inside*"),
                       [.emphasis([.text("italic with ")]),
                        .strong([.emphasis([.text("bold")])]),
                        .emphasis([.text(" inside")])])
    }

    // MARK: - escapes and strikethrough (via the scanner)

    func test_escapedAsterisk_literal_backslashDropped() {
        XCTAssertEqual(parse(#"\*x\*"#), [.text("*x*")])
    }

    func test_strikethrough_parses() {
        XCTAssertEqual(parse("a ~~b~~ c"),
                       [.text("a "), .strikethrough([.text("b")]), .text(" c")])
    }

    func test_emphasisAcrossSoftBreak_withinParagraph() {
        XCTAssertEqual(parse("*a\nb*"),
                       [.emphasis([.text("a\nb")])])
    }

    func test_codeSpanContent_neverEmphasized_andBlocksFlanking() {
        XCTAssertEqual(parse("`*x*`"), [.code("*x*")])
    }

    // MARK: - unbalanced delimiters fall back to literal

    func testUnbalancedEmphasis_isLiteral() {
        XCTAssertEqual(parse("*hello"), [.text("*hello")])
    }

    func testUnbalancedStrong_isLiteral() {
        XCTAssertEqual(parse("**hello"), [.text("**hello")])
    }

    // MARK: - code spans never recurse

    func testCodeSpan() {
        XCTAssertEqual(parse("`x`"), [.code("x")])
    }

    func testCodeSpan_doesNotInterpretMarkdownInside() {
        XCTAssertEqual(parse("`**not bold**`"), [.code("**not bold**")])
    }

    func testUnbalancedCode_isLiteral() {
        XCTAssertEqual(parse("`oops"), [.text("`oops")])
    }

    // MARK: - wiki links

    func testWikiLink_targetAndDisplay() {
        XCTAssertEqual(parse("[[Aaron|him]]"),
                       [.wikiLink(target: "Aaron", display: "him")])
    }

    func testWikiLink_targetOnly_displayMirrorsTarget() {
        XCTAssertEqual(parse("[[Aaron]]"),
                       [.wikiLink(target: "Aaron", display: "Aaron")])
    }

    func testWikiLink_embeddedInText() {
        XCTAssertEqual(parse("See [[Aaron|him]] now."),
                       [.text("See "),
                        .wikiLink(target: "Aaron", display: "him"),
                        .text(" now.")])
    }

    // MARK: - hard line break

    func testHardLineBreak_twoSpacesNewline() {
        XCTAssertEqual(parse("a  \nb"),
                       [.text("a"), .lineBreak, .text("b")])
    }

    func testSingleNewline_isNotABreak() {
        // A lone newline inside a block stays in the text run (the block
        // parser is responsible for soft-break handling, not InlineParser).
        XCTAssertEqual(parse("a\nb"), [.text("a\nb")])
    }
}
