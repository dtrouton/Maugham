import XCTest
import MaughamCore
@testable import Maugham

/// **The manuscript's Accept over text it already applied** (R-B; hardening
/// 11-11 Task 5). The figure race, run against a manuscript suggestion: this
/// Mac accepts, another device's newer reject / archive / stet wins (latest
/// lifecycle op wins), the writer Reopens, and Accepts again.
///
/// - A peer REJECT is repaired by RULING-33 at the merge (the text goes back
///   to the original before any Reopen), so the second accept is ordinary.
/// - A peer ARCHIVE or STET triggers no repair, so the note reopens over its
///   own splice. Before the guard the second Accept wrote a change whose
///   before-text equalled its after-text, or spliced the suggestion in twice,
///   and neither ⌘Z nor Revert could reach the original again. Now the accept
///   is status-only (`SuggestionSplice.planAccept`, shared with the phone):
///   its ⌘Z reopens the note and leaves the text, its ⇧⌘Z re-accepts, and
///   the pane's Revert restores the pre-accept text through the newest
///   accept that carries one (`SuggestionSplice.newestAppliedAccept`).
@MainActor
final class AcceptOverAppliedTextTests: XCTestCase {

    private struct Raced { let dir: URL; let doc: Document; let pid: String; let id: String }

    private static let original = "Alpha original."
    private static let suggested = "Alpha SUGGESTED."

