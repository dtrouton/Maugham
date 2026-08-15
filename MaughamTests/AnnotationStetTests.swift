import XCTest
@testable import MaughamCore
@testable import Maugham

/// **Stet** — the fourth resolution (spec §5): the note was read, considered,
/// and the words stand. Not an accept (nothing is applied), not a reject
/// (nothing is refused), not an archive (it was not set aside unread).
///
/// These pin the Mac writer verb `Document.stetAnnotation` on Task 1's wire:
/// the status flip, the queue departure, the compensating-op ⌘Z (ADR 0023 —
/// append, never truncate), the ⇧⌘Z re-arm, and the drifted undo's LOUD
/// decline (RULING-22: a menu item that says "Undo Stet Annotation" and then
/// does nothing must say why).
///
/// It also carries **the census**: `Document.isLifecycleOpKind` restates
/// `AnnotationDeriver.isLifecycleKind` because the deriver's copy is internal
/// to MaughamCore and the app cannot call it. A restatement with no test
/// binding it is exactly how one list gains a member and the other silently
/// does not.
@MainActor
final class AnnotationStetTests: XCTestCase {

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

    /// Across ALL statuses — `annotations()` defaults to `[.open]`, which hides
    /// the very `.stetted` note under test (M5-AN-002, the documented footgun).
    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    /// Every writer-facing notice posted while the block runs, in order.
    /// Mirrors `DocumentNoticeTests`' collector — same channel, same shape.
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

    /// The note stops being a question. It is still in the projection — a
    /// resolution is a record, not a deletion — but it has left the queue the
    /// default filter draws.
    func test_stetFlipsAnOpenNoteToStettedAndItLeavesTheQueue() async throws {
        let h = try await makeHarness(prefix: "Stet-Flip")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "is this too florid?")
        XCTAssertEqual(h.doc.annotations().count, 1, "precondition: it is in the queue")

        try await h.doc.stetAnnotation(id: cid, userResponse: "it stands")

