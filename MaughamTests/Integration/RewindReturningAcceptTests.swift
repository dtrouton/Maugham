import XCTest
import MaughamCore
@testable import Maugham

/// **Travel that brings an accepted change back brings its accepted status
/// back.** RULING-57: the writer accepts a suggestion, a checkpoint is taken,
/// then the writer Reverts (the change comes back out, the note is open). A
/// restore to the checkpoint puts the accepted text back, so the note returns
/// to `.accepted`, the status it had at that moment, instead of offering Accept
/// for a change already in the text. RULING-26 covers the same return after
/// Maugham's own travel took the change out (a rewind's status-only revert, or
/// the return journey's reopen). One rule (`RewindImpact.travelStatusChanges`)
/// answers the sheet, the restore and the toast.
@MainActor
final class RewindReturningAcceptTests: XCTestCase {

    private struct Harness { let doc: Document; let pid: String }

    private func makeHarness(_ initialMd: String = "First.") async throws -> Harness {
        let tmp = TestTemp.root
            .appendingPathComponent("RewindReturningAccept-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let relativePath = "manuscript/c1.md"
        try initialMd.write(to: tmp.appendingPathComponent(relativePath),
                            atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "Chapter 1", type: .document,
                                 path: relativePath)
        let manifest = ProjectManifest(type: .novel, title: "Returning", author: "A",
                                       created: Date(), modified: Date(),
                                       structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let doc = try await Document.load(url: tmp.appendingPathComponent(relativePath),
                                          device: "test", session: "s", presenter: nil)
        let pid = try await doc.opLog().first { $0.kind == .bootstrap }!.changes.first!.paragraphId
        return Harness(doc: doc, pid: pid)
    }

    private func status(_ doc: Document, _ id: String) -> AnnotationStatus? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }?.status
    }

    private func tip(_ doc: Document) async throws -> String {
        try await doc.flushBurstNow()
        let last = try await doc.opLog().last?.opId
        return try XCTUnwrap(last)
    }

    /// A suggestion on the first paragraph, accepted with a reply.
    private func acceptFirst(_ doc: Document, _ pid: String) async throws -> String {
        let id = try await doc.addAnnotation(kind: .suggestedChange, paragraphId: pid,
                                             body: "b", suggestedText: "First, improved.")
        try await doc.acceptAnnotation(id: id, userResponse: "yes")
        return id
    }

    /// Accept → checkpoint → Revert: the shape RULING-57 rules on.
    private func acceptCheckpointRevert() async throws -> (Document, String, String) {
        let h = try await makeHarness()
        let id = try await acceptFirst(h.doc, h.pid)
        let checkpoint = try await tip(h.doc)
        try await h.doc.revertAcceptedAnnotation(id: id)
        try await h.doc.flushBurstNow()
        XCTAssertEqual(status(h.doc, id), .open, "precondition: the Revert reopened it")
        XCTAssertFalse(h.doc.materialize().contains("improved"), "precondition: and took the text out")
        return (h.doc, id, checkpoint)
    }

    // MARK: - The writer's Revert (RULING-57)

    func test_travelBackOverAWritersRevert_returnsTheSuggestionToAccepted() async throws {
        let (doc, id, checkpoint) = try await acceptCheckpointRevert()

        let p = RewindImpact.preview(ops: try await doc.opLog(), cursorOpId: checkpoint,
                                     amendments: doc.annotationAmendments)
        XCTAssertEqual(p.acceptsToRestore, 1, "the sheet promises it")
        XCTAssertTrue(RewindImpact.confirmSummary(p).contains("1 suggestion restored to accepted."))

        let r = try await doc.restoreToOp(opId: checkpoint)

        XCTAssertTrue(doc.materialize().contains("First, improved."), "the accepted text is back")
        XCTAssertEqual(status(doc, id), .accepted,
                       "and so is the status the note had at that moment")
        XCTAssertEqual(r.returnedAcceptAnnotationIds, [id])
        XCTAssertEqual(r.returnedAcceptAnnotationIds.count + r.travelReacceptedAnnotationIds.count,
                       p.acceptsToRestore, "the toast counts what the sheet promised")
        XCTAssertTrue(try XCTUnwrap(RewindImpact.toast(for: r))
            .contains("1 suggestion restored to accepted."))
        let log = try await doc.opLog()
        let reaccept = try XCTUnwrap(log.last {
            $0.kind == .claudeAccept && $0.provenance?.sourceAnnotationId == id })
        XCTAssertTrue(reaccept.changes.isEmpty, "status only: the restore op carries the text")
        XCTAssertEqual(reaccept.provenance?.synthesisSource, .rewind)
        XCTAssertEqual(reaccept.provenance?.userResponse, "yes", "the writer's reply is kept")
    }

