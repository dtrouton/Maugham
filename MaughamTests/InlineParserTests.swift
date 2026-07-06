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

    // The masked (non-space) placeholder keeps flanking alive ACROSS a
    // protected span sitting inside emphasis markers, but the scanner emits
    // flattened cumulative-trait runs (same mechanism as
    // testEmphasisContainingStrong_flattened above) — the protected span is
    // spliced in as a sibling, not re-wrapped in the enclosing emphasis.
    // Pinned so a converter change can't silently flip this shape.
    func test_emphasisFlanksAcrossCodeSpan() {
        XCTAssertEqual(parse("*a `code` b*"),
                       [.emphasis([.text("a ")]),
                        .code("code"),
                        .emphasis([.text(" b")])])
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

    // Backslash-newline is a second hard-break spelling (alongside the
    // two-space form above). Must be caught by protected-span pre-extraction
    // BEFORE the scanner's own escape pre-pass runs, since that pre-pass only
    // neutralizes a backslash before `* ~ _ \``/`\` — newline isn't in that
    // escapable set, so left alone the backslash would survive as literal text.
    func testBackslashHardBreak() {
        XCTAssertEqual(parse("a\\\nb"),
                       [.text("a"), .lineBreak, .text("b")])
    }

    // An escaped backslash (`\\`) is an escape PAIR, not a hard-break opener:
    // the first `\` neutralizes the second into a literal character, so the
    // following newline is an ordinary (soft) newline, not `.lineBreak`.
    // Source chars: a, \, \, \n, b.
    func testEscapedBackslash_thenNewline_isNotAHardBreak() {
        let result = parse("a\\\\\nb")
        XCTAssertFalse(result.contains(.lineBreak))
        XCTAssertEqual(result, [.text("a\\\nb")])
    }
}
