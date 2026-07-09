import XCTest
@testable import MaughamCore

final class AnnotationInverseTests: XCTestCase {

    func test_undoReject_currentRejected_producesReopen() {
        let outcome = AnnotationInverse.reopenOp(
            undoing: .claudeReject, annotationId: "01A", currentStatus: .rejected,
            docId: "d1", device: "mac", session: "s1")
        guard case .op(let op) = outcome else { return XCTFail("expected op") }
        XCTAssertEqual(op.kind, .annotationReopen)
        XCTAssertEqual(op.provenance?.sourceAnnotationId, "01A")
        XCTAssertTrue(op.changes.isEmpty)
        XCTAssertEqual(op.docId, "d1")
    }

    func test_undoArchive_currentArchived_producesReopen() {
        let outcome = AnnotationInverse.reopenOp(
            undoing: .claudeArchive, annotationId: "01A", currentStatus: .archived,
            docId: "d1", device: "mac", session: "s1")
        guard case .op = outcome else { return XCTFail("expected op") }
    }

    func test_undoWithdraw_currentAbsent_producesReopen() {
        let outcome = AnnotationInverse.reopenOp(
            undoing: .annotationWithdraw, annotationId: "01A", currentStatus: nil,
            docId: "d1", device: "mac", session: "s1")
        guard case .op = outcome else { return XCTFail("expected op") }
    }

    func test_statusDrift_declines() {
        // Undoing a reject when the annotation is meanwhile .open (someone
        // else already reopened it) must decline, not double-reopen.
        let outcome = AnnotationInverse.reopenOp(
            undoing: .claudeReject, annotationId: "01A", currentStatus: .open,
            docId: "d1", device: "mac", session: "s1")
        guard case .declined(.stateDrifted) = outcome else { return XCTFail("expected drift decline") }
    }

    func test_undoAccept_declines_noInverse() {
        // Accept reversal is claudeAcceptRevert's job (v0.17.0), not reopen's.
        let outcome = AnnotationInverse.reopenOp(
            undoing: .claudeAccept, annotationId: "01A", currentStatus: .accepted,
            docId: "d1", device: "mac", session: "s1")
        guard case .declined(.noInverse) = outcome else { return XCTFail("expected noInverse") }
    }

    func test_phoneForensicFields_carried() {
        let outcome = AnnotationInverse.reopenOp(
            undoing: .claudeReject, annotationId: "01A", currentStatus: .rejected,
            docId: "d1", device: "phone", session: "s1",
            appVersion: "0.5.0", osVersion: "iOS 19")
        guard case .op(let op) = outcome else { return XCTFail("expected op") }
        XCTAssertEqual(op.provenance?.appVersion, "0.5.0")
        XCTAssertEqual(op.provenance?.osVersion, "iOS 19")
    }

    func test_editRevert_carriesPriorBodyAndSuggestion() {
        let op = AnnotationInverse.editRevertOp(
            annotationId: "01A", priorBody: "old body",
            priorSuggested: (paragraphId: "ab2c", prior: "was", next: "old suggestion"),
            authorSourceKind: "human", authorDisplayName: "Denver", authorCollaboratorId: nil,
            docId: "d1", device: "mac", session: "s1")
        XCTAssertEqual(op.kind, .annotationEdit)
        XCTAssertEqual(op.provenance?.annotationBody, "old body")
        XCTAssertEqual(op.changes.first?.next, "old suggestion")
        XCTAssertEqual(op.provenance?.sourceAnnotationId, "01A")
    }

    func test_derivedRoundTrip_rejectThenFactoryReopen_isOpen() {
        let creation = Op(opId: "01A", docId: "d1", at: Date(timeIntervalSince1970: 1_000),
                          device: "mac", session: "s1", kind: .claudeComment,
                          changes: [.init(paragraphId: "ab2c", prior: "t", next: "t")],
                          sequence: nil,
                          provenance: Op.Provenance(sessionId: "s1", annotationBody: "n",
                                                    sourceAnnotationId: nil))
        let reject = Op(opId: "01B", docId: "d1", at: Date(timeIntervalSince1970: 1_001),
                        device: "mac", session: "s1", kind: .claudeReject, changes: [],
                        sequence: nil,
                        provenance: Op.Provenance(sessionId: "s1", sourceAnnotationId: "01A"))
        guard case .op(let reopen) = AnnotationInverse.reopenOp(
            undoing: .claudeReject, annotationId: "01A", currentStatus: .rejected,
            docId: "d1", device: "mac", session: "s1") else { return XCTFail() }
        let derived = AnnotationDeriver.derive(ops: [creation, reject, reopen],
                                               paragraphs: ["ab2c": "t"])
        XCTAssertEqual(derived.first?.status, .open)
    }
}
