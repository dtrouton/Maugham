import XCTest
import MaughamCore
@testable import Maugham

/// The `Document`'s one writer-facing channel, and the three occasions that
/// need it.
///
/// All three used to end at `documentLog` and nowhere else. Two are declines —
/// a ⌘Z the document refuses because it drifted (RULING-7 / M4-RW-026,
/// RULING-22 / M5-AN-019) — and one is a report the writer is owed after the
/// fact (RULING-32 / M5-AN-041, the typing sweep's batched summary). The
/// declines themselves are correct and stay; what these tests pin is that the
/// writer hears about them.
///
/// The channel is `.maughamDocumentNotice`, project-scoped, rendered by
/// `RewindModifier`'s toast. `MaughamEventLivenessTests` owns the scope filter;
/// what is asserted here is the post — the half that did not exist.
@MainActor
final class DocumentNoticeTests: XCTestCase {

    /// Collects every notice posted while the block runs, in order.
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

    /// Every notice carries the project scope, so a second window on a
    /// different project cannot report a decline that was not its own.
    private func scopeIds(
        during body: () async throws -> Void
    ) async rethrows -> [String?] {
        var seen: [String?] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            seen.append(note.userInfo?[MaughamEvent.scopeIdKey] as? String)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return seen
    }

    // MARK: - RULING-32: the sweep reports at the pause

    /// The writer deleted a paragraph carrying an open note. Maugham archived
    /// the note on their behalf — defensible — and said nothing at all, which
    /// is not. The report lands at the BURST BOUNDARY, which is the writing
    /// pause: quiet, batched, after the fact, never a prompt.
    func test_theSweepReportsWhatItArchived_atTheBurstBoundary() async throws {
        let (_, docURL) = try makeTestProject(
            prefix: "Notice-Sweep", initialMd: "One.\n\nTwo.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid2 = try XCTUnwrap(doc.sequence.last)
        _ = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid2, body: "a note on the second")

        let said = try await notices {
            // Delete the second paragraph, the way typing does.
            doc.setFullText("One.\n")
            try await doc.flushBurstNow()
        }
        XCTAssertEqual(said, ["While you edited: 1 note archived."])
    }

    /// Batched means batched: four notes going in one burst is one sentence
    /// with a number in it, not four sentences.
    func test_aBurstThatArchivesSeveralNotesIsOneSentence() async throws {
        let (_, docURL) = try makeTestProject(
            prefix: "Notice-Batch", initialMd: "One.\n\nTwo.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid2 = try XCTUnwrap(doc.sequence.last)
        for i in 1...3 {
            _ = try await doc.addAnnotation(
                kind: .comment, paragraphId: pid2, body: "note \(i)")
        }

        let said = try await notices {
            doc.setFullText("One.\n")
            try await doc.flushBurstNow()
        }
        XCTAssertEqual(said, ["While you edited: 3 notes archived."])
    }

    /// Silent in the moment. The sweep runs at the flush, so the deletion
    /// itself must say nothing — that is the difference between the ruling's
    /// chosen option and the tell-at-the-time one it rejected.
    func test_theDeletionItselfSaysNothing() async throws {
        let (_, docURL) = try makeTestProject(
            prefix: "Notice-Quiet", initialMd: "One.\n\nTwo.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid2 = try XCTUnwrap(doc.sequence.last)
        _ = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid2, body: "a note")

        let said = try await notices { doc.setFullText("One.\n") }
        XCTAssertEqual(said, [], "typing is never interrupted")
    }

    /// And a burst that swept nothing says nothing — the report is not a
    /// heartbeat.
    func test_aBurstThatArchivedNothingIsSilent() async throws {
        let (_, docURL) = try makeTestProject(
            prefix: "Notice-None", initialMd: "One.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        let said = try await notices {
            doc.setFullText("One. And more.\n")
            try await doc.flushBurstNow()
        }
        XCTAssertEqual(said, [])
    }

    /// The count is reset by the report, so the next pause does not re-announce
    /// notes the writer has already been told about.
    func test_theCountIsSpentWhenItIsReported() async throws {
        let (_, docURL) = try makeTestProject(
            prefix: "Notice-Spent", initialMd: "One.\n\nTwo.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid2 = try XCTUnwrap(doc.sequence.last)
        _ = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid2, body: "a note")

        doc.setFullText("One.\n")
        try await doc.flushBurstNow()

        let said = try await notices {
            doc.setFullText("One. Again.\n")
            try await doc.flushBurstNow()
        }
        XCTAssertEqual(said, [])
    }

    // MARK: - RULING-7: the rewind undo's decline

    /// The writer pressed ⌘Z on a menu item reading "Undo Restore from
    /// History". The document had drifted under it, so declining is right —
    /// and the refusal must name its real cause and point at the tool that
    /// CAN get them back.
    func test_theRewindUndoDeclineReachesTheWriter() async throws {
        let (_, docURL) = try makeTestProject(
            prefix: "Notice-Rewind", initialMd: "Original sentence here.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        doc.setFullText("Original sentence here.\n\nSecond.\n")
        try await doc.flushBurstNow()
        let ops = try await doc.opLog()
        let bootstrap = try XCTUnwrap(
            ops.first { $0.kind == .bootstrap }?.opId)

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: bootstrap, undoManager: um)

        // A peer's merged edit lands after the restore.
        doc.setParagraph(id: pid, text: "Something a peer wrote.")
        try await doc.flushBurstNow()

        let said = await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, [
            "Couldn't undo the restore — the document has changed since. "
            + "History Rewind can take you back."])
    }

