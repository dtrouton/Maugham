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

    func testEmphasis_underscore() {
        XCTAssertEqual(parse("_italic_"), [.emphasis([.text("italic")])])
    }

    func testStrong_doubleAsterisk() {
        XCTAssertEqual(parse("**bold**"), [.strong([.text("bold")])])
    }

    func testTextThenEmphasis() {
        XCTAssertEqual(parse("a *b* c"),
                       [.text("a "), .emphasis([.text("b")]), .text(" c")])
    }

    // MARK: - nesting

    func testStrongContainingEmphasis() {
        XCTAssertEqual(parse("**bold _italic_**"),
                       [.strong([.text("bold "), .emphasis([.text("italic")])])])
    }

    func testEmphasisContainingStrong() {
        XCTAssertEqual(parse("*italic with **bold** inside*"),
                       [.emphasis([
                            .text("italic with "),
                            .strong([.text("bold")]),
                            .text(" inside")
                       ])])
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
