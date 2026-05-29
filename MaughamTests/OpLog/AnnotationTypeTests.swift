import XCTest
import MaughamCore
@testable import Maugham

final class AnnotationTypeTests: XCTestCase {
    func test_annotationKind_encodesSnakeCase() {
        let pairs: [(AnnotationKind, String)] = [
            (.comment, "comment"),
            (.suggestedChange, "suggested_change"),
            (.query, "query"),
            (.craftNote, "craft_note"),
        ]
        for (kind, raw) in pairs {
            XCTAssertEqual(kind.rawValue, raw)
        }
    }

    func test_annotationStatus_allCases() {
        XCTAssertEqual(
            Set(AnnotationStatus.allCases.map(\.rawValue)),
            ["open", "accepted", "rejected", "archived"])
    }

    func test_filter_defaults_toOpenOnly() {
        let f = AnnotationFilter()
        XCTAssertEqual(f.statuses, [.open])
        XCTAssertNil(f.kinds)
        XCTAssertNil(f.paragraphId)
    }

    func test_annotation_isIdentifiable_byOpId() {
        let a = Annotation(
            id: "01HXYZ", kind: .comment, paragraphId: "p1",
            body: "hi", suggestedText: nil, priorText: nil,
            createdAt: Date(), createdBySession: nil,
            status: .open, userResponse: nil,
            resolvedAt: nil, isStale: false)
        XCTAssertEqual(a.id, "01HXYZ")
    }

    func test_fromOpKind_mapsCreationKinds() {
        XCTAssertEqual(AnnotationKind.fromOpKind(.claudeComment), .comment)
        XCTAssertEqual(
            AnnotationKind.fromOpKind(.claudeSuggestion), .suggestedChange)
        XCTAssertEqual(AnnotationKind.fromOpKind(.claudeQuery), .query)
        XCTAssertEqual(AnnotationKind.fromOpKind(.claudeCraftNote), .craftNote)
        XCTAssertNil(AnnotationKind.fromOpKind(.typingBurst))
        XCTAssertNil(AnnotationKind.fromOpKind(.claudeAccept))
    }
}
