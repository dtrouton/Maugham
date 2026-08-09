import XCTest
@testable import MaughamCore

final class SuggestionSpliceTests: XCTestCase {

    private func span(_ quote: String, in text: String) -> SpanAnchor {
        let chars = Array(text)
        let lo = String(chars).range(of: quote).map {
            text.distance(from: text.startIndex, to: $0.lowerBound)
        } ?? 0
        return SpanAnchorResolver.capture(in: text, range: lo..<(lo + quote.count))
    }

    /// Sub-paragraph span suggestion: only the span is replaced.
    func test_apply_spliceReplacesOnlyTheSpan() {
        let para = "She was very angry."
        let s = span("very angry", in: para)
        XCTAssertEqual(
            SuggestionSplice.attempt(suggestion: "furious", span: s, to: para),
            .applied("She was furious."))
    }

    /// A one-word span change in a long paragraph leaves the rest intact (the
    /// case that motivated splicing at accept rather than storing the whole
    /// paragraph as the suggestion).
    func test_apply_longParagraph_onlySpanChanges() {
        let para = "The quick brown fox jumped over the lazy sleeping dog by the river."
        let s = span("lazy sleeping", in: para)
        XCTAssertEqual(
            SuggestionSplice.attempt(suggestion: "alert", span: s, to: para),
            .applied("The quick brown fox jumped over the alert dog by the river."))
    }

    /// Paragraph-level suggestion (no span): the bare text is the whole paragraph.
    func test_apply_noSpan_replacesWholeParagraph() {
        XCTAssertEqual(
            SuggestionSplice.attempt(suggestion: "Her jaw clenched.", span: nil,
                                   to: "She was angry."),
            .applied("Her jaw clenched."))
    }

    /// Lost anchor (quote not present): REFUSED (RULING-5, 2026-08-09). The
    /// old whole-paragraph fallback was the M5-AN-049 data-loss path.
    func test_attempt_unresolvableSpan_isRefused() {
        let s = SpanAnchor(quote: "not here", prefix: "", suffix: "", posHint: 0)
        XCTAssertEqual(
            SuggestionSplice.attempt(suggestion: "x", span: s, to: "abc def"),
            .anchorLost)
    }

    /// Provenance round-trip: a span-bearing provenance reconstructs its anchor;
    /// an empty/absent quote yields nil (paragraph-level).
    func test_spanAnchor_fromProvenance() {
        let prov = Op.Provenance(
            sessionId: "s",
            spanQuote: "very angry", spanPrefix: "She was ",
            spanSuffix: ".", spanPosHint: 8)
        let anchor = SuggestionSplice.spanAnchor(from: prov)
        XCTAssertEqual(anchor?.quote, "very angry")
        XCTAssertEqual(anchor?.prefix, "She was ")
        XCTAssertEqual(anchor?.posHint, 8)

        XCTAssertNil(SuggestionSplice.spanAnchor(from: nil))
        let noQuote = Op.Provenance(sessionId: "s")
        XCTAssertNil(SuggestionSplice.spanAnchor(from: noQuote))
    }
}
