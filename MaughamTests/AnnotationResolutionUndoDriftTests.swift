import XCTest
@testable import MaughamCore
@testable import Maugham

/// #51 — the reject, archive and pane-Reopen undos re-check the note before
/// they act, and say so when it moved (RULING-22).
///
/// Before this, "Undo Reject Annotation" ended in a bare
/// `reopenAnnotation(id:)`, which dispatches on whatever the status is NOW
/// rather than on what this undo wrote: a rejected note archived since on
/// another device was reopened out of its archive, and one withdrawn since was
/// RESTORED — a deleted note back in the queue under "Undo Reject". Either way
/// nothing was said. `reopenAnnotation` itself is unchanged (M5-AN-034 pins its
/// status set, and it is also the pane's Reopen and the withdrawal restore);
/// the guard is the undo's, `stetAnnotation`'s shape.
@MainActor
final class AnnotationResolutionUndoDriftTests: XCTestCase {

    private struct Harness {
        let doc: Document
        let pid: String
    }

    private func makeHarness(prefix: String) async throws -> Harness {
        let (_, docURL) = try makeTestProject(
            prefix: prefix, initialMd: "A single paragraph.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        return Harness(doc: doc, pid: pid)
    }

    /// Across ALL statuses — the default `[.open]` filter hides every status
    /// these tests are about (M5-AN-002).
    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    /// Every writer-facing notice posted while the block runs, in order.
    private func notices(
        during body: () async throws -> Void
    ) async rethrows -> [String] {
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let m = note.userInfo?[MaughamEvent.noticeMessageKey] as? String {
                seen.append(m)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return seen
    }

    private func undo(_ um: UndoManager, _ doc: Document) async -> [String] {
        await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }
    }

    // MARK: - Reject

    /// The Edit menu said "Undo Reject Annotation"; another device had already
    /// reopened the note. Declining is right; declining silently is not.
    func test_aDriftedRejectUndoDeclinesToTheWriter() async throws {
        let h = try await makeHarness(prefix: "RejDrift")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()
        try await h.doc.rejectAnnotation(id: cid, userResponse: "no", undoManager: um)
        try await h.doc.reopenAnnotation(id: cid)  // another Mac's reopen
        let opsBefore = h.doc._opLogMirror.count

        let said = await undo(um, h.doc)

        XCTAssertEqual(said, [
            "Couldn't undo rejecting the note — it changed on another device."])
        XCTAssertEqual(h.doc._opLogMirror.count, opsBefore, "a declined undo appends nothing")
        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
    }

    /// The control: an undrifted ⌘Z reopens and says nothing.
    func test_aRejectUndoThatSucceedsIsSilent() async throws {
        let h = try await makeHarness(prefix: "RejQuiet")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()
        try await h.doc.rejectAnnotation(id: cid, undoManager: um)

        let said = await undo(um, h.doc)

        XCTAssertEqual(said, [])
        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
    }

    /// The wrong-verb case the issue missed: `reopenAnnotation` reopens
    /// whatever resolution is there now, so "Undo Reject" used to undo an
    /// ARCHIVE nobody asked it to.
    func test_undoRejectNeverReopensAnArchivedNote() async throws {
        let h = try await makeHarness(prefix: "RejArch")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()
        try await h.doc.rejectAnnotation(id: cid, undoManager: um)
        try await h.doc.archiveAnnotation(id: cid)  // archived since, elsewhere
        let opsBefore = h.doc._opLogMirror.count

        let said = await undo(um, h.doc)

        XCTAssertEqual(annotation(h.doc, cid)?.status, .archived,
                       "the archive stands — Undo Reject is not Undo Archive")
        XCTAssertEqual(h.doc._opLogMirror.count, opsBefore)
        XCTAssertEqual(said, [
            "Couldn't undo rejecting the note — it changed on another device."])
    }

    /// The worse case: a note withdrawn since the reject took the
    /// `.annotationWithdraw` arm of `reopenAnnotation` and came back from the
    /// dead under "Undo Reject Annotation".
    func test_undoRejectNeverResurrectsAWithdrawnNote() async throws {
        let h = try await makeHarness(prefix: "RejWdr")
        let cid = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: nil,
            body: "reviewer note", authorName: "Denver")
        let um = UndoManager()
        try await h.doc.rejectAnnotation(id: cid, undoManager: um)
        try await h.doc.withdrawReviewerAnnotation(id: cid, authorName: "Denver")
        XCTAssertNil(annotation(h.doc, cid))
        let opsBefore = h.doc._opLogMirror.count

        let said = await undo(um, h.doc)

        XCTAssertNil(annotation(h.doc, cid), "a withdrawn note stays withdrawn")
        XCTAssertEqual(h.doc._opLogMirror.count, opsBefore)
        XCTAssertEqual(said, [
            "Couldn't undo rejecting the note — it changed on another device."])
    }

