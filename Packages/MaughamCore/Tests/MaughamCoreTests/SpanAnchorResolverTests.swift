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

extension SpanAnchorResolverTests {
    func test_minorEditInsideSpan_stillAnchors() {
        let text = "it was for the excercise, half true."   // misspelling in current text
        let anchor = SpanAnchor(quote: "for the exercise", prefix: "was ", suffix: ", half", posHint: 7)
        XCTAssertNotNil(SpanAnchorResolver.resolve(anchor: anchor, in: text))
    }
    func test_spanFullyRewritten_goesStale() {
        let text = "it was a kind of penance, half true."
        let anchor = SpanAnchor(quote: "for the exercise", prefix: "was ", suffix: ", half", posHint: 7)
        XCTAssertNil(SpanAnchorResolver.resolve(anchor: anchor, in: text))
    }
}

extension SpanAnchorResolverTests {
    func test_capture_thenResolve_roundTrips() {
        let text = "She told herself it was for the exercise, half true."
        let chars = Array(text)
        let lo = text.distance(from: text.startIndex, to: text.range(of: "for the exercise")!.lowerBound)
        let anchor = SpanAnchorResolver.capture(in: text, range: lo..<(lo+16), contextLength: 8)
        XCTAssertEqual(anchor.quote, "for the exercise")
        XCTAssertEqual(anchor.posHint, lo)
        XCTAssertFalse(anchor.prefix.isEmpty)
        let r = SpanAnchorResolver.resolve(anchor: anchor, in: text)!
        XCTAssertEqual(String(chars[r]), "for the exercise")
    }
}
