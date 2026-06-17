import XCTest
@testable import MaughamCore

final class SpanAnchorResolverTests: XCTestCase {
    private func matched(_ anchor: SpanAnchor, in text: String) -> String? {
        guard let r = SpanAnchorResolver.resolve(anchor: anchor, in: text) else { return nil }
        let chars = Array(text)
        return String(chars[r])
    }

    func test_exactSingleOccurrence_matches() {
        let text = "She told herself it was for the exercise, half true."
        let anchor = SpanAnchor(quote: "for the exercise", prefix: "it was ", suffix: ", half", posHint: 24)
        XCTAssertEqual(matched(anchor, in: text), "for the exercise")
    }

    func test_repeatedSpan_otherOccurrenceDeleted_usesContext() {
        let text = "he said. she said again."
        let anchor = SpanAnchor(quote: "said", prefix: "she ", suffix: " again", posHint: 11)
        let r = SpanAnchorResolver.resolve(anchor: anchor, in: text)!
        XCTAssertEqual(r.lowerBound, 13) // the 2nd "said"
    }

    func test_quoteAbsent_returnsNilStale() {
        let text = "completely different sentence."
        let anchor = SpanAnchor(quote: "for the exercise", prefix: "", suffix: "", posHint: 0)
        XCTAssertNil(SpanAnchorResolver.resolve(anchor: anchor, in: text))
    }

    func test_emptyQuote_isParagraphLevel_returnsNil() {
        let anchor = SpanAnchor(quote: "", prefix: "", suffix: "", posHint: 0)
        XCTAssertNil(SpanAnchorResolver.resolve(anchor: anchor, in: "anything"))
    }
}
