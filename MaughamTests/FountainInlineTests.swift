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

    func testBoldContainingItalic() {
        XCTAssertEqual(parse("**a *b* c**"),
                       [.strong([.text("a "), .emphasis([.text("b")]), .text(" c")])])
    }

    func testItalicContainingBold() {
        XCTAssertEqual(parse("*a **b** c*"),
                       [.emphasis([.text("a "), .strong([.text("b")]), .text(" c")])])
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