    private func status(_ doc: Document, _ id: String) -> AnnotationStatus? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }?.status
    }

    /// Another device's lifecycle line, as a synced file brings it: a newer
    /// opId than this Mac's accept, so it wins the status.
    private func peerOp(_ kind: OpKind, for id: String, doc: Document) -> Op {
        Op(opId: ULID.generate(), docId: doc.docId, at: Date(),
           device: "peer-mac", session: "peer-session",
           kind: kind, changes: [], sequence: nil,
           provenance: Op.Provenance(sessionId: "peer-session", sourceAnnotationId: id))
    }

    private func accepts(_ doc: Document, _ id: String) -> [Op] {
        doc.opLogSnapshot.filter {
            $0.kind == .claudeAccept && $0.provenance?.sourceAnnotationId == id
        }
    }

    /// The invariant R-B is about, read off the op log ON DISK: no accept or
    /// revert line records a before-text equal to its after-text.
    private func linesRecordingTheirOwnText(_ r: Raced) async throws -> [Op] {
        try await OpLogStore(projectURL: r.dir).load(docId: r.doc.docId).filter { op in
            (op.kind == .claudeAccept || op.kind == .claudeAcceptRevert)
                && op.changes.contains { $0.prior == $0.next }
        }
    }

    /// Accept → the peer's `peer` line merges → Reopen. Returns with the note
    /// open, ready for the second Accept.
    private func raceThenReopen(
        _ prefix: String, peer: OpKind, original: String = original,
        suggestion: String = suggested, span: SpanAnchor? = nil
    ) async throws -> Raced {
        let (dir, docURL) = try makeTestProject(prefix: prefix, initialMd: "\(original)\n")
        let doc = try await Document.load(url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        let id = try await doc.addAnnotation(kind: .suggestedChange, paragraphId: pid,
                                             body: "b", suggestedText: suggestion, span: span)
        try await doc.acceptAnnotation(id: id)
        try await OpLogStore(projectURL: dir).append(peerOp(peer, for: id, doc: doc))
        try await doc.handleExternalLogChange()
        XCTAssertNotEqual(status(doc, id), .accepted, "premise: the peer's newer line wins")
        try await doc.reopenAnnotation(id: id)
        XCTAssertEqual(status(doc, id), .open, "premise: reopened")
        return Raced(dir: dir, doc: doc, pid: pid, id: id)
    }

    // MARK: - Safe: the reject route (RULING-33 repairs first)

    func test_aPeerRejectIsRepairedFirst_soTheSecondAcceptIsOrdinary() async throws {
        let r = try await raceThenReopen("AOAT-reject", peer: .claudeReject)
        XCTAssertEqual(r.doc.paragraph(id: r.pid), Self.original,
                       "the RULING-33 repair took the splice out at the merge")
        let um = UndoManager()

        try await r.doc.acceptAnnotation(id: r.id, undoManager: um)

        let second = try XCTUnwrap(accepts(r.doc, r.id).last?.changes.first)
        XCTAssertEqual(second.prior, Self.original)
        XCTAssertEqual(second.next, Self.suggested)
        um.undo(); await r.doc.awaitPendingUndoWork()
        XCTAssertEqual(r.doc.paragraph(id: r.pid), Self.original, "⌘Z reaches the original")
        um.redo(); await r.doc.awaitPendingUndoWork()
        try await r.doc.revertAcceptedAnnotation(id: r.id)
        XCTAssertEqual(r.doc.paragraph(id: r.pid), Self.original, "and so does Revert")
        await r.doc.close()
    }

    // MARK: - The archive / stet route: guarded

    func test_aPeerArchive_theSecondAcceptIsStatusOnly_andRevertReachesTheOriginal() async throws {
        let r = try await raceThenReopen("AOAT-archive", peer: .claudeArchive)
        XCTAssertEqual(r.doc.paragraph(id: r.pid), Self.suggested, "premise: open over its own text")

        try await r.doc.acceptAnnotation(id: r.id)

        let second = try XCTUnwrap(accepts(r.doc, r.id).last)
        XCTAssertEqual(accepts(r.doc, r.id).count, 2)
        XCTAssertTrue(second.changes.isEmpty, "status only: the splice is already in the text")
        XCTAssertEqual(status(r.doc, r.id), .accepted)
        XCTAssertEqual(r.doc.paragraph(id: r.pid), Self.suggested)
        let none = try await linesRecordingTheirOwnText(r)
        XCTAssertEqual(none, [])
        try await r.doc.revertAcceptedAnnotation(id: r.id)
        XCTAssertEqual(r.doc.paragraph(id: r.pid), Self.original, "Revert reaches the original")
        XCTAssertEqual(status(r.doc, r.id), .open)
        await r.doc.close()
    }

    func test_aPeerStet_theSecondAcceptIsStatusOnly_andRevertReachesTheOriginal() async throws {
        let r = try await raceThenReopen("AOAT-stet", peer: .annotationStet)

        try await r.doc.acceptAnnotation(id: r.id)

        XCTAssertEqual(accepts(r.doc, r.id).last?.changes, [])
        XCTAssertEqual(status(r.doc, r.id), .accepted)
        let none = try await linesRecordingTheirOwnText(r)
        XCTAssertEqual(none, [])
        try await r.doc.revertAcceptedAnnotation(id: r.id)
        XCTAssertEqual(r.doc.paragraph(id: r.pid), Self.original)
        await r.doc.close()
    }

    /// Ruling 4b: ⌘Z of a guarded accept undoes exactly what it did — the
    /// note reopens and the text stays; ⇧⌘Z re-accepts, guarded again. Run
    /// twice round so the whole log can be checked for self-recording lines.
    func test_theGuardedAcceptsUndoReopensAndLeavesTheText_andRedoReacceptsStatusOnly() async throws {
        let r = try await raceThenReopen("AOAT-undo", peer: .claudeArchive)
        let um = UndoManager()
        try await r.doc.acceptAnnotation(id: r.id, undoManager: um)
        XCTAssertEqual(um.undoActionName, "Accept Suggestion")

        for _ in 0..<2 {
            um.undo(); await r.doc.awaitPendingUndoWork()
            XCTAssertEqual(status(r.doc, r.id), .open, "⌘Z reopens the note")
            XCTAssertEqual(r.doc.paragraph(id: r.pid), Self.suggested, "and leaves the text")
            XCTAssertEqual(r.doc.opLogSnapshot.last?.kind, .annotationReopen)
            XCTAssertEqual(r.doc.opLogSnapshot.last?.changes, [])

            um.redo(); await r.doc.awaitPendingUndoWork()
            XCTAssertEqual(status(r.doc, r.id), .accepted, "⇧⌘Z re-accepts")
            XCTAssertEqual(accepts(r.doc, r.id).last?.changes, [], "guarded again")
            XCTAssertEqual(r.doc.paragraph(id: r.pid), Self.suggested)
        }
        let none = try await linesRecordingTheirOwnText(r)
        XCTAssertEqual(none, [], "no accept or revert in the log records its own text")
        try await r.doc.revertAcceptedAnnotation(id: r.id)
        XCTAssertEqual(r.doc.paragraph(id: r.pid), Self.original, "Revert still reaches the original")
        await r.doc.close()
    }

    /// The guarded accept's ⌘Z re-checks at fire time: a note another device
    /// moved since is not reopened, and nothing is appended.
    func test_theGuardedAcceptsUndo_declinesOnceAnotherDeviceMovedTheNote() async throws {
        let r = try await raceThenReopen("AOAT-undo-drift", peer: .claudeArchive)
        let um = UndoManager()
        try await r.doc.acceptAnnotation(id: r.id, undoManager: um)
        try await OpLogStore(projectURL: r.dir).append(peerOp(.claudeArchive, for: r.id, doc: r.doc))
        try await r.doc.handleExternalLogChange()
        XCTAssertEqual(status(r.doc, r.id), .archived, "premise")
        let before = r.doc.opLogSnapshot.count

        um.undo(); await r.doc.awaitPendingUndoWork()

        XCTAssertEqual(r.doc.opLogSnapshot.count, before, "nothing appended")
        XCTAssertEqual(status(r.doc, r.id), .archived)
        await r.doc.close()
    }

    // MARK: - Spans

    /// A span whose suggestion contains its own quote ("dark" → "very dark")
    /// used to re-resolve inside the applied text and splice a second time.
    func test_aSpanContainingItsQuote_isNotAppliedTwice() async throws {
        let r = try await raceThenReopen(
            "AOAT-span-twice", peer: .claudeArchive,
            original: "The night was dark and cold.", suggestion: "very dark",
            span: SpanAnchor(quote: "dark", prefix: "was ", suffix: " and", posHint: 14))
        XCTAssertEqual(r.doc.paragraph(id: r.pid), "The night was very dark and cold.")

        try await r.doc.acceptAnnotation(id: r.id)

        XCTAssertEqual(r.doc.paragraph(id: r.pid), "The night was very dark and cold.",
                       "the suggestion is in the text once")
        XCTAssertEqual(accepts(r.doc, r.id).last?.changes, [])
        try await r.doc.revertAcceptedAnnotation(id: r.id)
        XCTAssertEqual(r.doc.paragraph(id: r.pid), "The night was dark and cold.",
                       "Revert reaches the original")
        await r.doc.close()
    }

    /// Ruling 4a: a span whose quote the splice itself replaced used to
    /// refuse as anchor-lost and strand the note open over its own text. The
    /// splice is in place, so it is accepted status-only.
    func test_aSpanWhoseQuoteTheSpliceReplaced_isAcceptedStatusOnly() async throws {
        let r = try await raceThenReopen(
            "AOAT-span-replaced", peer: .claudeArchive,
            original: "The night was very dark and cold.", suggestion: "pitch black",
            span: SpanAnchor(quote: "very dark", prefix: "was ", suffix: " and", posHint: 14))

        try await r.doc.acceptAnnotation(id: r.id)

        XCTAssertEqual(status(r.doc, r.id), .accepted)
        XCTAssertEqual(accepts(r.doc, r.id).last?.changes, [])
        XCTAssertEqual(r.doc.paragraph(id: r.pid), "The night was pitch black and cold.")
        try await r.doc.revertAcceptedAnnotation(id: r.id)
        XCTAssertEqual(r.doc.paragraph(id: r.pid), "The night was very dark and cold.")
        await r.doc.close()
    }

    /// The refusal stays where the splice is NOT in place: the writer rewrote
    /// the paragraph after the reopen, so the quote is truly gone (RULING-5).
    func test_aSpanWhoseQuoteTheWriterRewroteAway_stillRefuses() async throws {
        let r = try await raceThenReopen(
            "AOAT-span-gone", peer: .claudeArchive,
            original: "The night was very dark and cold.", suggestion: "pitch black",
            span: SpanAnchor(quote: "very dark", prefix: "was ", suffix: " and", posHint: 14))
        r.doc.setParagraph(id: r.pid, text: "Rain fell all evening.")
        try await r.doc.flushBurstNow()
        let before = r.doc.opLogSnapshot.count

        do {
            try await r.doc.acceptAnnotation(id: r.id)
            XCTFail("expected anchor lost")
        } catch AnnotationAcceptError.suggestionAnchorLost {}

        XCTAssertEqual(r.doc.opLogSnapshot.count, before, "nothing appended")
        XCTAssertEqual(r.doc.paragraph(id: r.pid), "Rain fell all evening.")
        XCTAssertEqual(status(r.doc, r.id), .open)
        await r.doc.close()
    }

    // MARK: - Hand-typed

    /// The writer typed the suggestion themselves: the computed paragraph is
    /// the live one, so the accept writes no change; there is no pre-accept
    /// text to return to, and Revert is a loud no-op over the writer's words.
    func test_aParagraphTheWriterTypedAsTheSuggestion_isAcceptedStatusOnly() async throws {
        let (dir, docURL) = try makeTestProject(prefix: "AOAT-typed", initialMd: "\(Self.original)\n")
        let doc = try await Document.load(url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        let id = try await doc.addAnnotation(kind: .suggestedChange, paragraphId: pid,
                                             body: "b", suggestedText: Self.suggested)
        doc.setParagraph(id: pid, text: Self.suggested)
        try await doc.flushBurstNow()

        try await doc.acceptAnnotation(id: id)

        XCTAssertEqual(accepts(doc, id).map(\.changes), [[]])
        XCTAssertEqual(status(doc, id), .accepted)
        try await doc.revertAcceptedAnnotation(id: id)
        XCTAssertEqual(doc.paragraph(id: pid), Self.suggested, "the writer's own words stay")
        let none = try await linesRecordingTheirOwnText(Raced(dir: dir, doc: doc, pid: pid, id: id))
        XCTAssertEqual(none, [])
        await doc.close()
    }

    // MARK: - RULING-57: Revert after a travel's status-only re-accept

    /// Accept → checkpoint → Revert → restore to the checkpoint: the restore
    /// puts the text back and re-accepts status-only (RULING-57). The pane
    /// then offers Revert; it reads the newest accept that CARRIES text, so it
    /// takes the change back out rather than declining.
    func test_revertAfterATravelsStatusOnlyReaccept_reachesTheOriginal() async throws {
        let (_, docURL) = try makeTestProject(prefix: "AOAT-r57", initialMd: "\(Self.original)\n")
        let doc = try await Document.load(url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        let id = try await doc.addAnnotation(kind: .suggestedChange, paragraphId: pid,
                                             body: "b", suggestedText: Self.suggested)
        try await doc.acceptAnnotation(id: id)
        try await doc.flushBurstNow()
        let log = try await doc.opLog()
        let checkpoint = try XCTUnwrap(log.last?.opId)
        try await doc.revertAcceptedAnnotation(id: id)
        _ = try await doc.restoreToOp(opId: checkpoint)
        XCTAssertEqual(status(doc, id), .accepted, "premise: RULING-57 re-accepted it")
        XCTAssertEqual(accepts(doc, id).last?.changes, [], "premise: status only")
        XCTAssertEqual(doc.paragraph(id: pid), Self.suggested)
        XCTAssertFalse(doc.acceptedTextDrifted(annotationId: id), "the text is the accept's")

        try await doc.revertAcceptedAnnotation(id: id)

        XCTAssertEqual(doc.paragraph(id: pid), Self.original, "Revert reaches the original")
        XCTAssertEqual(status(doc, id), .open)
        await doc.close()
    }
}
