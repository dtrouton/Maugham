import XCTest
@testable import MaughamCore
@testable import Maugham

/// Stands in for the writer's own previous undoable action — the typing that a
/// ⌘Z aimed at "Got it" used to take instead. All access is MainActor-confined
/// within one test.
private final class PriorActionSentinel: @unchecked Sendable {
    var fired = false
}

/// **Accepting a note is undoable** (Denver's 2026-08-18 ruling).
///
/// `Document.acceptAnnotation` registered a ⌘Z pair for a `.suggestedChange`
/// and for nothing else, so accepting a comment, a query or a craft note left
/// the writer's PRIOR action — usually their typing — sitting at the top of
/// the undo stack under a menu item that no longer described it. One ⌘Z aimed
/// at "Got it" took a sentence. Carried from the M3 handoff as a known shape,
/// surfaced three times, then ruled: fix.
///
/// The fix is reject's and stet's machinery, not accept's: an
/// `OpUndoRegistrar` pair whose undo appends a compensating `annotationReopen`
/// (ADR 0023 — append, never truncate) through
/// `Document.reopenAcceptedTextlessAnnotation`, with a fire-time re-check and
/// a LOUD decline (RULING-22). These pin all of it, plus the two controls that
/// matter most: the writer's own action is shielded rather than shadowed, and
/// the suggestion path's revert-undo is untouched.
@MainActor
final class AnnotationAcceptNoteUndoTests: XCTestCase {

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
    /// the very `.accepted` note under test (M5-AN-002, the documented footgun).
    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    /// Every writer-facing notice posted while the block runs, in order.
    /// `AnnotationStetTests`' collector — same channel, same shape.
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

    // MARK: - The undo

    /// ADR 0023: the undo APPENDS the compensating `annotationReopen`. The log
    /// only ever grows — a truncating undo would take the record of the
    /// writer's decision with it.
    func test_undoOfAnAcceptedNoteReopensItByAppending_neverTruncating() async throws {
        let h = try await makeHarness(prefix: "AcceptNote-Undo")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()

        try await h.doc.acceptAnnotation(id: cid, undoManager: um)
        XCTAssertEqual(annotation(h.doc, cid)?.status, .accepted)
        XCTAssertTrue(um.canUndo, "the accept registered no undo action at all")
        let opsAfterAccept = h.doc._opLogMirror.count

        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
        XCTAssertEqual(h.doc._opLogMirror.last?.kind, .annotationReopen)
        XCTAssertEqual(h.doc._opLogMirror.count, opsAfterAccept + 1,
                       "the undo appended; nothing was removed")
        XCTAssertTrue(
            h.doc._opLogMirror.contains { $0.kind == .claudeAccept },
            "the accept op survives its own undo")
        XCTAssertEqual(h.doc.paragraphs[h.pid], "A single paragraph.",
                       "and no manuscript text moved in either direction")
    }

    /// All three textless kinds, because the registration is gated on the
    /// kind and a gate that covers one of three is the same defect with a
    /// smaller blast radius. A craft note carries no anchor at all.
    func test_everyTextlessKindRegistersTheSameUndo() async throws {
        let h = try await makeHarness(prefix: "AcceptNote-Kinds")
        for kind in [AnnotationKind.comment, .query, .craftNote] {
            let id = try await h.doc.addAnnotation(
                kind: kind, paragraphId: kind == .craftNote ? nil : h.pid,
                body: "\(kind)")
            let um = UndoManager()
            try await h.doc.acceptAnnotation(id: id, undoManager: um)
            XCTAssertEqual(annotation(h.doc, id)?.status, .accepted, "\(kind)")
            XCTAssertTrue(um.canUndo, "\(kind) registered nothing")

            um.undo()
            await h.doc.awaitPendingUndoWork()
            XCTAssertEqual(annotation(h.doc, id)?.status, .open, "\(kind) did not reopen")
        }
    }

