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

    /// **The control for the two restores below** (#41 A2). A stet placed over
    /// an OPEN note displaced no resolution, so its undo has nothing to put
    /// back and must append the reopen ALONE. The restore is a SECOND op; run
    /// unconditionally it would settle every reopened note `.accepted` — undo
    /// inventing a resolution nobody chose, which is the same failure the
    /// restore exists to prevent from the other direction.
    func test_undoOfAStetOverAnOpenNoteStillJustReopens() async throws {
        let h = try await makeHarness(prefix: "Stet-UndoOpenControl")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "note")
        let um = UndoManager()

        try await h.doc.stetAnnotation(id: cid, undoManager: um)
        let opsAfterStet = h.doc._opLogMirror.count

        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(h.doc, cid)?.status, .open)
        XCTAssertEqual(h.doc._opLogMirror.count, opsAfterStet + 1,
                       "exactly one op — the reopen. Nothing was re-applied over it")
        XCTAssertEqual(h.doc._opLogMirror.suffix(1).map(\.kind),
                       [.annotationReopen])
    }

    // MARK: - ⌘Z over a note that was ALREADY resolved (#41 A2)

    /// **Undoing a stet puts back the resolution it displaced.** Stet refuses
    /// nothing on the way in — the deriver's latest-lifecycle-op-wins rule
    /// settles a stet over an earlier resolution — and the queue's row OFFERS
    /// Stet on an accepted comment (`AnnotationRow.showsReopen` is `false` for
    /// `.accepted`, so with show-resolved on the row draws its dispositions,
    /// Stet among them; `test_theRowsStetReachesAnAcceptedNote` pins that).
    /// Press it, change your mind, press ⌘Z: before the fix the note came back
    /// `.open` and the reply the writer typed into **Reply…** was gone. One
    /// ⌘Z had taken two of their decisions — M5-AN-036's shape, arriving at
    /// the fourth resolution.
    func test_undoOfAStetOverAnAcceptedNoteRestoresTheAcceptAndItsReply() async throws {
        let h = try await makeHarness(prefix: "Stet-UndoOverAccept")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "is this too florid?")
        // The textless accept arm — "Got it" / "Reply…" with the writer's own
        // words. Nothing is spliced, so the reply is all there is to lose.
        try await h.doc.acceptAnnotation(id: cid, userResponse: "yes — cut it")
        XCTAssertEqual(annotation(h.doc, cid)?.status, .accepted)
        let um = UndoManager()

        try await h.doc.stetAnnotation(
            id: cid, userResponse: "second thoughts: it stands", undoManager: um)
        XCTAssertEqual(annotation(h.doc, cid)?.status, .stetted)
        let opsAfterStet = h.doc._opLogMirror.count

        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(h.doc, cid)?.status, .accepted,
                       "not .open — the accept the stet displaced is back")
        XCTAssertEqual(annotation(h.doc, cid)?.userResponse, "yes — cut it",
                       "and back WHOLE: the writer's Reply… text returns with it")
        // ADR 0023: two compensating ops, appended in order. Nothing truncated.
        XCTAssertEqual(
            h.doc._opLogMirror.suffix(2).map(\.kind),
            [.annotationReopen, .claudeAccept],
            "the reopen clears the stet; the accept re-applies what it displaced")
        XCTAssertEqual(h.doc._opLogMirror.count, opsAfterStet + 2)
        XCTAssertTrue(
            h.doc._opLogMirror.contains { $0.kind == .annotationStet },
            "the stet op survives its own undo")
    }

    /// The same claim for a rejection, whose written reason is the thing a
    /// writer would most notice losing. `.rejected → .claudeReject`, carrying
    /// the reason forward — `withdrawReviewerAnnotation`'s arms, exactly.
    func test_undoOfAStetOverARejectedNoteRestoresTheReject() async throws {
        let h = try await makeHarness(prefix: "Stet-UndoOverReject")
        let cid = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pid,
            body: "tighten this", suggestedText: "A paragraph.")
        try await h.doc.rejectAnnotation(
            id: cid, userResponse: "the rhythm needs the extra beat")
        XCTAssertEqual(annotation(h.doc, cid)?.status, .rejected)
        let um = UndoManager()

        try await h.doc.stetAnnotation(id: cid, undoManager: um)
        let opsAfterStet = h.doc._opLogMirror.count

        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(h.doc, cid)?.status, .rejected)
        XCTAssertEqual(annotation(h.doc, cid)?.userResponse,
                       "the rhythm needs the extra beat",
                       "a reject returns with its reason (M5-AN-036's fidelity rule)")
        XCTAssertEqual(
            h.doc._opLogMirror.suffix(2).map(\.kind),
            [.annotationReopen, .claudeReject])
        XCTAssertEqual(h.doc._opLogMirror.count, opsAfterStet + 2)
    }

    /// The third arm of the restore switch. An ARCHIVED note is one the writer
    /// set aside unread; stetting it says something different ("read, and the
    /// words stand"), and ⌘Z must put the setting-aside back rather than
    /// leaving the note open in a queue the writer had deliberately cleared it
    /// from. `.archived → .claudeArchive`, the switch's remaining arm.
    func test_undoOfAStetOverAnArchivedNoteRestoresTheArchive() async throws {
        let h = try await makeHarness(prefix: "Stet-UndoOverArchive")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "for later")
        try await h.doc.archiveAnnotation(id: cid)
        XCTAssertEqual(annotation(h.doc, cid)?.status, .archived)
        let um = UndoManager()

        try await h.doc.stetAnnotation(id: cid, undoManager: um)
        XCTAssertEqual(annotation(h.doc, cid)?.status, .stetted)
        let opsAfterStet = h.doc._opLogMirror.count

        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertEqual(annotation(h.doc, cid)?.status, .archived,
                       "not .open — the archive the stet displaced is back")
        XCTAssertEqual(
            h.doc._opLogMirror.suffix(2).map(\.kind),
            [.annotationReopen, .claudeArchive])
        XCTAssertEqual(h.doc._opLogMirror.count, opsAfterStet + 2)
    }

    /// **The prior is re-captured on every pass, not remembered from the
    /// first.** ⌘Z restores the accept; ⇧⌘Z re-stets by calling
    /// `stetAnnotation` FORWARD, which reads the live status (`.accepted`
    /// again) and captures it afresh; so the second ⌘Z restores the accept and
    /// its reply exactly as the first did. A registration that closed over the
    /// first pass's capture would pass a single cycle and fail here — and
    /// silently, since a `.open` note looks like an ordinary reopen.
    func test_theStetCycleRestoresTheAcceptEveryTimeNotJustOnce() async throws {
        let h = try await makeHarness(prefix: "Stet-CycleRecapture")
        let cid = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "is this too florid?")
        try await h.doc.acceptAnnotation(id: cid, userResponse: "yes — cut it")
        let um = UndoManager()

        try await h.doc.stetAnnotation(
            id: cid, userResponse: "second thoughts: it stands", undoManager: um)

        um.undo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(h.doc, cid)?.status, .accepted)
        XCTAssertEqual(annotation(h.doc, cid)?.userResponse, "yes — cut it")

        XCTAssertTrue(um.canRedo)
        um.redo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(h.doc, cid)?.status, .stetted)
        XCTAssertEqual(annotation(h.doc, cid)?.userResponse,
                       "second thoughts: it stands",
                       "the redo forwards the writer's own stet reply")

        XCTAssertTrue(um.canUndo, "the forward re-stet re-registered undo")
        um.undo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(annotation(h.doc, cid)?.status, .accepted,
                       "the second ⌘Z restores the accept too — the redo's own "
                       + "capture, not the first pass's")
        XCTAssertEqual(annotation(h.doc, cid)?.userResponse, "yes — cut it",
                       "with the reply, still")
    }

    /// **When the re-apply fails, the writer hears it** (RULING-22, #41's
    /// final review). The reopen lands and the second op does not, so the note
    /// sits in the queue OPEN with its accept gone — which from the queue is
    /// indistinguishable from the pre-A2 defect. Logging that and saying
    /// nothing leaves the writer to report a fixed bug.
    ///
    /// **Forcing exactly that half-failure.** Both ops go through
    /// `opStore.append`, so a lock taken before ⌘Z would fail the REOPEN too
    /// and the note would stay `.stetted` — a different case, and one where
    /// "it's open again" would be a lie. The window between them is the
    /// `.maughamAnnotationsChanged` post: `appendAnnotationOpInternal` posts it
    /// synchronously at the END of a successful append, so an observer armed
    /// just before `um.undo()` fires INSIDE the undo closure, after the reopen
    /// has landed in the log and before the restore's append opens the file.
    /// Making the op-log files read-only there fails the second op only — and
    /// `lockedAfterTheReopen` is asserted, so a test that armed but never fired
    /// cannot pass by taking a shortcut through a different failure.
    func test_aFailedRestoreOfThePriorResolutionSaysSoRatherThanOnlyLogging() async throws {
        let (projectURL, docURL) = try makeTestProject(
            prefix: "Stet-RestoreFails", initialMd: "A single paragraph.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        let cid = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "is this too florid?")
        try await doc.acceptAnnotation(id: cid, userResponse: "yes — cut it")
        let um = UndoManager()
        try await doc.stetAnnotation(
            id: cid, userResponse: "it stands", undoManager: um)
        XCTAssertEqual(annotation(doc, cid)?.status, .stetted)

        let originals = try opLogModes(in: projectURL)
        defer { restoreModes(originals) }

        var lockedAfterTheReopen = false
        let armed = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamAnnotationsChanged, object: nil, queue: nil
        ) { _ in
            guard !lockedAfterTheReopen else { return }
            lockedAfterTheReopen = true
            lockForWriting(originals)
        }
        defer { NotificationCenter.default.removeObserver(armed) }

        let said = await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }

        XCTAssertTrue(lockedAfterTheReopen,
                      "premise: the reopen landed and armed the lock — without "
                      + "this the test could pass off a different failure")
        XCTAssertEqual(said, [
            "Couldn't put back the note's earlier resolution — it's open again."])
        XCTAssertEqual(annotation(doc, cid)?.status, .open,
                       "the sentence is true: the reopen stands, the accept did not "
                       + "come back")
    }

    /// **The other side of that sentence: when the REOPEN fails, nothing is
    /// said** (Denver's ruling on the final review). The note never left
    /// `.stetted`, so "it's open again" would be a lie about the queue the
    /// writer is looking at — and there is nothing to be sorry about either,
    /// because nothing moved: no resolution was displaced-and-not-put-back.
    /// The restore waits on the reopen, and this branch leaves a failed reopen
    /// exactly as loud as it has always been (the log alone).
    ///
    /// Forcing it is the easy direction — lock the op-log files BEFORE ⌘Z and
    /// the first append is the one that fails.
    func test_aFailedReopenRestoresNothingAndSaysNothing() async throws {
        let (projectURL, docURL) = try makeTestProject(
            prefix: "Stet-ReopenFails", initialMd: "A single paragraph.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        let cid = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "is this too florid?")
        try await doc.acceptAnnotation(id: cid, userResponse: "yes — cut it")
        let um = UndoManager()
        try await doc.stetAnnotation(
            id: cid, userResponse: "it stands", undoManager: um)
        XCTAssertEqual(annotation(doc, cid)?.status, .stetted)
        let opsBefore = doc._opLogMirror.count

        let originals = try opLogModes(in: projectURL)
        defer { restoreModes(originals) }
        lockForWriting(originals)

        let said = await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }

        XCTAssertEqual(said, [], "nothing moved, so there is nothing to say")
        XCTAssertEqual(annotation(doc, cid)?.status, .stetted,
                       "the note never left .stetted — which is why the "
                       + "open-again sentence would have been false")
        XCTAssertEqual(doc._opLogMirror.count, opsBefore,
                       "and no op landed: neither the reopen nor the restore")
    }

    /// **The fact that makes the restores above reachable.** A2 is not a theoretical
    /// arm of a permissive verb: with show-resolved on, the queue's row for an
    /// ACCEPTED comment draws its dispositions — `AnnotationRow.showsReopen` is
    /// `false` for `.accepted`, so the `else` branch runs — and every
    /// `dispositions` arm offers `stetButton`. Both are `private` to
    /// `AnnotationRow`, and a row's verbs are only observable mounted, so this
    /// is a SOURCE census in the idiom the two censuses below already use in
    /// this file — the same technique for the same reason: nothing else binds
    /// the claim.
    func test_theRowsStetReachesAnAcceptedNote() throws {
        let pane = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham/Views/AnnotationsPane.swift")
        let text = try String(contentsOf: pane, encoding: .utf8)
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        XCTAssertTrue(
            flat.contains("private var showsReopen: Bool { switch annotation.status"
                          + " { case .archived, .rejected, .stetted: return true"
                          + " case .open, .accepted: return false } }"),
            "an accepted row does NOT swap its verbs for Reopen — it draws "
            + "`dispositions`, which is how Stet reaches a resolved note")

        let builder = try XCTUnwrap(
            flat.range(of: "private func dispositions(useIcons: Bool) -> some View {"),
            "control: the row's disposition builder is still named this")
        let body = String(flat[builder.upperBound...])
        let commentArm = try XCTUnwrap(
            body.range(of: "case .comment:").flatMap { start in
                body.range(of: "case .suggestedChange:").map {
                    String(body[start.upperBound..<$0.lowerBound])
                }
            },
            "control: the comment arm is still the first of the four")
        XCTAssertTrue(commentArm.contains("stetButton("),
                      "an accepted COMMENT's row offers Stet — the reachable "
                      + "path A2's undo has to be right about")
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
            "Couldn't undo stetting the note — it changed on another device."])
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

    /// **The verbs have faces, and the two do not have the SAME face** (M3 P2
    /// Task 4). A verb with no production caller is the shape M1A's
    /// `RegionBinding.references` shipped in — correct, tested, and reachable by
    /// nobody — so both halves are pinned here rather than left to the eye.
    ///
    /// Stet is a resolution: it reaches the writer from the queue AND from the
    /// margin card, exactly like archive. Triage is a MARK, and marks are how a
    /// writer plans a pass over a pile — the margin card is one note beside the
    /// sentence it is about, with no pile to sort, so its absence from
    /// `EditorHost` is a decision. `ReviewCardActions`' doc comment says so in
    /// prose and `ReviewCardActionsTests` says so about the declared set; this
    /// says it about the WIRING, which is the layer where a later hand adding a
    /// triage handler would not contradict either.
    func test_theVerbsProductionCallers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham")
        let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "control: the scan found the sources")

        func callers(of call: String) -> Set<String> {
            var found: Set<String> = []
            for file in files {
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      text.contains(call) else { continue }
                found.insert(file.lastPathComponent)
            }
            return found
        }

        XCTAssertEqual(callers(of: "stetAnnotation("), [
            "Document+Annotations.swift",   // the definition (+ its own redo)
            "AnnotationsPane.swift",        // the queue's Stet button
            "EditorHost.swift",             // the margin card's Stet handler
            "AnnotationBulkActions.swift",  // (Task 5) the bulk bar's executor
        ], "the stet caller census — update deliberately, never accidentally")

        XCTAssertEqual(callers(of: "triageAnnotation("), [
            "Document+Annotations.swift",   // the definition (+ its own redo)
            "AnnotationsPane.swift",        // the row's Do / Decline / Discuss menu
            "AnnotationBulkActions.swift",  // (Task 5) the bulk bar's executor
        ], "triage is a queue verb: a margin-card caller here is a design change")
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

