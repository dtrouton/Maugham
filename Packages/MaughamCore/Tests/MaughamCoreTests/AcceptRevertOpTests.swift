import XCTest
@testable import MaughamCore

final class AcceptRevertOpTests: XCTestCase {

    private func op(
        _ opId: String, kind: OpKind,
        changes: [Op.ParagraphChange] = [],
        sequence: [String]? = nil,
        sourceAnnotationId: String? = nil
    ) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 1_000),
           device: "test", session: "s1", kind: kind,
           changes: changes, sequence: sequence,
           provenance: Op.Provenance(sourceAnnotationId: sourceAnnotationId))
    }

    func test_rawValue_roundTrips() throws {
        XCTAssertEqual(OpKind.claudeAcceptRevert.rawValue, "claude_accept_revert")
        let data = try JSONEncoder().encode(OpKind.claudeAcceptRevert)
        let back = try JSONDecoder().decode(OpKind.self, from: data)
        XCTAssertEqual(back, .claudeAcceptRevert)
    }

    func test_revertWithChanges_restoresParagraphText() {
        let ops = [
            op("01A", kind: .bootstrap,
               changes: [.init(paragraphId: "abcd", prior: nil, next: "original")],
               sequence: ["abcd"]),
            op("01B", kind: .claudeAccept,
               changes: [.init(paragraphId: "abcd", prior: "original", next: "accepted")],
               sourceAnnotationId: "01A0"),
            op("01C", kind: .claudeAcceptRevert,
               changes: [.init(paragraphId: "abcd", prior: "accepted", next: "original")],
               sourceAnnotationId: "01A0"),
        ]
        let state = Deriver.derive(ops: ops)
        XCTAssertEqual(state.paragraphs["abcd"], "original")
    }

    func test_revertWithEmptyChanges_isManuscriptNoOp() {
        let ops = [
            op("01A", kind: .bootstrap,
               changes: [.init(paragraphId: "abcd", prior: nil, next: "current")],
               sequence: ["abcd"]),
            op("01B", kind: .claudeAcceptRevert, changes: [],
               sourceAnnotationId: "01A0"),
        ]
        let state = Deriver.derive(ops: ops)
        XCTAssertEqual(state.paragraphs["abcd"], "current")
        XCTAssertEqual(state.sequence, ["abcd"])
    }

    func test_schemaVersionBumped() {
        // Contract: adding an OpKind case bumps the manifest schema version
        // (OpKind.swift ADR 0015 comment). claudeAcceptRevert is new in v2.
        XCTAssertGreaterThanOrEqual(ProjectManifest.currentSchemaVersion, 2)
    }

    private func annotationOps() -> [Op] {
        [
            op("01A", kind: .bootstrap,
               changes: [.init(paragraphId: "abcd", prior: nil, next: "original")],
               sequence: ["abcd"]),
            Op(opId: "01B", docId: "doc-1", at: Date(timeIntervalSince1970: 1_001),
               device: "test", session: "s1", kind: .claudeSuggestion,
               changes: [.init(paragraphId: "abcd", prior: "original", next: "better")],
               sequence: nil,
               provenance: Op.Provenance(annotationBody: "tighten this")),
        ]
    }

    func test_acceptThenRevert_derivesOpen() {
        var ops = annotationOps()
        // The accept carries a userResponse so the revert's fall-back to the
        // creation-side value (nil here) is observable below.
        ops.append(Op(opId: "01C", docId: "doc-1", at: Date(timeIntervalSince1970: 1_002),
                      device: "test", session: "s1", kind: .claudeAccept,
                      changes: [.init(paragraphId: "abcd", prior: "original", next: "better")],
                      sequence: nil,
                      provenance: Op.Provenance(sourceAnnotationId: "01B",
                                                userResponse: "looks good")))
        ops.append(op("01D", kind: .claudeAcceptRevert,
                      changes: [.init(paragraphId: "abcd", prior: "better", next: "original")],
                      sourceAnnotationId: "01B"))
        let anns = AnnotationDeriver.derive(ops: ops, paragraphs: ["abcd": "original"])
        XCTAssertEqual(anns.count, 1)
        XCTAssertEqual(anns[0].status, .open)
        // A reopened annotation is not "resolved": no resolution timestamp,
        // and the accept's userResponse must not survive the revert.
        XCTAssertNil(anns[0].resolvedAt)
        XCTAssertNil(anns[0].userResponse)
    }

    func test_revertThenReAccept_derivesAccepted() {
        var ops = annotationOps()
        ops.append(op("01C", kind: .claudeAccept,
                      changes: [.init(paragraphId: "abcd", prior: "original", next: "better")],
                      sourceAnnotationId: "01B"))
        ops.append(op("01D", kind: .claudeAcceptRevert,
                      changes: [.init(paragraphId: "abcd", prior: "better", next: "original")],
                      sourceAnnotationId: "01B"))
        ops.append(op("01E", kind: .claudeAccept,
                      changes: [.init(paragraphId: "abcd", prior: "original", next: "better")],
                      sourceAnnotationId: "01B"))
        let anns = AnnotationDeriver.derive(ops: ops, paragraphs: ["abcd": "better"])
        XCTAssertEqual(anns[0].status, .accepted)
        // Re-accepting after a revert resolves the annotation again.
        XCTAssertNotNil(anns[0].resolvedAt)
    }
}
