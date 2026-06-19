import XCTest
@testable import MaughamCore

/// Edit + withdraw of an author's own annotation, derived purely from the
/// append-only op log. The creation op is never mutated; an `annotationEdit`
/// op updates the derived body (and suggestedText), latest-by-opId wins; an
/// `annotationWithdraw` op drops the annotation entirely from the derived set.
final class AnnotationEditWithdrawTests: XCTestCase {

    private let docId = "doc-abc"
    private let device = "devA"
    private let session = "sessA"

    // Monotonic opId helper — ULID-shaped lexically-ordered ids so opId order
    // is deterministic in tests (the deriver resolves latest-wins by opId).
    private func opId(_ n: Int) -> String {
        String(format: "01J%023d", n)
    }

    private func commentOp(
        id: String, paragraphId: String, body: String,
        authorName: String = "Sam"
    ) -> Op {
        Op(opId: id, docId: docId, at: Date(timeIntervalSince1970: 1000),
           device: device, session: session, kind: .claudeComment,
           changes: [.init(paragraphId: paragraphId, prior: "para text", next: "")],
           provenance: Op.Provenance(
            annotationBody: body,
            authorSourceKind: AnnotationAuthor.SourceKind.human.rawValue,
            authorDisplayName: authorName))
    }

    private func suggestionOp(
        id: String, paragraphId: String, body: String, suggested: String
    ) -> Op {
        Op(opId: id, docId: docId, at: Date(timeIntervalSince1970: 1000),
           device: device, session: session, kind: .claudeSuggestion,
           changes: [.init(paragraphId: paragraphId, prior: "para text", next: suggested)],
           provenance: Op.Provenance(
            annotationBody: body,
            authorSourceKind: AnnotationAuthor.SourceKind.human.rawValue,
            authorDisplayName: "Sam"))
    }

    private func editOp(
        id: String, target: String, body: String, suggested: String? = nil
    ) -> Op {
        let changes: [Op.ParagraphChange] = suggested.map {
            [.init(paragraphId: "p001", prior: nil, next: $0)]
        } ?? []
        return Op(opId: id, docId: docId, at: Date(timeIntervalSince1970: 1001),
                  device: device, session: session, kind: .annotationEdit,
                  changes: changes,
                  provenance: Op.Provenance(
                    annotationBody: body, sourceAnnotationId: target))
    }

    private func withdrawOp(id: String, target: String) -> Op {
        Op(opId: id, docId: docId, at: Date(timeIntervalSince1970: 1002),
           device: device, session: session, kind: .annotationWithdraw,
           changes: [],
           provenance: Op.Provenance(sourceAnnotationId: target))
    }

    func test_edit_updatesBody() {
        let create = commentOp(id: opId(1), paragraphId: "p001", body: "origonal")
        let edit = editOp(id: opId(2), target: opId(1), body: "original")
        let result = AnnotationDeriver.derive(
            ops: [create, edit], paragraphs: ["p001": "para text"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.body, "original")
    }

    func test_twoEdits_latestByOpIdWins() {
        let create = commentOp(id: opId(1), paragraphId: "p001", body: "v0")
        let edit1 = editOp(id: opId(2), target: opId(1), body: "v1")
        let edit2 = editOp(id: opId(3), target: opId(1), body: "v2")
        // Feed out of order to prove resolution is by opId, not array order.
        let result = AnnotationDeriver.derive(
            ops: [create, edit2, edit1], paragraphs: ["p001": "para text"])
        XCTAssertEqual(result.first?.body, "v2")
    }

    func test_withdraw_removesAnnotation() {
        let create = commentOp(id: opId(1), paragraphId: "p001", body: "bye")
        let withdraw = withdrawOp(id: opId(2), target: opId(1))
        let result = AnnotationDeriver.derive(
            ops: [create, withdraw], paragraphs: ["p001": "para text"])
        XCTAssertTrue(result.isEmpty, "withdrawn annotation must be absent")
    }

    func test_withdraw_isIdempotent() {
        let create = commentOp(id: opId(1), paragraphId: "p001", body: "bye")
        let w1 = withdrawOp(id: opId(2), target: opId(1))
        let w2 = withdrawOp(id: opId(3), target: opId(1))
        let result = AnnotationDeriver.derive(
            ops: [create, w1, w2], paragraphs: ["p001": "para text"])
        XCTAssertTrue(result.isEmpty)
    }

    func test_editOfSuggestion_updatesSuggestedTextAndBody() {
        let create = suggestionOp(
            id: opId(1), paragraphId: "p001", body: "fix typo", suggested: "teh")
        let edit = editOp(
            id: opId(2), target: opId(1), body: "fix typo (better)", suggested: "the")
        let result = AnnotationDeriver.derive(
            ops: [create, edit], paragraphs: ["p001": "para text"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.body, "fix typo (better)")
        XCTAssertEqual(result.first?.suggestedText, "the")
        XCTAssertEqual(result.first?.priorText, "para text",
                       "editing the suggestion must not lose the captured prior")
    }

    func test_editWithoutSuggestedText_leavesSuggestionUnchanged() {
        // Editing only the body of a suggestedChange keeps the original
        // suggested replacement (no suggested payload on the edit op).
        let create = suggestionOp(
            id: opId(1), paragraphId: "p001", body: "fix", suggested: "the")
        let edit = editOp(id: opId(2), target: opId(1), body: "fix better")
        let result = AnnotationDeriver.derive(
            ops: [create, edit], paragraphs: ["p001": "para text"])
        XCTAssertEqual(result.first?.body, "fix better")
        XCTAssertEqual(result.first?.suggestedText, "the")
    }

    func test_withdrawWinsOverEdit_regardlessOfOrder() {
        let create = commentOp(id: opId(1), paragraphId: "p001", body: "v0")
        let edit = editOp(id: opId(2), target: opId(1), body: "v1")
        let withdraw = withdrawOp(id: opId(3), target: opId(1))
        let result = AnnotationDeriver.derive(
            ops: [create, edit, withdraw], paragraphs: ["p001": "para text"])
        XCTAssertTrue(result.isEmpty,
                      "a withdrawn annotation is gone even if it was also edited")
    }
}
