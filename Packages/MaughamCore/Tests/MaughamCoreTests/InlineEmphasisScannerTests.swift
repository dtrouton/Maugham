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
}
