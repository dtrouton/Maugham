import XCTest
@testable import MaughamCore

final class AnnotationReopenOpTests: XCTestCase {

    private func op(_ id: String, kind: OpKind, source: String? = nil,
                    userResponse: String? = nil, body: String? = nil,
                    changes: [Op.ParagraphChange] = []) -> Op {
        Op(opId: id, docId: "d1", at: Date(timeIntervalSince1970: 1_000),
           device: "mac", session: "s1", kind: kind, changes: changes,
           sequence: nil,
           provenance: Op.Provenance(sessionId: "s1",
                                     annotationBody: body,
                                     sourceAnnotationId: source,
                                     userResponse: userResponse))
    }

    func test_rawValue_roundTrip() throws {
        XCTAssertEqual(OpKind.annotationReopen.rawValue, "annotation_reopen")
        let data = try JSONEncoder().encode(OpKind.annotationReopen)
        XCTAssertEqual(try JSONDecoder().decode(OpKind.self, from: data), .annotationReopen)
    }

    func test_synthesisSource_undoRewind_rawValue() throws {
        XCTAssertEqual(SynthesisSource.undoRewind.rawValue, "undo_rewind")
    }

    func test_schemaVersion_bumped() {
        XCTAssertGreaterThanOrEqual(ProjectManifest.currentSchemaVersion, 3)
    }

    func test_rejectThenReopen_derivesOpen() {
        let creation = op("01A", kind: .claudeComment, body: "note",
                          changes: [.init(paragraphId: "ab2c", prior: "text", next: "text")])
        let reject = op("01B", kind: .claudeReject, source: "01A", userResponse: "no thanks")
        let reopen = op("01C", kind: .annotationReopen, source: "01A")
        let derived = AnnotationDeriver.derive(ops: [creation, reject, reopen],
                                               paragraphs: ["ab2c": "text"])
        XCTAssertEqual(derived.first?.status, .open)
    }

    func test_archiveThenReopen_derivesOpen() {
        let creation = op("01A", kind: .claudeComment, body: "note",
                          changes: [.init(paragraphId: "ab2c", prior: "text", next: "text")])
        let archive = op("01B", kind: .claudeArchive, source: "01A")
        let reopen = op("01C", kind: .annotationReopen, source: "01A")
        let derived = AnnotationDeriver.derive(ops: [creation, archive, reopen],
                                               paragraphs: ["ab2c": "text"])
        XCTAssertEqual(derived.first?.status, .open)
    }

    func test_reopenThenReReject_derivesRejected_withUserResponse() {
        let creation = op("01A", kind: .claudeComment, body: "note",
                          changes: [.init(paragraphId: "ab2c", prior: "text", next: "text")])
        let reject = op("01B", kind: .claudeReject, source: "01A", userResponse: "no")
        let reopen = op("01C", kind: .annotationReopen, source: "01A")
        let rereject = op("01D", kind: .claudeReject, source: "01A", userResponse: "no")
        let derived = AnnotationDeriver.derive(ops: [creation, reject, reopen, rereject],
                                               paragraphs: ["ab2c": "text"])
        XCTAssertEqual(derived.first?.status, .rejected)
        XCTAssertEqual(derived.first?.userResponse, "no")
    }

    func test_withdrawThenReopen_annotationReappears() {
        let creation = op("01A", kind: .claudeComment, body: "note",
                          changes: [.init(paragraphId: "ab2c", prior: "text", next: "text")])
        let withdraw = op("01B", kind: .annotationWithdraw, source: "01A")
        let reopen = op("01C", kind: .annotationReopen, source: "01A")
        // Withdraw alone drops it:
        XCTAssertTrue(AnnotationDeriver.derive(ops: [creation, withdraw],
                                               paragraphs: ["ab2c": "text"]).isEmpty)
        // Reopen newer than withdraw cancels the withdrawal:
        let derived = AnnotationDeriver.derive(ops: [creation, withdraw, reopen],
                                               paragraphs: ["ab2c": "text"])
        XCTAssertEqual(derived.count, 1)
        XCTAssertEqual(derived.first?.status, .open)
    }

    func test_reopen_neverAppliesToManuscript() {
        // The derive loop only folds op.changes; annotationReopen always has [].
        // Guard the classification so a future change can't make it text-mutating.
        XCTAssertFalse(Deriver.appliesToManuscript(.annotationReopen))
    }
}
