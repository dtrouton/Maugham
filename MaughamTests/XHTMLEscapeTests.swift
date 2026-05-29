import XCTest
@testable import Maugham

final class XHTMLEscapeTests: XCTestCase {

    func testEscapes_amp() {
        XCTAssertEqual(XHTMLEscape.escape("Tom & Jerry"), "Tom &amp; Jerry")
    }

    func testEscapes_lt_gt() {
        XCTAssertEqual(XHTMLEscape.escape("a<b>c"), "a&lt;b&gt;c")
    }

    func testEscapes_quotes() {
        XCTAssertEqual(XHTMLEscape.escape("\"x\""), "&quot;x&quot;")
        XCTAssertEqual(XHTMLEscape.escape("'y'"), "&apos;y&apos;")
    }

    func testIdempotent_safe() {
        XCTAssertEqual(XHTMLEscape.escape("Hello, world."), "Hello, world.")
    }

    func testEscapesAttribute_doublesQuotes() {
        XCTAssertEqual(
            XHTMLEscape.attribute("a \"b\" & <c>"),
            "a &quot;b&quot; &amp; &lt;c&gt;"
        )
    }

    func testAmpFirst_ordering() {
        // & must be replaced before others
        XCTAssertEqual(XHTMLEscape.escape("a&b<c"), "a&amp;b&lt;c")
    }
}
