import XCTest
@testable import MaughamCore

/// Ownership gate for author self-service (edit/withdraw your own annotation).
/// Cooperative identity: human author + matching display name → own.
final class AnnotationOwnershipTests: XCTestCase {

    private func annotation(author: AnnotationAuthor?) -> Annotation {
        Annotation(
            id: "op1", kind: .comment, paragraphId: "p001",
            body: "b", suggestedText: nil, priorText: nil,
            createdAt: Date(), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil,
            isStale: false, author: author)
    }

    func test_ownHumanAnnotation_isOwn() {
        let ann = annotation(author: AnnotationAuthor(
            sourceKind: .human, displayName: "Sam"))
        XCTAssertTrue(AnnotationOwnership.isOwn(ann, localName: "Sam"))
    }

    func test_otherHumanAnnotation_isNotOwn() {
        let ann = annotation(author: AnnotationAuthor(
            sourceKind: .human, displayName: "Alex"))
        XCTAssertFalse(AnnotationOwnership.isOwn(ann, localName: "Sam"))
    }

    func test_claudeAnnotation_isNotOwn() {
        let ann = annotation(author: AnnotationAuthor(
            sourceKind: .claude, displayName: "Sam"))
        XCTAssertFalse(AnnotationOwnership.isOwn(ann, localName: "Sam"),
                       "Claude is never the local human, even on a name collision")
    }

    func test_nilAuthor_isNotOwn() {
        XCTAssertFalse(AnnotationOwnership.isOwn(
            annotation(author: nil), localName: "Sam"))
    }
}
