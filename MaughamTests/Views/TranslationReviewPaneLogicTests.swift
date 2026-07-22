import XCTest
import MaughamCore
@testable import Maugham

/// Task 14: the pure view-model logic behind the right-pane Translation segment.
///
/// Two responsibilities, both extracted so they can be exercised without AppKit
/// or a live `Document`:
///   1. cursor → selected paragraph, mapped through the TRANSLATED render
///      (`TranslationBadgeLayout.ranges` over the badge entries) — NOT the
///      source `displayText`, whose offsets are wrong in this mode.
///   2. the open-query filter (kind == .query, status == .open, and the SAME
///      translation language as the review posture).
final class TranslationReviewPaneLogicTests: XCTestCase {

    private func entry(
        _ id: String, _ text: String, _ status: TranslationStatus = .fresh
    ) -> TranslationBadgeLayout.Entry {
        TranslationBadgeLayout.Entry(paragraphId: id, text: text, status: status)
    }

    private func query(
        _ id: String, paragraphId: String? = "p1",
        status: AnnotationStatus = .open, language: String? = "fr",
        kind: AnnotationKind = .query
    ) -> Annotation {
        Annotation(
            id: id, kind: kind, paragraphId: paragraphId,
            body: "Body \(id)", suggestedText: nil, priorText: nil,
            createdAt: Date(), createdBySession: nil,
            status: status, userResponse: nil, resolvedAt: nil, isStale: false,
            language: language)
    }

    // MARK: - Cursor → selected entry

    func test_selectedEntry_emptyEntries_isNil() {
        XCTAssertNil(TranslationReviewPaneLogic.selectedEntry(
            cursorLocation: 0, entries: []))
    }

    func test_selectedEntry_cursorInsideFirstBlock() {
        let entries = [entry("a", "Bonjour"), entry("b", "Le monde")]
        // "Bonjour" is [0,7); cursor at 3 is inside it.
        XCTAssertEqual(
            TranslationReviewPaneLogic.selectedEntry(
                cursorLocation: 3, entries: entries)?.paragraphId, "a")
    }

    func test_selectedEntry_cursorInsideSecondBlock() {
        let entries = [entry("a", "Bonjour"), entry("b", "Le monde")]
        // "Bonjour"=7, "\n\n"=2, so "Le monde" starts at 9.
        XCTAssertEqual(
            TranslationReviewPaneLogic.selectedEntry(
                cursorLocation: 11, entries: entries)?.paragraphId, "b")
    }

    func test_selectedEntry_cursorAtBlockEndBoundary_belongsToThatBlock() {
        let entries = [entry("a", "Bonjour"), entry("b", "Le monde")]
        // Cursor at 7 = end of "Bonjour" — still that paragraph (mirrors
        // Document.paragraphId(at:) boundary semantics).
        XCTAssertEqual(
            TranslationReviewPaneLogic.selectedEntry(
                cursorLocation: 7, entries: entries)?.paragraphId, "a")
    }

    func test_selectedEntry_cursorInSeparatorGap_belongsToPrecedingBlock() {
        let entries = [entry("a", "Bonjour"), entry("b", "Le monde")]
        // 8 is the second "\n" of the "\n\n" join (between 7 and 9).
        XCTAssertEqual(
            TranslationReviewPaneLogic.selectedEntry(
                cursorLocation: 8, entries: entries)?.paragraphId, "a")
    }

    func test_selectedEntry_cursorBeyondEnd_clampsToLast() {
        let entries = [entry("a", "Bonjour"), entry("b", "Le monde")]
        XCTAssertEqual(
            TranslationReviewPaneLogic.selectedEntry(
                cursorLocation: 9_999, entries: entries)?.paragraphId, "b")
    }

    func test_selectedEntry_negativeCursor_clampsToFirst() {
        let entries = [entry("a", "Bonjour"), entry("b", "Le monde")]
        XCTAssertEqual(
            TranslationReviewPaneLogic.selectedEntry(
                cursorLocation: -5, entries: entries)?.paragraphId, "a")
    }

    func test_selectedEntry_carriesStatus() {
        let entries = [entry("a", "Bonjour", .stale), entry("b", "Le monde", .missing)]
        XCTAssertEqual(
            TranslationReviewPaneLogic.selectedEntry(
                cursorLocation: 11, entries: entries)?.status, .missing)
    }

    func test_selectedEntry_multiLineBlock_doesNotDesyncFollowingBlock() {
        // A translated block with an internal blank line stays one entry; the
        // following block's offset must not shift (the whole point of
        // accumulating over entry texts rather than re-splitting on "\n\n").
        let entries = [entry("a", "Line one\n\nLine two"), entry("b", "Suivant")]
        // "Line one\n\nLine two" = 18 UTF-16 units; "\n\n"=2 ⇒ "Suivant" at 20.
        XCTAssertEqual(
            TranslationReviewPaneLogic.selectedEntry(
                cursorLocation: 22, entries: entries)?.paragraphId, "b")
    }

    // MARK: - Open-query filter

    func test_openQueries_keepsMatchingLanguageOnly() {
        let anns = [
            query("1", language: "fr"),
            query("2", language: "es"),
            query("3", language: "fr"),
        ]
        let out = TranslationReviewPaneLogic.openQueries(anns, language: "fr")
        XCTAssertEqual(out.map(\.id), ["1", "3"])
    }

    func test_openQueries_dropsNonQueryKinds() {
        let anns = [
            query("1", language: "fr", kind: .query),
            query("2", language: "fr", kind: .comment),
            query("3", language: "fr", kind: .suggestedChange),
        ]
        let out = TranslationReviewPaneLogic.openQueries(anns, language: "fr")
        XCTAssertEqual(out.map(\.id), ["1"])
    }

    func test_openQueries_dropsResolvedStatuses() {
        let anns = [
            query("1", status: .open, language: "fr"),
            query("2", status: .accepted, language: "fr"),
            query("3", status: .rejected, language: "fr"),
        ]
        let out = TranslationReviewPaneLogic.openQueries(anns, language: "fr")
        XCTAssertEqual(out.map(\.id), ["1"])
    }

    func test_openQueries_nilLanguage_returnsEmpty() {
        // No active translation language ⇒ nothing to reply to. A query with a
        // nil language tag must not leak in as a match on nil == nil.
        let anns = [query("1", language: "fr"), query("2", language: nil)]
        XCTAssertTrue(
            TranslationReviewPaneLogic.openQueries(anns, language: nil).isEmpty)
    }
}
