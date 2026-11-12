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

    // MARK: - planAccept / newestAppliedAccept (R-B, hardening 11-11 Task 5)

    private func line(_ opId: String, _ kind: OpKind, prior: String? = nil, next: String? = nil) -> Op {
        Op(opId: opId, docId: "doc-0f677d7e", at: Date(timeIntervalSince1970: 0),
           device: "mac", session: "s", kind: kind,
           changes: next.map { [Op.ParagraphChange(paragraphId: "k7m3", prior: prior, next: $0)] } ?? [],
           provenance: Op.Provenance(sessionId: "s", sourceAnnotationId: "01NOTE"))
    }

    func test_planAccept_splicesWhenNothingIsApplied() {
        XCTAssertEqual(
            SuggestionSplice.planAccept(annotationId: "01NOTE", suggestion: "B.", span: nil,
                                        paragraph: "A.", ops: []),
            .splice(next: "B."))
    }

    /// The race: accepted, archived on another device, reopened. The splice is
    /// in the text, so a second accept is status-only — even for a span whose
    /// quote the splice replaced (it would otherwise refuse as anchor lost).
    func test_planAccept_isStatusOnlyWhileTheNotesSpliceIsInPlace() {
        let para = "The night was very dark and cold."
        let s = span("very dark", in: para)
        let applied = "The night was pitch black and cold."
        let ops = [
            line("01A", .claudeAccept, prior: para, next: applied),
            line("01B", .claudeArchive),
            line("01C", .annotationReopen),
        ]
        XCTAssertEqual(SuggestionSplice.attempt(suggestion: "pitch black", span: s, to: applied),
                       .anchorLost, "premise: the quote is gone")
        XCTAssertEqual(
            SuggestionSplice.planAccept(annotationId: "01NOTE", suggestion: "pitch black",
                                        span: s, paragraph: applied, ops: ops),
            .statusOnly)
    }

    /// Not in place: the newest text-carrying line is a revert or a RULING-33
    /// repair, or the writer has typed over the accept's text.
    func test_planAccept_splicesOrRefusesOnceTheSpliceIsNoLongerInPlace() {
        let reverted = [line("01A", .claudeAccept, prior: "A.", next: "B."),
                        line("01B", .claudeAcceptRevert, prior: "B.", next: "A.")]
        XCTAssertEqual(SuggestionSplice.planAccept(annotationId: "01NOTE", suggestion: "B.",
                                                   span: nil, paragraph: "A.", ops: reverted),
                       .splice(next: "B."))
        let repaired = [line("01A", .claudeAccept, prior: "A.", next: "B."),
                        line("01B", .claudeReject, prior: "B.", next: "A.")]
        XCTAssertEqual(SuggestionSplice.planAccept(annotationId: "01NOTE", suggestion: "B.",
                                                   span: nil, paragraph: "A.", ops: repaired),
                       .splice(next: "B."))
        let para = "The night was very dark and cold."
        let s = span("very dark", in: para)
        let accepted = [line("01A", .claudeAccept, prior: para,
                             next: "The night was pitch black and cold.")]
        XCTAssertEqual(SuggestionSplice.planAccept(annotationId: "01NOTE", suggestion: "pitch black",
                                                   span: s, paragraph: "Rain fell.", ops: accepted),
                       .anchorLost, "the writer rewrote it: RULING-5's refusal stands")
    }

    func test_planAccept_isStatusOnlyWhenTheParagraphAlreadyReadsAsTheSuggestion() {
        XCTAssertEqual(
            SuggestionSplice.planAccept(annotationId: "01NOTE", suggestion: "B.", span: nil,
                                        paragraph: "B.", ops: []),
            .statusOnly)
    }

    /// A status-only accept moved no text: Revert reads the newest accept that did.
    func test_newestAppliedAccept_skipsStatusOnlyAccepts_andOtherNotes() {
        let ops = [
            line("01A", .claudeAccept, prior: "A.", next: "B."),
            line("01B", .claudeArchive),
            line("01C", .claudeAccept),
            Op(opId: "01D", docId: "doc-0f677d7e", at: Date(timeIntervalSince1970: 0),
               device: "mac", session: "s", kind: .claudeAccept,
               changes: [Op.ParagraphChange(paragraphId: "k7m3", prior: "x", next: "y")],
               provenance: Op.Provenance(sessionId: "s", sourceAnnotationId: "01OTHER")),
        ]
        XCTAssertEqual(SuggestionSplice.newestAppliedAccept(annotationId: "01NOTE", in: ops)?.opId, "01A")
        XCTAssertNil(SuggestionSplice.newestAppliedAccept(annotationId: "01NOTE", in: [line("01C", .claudeAccept)]))
    }
}
