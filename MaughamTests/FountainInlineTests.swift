import XCTest
@testable import Maugham

final class FountainInlineTests: XCTestCase {

    private func parse(_ s: String) -> [ProjectAST.Inline] {
        FountainInline.parse(s)
    }

    func testPlainText() {
        XCTAssertEqual(parse("She runs."), [.text("She runs.")])
    }

    func testItalic() {
        XCTAssertEqual(parse("*fast*"), [.emphasis([.text("fast")])])
    }

    func testBold() {
        XCTAssertEqual(parse("**loud**"), [.strong([.text("loud")])])
    }

    func testBoldItalic_tripleStar() {
        XCTAssertEqual(parse("***both***"), [.strong([.emphasis([.text("both")])])])
    }

    func testUnderline_isUnderlineNotItalic() {
        // Fountain: _x_ is underline, unlike markdown where it is italic.
        XCTAssertEqual(parse("_under_"), [.underline([.text("under")])])
    }

    func testInlineWithinSentence() {
        XCTAssertEqual(parse("He said *no* loudly."),
                       [.text("He said "), .emphasis([.text("no")]), .text(" loudly.")])
    }

    // The scanner emits FLATTENED cumulative-trait runs, so mixed nesting
    // becomes sibling runs each independently wrapped (emitters flatten anyway).
    func testBoldContainingItalic_flattened() {
        XCTAssertEqual(parse("**a *b* c**"),
                       [.strong([.text("a ")]),
                        .strong([.emphasis([.text("b")])]),
                        .strong([.text(" c")])])
    }

    func testItalicContainingBold_flattened() {
        XCTAssertEqual(parse("*a **b** c*"),
                       [.emphasis([.text("a ")]),
                        .strong([.emphasis([.text("b")])]),
                        .emphasis([.text(" c")])])
    }

    // Emphasis inside underline is preserved: the underline's inner text runs
    // through the converter too.
    func test_underline_containingEmphasis() {
        XCTAssertEqual(parse("_a *b* c_"),
                       [.underline([.text("a "), .emphasis([.text("b")]), .text(" c")])])
    }

    // Fountain does NOT enable strikethrough — `~` is a lyric marker there, so
    // tildes stay literal.
    func test_fountain_tildesStayLiteral() {
        XCTAssertEqual(parse("a ~~x~~ b"), [.text("a ~~x~~ b")])
    }

    // Escapes match prose: backslash dropped, delimiter literal.
    func test_fountain_escapes_matchProse() {
        XCTAssertEqual(parse(#"\*x\*"#), [.text("*x*")])
    }

    func testEscapedStar_isLiteral() {
        XCTAssertEqual(parse("a \\*b\\* c"), [.text("a *b* c")])
    }

    func testEscapedUnderscore_isLiteral() {
        XCTAssertEqual(parse("snake\\_case"), [.text("snake_case")])
    }

    func testUnbalancedStar_isLiteral() {
        XCTAssertEqual(parse("*oops"), [.text("*oops")])
    }

    func testUnbalancedUnderscore_isLiteral() {
        XCTAssertEqual(parse("_oops"), [.text("_oops")])
    }
}
