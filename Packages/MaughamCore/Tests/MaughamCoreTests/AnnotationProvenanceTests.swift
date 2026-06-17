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

extension AnnotationProvenanceTests {
    func test_provenance_carriesAuthorAndSpan_andLegacyDecodesNil() throws {
        let prov = Op.Provenance(
            annotationBody: "undersells her",
            authorSourceKind: "human", authorDisplayName: "Marian", authorCollaboratorId: "c-1",
            spanQuote: "for the exercise", spanPrefix: "was ", spanSuffix: ", half", spanPosHint: 7)
        let data = try JSONEncoder().encode(prov)
        let decoded = try JSONDecoder().decode(Op.Provenance.self, from: data)
        XCTAssertEqual(decoded.authorSourceKind, "human")
        XCTAssertEqual(decoded.spanQuote, "for the exercise")
        XCTAssertEqual(decoded.spanPosHint, 7)
        let legacy = #"{"annotation_body":"hi"}"#.data(using: .utf8)!
        let legacyDecoded = try JSONDecoder().decode(Op.Provenance.self, from: legacy)
        XCTAssertNil(legacyDecoded.authorSourceKind)
        XCTAssertNil(legacyDecoded.spanQuote)
    }
}
