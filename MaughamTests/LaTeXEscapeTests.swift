import XCTest
@testable import Maugham

final class LaTeXEscapeTests: XCTestCase {

    func testEscapes_percent() {
        XCTAssertEqual(LaTeXEscape.escape("50% off"), "50\\% off")
    }

    func testEscapes_ampersand() {
        XCTAssertEqual(LaTeXEscape.escape("Tom & Jerry"), "Tom \\& Jerry")
    }

    func testEscapes_dollar() {
        XCTAssertEqual(LaTeXEscape.escape("price: $5"), "price: \\$5")
    }

    func testEscapes_underscore() {
        XCTAssertEqual(LaTeXEscape.escape("var_name"), "var\\_name")
    }

    func testEscapes_hash() {
        XCTAssertEqual(LaTeXEscape.escape("#tag"), "\\#tag")
    }

    func testEscapes_braces() {
        XCTAssertEqual(LaTeXEscape.escape("{a}"), "\\{a\\}")
    }

    func testEscapes_backslash() {
        XCTAssertEqual(LaTeXEscape.escape("C:\\path"), "C:\\textbackslash{}path")
    }

    func testEscapes_tilde() {
        XCTAssertEqual(LaTeXEscape.escape("a~b"), "a\\textasciitilde{}b")
    }

    func testEscapes_caret() {
        XCTAssertEqual(LaTeXEscape.escape("a^b"), "a\\textasciicircum{}b")
    }

    func testIdempotent_safeAscii() {
        XCTAssertEqual(LaTeXEscape.escape("Hello, world."), "Hello, world.")
    }

    func testEscapes_combinations() {
        XCTAssertEqual(
            LaTeXEscape.escape("100% & $5 (no #1)"),
            "100\\% \\& \\$5 (no \\#1)"
        )
    }
}