    // MARK: - Maugham's own travel (RULING-26)

    /// Accept → checkpoint; rewind to before the accept (step 8 reopens it,
    /// status only); then forward to the checkpoint: the text comes back, so
    /// the status does too.
    func test_forwardTravelOverARewindsOwnRevert_returnsTheSuggestionToAccepted() async throws {
        let h = try await makeHarness()
        let early = try await tip(h.doc)
        let id = try await acceptFirst(h.doc, h.pid)
        let later = try await tip(h.doc)
        _ = try await h.doc.restoreToOp(opId: early)
        XCTAssertEqual(status(h.doc, id), .open, "precondition: step 8 reopened the stranded accept")

        let p = RewindImpact.preview(ops: try await h.doc.opLog(), cursorOpId: later)
        XCTAssertEqual(p.acceptsToRestore, 1)
        let r = try await h.doc.restoreToOp(opId: later)

        XCTAssertTrue(h.doc.materialize().contains("First, improved."))
        XCTAssertEqual(status(h.doc, id), .accepted)
        XCTAssertEqual(r.returnedAcceptAnnotationIds, [id])
    }

    /// The return journey's before-accept arm reopened an archived accept
    /// (`.rewind`-stamped `annotationReopen`); travelling on past the accept
    /// returns it to accepted.
    func test_forwardTravelOverTheReturnJourneysReopen_returnsTheSuggestionToAccepted() async throws {
        let h = try await makeHarness()
        let early = try await tip(h.doc)
        h.doc.setFullText("First.\n\nSecond.\n")
        let beforeAccept = try await tip(h.doc)
        let p2 = try XCTUnwrap(h.doc.sequence.last)
        let id = try await h.doc.addAnnotation(kind: .suggestedChange, paragraphId: p2,
                                               body: "b", suggestedText: "Second, improved.")
        try await h.doc.acceptAnnotation(id: id)
        let later = try await tip(h.doc)
        _ = try await h.doc.restoreToOp(opId: early)
        _ = try await h.doc.restoreToOp(opId: beforeAccept)
        XCTAssertEqual(status(h.doc, id), .open, "precondition: the return journey reopened it")

        let r = try await h.doc.restoreToOp(opId: later)

        XCTAssertEqual(status(h.doc, id), .accepted)
        XCTAssertTrue(h.doc.materialize().contains("Second, improved."))
        XCTAssertEqual(r.returnedAcceptAnnotationIds, [id])
    }

    // MARK: - Controls: the writer's other answers stand

    /// Reverted BEFORE the checkpoint: at that moment the note was open.
    func test_aRevertBeforeTheCheckpoint_staysOpen() async throws {
        let h = try await makeHarness()
        let id = try await acceptFirst(h.doc, h.pid)
        try await h.doc.revertAcceptedAnnotation(id: id)
        let checkpoint = try await tip(h.doc)
        // Typed over since, so the restore writes the note's paragraph.
        h.doc.setParagraph(id: h.pid, text: "First, since.")
        try await h.doc.flushBurstNow()

        let p = RewindImpact.preview(ops: try await h.doc.opLog(), cursorOpId: checkpoint)
        let r = try await h.doc.restoreToOp(opId: checkpoint)

        XCTAssertTrue(r.restoreOp?.changes.contains { $0.paragraphId == h.pid } == true,
                      "precondition: the restore wrote the note's paragraph")
        XCTAssertEqual(status(h.doc, id), .open)
        XCTAssertEqual(p.acceptsToRestore, 0)
        XCTAssertTrue(r.returnedAcceptAnnotationIds.isEmpty)
    }

