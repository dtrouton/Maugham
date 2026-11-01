import XCTest
@testable import MaughamCore
@testable import Maugham

/// **One ⌘Z undoes one decision** — for Reject and Archive, as for Stet
/// (#41 A2, M5-AN-060) and the figure verbs (M5-AN-065). Issue #128 item 1.
///
/// The manuscript lets the writer answer over an answer: Reject or Archive a
/// note they had already accepted with a Reply…. Before this, the undo ended
/// in a bare reopen, so "Undo Reject Annotation" left the note OPEN — the
/// accept and the reply underneath gone with the rejection (RULING-22). The
/// undo now puts back the answer the decision displaced; over an open note it
/// still just reopens. Pins M5-AN-069.
@MainActor
final class AnnotationRejectArchiveUndoTests: XCTestCase {

    private func makeDoc(prefix: String) async throws -> (Document, String) {
        let (_, docURL) = try makeTestProject(
            prefix: prefix, initialMd: "A single paragraph.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        return (doc, try XCTUnwrap(doc.sequence.first))
    }

    /// Across ALL statuses — the default `[.open]` filter hides every
    /// resolved note (M5-AN-002).
    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    /// A comment the writer already answered with Got it / Reply… — the
    /// textless accept, so the reply is all there is to lose.
    private func acceptedComment(_ doc: Document, _ pid: String) async throws -> String {
        let cid = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "is this too florid?")
        try await doc.acceptAnnotation(id: cid, userResponse: "yes — cut it")
        XCTAssertEqual(annotation(doc, cid)?.status, .accepted, "precondition")
        return cid
    }

    // MARK: - Over an earlier answer: the answer comes back

    func test_undoOfARejectOverAnAcceptedNoteRestoresTheAcceptAndItsReply() async throws {
        let (doc, pid) = try await makeDoc(prefix: "RejectUndo-OverAccept")
        let cid = try await acceptedComment(doc, pid)
        let um = UndoManager()

        try await doc.rejectAnnotation(id: cid, userResponse: "on reflection, no", undoManager: um)
        XCTAssertEqual(annotation(doc, cid)?.status, .rejected)
        let opsAfterReject = doc._opLogMirror.count

        um.undo()
        await doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(doc, cid)?.status, .accepted,
                       "not .open — the accept the rejection displaced is back")
        XCTAssertEqual(annotation(doc, cid)?.userResponse, "yes — cut it",
                       "and back whole: the writer's reply returns with it")
        // ADR 0023: compensating ops appended in order, nothing truncated.
        XCTAssertEqual(doc._opLogMirror.suffix(2).map(\.kind), [.annotationReopen, .claudeAccept])
        XCTAssertEqual(doc._opLogMirror.count, opsAfterReject + 2)
    }

    func test_undoOfAnArchiveOverAnAcceptedNoteRestoresTheAcceptAndItsReply() async throws {
        let (doc, pid) = try await makeDoc(prefix: "ArchiveUndo-OverAccept")
        let cid = try await acceptedComment(doc, pid)
        let um = UndoManager()

        try await doc.archiveAnnotation(id: cid, undoManager: um)
        XCTAssertEqual(annotation(doc, cid)?.status, .archived)
        let opsAfterArchive = doc._opLogMirror.count

        um.undo()
        await doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(doc, cid)?.status, .accepted,
                       "not .open — the accept the archive displaced is back")
        XCTAssertEqual(annotation(doc, cid)?.userResponse, "yes — cut it")
        XCTAssertEqual(doc._opLogMirror.suffix(2).map(\.kind), [.annotationReopen, .claudeAccept])
        XCTAssertEqual(doc._opLogMirror.count, opsAfterArchive + 2)
    }

    /// A reject over an earlier reject with a different reason: ⌘Z returns
    /// the FIRST reason, not an open note and not the second reason.
    func test_undoOfARejectOverARejectionRestoresTheEarlierReason() async throws {
        let (doc, pid) = try await makeDoc(prefix: "RejectUndo-OverReject")
        let cid = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "is this too florid?")
        try await doc.rejectAnnotation(id: cid, userResponse: "the rhythm needs it")
        let um = UndoManager()

        try await doc.rejectAnnotation(id: cid, userResponse: "second reason", undoManager: um)
        um.undo()
        await doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(doc, cid)?.status, .rejected)
        XCTAssertEqual(annotation(doc, cid)?.userResponse, "the rhythm needs it")
    }

    /// ⇧⌘Z re-rejects and re-arms: a second ⌘Z puts the accept back again.
    func test_redoReRejects_andTheNextUndoPutsTheAcceptBackAgain() async throws {
        let (doc, pid) = try await makeDoc(prefix: "RejectUndo-Cycle")
        let cid = try await acceptedComment(doc, pid)
        let um = UndoManager()

        try await doc.rejectAnnotation(id: cid, userResponse: "no", undoManager: um)
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(doc, cid)?.status, .accepted)

        um.redo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(doc, cid)?.status, .rejected)
        XCTAssertEqual(annotation(doc, cid)?.userResponse, "no")

        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(doc, cid)?.status, .accepted)
        XCTAssertEqual(annotation(doc, cid)?.userResponse, "yes — cut it")
    }

    // MARK: - Over an open note: it just reopens (the controls)

    func test_undoOfARejectOverAnOpenNoteJustReopens() async throws {
        let (doc, pid) = try await makeDoc(prefix: "RejectUndo-OverOpen")
        let cid = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "is this too florid?")
        let um = UndoManager()

        try await doc.rejectAnnotation(id: cid, userResponse: "no", undoManager: um)
        let opsAfterReject = doc._opLogMirror.count
        um.undo()
        await doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(doc, cid)?.status, .open)
        XCTAssertEqual(doc._opLogMirror.count, opsAfterReject + 1,
                       "one reopen and nothing put back — there was nothing displaced")
        XCTAssertEqual(doc._opLogMirror.last?.kind, .annotationReopen)
    }

    func test_undoOfAnArchiveOverAnOpenNoteJustReopens() async throws {
        let (doc, pid) = try await makeDoc(prefix: "ArchiveUndo-OverOpen")
        let cid = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "is this too florid?")
        let um = UndoManager()

        try await doc.archiveAnnotation(id: cid, undoManager: um)
        let opsAfterArchive = doc._opLogMirror.count
        um.undo()
        await doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(doc, cid)?.status, .open)
        XCTAssertEqual(doc._opLogMirror.count, opsAfterArchive + 1,
                       "one reopen and nothing put back — there was nothing displaced")
        XCTAssertEqual(doc._opLogMirror.last?.kind, .annotationReopen)
    }
}
