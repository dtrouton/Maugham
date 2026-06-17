import XCTest
@testable import MaughamCore

final class AnnotationProvenanceTests: XCTestCase {
    func test_spanAnchor_roundTripsThroughJSON() throws {
        let anchor = SpanAnchor(quote: "habit alone", prefix: "as though the ", suffix: " could summon", posHint: 31)
        let data = try JSONEncoder().encode(anchor)
        let decoded = try JSONDecoder().decode(SpanAnchor.self, from: data)
        XCTAssertEqual(decoded, anchor)
    }

    func test_annotationAuthor_roundTripsThroughJSON() throws {
        let author = AnnotationAuthor(sourceKind: .human, displayName: "Marian", collaboratorId: "c-123")
        let data = try JSONEncoder().encode(author)
        let decoded = try JSONDecoder().decode(AnnotationAuthor.self, from: data)
        XCTAssertEqual(decoded, author)
    }
}
