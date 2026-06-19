import XCTest
import MaughamCore
@testable import Maugham

final class AnnotationAuthorFilterTests: XCTestCase {

    private func annotation(
        id: String, author: AnnotationAuthor?
    ) -> Annotation {
        Annotation(
            id: id, kind: .comment, paragraphId: "p1az",
            body: "body", suggestedText: nil, priorText: nil,
            createdAt: Date(), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil,
            isStale: false, author: author)
    }

    private var claudeAuthored: Annotation {
        annotation(id: "c", author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"))
    }
    private var nilAuthored: Annotation {
        annotation(id: "n", author: nil)
    }
    private var humanAuthored: Annotation {
        annotation(id: "h", author: AnnotationAuthor(sourceKind: .human, displayName: "Somerset"))
    }

    // MARK: - Presentation labels

    func test_label_nilAuthor_isClaude() {
        XCTAssertEqual(AnnotationAuthorPresentation.label(for: nil), "Claude")
    }

    func test_label_claudeAuthor_isClaude() {
        let a = AnnotationAuthor(sourceKind: .claude, displayName: "Claude")
        XCTAssertEqual(AnnotationAuthorPresentation.label(for: a), "Claude")
    }

    func test_label_humanAuthor_isDisplayName() {
        let a = AnnotationAuthor(sourceKind: .human, displayName: "Somerset")
        XCTAssertEqual(AnnotationAuthorPresentation.label(for: a), "Somerset")
    }

    func test_label_emptyHumanName_fallsBackToReviewer() {
        let a = AnnotationAuthor(sourceKind: .human, displayName: "")
        XCTAssertEqual(AnnotationAuthorPresentation.label(for: a), "Reviewer")
    }

    func test_isClaude_nilAndClaude_true_human_false() {
        XCTAssertTrue(AnnotationAuthorPresentation.isClaude(nil))
        XCTAssertTrue(AnnotationAuthorPresentation.isClaude(
            AnnotationAuthor(sourceKind: .claude, displayName: "Claude")))
        XCTAssertFalse(AnnotationAuthorPresentation.isClaude(
            AnnotationAuthor(sourceKind: .human, displayName: "Somerset")))
    }

    // MARK: - Filter predicate

    func test_matches_nilSelected_matchesAll() {
        XCTAssertTrue(AnnotationAuthorFilter.matches(claudeAuthored, selected: nil))
        XCTAssertTrue(AnnotationAuthorFilter.matches(humanAuthored, selected: nil))
        XCTAssertTrue(AnnotationAuthorFilter.matches(nilAuthored, selected: nil))
    }

    func test_matches_allSentinel_matchesAll() {
        XCTAssertTrue(AnnotationAuthorFilter.matches(claudeAuthored, selected: "All"))
        XCTAssertTrue(AnnotationAuthorFilter.matches(humanAuthored, selected: "All"))
        XCTAssertTrue(AnnotationAuthorFilter.matches(nilAuthored, selected: "All"))
    }

    func test_matches_byName_onlyThatAuthor() {
        XCTAssertTrue(AnnotationAuthorFilter.matches(humanAuthored, selected: "Somerset"))
        XCTAssertFalse(AnnotationAuthorFilter.matches(claudeAuthored, selected: "Somerset"))
        XCTAssertFalse(AnnotationAuthorFilter.matches(nilAuthored, selected: "Somerset"))
    }

    func test_matches_claude_matchesNilAndClaudeAuthored() {
        XCTAssertTrue(AnnotationAuthorFilter.matches(claudeAuthored, selected: "Claude"))
        XCTAssertTrue(AnnotationAuthorFilter.matches(nilAuthored, selected: "Claude"))
        XCTAssertFalse(AnnotationAuthorFilter.matches(humanAuthored, selected: "Claude"))
    }

    // MARK: - Distinct labels

    func test_distinctLabels_claudeFirstThenAlphabetical() {
        let anns = [
            humanAuthored,
            nilAuthored,
            annotation(id: "z", author: AnnotationAuthor(sourceKind: .human, displayName: "Aldous")),
            claudeAuthored,
        ]
        XCTAssertEqual(
            AnnotationAuthorFilter.distinctLabels(in: anns),
            ["Claude", "Aldous", "Somerset"])
    }

    func test_distinctLabels_noClaude_omitsIt() {
        let anns = [humanAuthored]
        XCTAssertEqual(AnnotationAuthorFilter.distinctLabels(in: anns), ["Somerset"])
    }
}