    /// The control: an undo that SUCCEEDS says nothing. A notice on every ⌘Z
    /// would be its own kind of noise, and would make the decline invisible by
    /// making it ordinary.
    func test_aRewindUndoThatSucceedsIsSilent() async throws {
        let (_, docURL) = try makeTestProject(
            prefix: "Notice-RewindOK", initialMd: "Original sentence here.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        doc.setFullText("Original sentence here.\n\nSecond.\n")
        try await doc.flushBurstNow()
        let ops = try await doc.opLog()
        let bootstrap = try XCTUnwrap(
            ops.first { $0.kind == .bootstrap }?.opId)

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: bootstrap, undoManager: um)

        let said = await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, [])
    }

    // MARK: - RULING-22: the annotation-edit undo's decline

    /// Same channel, same shape: the Edit menu read "Undo Edit Annotation", the
    /// annotation had moved on under it, and the guard that stops the clobber
    /// declined to the log alone.
    func test_theAnnotationEditUndoDeclineReachesTheWriter() async throws {
        let (_, docURL) = try makeTestProject(
            prefix: "Notice-Edit", initialMd: "Alpha.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        let cid = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: pid, span: nil, body: "original",
            authorName: "D")
        let um = UndoManager()
        try await doc.editReviewerAnnotation(
            id: cid, newBody: "first edit", newSuggestedText: nil,
            authorName: "D", undoManager: um)
        // Something else moves the annotation on — a second Mac's merge, in
        // production; a second unregistered edit here.
        try await doc.editReviewerAnnotation(
            id: cid, newBody: "moved on", newSuggestedText: nil, authorName: "D")

        let said = await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, [
            "Couldn't undo the annotation edit — it changed on another device."])
    }

    /// The control again: an undrifted undo reverts and stays quiet.
    func test_anAnnotationEditUndoThatSucceedsIsSilent() async throws {
        let (_, docURL) = try makeTestProject(
            prefix: "Notice-EditOK", initialMd: "Alpha.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        let cid = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: pid, span: nil, body: "original",
            authorName: "D")
        let um = UndoManager()
        try await doc.editReviewerAnnotation(
            id: cid, newBody: "first edit", newSuggestedText: nil,
            authorName: "D", undoManager: um)

        let said = await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, [])
        XCTAssertEqual(
            doc.annotations(filter: AnnotationFilter(statuses: nil))
                .first { $0.id == cid }?.body, "original")
    }

    // MARK: - The scope

    /// Every notice is `.project`-scoped and carries the project's identifier,
    /// not the document's file URL — which is what lets `RewindModifier`'s
    /// `.onProjectEvent` drop one belonging to another window's project
    /// (ADR 0021).
    func test_everyNoticeCarriesItsProjectScope() async throws {
        let (dir, docURL) = try makeTestProject(
            prefix: "Notice-Scope", initialMd: "One.\n\nTwo.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid2 = try XCTUnwrap(doc.sequence.last)
        _ = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid2, body: "a note")

        let ids = try await scopeIds {
            doc.setFullText("One.\n")
            try await doc.flushBurstNow()
        }
        XCTAssertEqual(ids, [ProjectIdentifier.id(for: dir)])
    }

    /// The receiving end, as a wiring census rather than a mounted window: the
    /// notice has a subscriber, and it is the modifier that owns the toast. A
    /// post with nobody listening is the same silence this whole suite exists
    /// to end, and it would pass every assertion above.
    func test_theProjectWindowSubscribesToTheNotice() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpLog/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
        let source = try String(
            contentsOf: root.appendingPathComponent("Maugham/Views/ProjectWindow.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            source.contains(".onProjectEvent(.maughamDocumentNotice"),
            "ProjectWindow must receive the notice through the project-scoped "
            + "helper — the liveness guard is what keeps a closed window from "
            + "announcing a decline it did not see")
        XCTAssertTrue(
            source.contains("restoreToast = message"),
            "and render it in the toast RewindModifier already owns, rather "
            + "than a second overlay that could stack with a restore report")
    }
}