    /// Only a change-removing revert qualifies: a Stet, or an archive, put
    /// after the checkpoint (over the Revert, or over the accept) is the
    /// writer's answer and stands.
    func test_aStetOrArchiveAfterTheCheckpoint_stands() async throws {
        let h = try await makeHarness("First.\n\nSecond.\n\nThird.")
        let seq = h.doc.sequence
        func suggest(_ i: Int) async throws -> String {
            let id = try await h.doc.addAnnotation(kind: .suggestedChange, paragraphId: seq[i],
                                                   body: "b", suggestedText: "Changed \(i).")
            try await h.doc.acceptAnnotation(id: id)
            return id
        }
        let revertedThenStetted = try await suggest(0)
        let revertedThenArchived = try await suggest(1)
        let stettedOverTheAccept = try await suggest(2)
        let checkpoint = try await tip(h.doc)
        try await h.doc.revertAcceptedAnnotation(id: revertedThenStetted)
        try await h.doc.stetAnnotation(id: revertedThenStetted, userResponse: "no")
        try await h.doc.revertAcceptedAnnotation(id: revertedThenArchived)
        try await h.doc.archiveAnnotation(id: revertedThenArchived)
        try await h.doc.stetAnnotation(id: stettedOverTheAccept, userResponse: "no")
        try await h.doc.flushBurstNow()

        let p = RewindImpact.preview(ops: try await h.doc.opLog(), cursorOpId: checkpoint)
        let r = try await h.doc.restoreToOp(opId: checkpoint)

        XCTAssertEqual(status(h.doc, revertedThenStetted), .stetted)
        XCTAssertEqual(status(h.doc, revertedThenArchived), .archived)
        XCTAssertEqual(status(h.doc, stettedOverTheAccept), .stetted)
        XCTAssertEqual(p.acceptsToRestore, 0)
        XCTAssertTrue(r.returnedAcceptAnnotationIds.isEmpty)
    }

    /// The travel must itself put the text back: a paragraph the writer
    /// retyped to the accepted text since is not written by the restore, so
    /// the note is left as the writer left it.
    func test_aParagraphTheRestoreDoesNotWrite_staysOpen() async throws {
        let (doc, id, checkpoint) = try await acceptCheckpointRevert()
        let pid = try XCTUnwrap(doc.sequence.first)
        doc.setParagraph(id: pid, text: "First, improved.")
        doc.setFullText(doc.displayText + "\n\nLater.")
        try await doc.flushBurstNow()

        let p = RewindImpact.preview(ops: try await doc.opLog(), cursorOpId: checkpoint)
        let r = try await doc.restoreToOp(opId: checkpoint)

        XCTAssertNotNil(r.restoreOp, "precondition: the restore did something")
        XCTAssertEqual(status(doc, id), .open)
        XCTAssertEqual(p.acceptsToRestore, 0)
        XCTAssertTrue(r.returnedAcceptAnnotationIds.isEmpty)
    }

    // MARK: - Withdrawn

    /// A deleted note gets its re-accept in the log, but is neither promised
    /// nor reported — step 8's rule.
    func test_aWithdrawnNote_isNeitherPromisedNorReported() async throws {
        let h = try await makeHarness()
        let id = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, span: nil, body: "b",
            suggestedText: "First, improved.", authorName: "Denver")
        try await h.doc.acceptAnnotation(id: id)
        let checkpoint = try await tip(h.doc)
        try await h.doc.revertAcceptedAnnotation(id: id)
        try await h.doc.withdrawReviewerAnnotation(id: id, authorName: "Denver")
        try await h.doc.flushBurstNow()

        let p = RewindImpact.preview(ops: try await h.doc.opLog(), cursorOpId: checkpoint)
        let r = try await h.doc.restoreToOp(opId: checkpoint)