    // MARK: - Archive

    func test_aDriftedArchiveUndoDeclinesToTheWriter() async throws {
        let h = try await makeHarness(prefix: "ArchDrift")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()
        try await h.doc.archiveAnnotation(id: cid, undoManager: um)
        try await h.doc.rejectAnnotation(id: cid, userResponse: "no")  // rejected since
        let opsBefore = h.doc._opLogMirror.count

        let said = await undo(um, h.doc)

        XCTAssertEqual(said, [
            "Couldn't undo archiving the note — it changed on another device."])
        XCTAssertEqual(h.doc._opLogMirror.count, opsBefore)
        XCTAssertEqual(annotation(h.doc, cid)?.status, .rejected,
                       "Undo Archive does not reopen a rejection")
    }

    func test_anArchiveUndoThatSucceedsIsSilent() async throws {
        let h = try await makeHarness(prefix: "ArchQuiet")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()
        try await h.doc.archiveAnnotation(id: cid, undoManager: um)

        let said = await undo(um, h.doc)

        XCTAssertEqual(said, [])
        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
    }

    // MARK: - The pane's Reopen

    /// The sibling: the pane Reopen's ⌘Z re-applies the prior resolution, and
    /// used to do it over whatever the note had become since — here a stet
    /// from another device, which "Undo Reopen" would have overwritten with a
    /// rejection.
    func test_aReopenUndoneAfterTheNoteMovedDeclines() async throws {
        let h = try await makeHarness(prefix: "ReopDrift")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        try await h.doc.rejectAnnotation(id: cid, userResponse: "no")
        let um = UndoManager()
        try await h.doc.reopenAnnotation(id: cid, undoManager: um)
        try await h.doc.stetAnnotation(id: cid, userResponse: "it stands")  // since
        let opsBefore = h.doc._opLogMirror.count

        let said = await undo(um, h.doc)

        XCTAssertEqual(said, [
            "Couldn't undo reopening the note — it changed on another device."])
        XCTAssertEqual(h.doc._opLogMirror.count, opsBefore)
        XCTAssertEqual(annotation(h.doc, cid)?.status, .stetted)
        XCTAssertEqual(annotation(h.doc, cid)?.userResponse, "it stands")
    }

    func test_aReopenUndoThatSucceedsIsSilent() async throws {
        let h = try await makeHarness(prefix: "ReopQuiet")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        try await h.doc.archiveAnnotation(id: cid)
        let um = UndoManager()
        try await h.doc.reopenAnnotation(id: cid, undoManager: um)

        let said = await undo(um, h.doc)

        XCTAssertEqual(said, [])
        XCTAssertEqual(annotation(h.doc, cid)?.status, .archived)
    }

    /// Singular and plural, side by side, for every new verb — the
    /// accumulator spends one sentence per verb per ⌘Z.
    func test_theNewDeclinesCountInThePlural() {
        XCTAssertEqual(Document.UndoDecline.reject.sentence(count: 2),
                       "Couldn't undo rejecting 2 notes — they changed on another device.")
        XCTAssertEqual(Document.UndoDecline.archive.sentence(count: 3),
                       "Couldn't undo archiving 3 notes — they changed on another device.")
        XCTAssertEqual(Document.UndoDecline.reopen.sentence(count: 2),
                       "Couldn't undo reopening 2 notes — they changed on another device.")
    }
}
