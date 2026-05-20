import XCTest
@testable import Maugham

final class AnnotationDeriverTests: XCTestCase {

    private func makeOp(
        id: String, kind: OpKind,
        changes: [Op.ParagraphChange] = [],
        provenance: Op.Provenance? = nil,
        at: Date = Date()
    ) -> Op {
        Op(opId: id, docId: "d", at: at,
           device: "test", session: "s",
           kind: kind, changes: changes,
           sequence: nil, provenance: provenance)
    }

    func test_creationOp_derivesOpenAnnotation() {
        let op = makeOp(
            id: "01A", kind: .claudeComment,
            changes: [.init(paragraphId: "p1", prior: nil, next: "")],
            provenance: .init(annotationBody: "consider X"))
        let result = AnnotationDeriver.derive(
            ops: [op], paragraphs: ["p1": "current"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "01A")
        XCTAssertEqual(result[0].kind, .comment)
        XCTAssertEqual(result[0].paragraphId, "p1")
        XCTAssertEqual(result[0].body, "consider X")
        XCTAssertEqual(result[0].status, .open)
    }

    func test_acceptOp_setsAcceptedStatus() {
        let create = makeOp(
            id: "01A", kind: .claudeSuggestion,
            changes: [.init(paragraphId: "p1", prior: "old", next: "new")],
            provenance: .init(annotationBody: "rewrite"))
        let accept = makeOp(
            id: "01B", kind: .claudeAccept,
            provenance: .init(sourceAnnotationId: "01A"))
        let result = AnnotationDeriver.derive(
            ops: [create, accept], paragraphs: ["p1": "new"])
        XCTAssertEqual(result[0].status, .accepted)
        XCTAssertNotNil(result[0].resolvedAt)
    }

    func test_rejectOp_setsRejectedStatus_andCapturesUserResponse() {
        let create = makeOp(
            id: "01A", kind: .claudeSuggestion,
            changes: [.init(paragraphId: "p1", prior: "x", next: "y")],
            provenance: .init(annotationBody: "rewrite"))
        let reject = makeOp(
            id: "01B", kind: .claudeReject,
            provenance: .init(
                sourceAnnotationId: "01A",
                userResponse: "original lands harder"))
        let result = AnnotationDeriver.derive(
            ops: [create, reject], paragraphs: ["p1": "x"])
        XCTAssertEqual(result[0].status, .rejected)
        XCTAssertEqual(result[0].userResponse, "original lands harder")
    }

    func test_archiveOp_setsArchivedStatus() {
        let create = makeOp(
            id: "01A", kind: .claudeComment,
            changes: [.init(paragraphId: "p1", prior: nil, next: "")],
            provenance: .init(annotationBody: "x"))
        let archive = makeOp(
            id: "01B", kind: .claudeArchive,
            provenance: .init(sourceAnnotationId: "01A"))
        let result = AnnotationDeriver.derive(
            ops: [create, archive], paragraphs: [:])
        XCTAssertEqual(result[0].status, .archived)
    }

    func test_isStale_true_whenPriorTextDoesNotMatchCurrentParagraph() {
        let op = makeOp(
            id: "01A", kind: .claudeSuggestion,
            changes: [.init(paragraphId: "p1", prior: "OLD", next: "new")],
            provenance: .init(annotationBody: "x"))
        let result = AnnotationDeriver.derive(
            ops: [op], paragraphs: ["p1": "DIFFERENT"])
        XCTAssertTrue(result[0].isStale)
    }

    func test_isStale_false_whenPriorMatches() {
        let op = makeOp(
            id: "01A", kind: .claudeSuggestion,
            changes: [.init(paragraphId: "p1", prior: "SAME", next: "new")],
            provenance: .init(annotationBody: "x"))
        let result = AnnotationDeriver.derive(
            ops: [op], paragraphs: ["p1": "SAME"])
        XCTAssertFalse(result[0].isStale)
    }

    func test_craftNote_hasNilParagraphId_andIsNeverStale() {
        let op = makeOp(
            id: "01A", kind: .claudeCraftNote,
            changes: [],
            provenance: .init(annotationBody: "voice rule"))
        let result = AnnotationDeriver.derive(
            ops: [op], paragraphs: [:])
        XCTAssertNil(result[0].paragraphId)
        XCTAssertFalse(result[0].isStale)
    }
}
