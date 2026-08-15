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

// MARK: - M3 P2: stet's reopen inverse, and triage's revert

extension AnnotationInverseTests {

    func test_undoStet_currentStetted_producesReopen() {
        let outcome = AnnotationInverse.reopenOp(
            undoing: .annotationStet, annotationId: "01A", currentStatus: .stetted,
            docId: "d1", device: "mac", session: "s1")
        guard case .op(let op) = outcome else { return XCTFail("expected op") }
        XCTAssertEqual(op.kind, .annotationReopen)
        XCTAssertEqual(op.provenance?.sourceAnnotationId, "01A")
        XCTAssertTrue(op.changes.isEmpty)
    }

    func test_undoStet_driftedStatus_declines() {
        let outcome = AnnotationInverse.reopenOp(
            undoing: .annotationStet, annotationId: "01A", currentStatus: .open,
            docId: "d1", device: "mac", session: "s1")
        guard case .declined(.stateDrifted) = outcome else {
            return XCTFail("expected drift decline")
        }
    }

    /// Triage's inverse is another triage carrying the PRIOR mark — never a
    /// reopen, because triage never resolved anything.
    func test_triageRevert_restoresThePriorMark() {
        let creation = Op(opId: "01A", docId: "d1", at: Date(timeIntervalSince1970: 1_000),
                          device: "mac", session: "s1", kind: .claudeComment,
                          changes: [.init(paragraphId: "ab2c", prior: "t", next: "t")],
                          provenance: Op.Provenance(sessionId: "s1", annotationBody: "n"))
        let toDo = Op(opId: "01B", docId: "d1", at: Date(timeIntervalSince1970: 1_001),
                      device: "mac", session: "s1", kind: .annotationTriage, changes: [],
                      provenance: Op.Provenance(
                          sessionId: "s1", sourceAnnotationId: "01A", triageMark: "do"))
        let toDiscuss = Op(opId: "01C", docId: "d1", at: Date(timeIntervalSince1970: 1_002),
                           device: "mac", session: "s1", kind: .annotationTriage, changes: [],
                           provenance: Op.Provenance(
                               sessionId: "s1", sourceAnnotationId: "01A", triageMark: "discuss"))

        let revert = AnnotationInverse.triageRevertOp(
            annotationId: "01A", priorMark: .do,
            docId: "d1", device: "mac", session: "s1")
        XCTAssertEqual(revert.kind, .annotationTriage)
        XCTAssertEqual(revert.provenance?.sourceAnnotationId, "01A")
        XCTAssertEqual(revert.provenance?.triageMark, "do")

        let derived = AnnotationDeriver.derive(
            ops: [creation, toDo, toDiscuss, revert], paragraphs: ["ab2c": "t"])
        XCTAssertEqual(derived.first?.triage, .do,
            "reverting the .discuss must put the note back where the writer had it")
        XCTAssertEqual(derived.first?.status, .open,
            "…and triage never touched the note's status")
    }

    /// A nil prior mark is "it was untriaged" — the revert clears the mark.
    func test_triageRevert_withNoPriorMark_clearsTheMark() {
        let creation = Op(opId: "01A", docId: "d1", at: Date(timeIntervalSince1970: 1_000),
                          device: "mac", session: "s1", kind: .claudeComment,
                          changes: [.init(paragraphId: "ab2c", prior: "t", next: "t")],
                          provenance: Op.Provenance(sessionId: "s1", annotationBody: "n"))
        let toDo = Op(opId: "01B", docId: "d1", at: Date(timeIntervalSince1970: 1_001),
                      device: "mac", session: "s1", kind: .annotationTriage, changes: [],
                      provenance: Op.Provenance(
                          sessionId: "s1", sourceAnnotationId: "01A", triageMark: "do"))
        let revert = AnnotationInverse.triageRevertOp(
            annotationId: "01A", priorMark: nil,
            docId: "d1", device: "mac", session: "s1")
        XCTAssertNil(revert.provenance?.triageMark)

        let derived = AnnotationDeriver.derive(
            ops: [creation, toDo, revert], paragraphs: ["ab2c": "t"])
        XCTAssertNil(derived.first?.triage)
    }
}