        XCTAssertEqual(annotation(h.doc, cid)?.status, .stetted)
        XCTAssertEqual(annotation(h.doc, cid)?.userResponse, "it stands",
                       "a stet carries the writer's reply the way a reject does")
        XCTAssertEqual(h.doc.annotations().count, 0,
                       "the default [.open] filter no longer shows it")
        XCTAssertEqual(
            h.doc.annotations(filter: AnnotationFilter(statuses: nil)).count, 1,
            "…but the note itself is still there")
    }

    /// The pane redraws off `annotationsVersion`. A resolution the writer can
    /// see happen is worth nothing if the list does not notice it.
    func test_stetBumpsTheAnnotationsVersion() async throws {
        let h = try await makeHarness(prefix: "Stet-Version")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let before = h.doc.annotationsVersion

        try await h.doc.stetAnnotation(id: cid)

        XCTAssertGreaterThan(h.doc.annotationsVersion, before)
    }

    /// A stet writes one `annotation_stet` op and no manuscript change — the
    /// prose is untouched, which is the entire point of the word.
    func test_stetAppendsOneStatusOnlyOpAndMovesNoText() async throws {
        let h = try await makeHarness(prefix: "Stet-OpShape")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let textBefore = h.doc.displayText

        try await h.doc.stetAnnotation(id: cid)

        let stet = try XCTUnwrap(h.doc._opLogMirror.last)
        XCTAssertEqual(stet.kind, .annotationStet)
        XCTAssertEqual(stet.provenance?.sourceAnnotationId, cid)
        XCTAssertTrue(stet.changes.isEmpty, "a stet carries no paragraph change")
        XCTAssertEqual(h.doc.displayText, textBefore)
    }

    // MARK: - ⌘Z

    /// ADR 0023: undo APPENDS the compensating `annotationReopen`. The log only
    /// ever grows — a truncating undo would take the forensic record with it.
    func test_undoOfAStetReopensItByAppending_neverTruncating() async throws {
        let h = try await makeHarness(prefix: "Stet-Undo")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()

        try await h.doc.stetAnnotation(id: cid, undoManager: um)
        XCTAssertEqual(annotation(h.doc, cid)?.status, .stetted)
        XCTAssertTrue(um.canUndo)
        let opsAfterStet = h.doc._opLogMirror.count

        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
        XCTAssertEqual(h.doc._opLogMirror.last?.kind, .annotationReopen)
        XCTAssertEqual(h.doc._opLogMirror.count, opsAfterStet + 1,
                       "the undo appended; nothing was removed")
        XCTAssertTrue(
            h.doc._opLogMirror.contains { $0.kind == .annotationStet },
            "the stet op survives its own undo")
    }

    /// ⇧⌘Z re-stets carrying the original reply, and the redo forwards the LIVE
    /// undo manager so the pair re-arms — ⌘Z/⇧⌘Z cycles indefinitely rather
    /// than dying after one round (reject's precedent).
    func test_redoReStetsWithItsReply_andTheCycleReArms() async throws {
        let h = try await makeHarness(prefix: "Stet-Redo")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()

        try await h.doc.stetAnnotation(
            id: cid, userResponse: "deliberate", undoManager: um)
        um.undo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
        XCTAssertTrue(um.canRedo, "the undo must nest a re-stet onto the redo stack")

        um.redo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(h.doc, cid)?.status, .stetted)
        XCTAssertEqual(annotation(h.doc, cid)?.userResponse, "deliberate",
                       "the redo forwards the reply the writer wrote")

        XCTAssertTrue(um.canUndo, "the forward re-stet re-registered undo")
        um.undo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(h.doc, cid)?.status, .open,
                       "a second ⌘Z after ⇧⌘Z reopens again")
    }

    /// RULING-22. The Edit menu said "Undo Stet Annotation"; another device had
    /// already reopened the note; declining is right and declining SILENTLY is
    /// the control not doing what it says.
    func test_aDriftedStetUndoDeclinesToTheWriter() async throws {
        let h = try await makeHarness(prefix: "Stet-Drift")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()

        try await h.doc.stetAnnotation(id: cid, undoManager: um)
        // Another Mac's reopen, merged in behind the writer's back.
        try await h.doc.reopenAnnotation(id: cid)
        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
        let opsBefore = h.doc._opLogMirror.count

        let said = await notices {
            um.undo()
            await h.doc.awaitPendingUndoWork()
        }

        XCTAssertEqual(said, [
            "Couldn't undo letting the note stand — it changed on another device."])
        XCTAssertEqual(h.doc._opLogMirror.count, opsBefore,
                       "a declined undo appends nothing")
    }

    /// The control: an undrifted ⌘Z reopens and stays quiet. A notice on every
    /// undo would make the decline invisible by making it ordinary.
    func test_aStetUndoThatSucceedsIsSilent() async throws {
        let h = try await makeHarness(prefix: "Stet-Quiet")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()

        try await h.doc.stetAnnotation(id: cid, undoManager: um)
        let said = await notices {
            um.undo()
            await h.doc.awaitPendingUndoWork()
        }

        XCTAssertEqual(said, [])
        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
    }

    // MARK: - Reopen from stetted

    /// The pane's own Reopen, and the phone's: no new signature, because
    /// `AnnotationInverse.reopenOp` already answers for `.stetted` (Task 1).
    func test_reopenOnAStettedNoteReturnsItToOpen() async throws {
        let h = try await makeHarness(prefix: "Stet-Reopen")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        try await h.doc.stetAnnotation(id: cid)

        try await h.doc.reopenAnnotation(id: cid)

        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
        XCTAssertEqual(h.doc._opLogMirror.last?.kind, .annotationReopen)
    }

    /// The pane's Reopen with its ⌘Z pair (RULING-29): undo re-applies the
    /// PRIOR resolution WHOLE, so a stet comes back a stet and comes back with
    /// the reply the writer wrote. Reopening a stet and getting `.open` back
    /// from ⌘Z would be undo inventing a resolution nobody chose — the same
    /// fidelity rule that makes a reject return with its reason.
    func test_thePanesUndoableReopenPutsTheStetBackWhole() async throws {
        let h = try await makeHarness(prefix: "Stet-ReopenUndoable")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        try await h.doc.stetAnnotation(id: cid, userResponse: "it stands")
        let um = UndoManager()

        try await h.doc.reopenAnnotation(id: cid, undoManager: um)
        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
        XCTAssertTrue(um.canUndo)

        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(h.doc, cid)?.status, .stetted)
        XCTAssertEqual(annotation(h.doc, cid)?.userResponse, "it stands")
    }

    // MARK: - Parity with reject on an already-resolved note

    /// Stet does not invent a refusal reject does not have. Both verbs append
    /// their lifecycle op unconditionally and the deriver's latest-op-wins rule
    /// settles it — so stetting an archived note stets it, exactly as rejecting
    /// an archived note rejects it. (Which notes the QUEUE offers Stet on is
    /// the pane's business, Task 4's.)
    func test_stetOnAnAlreadyResolvedNoteBehavesExactlyAsRejectDoes() async throws {
        let h = try await makeHarness(prefix: "Stet-Resolved")
        let stetId = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "one")
        let rejectId = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "two")
        try await h.doc.archiveAnnotation(id: stetId)
        try await h.doc.archiveAnnotation(id: rejectId)

        try await h.doc.stetAnnotation(id: stetId)
        try await h.doc.rejectAnnotation(id: rejectId)

        XCTAssertEqual(annotation(h.doc, stetId)?.status, .stetted)
        XCTAssertEqual(annotation(h.doc, rejectId)?.status, .rejected,
                       "the control: reject does not refuse a resolved note either")
    }

    // MARK: - The withdraw carry (Task 1's unpinned arm)

    /// Task 1 taught `withdrawReviewerAnnotation`'s undo to restore a
    /// `.stetted` prior status, and nothing could mint one to prove it.
    /// RULING-22 / M5-AN-036: undoing "delete my note" gives back the note and
    /// NOTHING ELSE — the stet the writer never asked to undo is still theirs,
    /// and the reply they wrote comes back with it.
    func test_withdrawUndoReturnsAStettedNoteStetted_withItsReply() async throws {
        let h = try await makeHarness(prefix: "Stet-Withdraw")
        let cid = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: nil,
            body: "reviewer note", authorName: "Denver")
        try await h.doc.stetAnnotation(id: cid, userResponse: "the line stays")
        XCTAssertEqual(annotation(h.doc, cid)?.status, .stetted)

        let um = UndoManager()
        try await h.doc.withdrawReviewerAnnotation(
            id: cid, authorName: "Denver", undoManager: um)
        XCTAssertNil(annotation(h.doc, cid), "withdraw drops it from the projection")

        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(h.doc, cid)?.status, .stetted,
                       "not .open — the writer's stet survives the withdraw's undo")
        XCTAssertEqual(annotation(h.doc, cid)?.userResponse, "the line stays")
    }

    // MARK: - The census (a census beats a warning)

    /// `AnnotationDeriver.isLifecycleKind` is internal to MaughamCore, so the
    /// app restates it as `Document.isLifecycleOpKind` —
    /// `repairRejectedButSplicedAnnotations`' whole correctness is that it
    /// applies the deriver's own rule rather than a second opinion. Two
    /// hand-maintained lists with nothing binding them is how one gains a
    /// member and the other silently does not; `.annotationStet` is precisely
    /// that shape of member.
    func test_theTwoLifecycleListsAgreeOnEveryOpKind() {
        for kind in OpKind.allCases {
            XCTAssertEqual(
                Document.isLifecycleOpKind(kind),
                AnnotationDeriver.isLifecycleKind(kind),
                "\(kind.rawValue): the app's lifecycle list and the deriver's disagree")
        }
        XCTAssertTrue(Document.isLifecycleOpKind(.annotationStet),
                      "a stet settles a note — it is a lifecycle op")
    }

    /// `.annotationTriage`'s ABSENCE from the lifecycle rule is as load-bearing
    /// as `.annotationStet`'s presence: a triage is a MARK on a note the writer
    /// is still holding, and a mark that could displace a resolution would take
    /// notes out of the queue for being labelled. It is an annotation op all
    /// the same — it must flip `_hasAnyAnnotationOps` and reach the mirror, or
    /// a merged triage would be invisible.
    func test_triageIsAnAnnotationOpButNeverALifecycleOne() {
        XCTAssertTrue(Document.isAnnotationOpKind(.annotationTriage))
        XCTAssertTrue(Document.isAnnotationOpKind(.annotationStet))
        XCTAssertFalse(Document.isLifecycleOpKind(.annotationTriage))
        XCTAssertFalse(Document.lifecycleOpKinds.contains(.annotationTriage))
    }

    /// The set and the predicate are one rule, so the rewind's two membership
    /// tests cannot drift from the deriver either.
    func test_theLifecycleSetIsThePredicate() {
        XCTAssertEqual(
            Document.lifecycleOpKinds,
            Set(OpKind.allCases.filter { AnnotationDeriver.isLifecycleKind($0) }))
    }

    /// The grep half. `RewindImpact.statusKinds` and `Document+Rewind`'s local
    /// `statusKinds` each carried their own literal copy of this set until M3
    /// P2 — four copies of one rule, none of them tested. They now read
    /// `Document.lifecycleOpKinds`, and this stops the literal coming back
    /// somewhere a later `OpKind` will not reach.
    ///
    /// The canonical declaration is its own control: the scan must find
    /// exactly one file, and it must be `Document+Annotations.swift`.
    func test_onlyOnePlaceInProductionSpellsTheLifecycleSetOut() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham")
        let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "control: the scan found the sources")

        var spelling: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if flat.contains(".claudeAcceptRevert, .annotationReopen") {
                spelling.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(spelling, ["Document+Annotations.swift"],
                       "the lifecycle set is spelled out once; everything else asks")
    }

    // MARK: - The rewind's copy, on the delivery path

    /// The other half of the same drift, asserted through behaviour rather than
    /// through the set: the rewind preview reads a note's lifecycle history to
    /// decide what a restore would reopen. With the stet outside its status
    /// set, the op before a rewind-archive reads as "there wasn't one" and the
    /// preview promises to reopen a note the restore will not reopen.
    func test_theRewindPreviewReadsAStetAsPartOfTheHistory() async throws {
        let h = try await makeHarness(
            prefix: "Stet-Rewind", initialMd: "First.\n\nSecond.\n")
        let pid2 = try XCTUnwrap(h.doc.sequence.last)
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: pid2, body: "on the second")
        try await h.doc.stetAnnotation(id: cid)
        // A rewind-stamped archive on top of the stet — the shape step 9's
        // return journey inspects.
        try await h.doc.appendLifecycleOp(
            kind: .claudeArchive, sourceAnnotationId: cid,
            userResponse: nil, synthesisSource: .rewind)

        let ops = h.doc._opLogMirror
        let bootstrap = try XCTUnwrap(ops.first { $0.kind == .bootstrap }?.opId)
        let preview = RewindImpact.preview(ops: ops, cursorOpId: bootstrap)

        XCTAssertEqual(preview.annotationsToReopen, 0,
            "the note was stetted before it was archived, so a restore does not reopen it")
    }
}