// MARK: - Failing an op-log append on purpose

/// The two tests above that force an append to fail share these. They are FILE
/// SCOPE rather than methods because one of them runs inside a `@Sendable`
/// NotificationCenter observer block, which cannot capture a `@MainActor` test
/// case.
///
/// **It is the FILE's permission that matters here, not the directory's.**
/// `JSONLAppendStore.append` opens an existing log with
/// `FileHandle(forWritingTo:)` and only writes a new file when none exists — so
/// the `0o500`-on-the-ops-directory idiom used elsewhere in this suite blocks
/// file CREATION and would let both of these appends straight through.
private func opLogModes(in projectURL: URL) throws -> [(URL, NSNumber)] {
    let fm = FileManager.default
    let logs = try fm.contentsOfDirectory(
        at: projectURL.appendingPathComponent(".maugham/ops"),
        includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jsonl" }
    XCTAssertFalse(logs.isEmpty, "premise: this doc has an op log on disk")
    return try logs.map {
        ($0, try XCTUnwrap(
            fm.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber))
    }
}

private func lockForWriting(_ modes: [(URL, NSNumber)]) {
    for (url, _) in modes {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o400], ofItemAtPath: url.path)
    }
}

private func restoreModes(_ modes: [(URL, NSNumber)]) {
    for (url, mode) in modes {
        try? FileManager.default.setAttributes(
            [.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
