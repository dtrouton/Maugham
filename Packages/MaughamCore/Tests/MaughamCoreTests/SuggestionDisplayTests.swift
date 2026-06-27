import XCTest
@testable import MaughamCore

final class SuggestionDisplayTests: XCTestCase {

    private func suggestion(span: SpanAnchor?, prior: String?, suggested: String?) -> Annotation {
        Annotation(
            id: "op1", kind: .suggestedChange, paragraphId: "p1",
            body: "", suggestedText: suggested, priorText: prior,
            createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false,
            span: span)
    }

    /// Span suggestion → the "before" is the span's original text, so the diff
    /// reads `very angry → furious`, not `<whole paragraph> → furious`.
    func test_before_spanSuggestion_isTheSpanText() {
        let ann = suggestion(
            span: SpanAnchor(quote: "very angry", prefix: "She was ", suffix: ".", posHint: 8),
            prior: "She was very angry.", suggested: "furious")
        XCTAssertEqual(SuggestionDisplay.before(for: ann), "very angry")
    }

    /// Paragraph-level suggestion (no span) → the "before" is the whole prior paragraph.
    func test_before_paragraphSuggestion_isThePriorParagraph() {
        let ann = suggestion(span: nil, prior: "She was angry.", suggested: "Her jaw clenched.")
        XCTAssertEqual(SuggestionDisplay.before(for: ann), "She was angry.")
    }

    /// Empty-quote span behaves as paragraph-level.
    func test_before_emptyQuoteSpan_fallsBackToParagraph() {
        let ann = suggestion(
            span: SpanAnchor(quote: "", prefix: "", suffix: "", posHint: 0),
            prior: "Whole paragraph.", suggested: "New.")
        XCTAssertEqual(SuggestionDisplay.before(for: ann), "Whole paragraph.")
    }

    /// Non-suggestions have no before/after.
    func test_before_nonSuggestion_isNil() {
        let comment = Annotation(
            id: "op2", kind: .comment, paragraphId: "p1",
            body: "nice", suggestedText: nil, priorText: "Para.",
            createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false)
        XCTAssertNil(SuggestionDisplay.before(for: comment))
    }
}
