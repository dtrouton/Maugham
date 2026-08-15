import XCTest
@testable import MaughamCore
@testable import Maugham

/// **Triage** — what the writer intends to DO about a note they are still
/// holding (spec §5): `do`, `decline`, `discuss`. A mark, not a resolution.
/// The whole point of the distinction is that a triaged note is still open:
/// marking a queue is how the writer plans their pass, and a plan that
/// silently cleared the queue would be the queue answering itself.
///
/// These pin the Mac writer verb `Document.triageAnnotation` on Task 1's wire:
/// the mark's orthogonality to status, latest-op-wins replacement, the clear,
/// and the ⌘Z that restores the PRIOR mark rather than blanket-clearing —
/// which is the difference between undo and forgetting. Plus the drifted
/// undo's LOUD decline (RULING-22, `stetAnnotation`'s shape).
@MainActor
final class AnnotationTriageTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let doc: Document
        let pid: String
    }

    private func makeHarness(
        prefix: String, initialMd: String = "A single paragraph.\n"
    ) async throws -> Harness {
        let (_, docURL) = try makeTestProject(prefix: prefix, initialMd: initialMd)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        return Harness(doc: doc, pid: pid)
    }

    /// Across ALL statuses — `annotations()` defaults to `[.open]`, and half
    /// of what these tests assert is about notes that are NOT open
    /// (M5-AN-002, the documented footgun).
    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    /// Every writer-facing notice posted while the block runs, in order.
    /// Mirrors `AnnotationStetTests`' collector — same channel, same shape.
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

    // MARK: - The verb

    /// The mark is orthogonal to the status. A note the writer marked `do` is
    /// a note they have decided to act on LATER — it has to still be in the
    /// queue when they get there, or triaging it was the same as answering it.
    func test_triageMarksTheNoteAndLeavesItOpen() async throws {
        let h = try await makeHarness(prefix: "Triage-Mark")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "is this too florid?")

        try await h.doc.triageAnnotation(id: cid, mark: .do)

        XCTAssertEqual(annotation(h.doc, cid)?.triage, .do)
        XCTAssertEqual(annotation(h.doc, cid)?.status, .open,
                       "a mark settles nothing")
        XCTAssertEqual(h.doc.annotations().count, 1,
                       "the default [.open] filter still shows it")
    }

    /// Latest-op-wins, the deriver's own rule. The writer changing their mind
    /// is the ordinary case, not a conflict.
    func test_aSecondTriageReplacesTheFirst() async throws {
        let h = try await makeHarness(prefix: "Triage-Replace")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")

        try await h.doc.triageAnnotation(id: cid, mark: .decline)
        try await h.doc.triageAnnotation(id: cid, mark: .discuss)

        XCTAssertEqual(annotation(h.doc, cid)?.triage, .discuss)
    }

    /// Re-marking with the mark it already has writes the op anyway, exactly
    /// as re-rejecting a rejected note appends another reject
    /// (`AnnotationStetTests`' parity test). The verb refuses nothing on the
    /// way in and the deriver settles it; whether the queue ever ASKS for a
    /// mark a note already carries is the pane's business, not the log's.
    /// Worth knowing at the pane: a repeat mark's ⌘Z restores the same mark,
    /// so it is an undo the writer cannot see.
    func test_reMarkingWithTheSameMarkIsWrittenLikeAnyOtherOp() async throws {
        let h = try await makeHarness(prefix: "Triage-Repeat")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        try await h.doc.triageAnnotation(id: cid, mark: .do)
        let opsBefore = h.doc._opLogMirror.count

        try await h.doc.triageAnnotation(id: cid, mark: .do)

        XCTAssertEqual(h.doc._opLogMirror.count, opsBefore + 1)
        XCTAssertEqual(annotation(h.doc, cid)?.triage, .do)
    }

    /// `mark: nil` is the writer taking the label back off — untriaged is a
    /// state they can return to, not a state that only exists before the
    /// first mark.
    func test_aNilMarkClearsTheNoteBackToUntriaged() async throws {
        let h = try await makeHarness(prefix: "Triage-Clear")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        try await h.doc.triageAnnotation(id: cid, mark: .do)

        try await h.doc.triageAnnotation(id: cid, mark: nil)

        XCTAssertNil(annotation(h.doc, cid)?.triage)
        XCTAssertEqual(h.doc._opLogMirror.last?.kind, .annotationTriage,
                       "a clear is an op like any other — untriaged is written, not erased")
        XCTAssertNil(h.doc._opLogMirror.last?.provenance?.triageMark)
    }

    /// Deliberate: the mark is METADATA, so a resolved note takes one. A note
    /// the writer let stand can still be worth marking `discuss` — the
    /// conversation with Claude outlives the resolution, and refusing here
    /// would make the writer reopen a note they had already settled just to
    /// label it. The status is untouched, which is the guarantee that matters.
    func test_aResolvedNoteCanStillBeMarked_andKeepsItsResolution() async throws {
        let h = try await makeHarness(prefix: "Triage-Resolved")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        try await h.doc.stetAnnotation(id: cid, userResponse: "it stands")

        try await h.doc.triageAnnotation(id: cid, mark: .discuss)

        XCTAssertEqual(annotation(h.doc, cid)?.triage, .discuss)
        XCTAssertEqual(annotation(h.doc, cid)?.status, .stetted,
                       "the mark did not disturb the resolution")
        XCTAssertEqual(annotation(h.doc, cid)?.userResponse, "it stands")
    }

    /// The pane redraws off `annotationsVersion`. A mark the writer can see
    /// themselves make is worth nothing if the list does not notice it.
    func test_triageBumpsTheAnnotationsVersion() async throws {
        let h = try await makeHarness(prefix: "Triage-Version")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let before = h.doc.annotationsVersion

        try await h.doc.triageAnnotation(id: cid, mark: .do)

        XCTAssertGreaterThan(h.doc.annotationsVersion, before)
    }

    /// One `annotation_triage` op, the mark on provenance, and not a
    /// character of manuscript moved.
    func test_triageAppendsOneMarkOpAndMovesNoText() async throws {
        let h = try await makeHarness(prefix: "Triage-OpShape")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let textBefore = h.doc.displayText

        try await h.doc.triageAnnotation(id: cid, mark: .decline)

        let op = try XCTUnwrap(h.doc._opLogMirror.last)
        XCTAssertEqual(op.kind, .annotationTriage)
        XCTAssertEqual(op.provenance?.sourceAnnotationId, cid)
        XCTAssertEqual(op.provenance?.triageMark, "decline")
        XCTAssertTrue(op.changes.isEmpty, "a mark carries no paragraph change")
        XCTAssertEqual(h.doc.displayText, textBefore)
    }

    /// An id the projection does not hold (never existed, or withdrawn) is a
    /// loud no-op, never a crash and never an orphan op — the same refusal
    /// shape `revertAcceptedAnnotation` uses. A triage op naming a withdrawn
    /// note would sit in the log forever marking nothing.
    func test_triagingAnAnnotationTheProjectionDoesNotHoldIsALoudNoOp() async throws {
        let h = try await makeHarness(prefix: "Triage-Unknown")
        let cid = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: nil,
            body: "note", authorName: "Denver")
        try await h.doc.withdrawReviewerAnnotation(id: cid, authorName: "Denver")
        let opsBefore = h.doc._opLogMirror.count

        try await h.doc.triageAnnotation(id: cid, mark: .do)
        try await h.doc.triageAnnotation(id: "nosuchid", mark: .do)

        XCTAssertEqual(h.doc._opLogMirror.count, opsBefore,
                       "neither call appended anything")
    }

    // MARK: - ⌘Z

    /// The sharp one. Undo restores the mark the note had BEFORE this triage,
    /// which is not the same as clearing it: mark `do`, change your mind to
    /// `discuss`, ⌘Z — the note is `do` again, not untriaged. A blanket clear
    /// would lose a decision the writer never asked to undo (the withdraw-undo
    /// lesson, M5-AN-036, in the mark's own key).
    func test_undoRestoresThePriorMark_ratherThanClearingIt() async throws {
        let h = try await makeHarness(prefix: "Triage-UndoPrior")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        try await h.doc.triageAnnotation(id: cid, mark: .do)
        let um = UndoManager()

        try await h.doc.triageAnnotation(id: cid, mark: .discuss, undoManager: um)
        XCTAssertEqual(annotation(h.doc, cid)?.triage, .discuss)
        let opsAfter = h.doc._opLogMirror.count

        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(h.doc, cid)?.triage, .do,
                       "the mark it had before, not nil")
        XCTAssertEqual(h.doc._opLogMirror.last?.kind, .annotationTriage)
        XCTAssertEqual(h.doc._opLogMirror.count, opsAfter + 1,
                       "ADR 0023: the undo appended; nothing was removed")
    }

    /// The first mark on an untriaged note undoes to untriaged — the prior
    /// mark there really is nil, and the revert op says so on the wire.
    func test_undoOfAFirstMarkReturnsItToUntriaged() async throws {
        let h = try await makeHarness(prefix: "Triage-UndoFirst")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()

        try await h.doc.triageAnnotation(id: cid, mark: .do, undoManager: um)
        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertNil(annotation(h.doc, cid)?.triage)
        XCTAssertTrue(
            h.doc._opLogMirror.contains { $0.kind == .annotationTriage
                                          && $0.provenance?.triageMark == "do" },
            "the original mark op survives its own undo")
    }

    /// ⇧⌘Z re-applies the mark, and the redo forwards the LIVE undo manager so
    /// the pair re-arms — ⌘Z/⇧⌘Z cycles indefinitely rather than dying after
    /// one round (the T3 dead-cycle regression's shape).
    func test_redoReAppliesTheMark_andTheCycleReArms() async throws {
        let h = try await makeHarness(prefix: "Triage-Redo")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        try await h.doc.triageAnnotation(id: cid, mark: .do)
        let um = UndoManager()

        try await h.doc.triageAnnotation(id: cid, mark: .discuss, undoManager: um)
        um.undo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(h.doc, cid)?.triage, .do)
        XCTAssertTrue(um.canRedo, "the undo must nest a re-triage onto the redo stack")

        um.redo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(h.doc, cid)?.triage, .discuss)

        XCTAssertTrue(um.canUndo, "the forward re-triage re-registered undo")
        um.undo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(h.doc, cid)?.triage, .do,
                       "a second ⌘Z after ⇧⌘Z restores the prior mark again")
    }

    /// RULING-22. The Edit menu said "Undo Triage Annotation"; another device
    /// had already marked the note something else; declining is right and
    /// declining SILENTLY is the control not doing what it says. Reverting
    /// anyway would overwrite the peer's mark with capture-time state.
    func test_aDriftedTriageUndoDeclinesToTheWriter() async throws {
        let h = try await makeHarness(prefix: "Triage-Drift")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()

        try await h.doc.triageAnnotation(id: cid, mark: .do, undoManager: um)
        // Another Mac's triage, merged in behind the writer's back.
        try await h.doc.triageAnnotation(id: cid, mark: .decline)
        let opsBefore = h.doc._opLogMirror.count

        let said = await notices {
            um.undo()
            await h.doc.awaitPendingUndoWork()
        }

        XCTAssertEqual(said, [
            "Couldn't undo the triage mark — it changed on another device."])
        XCTAssertEqual(annotation(h.doc, cid)?.triage, .decline,
                       "the peer's mark stands")
        XCTAssertEqual(h.doc._opLogMirror.count, opsBefore,
                       "a declined undo appends nothing")
    }

    /// The control: an undrifted ⌘Z reverts and stays quiet. A notice on every
    /// undo would make the decline invisible by making it ordinary.
    func test_aTriageUndoThatSucceedsIsSilent() async throws {
        let h = try await makeHarness(prefix: "Triage-Quiet")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()

        try await h.doc.triageAnnotation(id: cid, mark: .do, undoManager: um)
        let said = await notices {
            um.undo()
            await h.doc.awaitPendingUndoWork()
        }

        XCTAssertEqual(said, [])
        XCTAssertNil(annotation(h.doc, cid)?.triage)
    }

    // MARK: - Triage against the resolutions

    /// The two indexes are separate on purpose (Task 1's deriver): a mark
    /// cannot displace a resolution and a resolution cannot displace a mark.
    /// Stet a marked note and the mark is still there for the queue's history
    /// to read; the earlier op ordering makes no difference either way.
    func test_aResolutionLeavesTheMarkStanding() async throws {
        let h = try await makeHarness(prefix: "Triage-Orthogonal")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        try await h.doc.triageAnnotation(id: cid, mark: .do)

        try await h.doc.stetAnnotation(id: cid)

        XCTAssertEqual(annotation(h.doc, cid)?.status, .stetted)
        XCTAssertEqual(annotation(h.doc, cid)?.triage, .do,
                       "resolving a note does not un-mark it")
    }
}