        XCTAssertEqual(p.acceptsToRestore, 0, "a deleted note is not promised")
        XCTAssertTrue(r.returnedAcceptAnnotationIds.isEmpty, "a deleted note is not reported")
        XCTAssertTrue(h.doc.materialize().contains("First, improved."), "precondition: text back")
        let log = try await h.doc.opLog()
        XCTAssertTrue(log.contains {
            $0.kind == .claudeAccept && $0.changes.isEmpty
                && $0.provenance?.sourceAnnotationId == id
        }, "the log still records the re-accept, should the note be restored")
    }

    // MARK: - Undo

    /// ⌘Z of a full rewind leaves every note as it was before it: the note
    /// this rule re-accepted is open again over the reverted text, and the
    /// accept the forward rule reopened is accepted again over its text.
    func test_undoOfTheRewind_putsBothRulesStatusesBack() async throws {
        let h = try await makeHarness("First.\n\nSecond.")
        let p2 = try XCTUnwrap(h.doc.sequence.last)
        let returning = try await acceptFirst(h.doc, h.pid)
        let checkpoint = try await tip(h.doc)
        try await h.doc.revertAcceptedAnnotation(id: returning)
        let stranded = try await h.doc.addAnnotation(kind: .suggestedChange, paragraphId: p2,
                                                     body: "b", suggestedText: "Second, improved.")
        try await h.doc.acceptAnnotation(id: stranded)
        try await h.doc.flushBurstNow()
        let um = UndoManager()

        _ = try await h.doc.restoreToOpUndoable(opId: checkpoint, undoManager: um)
        XCTAssertEqual(status(h.doc, returning), .accepted)
        XCTAssertEqual(status(h.doc, stranded), .open)

        um.undo(); await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(status(h.doc, returning), .open, "the re-accept is undone")
        XCTAssertFalse(h.doc.materialize().contains("First, improved."), "over the reverted text")
        XCTAssertEqual(status(h.doc, stranded), .accepted, "the forward rule's reopen is undone")
        XCTAssertTrue(h.doc.materialize().contains("Second, improved."))

        um.redo(); await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(status(h.doc, returning), .accepted, "redo is a fresh rewind")
        XCTAssertEqual(status(h.doc, stranded), .open)
    }

    // MARK: - RULING-33

    /// The reject/splice repair never undoes a re-accept: its trigger is a
    /// winning reject, and the re-accept is the winner. Travel's own revert
    /// is status only, so the newest changes-carrying op here is still the
    /// accept — the reject test is the one guard that stands between them.
    func test_theRejectRepairLeavesAReacceptAlone() async throws {
        let h = try await makeHarness()
        let early = try await tip(h.doc)
        let id = try await acceptFirst(h.doc, h.pid)
        let later = try await tip(h.doc)
        _ = try await h.doc.restoreToOp(opId: early)
        _ = try await h.doc.restoreToOp(opId: later)
        XCTAssertEqual(status(h.doc, id), .accepted, "precondition")

        let repaired = await h.doc.repairRejectedButSplicedAnnotations()

        XCTAssertEqual(repaired, 0)
        XCTAssertEqual(status(h.doc, id), .accepted)
        XCTAssertTrue(h.doc.materialize().contains("First, improved."))
    }

    // MARK: - Accepted with its text at the target (M4-RW-042)

    /// Accept → checkpoint → Revert → accept again → other typing → rewind to
    /// the checkpoint: the change is in the text at the checkpoint and after
    /// the rewind, so the note is not stranded and stays accepted.
    func test_aNoteAcceptedAgainSinceTheCheckpoint_staysAccepted() async throws {
        let h = try await makeHarness("First.\n\nSecond.")
        let p2 = try XCTUnwrap(h.doc.sequence.last)
        let id = try await acceptFirst(h.doc, h.pid)
        let checkpoint = try await tip(h.doc)
        try await h.doc.revertAcceptedAnnotation(id: id)
        try await h.doc.acceptAnnotation(id: id, userResponse: "again")
        h.doc.setParagraph(id: p2, text: "Second, since.")
        try await h.doc.flushBurstNow()

        let p = RewindImpact.preview(ops: try await h.doc.opLog(), cursorOpId: checkpoint)
        let r = try await h.doc.restoreToOp(opId: checkpoint)

        XCTAssertNotNil(r.restoreOp, "precondition: the restore did something")
        XCTAssertEqual(p.acceptsToReopen, 0, "nothing is promised reopened")
        XCTAssertTrue(r.reopenedAnnotationOpIds.isEmpty)
        XCTAssertTrue(h.doc.materialize().contains("First, improved."), "the change is still in the text")
        XCTAssertEqual(status(h.doc, id), .accepted, "so the note stays accepted")
    }

    // MARK: - The reject control

    /// Revert, then reject, after the checkpoint: the reject is the writer's
    /// answer and stands, though the rewind puts the accepted text back.
    func test_aRejectAfterTheRevert_stands() async throws {
        let (doc, id, checkpoint) = try await acceptCheckpointRevert()
        try await doc.rejectAnnotation(id: id, userResponse: "no")
        try await doc.flushBurstNow()

        let p = RewindImpact.preview(ops: try await doc.opLog(), cursorOpId: checkpoint)
        let r = try await doc.restoreToOp(opId: checkpoint)

        XCTAssertTrue(doc.materialize().contains("First, improved."), "precondition: text back")
        XCTAssertEqual(status(doc, id), .rejected)
        XCTAssertEqual(p.acceptsToRestore, 0)
        XCTAssertTrue(r.returnedAcceptAnnotationIds.isEmpty)
    }

    // MARK: - Step 9's re-accept under ⌘Z (M4-RW-035)

    /// An accept archived with its paragraph, re-accepted by a forward
    /// travel: ⌘Z takes the paragraph away again and re-archives the note;
    /// redo returns it again.
    func test_undoOfAForwardTravel_reArchivesWhatStep9Reaccepted() async throws {
        let h = try await makeHarness()
        let early = try await tip(h.doc)
        h.doc.setFullText("First.\n\nSecond.\n")
        try await h.doc.flushBurstNow()
        let p2 = try XCTUnwrap(h.doc.sequence.last)
        let id = try await h.doc.addAnnotation(kind: .suggestedChange, paragraphId: p2,
                                               body: "b", suggestedText: "Second, improved.")
        try await h.doc.acceptAnnotation(id: id)
        let later = try await tip(h.doc)
        _ = try await h.doc.restoreToOp(opId: early)
        XCTAssertEqual(status(h.doc, id), .archived, "precondition: step 8 archived it")
        let um = UndoManager()

        let forward = try await h.doc.restoreToOpUndoable(opId: later, undoManager: um)
        XCTAssertEqual(forward.travelReacceptedAnnotationIds, [id], "precondition")
        XCTAssertEqual(status(h.doc, id), .accepted)

        um.undo(); await h.doc.awaitPendingUndoWork()
        XCTAssertFalse(h.doc.sequence.contains(p2), "precondition: the paragraph is gone again")
        XCTAssertEqual(status(h.doc, id), .archived, "the re-accept is undone")

        um.redo(); await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(status(h.doc, id), .accepted, "redo is a fresh forward travel")
    }

    // MARK: - A tick on a restore op (M4-RW-042, M4-RW-040)

    /// accept → rewind to before it (restore op R, then step 8's reopen V) →
    /// accept again → rewind to the tick R. R's text lacks the change, and
    /// at R's moment — R with the lines it wrote — the note was open; the
    /// second accept is stranded and is reopened, and the sheet says so.
    func test_aTickOnARestoreOp_strandsAnAcceptMadeSince() async throws {
        let h = try await makeHarness()
        let early = try await tip(h.doc)
        let id = try await acceptFirst(h.doc, h.pid)
        let back = try await h.doc.restoreToOp(opId: early)
        let tick = try XCTUnwrap(back.restoreOp?.opId)
        XCTAssertEqual(status(h.doc, id), .open, "precondition: step 8 reopened it")
        try await h.doc.acceptAnnotation(id: id, userResponse: "again")
        XCTAssertTrue(h.doc.materialize().contains("First, improved."), "precondition")

        let p = RewindImpact.preview(ops: try await h.doc.opLog(), cursorOpId: tick)
        let r = try await h.doc.restoreToOp(opId: tick)

        XCTAssertFalse(h.doc.materialize().contains("improved"), "R's text lacks the change")
        XCTAssertEqual(status(h.doc, id), .open, "so the accept is stranded and reopened")
        XCTAssertEqual(p.acceptsToReopen, 1, "and the sheet promised it")
        XCTAssertEqual(r.reopenedAnnotationOpIds, [id])
    }

    /// accept → rewind to before it (R, V) → type in that paragraph → rewind
    /// to the tick R. At R's moment the note was open over text without the
    /// change, so nothing returns to accepted.
    func test_aTickOnARestoreOp_returnsNothingItsMomentHadOpen() async throws {
        let h = try await makeHarness()
        let early = try await tip(h.doc)
        let id = try await acceptFirst(h.doc, h.pid)
        let back = try await h.doc.restoreToOp(opId: early)
        let tick = try XCTUnwrap(back.restoreOp?.opId)
        h.doc.setParagraph(id: h.pid, text: "First, typed.")
        try await h.doc.flushBurstNow()

        let p = RewindImpact.preview(ops: try await h.doc.opLog(), cursorOpId: tick)
        let r = try await h.doc.restoreToOp(opId: tick)

        XCTAssertTrue(r.restoreOp?.changes.contains { $0.paragraphId == h.pid } == true,
                      "precondition: the restore wrote the note's paragraph")
        XCTAssertFalse(h.doc.materialize().contains("improved"))
        XCTAssertEqual(status(h.doc, id), .open)
        XCTAssertEqual(p.acceptsToRestore, 0)
        XCTAssertTrue(r.returnedAcceptAnnotationIds.isEmpty)
    }

    // MARK: - momentEnd, pure

    private func op(_ id: String, _ kind: OpKind, changes: [Op.ParagraphChange] = [],
                    source: SynthesisSource? = nil, checkpoint: String? = nil) -> Op {
        Op(opId: id, docId: "d", at: Date(), device: "m", session: "s", kind: kind,
           changes: changes, sequence: nil,
           provenance: .init(sourceCheckpoint: checkpoint, synthesisSource: source,
                             sourceAnnotationId: "n"))
    }

    /// A checkpoint revert's lines carry its checkpoint stamp, and are its
    /// moment; a rewind's lines carry `.rewind`; a fresh marker-only rewind
    /// after them starts its own moment; a target that is no restore's is
    /// its own.
    func test_momentEnd_extendsOverTheLinesARestoreWroteAndNoFurther() {
        let text = [Op.ParagraphChange(paragraphId: "a1b2", prior: "x", next: "y")]
        let revert = [
            op("01A", .checkpointRestore, changes: text, checkpoint: "ck"),
            op("01B", .claudeAcceptRevert, checkpoint: "ck"),
            op("01C", .claudeAccept, checkpoint: "ck"),
            op("01D", .claudeAccept, changes: text),
        ]
        XCTAssertEqual(RewindImpact.momentEnd(of: "01A", in: revert), "01C")
        XCTAssertEqual(RewindImpact.momentEnd(of: "01B", in: revert), "01C")
        XCTAssertEqual(RewindImpact.momentEnd(of: "01D", in: revert), "01D")

        let rewind = [
            op("01A", .checkpointRestore, changes: text, source: .rewind, checkpoint: "00Z"),
            op("01B", .claudeArchive, source: .rewind),
            op("01C", .claudeAcceptRevert, source: .rewind),
            op("01D", .checkpointRestore, source: .rewind, checkpoint: "00Y"),
            op("01E", .claudeArchive, source: .rewind),
        ]
        XCTAssertEqual(RewindImpact.momentEnd(of: "01A", in: rewind), "01C",
                       "a marker-only rewind after the run is its own moment")
        XCTAssertEqual(RewindImpact.momentEnd(of: "01D", in: rewind), "01E")

        let undo = [
            op("01A", .checkpointRestore, changes: text, source: .undoRewind, checkpoint: "00Z"),
            op("01B", .claudeArchive, source: .rewind),
            op("01C", .checkpointRestore, source: .rewind, checkpoint: "00Y"),
            op("01D", .claudeAccept, source: .undoRewind),
        ]
        XCTAssertEqual(RewindImpact.momentEnd(of: "01A", in: undo), "01D",
                       "an undo's task-window closer is inside the undo's moment")
    }
}
