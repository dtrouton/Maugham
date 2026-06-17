import XCTest
@testable import MaughamCore

final class SpanTextTests: XCTestCase {
    func test_normalize_canonicalizesSmartQuotesAndDashes() {
        XCTAssertEqual(SpanText.normalize("don\u{2019}t \u{201C}go\u{201D}"), "don't \"go\"")
        XCTAssertEqual(SpanText.normalize("a \u{2014} b"), "a - b")
        XCTAssertEqual(SpanText.normalize("a \u{2013} b"), "a - b")
    }
    func test_normalize_collapsesWhitespaceRuns() {
        XCTAssertEqual(SpanText.normalize("for   the\texercise"), "for the exercise")
    }
    func test_normalize_isIdempotent() {
        let once = SpanText.normalize("the  \u{201C}cat\u{201D}")
        XCTAssertEqual(SpanText.normalize(once), once)
    }
}
