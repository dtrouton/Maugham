import XCTest
import MaughamCore
@testable import Maugham

final class TokenTests: XCTestCase {
    func test_kindEquality_distinguishesHeadingLevels() {
        XCTAssertNotEqual(Token.Kind.heading(level: 1), .heading(level: 2))
        XCTAssertEqual(Token.Kind.heading(level: 3), .heading(level: 3))
    }

    func test_kindEquality_distinguishesEmphasisStrength() {
        XCTAssertNotEqual(Token.Kind.emphasis([.italic]),
                          .emphasis([.bold]))
    }

    func test_kindEquality_distinguishesLinkHrefs() {
        XCTAssertNotEqual(Token.Kind.link(href: "a"),
                          .link(href: "b"))
        XCTAssertEqual(Token.Kind.link(href: "a"),
                       .link(href: "a"))
    }

    func test_token_equatableByRangeAndKind() {
        let a = Token(range: NSRange(location: 0, length: 5), kind: .plain)
        let b = Token(range: NSRange(location: 0, length: 5), kind: .plain)
        XCTAssertEqual(a, b)
    }
}