    /// ⇧⌘Z re-accepts carrying the writer's original reply, and the redo
    /// forwards the LIVE undo manager so the pair re-arms — ⌘Z/⇧⌘Z cycles
    /// indefinitely rather than dying after one round (reject's precedent).
    func test_redoReAcceptsWithItsReply_andTheCycleReArms() async throws {
        let h = try await makeHarness(prefix: "AcceptNote-Redo")
        let cid = try await h.doc.addAnnotation(
            kind: .query, paragraphId: h.pid, body: "how long?")
        let um = UndoManager()

        try await h.doc.acceptAnnotation(
            id: cid, userResponse: "about a week", undoManager: um)
        um.undo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
        XCTAssertTrue(um.canRedo, "the undo must nest a re-accept onto the redo stack")

        um.redo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(h.doc, cid)?.status, .accepted)
        XCTAssertEqual(annotation(h.doc, cid)?.userResponse, "about a week",
                       "the redo forwards the reply the writer wrote")

        XCTAssertTrue(um.canUndo, "the forward re-accept re-registered undo")
        um.undo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(h.doc, cid)?.status, .open,
                       "a second ⌘Z after ⇧⌘Z reopens again")
    }

    /// RULING-22. The Edit menu says "Undo Accept Note"; another device had
    /// already moved the note; declining is right and declining SILENTLY is
    /// the control not doing what it says.
    func test_aDriftedAcceptUndoDeclinesToTheWriter() async throws {
        let h = try await makeHarness(prefix: "AcceptNote-Drift")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()

        try await h.doc.acceptAnnotation(id: cid, undoManager: um)
        // Another Mac's reject, merged in behind the writer's back.
        try await h.doc.rejectAnnotation(id: cid)
        XCTAssertEqual(annotation(h.doc, cid)?.status, .rejected)
        let opsBefore = h.doc._opLogMirror.count

        let said = await notices {
            um.undo()
            await h.doc.awaitPendingUndoWork()
        }

        XCTAssertEqual(said, [
            "Couldn't undo accepting the note — it changed on another device."])
        XCTAssertEqual(h.doc._opLogMirror.count, opsBefore,
                       "a declined undo appends nothing")
        XCTAssertEqual(annotation(h.doc, cid)?.status, .rejected,
                       "…and leaves the other device's decision standing")
    }

    /// The control: an undrifted ⌘Z reopens and stays quiet. A notice on every
    /// undo would make the decline invisible by making it ordinary.
    func test_anAcceptUndoThatSucceedsIsSilent() async throws {
        let h = try await makeHarness(prefix: "AcceptNote-Quiet")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()

        try await h.doc.acceptAnnotation(id: cid, undoManager: um)
        let said = await notices {
            um.undo()
            await h.doc.awaitPendingUndoWork()
        }

        XCTAssertEqual(said, [])
        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
    }

    // MARK: - The writer's own action is shielded, not shadowed

    /// **The defect, stated as the thing it cost.** Before the fix the accept
    /// registered nothing, so the top of the stack after "Got it" was still
    /// the writer's previous action and the menu still named it — press ⌘Z
    /// once and a sentence went instead of the note.
    ///
    /// Two groups rather than the default event coalescing, because what is
    /// under test is precisely that the accept is its OWN step: `groupsByEvent`
    /// would fold the sentinel and the accept into one top-level group and one
    /// ⌘Z would legitimately reverse both, which is the app's behaviour inside
    /// a single event and not the case this is about. (Manual grouping is safe
    /// here for the reason it is not safe around a suggestion accept: no
    /// `removeAllActions` runs on this path — ADR 0023's D1 is about undo
    /// stacks that reference pre-replace text storage, and nothing is
    /// replaced.)
    func test_theAcceptIsItsOwnUndoStep_soTheWritersPriorActionIsShielded() async throws {
        let h = try await makeHarness(prefix: "AcceptNote-Shield")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")

        let sentinel = PriorActionSentinel()
        let um = UndoManager()
        um.groupsByEvent = false

        um.beginUndoGrouping()
        um.registerUndo(withTarget: sentinel) { $0.fired = true }
        um.setActionName("Typing")
        um.endUndoGrouping()
        XCTAssertEqual(um.undoActionName, "Typing", "premise: the writer acted first")

        um.beginUndoGrouping()
        try await h.doc.acceptAnnotation(id: cid, undoManager: um)
        um.endUndoGrouping()

        XCTAssertEqual(um.undoActionName, "Accept Note",
                       "the Edit menu must name the note, not the writer's sentence")

        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(h.doc, cid)?.status, .open,
                       "one ⌘Z reopens the note")
        XCTAssertFalse(sentinel.fired,
                       "…and it must not have reached the writer's prior action, "
                       + "which is the whole defect this fixes")

        um.undo()
        XCTAssertTrue(sentinel.fired, "a SECOND ⌘Z is what reaches their sentence")
    }

    // MARK: - The suggestion path is untouched

    /// The control on the other side: accepting a suggestion still goes
    /// through its own revert-undo, which restores the prose as well as the
    /// status, and still names itself "Accept Suggestion". A reopen-only undo
    /// here would leave the manuscript rewritten with the note open again —
    /// the reason `AnnotationInverse.reopenOp` excluded accept outright until
    /// the gated arm arrived.
    func test_anAcceptedSuggestionStillUndoesThroughItsRevert() async throws {
        let h = try await makeHarness(prefix: "AcceptNote-Suggestion")
        let sid = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, body: "tighter",
            suggestedText: "One paragraph.")
        let um = UndoManager()

        try await h.doc.acceptAnnotation(id: sid, undoManager: um)
        XCTAssertEqual(h.doc.paragraphs[h.pid], "One paragraph.")
        XCTAssertEqual(um.undoActionName, "Accept Suggestion")

        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(h.doc, sid)?.status, .open)
        XCTAssertEqual(h.doc.paragraphs[h.pid], "A single paragraph.",
                       "the suggestion's undo restores the prose, which a bare "
                       + "reopen never could")
        XCTAssertEqual(h.doc._opLogMirror.last?.kind, .claudeAcceptRevert,
                       "…and it is still the revert op, not a reopen")
    }

    /// **The textless door checks the KIND itself** (2026-08-18 review,
    /// Important 2). `reopenAcceptedTextlessAnnotation` is the one verb built
    /// to pass `acceptSplicedManuscriptText: false`, so it is the one place
    /// the factory's default refusal cannot protect. Its name says what it is
    /// for and today's single caller honours that, but a second caller handed
    /// an accepted suggestion would leave the manuscript rewritten with the
    /// note open again. It refuses on its own account instead — before the
    /// factory is asked, and appending nothing.
    func test_theTextlessDoorRefusesAnAcceptedSuggestionOnItsOwnAccount() async throws {
        let h = try await makeHarness(prefix: "AcceptNote-KindGate")
        let sid = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, body: "tighter",
            suggestedText: "One paragraph.")
        try await h.doc.acceptAnnotation(id: sid)
        XCTAssertEqual(annotation(h.doc, sid)?.status, .accepted)
        XCTAssertEqual(h.doc.paragraphs[h.pid], "One paragraph.",
                       "premise: the splice is in the manuscript")
        let opsBefore = h.doc._opLogMirror.count

        // Called directly, as a future second caller would.
        try await h.doc.reopenAcceptedTextlessAnnotation(id: sid)

        XCTAssertEqual(h.doc._opLogMirror.count, opsBefore,
                       "a suggestion must not get a bare reopen — nothing appended")
        XCTAssertEqual(annotation(h.doc, sid)?.status, .accepted,
                       "…so the note does not reopen over prose that stayed spliced")
        XCTAssertEqual(h.doc.paragraphs[h.pid], "One paragraph.")

        // The same door on an id that is not an annotation creation op at all.
        try await h.doc.reopenAcceptedTextlessAnnotation(id: "not-an-op")
        XCTAssertEqual(h.doc._opLogMirror.count, opsBefore,
                       "an unknown id appends nothing either")
    }

    /// The other half of the same boundary, at the factory: the door the
    /// textless undo opens stays shut for a suggestion, because only the
    /// caller can tell the two apart and the default is the refusal.
    func test_theFactoryStillRefusesABareReopenOfASplicedAccept() {
        switch AnnotationInverse.reopenOp(
            undoing: .claudeAccept, annotationId: "x", currentStatus: .accepted,
            docId: "d", device: "dev", session: "s") {
        case .declined(.noInverse(.claudeAccept)):
            break
        case let other:
            XCTFail("a spliced accept must still decline; got \(other)")
        }
    }
}
