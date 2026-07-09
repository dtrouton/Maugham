import XCTest
@testable import MaughamCore

final class SuggestionSpliceGrainTests: XCTestCase {

    // Paragraph: prefix "The rain fell hard on the tin roof, " +
    // span "and nobody spoke" + suffix " for a long time."
    private let paragraph = "The rain fell hard on the tin roof, and nobody spoke for a long time."
    private var span: SpanAnchor {
        SpanAnchor(quote: "and nobody spoke",
                   prefix: "tin roof, ", suffix: " for a long",
                   posHint: 37)
    }

    func test_correctGrain_splicesSpanOnly() {
        let out = SuggestionSplice.apply(
            suggestion: "and the silence held", span: span, to: paragraph)
        XCTAssertEqual(out, "The rain fell hard on the tin roof, and the silence held for a long time.")
    }

    func test_wholeParagraphBare_bothContextsPresent_replacesWholeParagraph() {
        // Claude followed the old contract: suggested_text is the WHOLE new
        // paragraph, but a quote was also supplied. Salvage: detect the
        // surrounding context inside the bare text and use it verbatim.
        let bare = "The rain fell hard on the tin roof, and the silence held for a long time."
        let out = SuggestionSplice.apply(suggestion: bare, span: span, to: paragraph)
        XCTAssertEqual(out, bare)
    }

    func test_wholeParagraphBare_spanAtStart_longSuffixMatch_replacesWholeParagraph() {
        let startSpan = SpanAnchor(quote: "The rain fell hard",
                                   prefix: "", suffix: " on the tin", posHint: 0)
        let bare = "Rain hammered down on the tin roof, and nobody spoke for a long time."
        let out = SuggestionSplice.apply(suggestion: bare, span: startSpan, to: paragraph)
        XCTAssertEqual(out, bare)
    }

    func test_shortSuffixCoincidence_doesNotTriggerSalvage() {
        // Span near the end; suffix is just ".". A correct bare replacement
        // ending in "." must NOT be misread as whole-paragraph grain (that
        // would silently DELETE the rest of the paragraph).
        let p = "Hello world. Goodbye."
        let endSpan = SpanAnchor(quote: "Goodbye", prefix: "world. ", suffix: ".", posHint: 13)
        let out = SuggestionSplice.apply(suggestion: "Farewell.", span: endSpan, to: p)
        XCTAssertEqual(out, "Hello world. Farewell..")
    }

    func test_shortBothSidesCoincidence_doesNotTriggerSalvage() {
        // BOTH sides match but the combined trimmed context is tiny: a
        // span-grain replacement that coincidentally starts with "She" and
        // ends with "." must NOT be misread as whole-paragraph grain (that
        // would silently DELETE the paragraph's surrounding text).
        let p = "She said hello to the stranger."
        let s = SpanAnchor(quote: "said hello to the stranger",
                           prefix: "She ", suffix: ".", posHint: 4)
        let out = SuggestionSplice.apply(suggestion: "She waved.", span: s, to: p)
        XCTAssertEqual(out, "She She waved..")
    }

    func test_wholeGrain_longCombinedContext_bothShortSides() {
        // Each side individually under the 12-char one-sided floor (trimmed
        // prefix "Meanwhile," = 10, trimmed suffix "tonight." = 8) but the
        // combined length is >= 12: a genuinely whole-grain bare embedding
        // both contexts must still be salvaged.
        let p = "Meanwhile, the dogs barked at shadows tonight."
        let s = SpanAnchor(quote: "the dogs barked at shadows",
                           prefix: "Meanwhile, ", suffix: " tonight.", posHint: 11)
        let bare = "Meanwhile, the cats hissed at nothing tonight."
        let out = SuggestionSplice.apply(suggestion: bare, span: s, to: p)
        XCTAssertEqual(out, bare)
    }

    func test_noSpan_bareIsWholeParagraph_unchangedBehavior() {
        XCTAssertEqual(SuggestionSplice.apply(suggestion: "New.", span: nil, to: paragraph), "New.")
    }

    func test_unresolvableSpan_fallsBackToBare_unchangedBehavior() {
        let ghost = SpanAnchor(quote: "zebra quantum", prefix: "", suffix: "", posHint: 0)
        XCTAssertEqual(SuggestionSplice.apply(suggestion: "New.", span: ghost, to: paragraph), "New.")
    }

    func test_display_wholeGrain_beforeIsPriorText() {
        let ann = Annotation(
            id: "01AA", kind: .suggestedChange, paragraphId: "abcd",
            body: "b",
            suggestedText: "The rain fell hard on the tin roof, and the silence held for a long time.",
            priorText: paragraph,
            createdAt: Date(), createdBySession: nil, status: .open,
            userResponse: nil, resolvedAt: nil, isStale: false,
            author: nil, span: span, resolvedSpanRange: nil)
        XCTAssertEqual(SuggestionDisplay.before(for: ann), paragraph)
    }

    func test_display_correctGrain_beforeIsQuote() {
        let ann = Annotation(
            id: "01AB", kind: .suggestedChange, paragraphId: "abcd",
            body: "b", suggestedText: "and the silence held",
            priorText: paragraph,
            createdAt: Date(), createdBySession: nil, status: .open,
            userResponse: nil, resolvedAt: nil, isStale: false,
            author: nil, span: span, resolvedSpanRange: nil)
        XCTAssertEqual(SuggestionDisplay.before(for: ann), "and nobody spoke")
    }
}
