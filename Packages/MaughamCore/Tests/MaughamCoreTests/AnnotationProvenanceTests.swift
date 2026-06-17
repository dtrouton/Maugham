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

extension AnnotationProvenanceTests {
    private func annotationOp(opId: String, pid: String, span: SpanAnchor?, author: AnnotationAuthor) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 1), device: "d", session: "s",
           kind: .claudeComment,
           changes: [Op.ParagraphChange(paragraphId: pid, prior: nil, next: "note")],
           provenance: Op.Provenance(
               annotationBody: "note",
               authorSourceKind: author.sourceKind.rawValue,
               authorDisplayName: author.displayName,
               authorCollaboratorId: author.collaboratorId,
               spanQuote: span?.quote, spanPrefix: span?.prefix,
               spanSuffix: span?.suffix, spanPosHint: span?.posHint))
    }

    func test_deriver_surfacesAuthorAndResolvesSpan() {
        let para = "She told herself it was for the exercise, half true."
        let span = SpanAnchor(quote: "for the exercise", prefix: "was ", suffix: ", half", posHint: 24)
        let op = annotationOp(opId: "01AAAA", pid: "ab12", span: span,
                              author: .init(sourceKind: .human, displayName: "Marian", collaboratorId: "c-1"))
        let a = AnnotationDeriver.derive(ops: [op], paragraphs: ["ab12": para]).first!
        XCTAssertEqual(a.author?.sourceKind, .human)
        XCTAssertEqual(a.author?.displayName, "Marian")
        XCTAssertEqual(a.span?.quote, "for the exercise")
        XCTAssertNotNil(a.resolvedSpanRange)
        XCTAssertFalse(a.isStale)
    }

    func test_deriver_lostSpan_marksStale() {
        let para = "completely rewritten paragraph."
        let span = SpanAnchor(quote: "for the exercise", prefix: "was ", suffix: ", half", posHint: 24)
        let op = annotationOp(opId: "01BBBB", pid: "ab12", span: span,
                              author: .init(sourceKind: .claude, displayName: "Claude"))
        let a = AnnotationDeriver.derive(ops: [op], paragraphs: ["ab12": para]).first!
        XCTAssertNil(a.resolvedSpanRange)
        XCTAssertTrue(a.isStale)
    }
}
