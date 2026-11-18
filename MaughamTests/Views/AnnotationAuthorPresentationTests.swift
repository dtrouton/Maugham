import XCTest
import MaughamCore
@testable import Maugham

/// **How a note row names its author** (`AnnotationAuthorPresentation`):
/// the label every note row draws, and the Claude predicate. Restored from
/// `AnnotationAuthorFilterTests` when the filter it also tested was culled
/// (shell plan 2 Task 7 fix 2).
final class AnnotationAuthorPresentationTests: XCTestCase {

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
}
