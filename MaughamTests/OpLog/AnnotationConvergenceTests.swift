import XCTest
import MaughamCore
@testable import Maugham

/// RULING-33 — **status and manuscript may not disagree.**
///
/// The race is modelled at `formal/AnnotationRace.tla` and this suite is the
/// Swift half of its acceptance: `AnnotationRace_Fixed_NoRejectedButSpliced`
/// passes over the full 7,709-state space, and these tests pin that the code
/// reaches the same converged state the constant describes.
///
/// The shape, from the model's own header: status derives from the single
/// latest LIFECYCLE op by opId, text from a fold of EVERY op's `changes` in
/// opId order, and the two derivations never consult each other. Accept on one
/// Mac, reject on another that had not seen it, reject wins the order — the
/// annotation settles `rejected` with the suggestion sitting in the manuscript.
/// Nothing repairs it by syncing harder, because neither reject nor reopen
/// could move text. Now the repair reject can.
@MainActor
final class AnnotationConvergenceTests: XCTestCase {

    // MARK: - Harness

    /// A suggestion on the first paragraph, accepted locally — i.e. the text is
    /// spliced and the annotation reads `accepted`. Returns everything a peer
    /// op needs to land on top of it.
    private struct Spliced {
        let dir: URL
        let doc: Document
        let pid: String
        let annotationId: String
        let originalText: String
        let suggestedText: String
    }

    private func makeSplicedAccept(
        _ prefix: String, original: String = "Alpha original.",
        suggestion: String = "Alpha SUGGESTED."
    ) async throws -> Spliced {
        let (dir, docURL) = try makeTestProject(
            prefix: prefix, initialMd: "\(original)\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        let aid = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid, body: "try this",
            suggestedText: suggestion)
        try await doc.acceptAnnotation(id: aid)
        XCTAssertEqual(doc.paragraph(id: pid), suggestion,
                       "precondition: the accept spliced the suggestion in")
        return Spliced(dir: dir, doc: doc, pid: pid, annotationId: aid,
                       originalText: original, suggestedText: suggestion)
    }

    /// A peer device's lifecycle op, written straight to the shared op log the
    /// way a synced file would arrive. `at` is irrelevant to both derivations;
    /// the opId is what orders them, and `ULID.generate()` here is newer than
    /// the local accept, which is the losing-race case.
    private func peerOp(
        _ kind: OpKind, for annotationId: String, doc: Document,
        userResponse: String? = nil
    ) -> Op {
        Op(opId: ULID.generate(), docId: doc.docId, at: Date(),
           device: "peer-mac", session: "peer-session",
           kind: kind, changes: [], sequence: nil,
           provenance: Op.Provenance(
            sessionId: "peer-session",
            sourceAnnotationId: annotationId,
            userResponse: userResponse))
    }

    private func status(_ doc: Document, _ id: String) -> AnnotationStatus? {
        doc.annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }?.status
    }

    // MARK: - The headline: NoRejectedButSpliced

    /// The model's Divergence A, in Swift. After the merge the annotation reads
    /// `rejected` AND the manuscript holds the original again — the writer
    /// rejected a change and does not have it.
    func test_aRejectThatBeatsAnAcceptTakesTheSplicedTextBackOut() async throws {
        let s = try await makeSplicedAccept("Converge-A")

        // The peer never saw the accept: on its screen the suggestion was open,
        // so rejecting it was an ordinary thing to do. Its op is newer.
        try await OpLogStore(projectURL: s.dir).append(
            peerOp(.claudeReject, for: s.annotationId, doc: s.doc,
                   userResponse: "not in this scene"))
        try await s.doc.handleExternalLogChange()

        XCTAssertEqual(status(s.doc, s.annotationId), .rejected,
                       "the status winner is unchanged — the reject still wins")
        XCTAssertEqual(s.doc.paragraph(id: s.pid), s.originalText,
                       "and the text it won now agrees with it")
    }

    /// The repair is an op, not a mutation: it says in the log what it did and
    /// why, and it carries the writer's own reason forward so the row still
    /// explains itself.
    func test_theRepairIsAStampedRejectCarryingTheInverseAndTheWritersReason() async throws {
        let s = try await makeSplicedAccept("Converge-Prov")
        try await OpLogStore(projectURL: s.dir).append(
            peerOp(.claudeReject, for: s.annotationId, doc: s.doc,
                   userResponse: "not in this scene"))
        try await s.doc.handleExternalLogChange()

        let repair = try XCTUnwrap(s.doc.opLogSnapshot.last {
            $0.provenance?.synthesisSource == .rejectConvergence })
        XCTAssertEqual(repair.kind, .claudeReject,
                       "one op is both the newest lifecycle op and the newest payload")
        XCTAssertEqual(repair.provenance?.sourceAnnotationId, s.annotationId)
        XCTAssertEqual(repair.changes.first?.paragraphId, s.pid)
        XCTAssertEqual(repair.changes.first?.prior, s.suggestedText)
        XCTAssertEqual(repair.changes.first?.next, s.originalText)
        XCTAssertEqual(repair.provenance?.userResponse, "not in this scene",
                       "the reason the writer gave survives the repair")
    }

    /// The converged state is reached by DERIVING the merged log, not only by
    /// the live instance's in-memory bookkeeping — which is what makes it
    /// converged rather than local. A second device folding the same ops sees
    /// the same paragraph.
    func test_theRepairConvergesForAnyReaderOfTheMergedLog() async throws {
        let s = try await makeSplicedAccept("Converge-Derive")
        try await OpLogStore(projectURL: s.dir).append(
            peerOp(.claudeReject, for: s.annotationId, doc: s.doc))
        try await s.doc.handleExternalLogChange()

        let ops = try await OpLogStore(projectURL: s.dir).load(docId: s.doc.docId)
        let derived = Deriver.derive(ops: ops)
        XCTAssertEqual(derived.paragraphs[s.pid], s.originalText)
        let projection = AnnotationDeriver.derive(
            ops: ops, paragraphs: derived.paragraphs)
        XCTAssertEqual(projection.first { $0.id == s.annotationId }?.status, .rejected)
    }

    /// Idempotence, which is what stops two devices repairing the same race
    /// from ping-ponging: once the repair is the newest payload the detection
    /// is false, so a second merge appends nothing.
    func test_theRepairRunsOnceAndNotAgainOnEveryLaterMerge() async throws {
        let s = try await makeSplicedAccept("Converge-Once")
        try await OpLogStore(projectURL: s.dir).append(
            peerOp(.claudeReject, for: s.annotationId, doc: s.doc))
        try await s.doc.handleExternalLogChange()
        let afterFirst = s.doc.opLogSnapshot.count

        // Another peer op lands for an unrelated reason; the merge re-runs.
        try await OpLogStore(projectURL: s.dir).append(
            Op(opId: ULID.generate(), docId: s.doc.docId, at: Date(),
               device: "peer-mac", session: "peer-session",
               kind: .typingBurst,
               changes: [.init(paragraphId: s.pid, prior: s.originalText,
                               next: s.originalText)],
               sequence: nil, provenance: nil))
        try await s.doc.handleExternalLogChange()

        XCTAssertEqual(
            s.doc.opLogSnapshot.filter {
                $0.provenance?.synthesisSource == .rejectConvergence }.count, 1,
            "exactly one repair, however many merges follow")
        XCTAssertEqual(s.doc.opLogSnapshot.count, afterFirst + 1,
                       "and the second merge added only the peer's own op")
    }

    /// A reject that LOSES the race is not a disagreement and must not be
    /// repaired: the accept is the latest lifecycle op, the annotation reads
    /// `accepted`, and the suggestion belongs in the manuscript.
    func test_anAcceptThatBeatsARejectIsLeftAlone() async throws {
        let (dir, docURL) = try makeTestProject(
            prefix: "Converge-Loser", initialMd: "Alpha original.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        let aid = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid, body: "try this",
            suggestedText: "Alpha SUGGESTED.")

        // The peer's reject lands FIRST, then the local accept beats it.
        try await OpLogStore(projectURL: dir).append(
            peerOp(.claudeReject, for: aid, doc: doc))
        try await doc.handleExternalLogChange()
        try await doc.acceptAnnotation(id: aid)
        try await doc.handleExternalLogChange()

        XCTAssertEqual(status(doc, aid), .accepted)
        XCTAssertEqual(doc.paragraph(id: pid), "Alpha SUGGESTED.")
        XCTAssertTrue(doc.opLogSnapshot.allSatisfy {
            $0.provenance?.synthesisSource != .rejectConvergence },
                      "nothing to repair — the two derivations already agree")
    }

    /// The refusal. If the writer has typed over the accepted paragraph, the
    /// suggestion's text is no longer what is there, and removing it would mean
    /// writing over sentences of theirs. Convergence is not worth that; the
    /// disagreement survives, visibly, with a row to act on.
    func test_itDeclinesRatherThanWriteOverTheWritersOwnEdit() async throws {
        let s = try await makeSplicedAccept("Converge-Drift")
        s.doc.setParagraph(id: s.pid, text: "Alpha, and then a sentence of mine.")
        try await s.doc.flushBurstNow()

        try await OpLogStore(projectURL: s.dir).append(
            peerOp(.claudeReject, for: s.annotationId, doc: s.doc))
        try await s.doc.handleExternalLogChange()

        XCTAssertEqual(s.doc.paragraph(id: s.pid),
                       "Alpha, and then a sentence of mine.",
                       "the writer's words are untouched")
        XCTAssertTrue(s.doc.opLogSnapshot.allSatisfy {
            $0.provenance?.synthesisSource != .rejectConvergence },
                      "and no repair was appended")
    }

    /// A comment or a query has no spliced text to disagree about, and the
    /// repair must not invent one. (Guards the walk, which iterates every
    /// creation op in the mirror.)
    func test_aRejectedCommentIsNotATextDisagreement() async throws {
        let (dir, docURL) = try makeTestProject(
            prefix: "Converge-Comment", initialMd: "Alpha original.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        let cid = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "a thought")
        try await doc.acceptAnnotation(id: cid)

        try await OpLogStore(projectURL: dir).append(
            peerOp(.claudeReject, for: cid, doc: doc))
        try await doc.handleExternalLogChange()

        XCTAssertEqual(doc.paragraph(id: pid), "Alpha original.")
        XCTAssertTrue(doc.opLogSnapshot.allSatisfy {
            $0.provenance?.synthesisSource != .rejectConvergence })
    }

    // MARK: - The other half: a withdrawn suggestion is not acceptable

    /// M5-AN-028. Deleting your own annotation is Maugham telling you it is
    /// gone — it vanishes from every surface at every status. Accepting it
    /// afterwards used to splice its replacement in anyway, with no row left to
    /// notice and no Revert to reach for.
    func test_acceptingAWithdrawnSuggestionDoesNotRewriteTheManuscript() async throws {
        let (_, docURL) = try makeTestProject(
            prefix: "Converge-Withdrawn", initialMd: "Alpha original.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        let sid = try await doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: pid, span: nil, body: "s",
            suggestedText: "REPLACED.", authorName: "D")
        try await doc.withdrawReviewerAnnotation(id: sid, authorName: "D")

        let before = doc.opLogSnapshot.count
        try await doc.acceptAnnotation(id: sid)

        XCTAssertEqual(doc.paragraph(id: pid), "Alpha original.")
        XCTAssertEqual(doc.opLogSnapshot.count, before,
                       "no accept op either — the refusal is before the append")
    }

    /// The repair is an act of Maugham's, not the writer's, and the history has
    /// to say so — a row reading plainly "Rejected" would put it in their
    /// column, which is the misattribution the `.rewind` / `.paragraphDeleted`
    /// arms beside it already exist to avoid.
    ///
    /// A source census rather than a mounted row: `HistoryRow` is `private`, and
    /// what is worth guarding is that the distinction is DRAWN at all. If this
    /// fails because the pane was refactored, the question to ask is whether the
    /// new shape still tells the writer who moved their paragraph.
    func test_theHistoryPaneTellsTheRepairApartFromTheWritersOwnReject() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpLog/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
        let source = try String(
            contentsOf: root.appendingPathComponent("Maugham/Views/HistoryPane.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains(".rejectConvergence"),
                      "the pane must branch on the repair's synthesis source")
        XCTAssertTrue(source.contains("Rejection applied"),
                      "and give it a badge of its own, not the writer's 'Rejected'")
        XCTAssertTrue(
            source.contains("Removed a change accepted on another device"),
            "and say in the expanded row why the paragraph moved")
    }

    /// The instruction has duration but it is not permanent: reopen the
    /// annotation and Accept works again. The guard reads the withdraw/reopen
    /// pair latest-first, exactly as the deriver does.
    func test_reopeningAWithdrawnSuggestionMakesItAcceptableAgain() async throws {
        let (_, docURL) = try makeTestProject(
            prefix: "Converge-Reopened", initialMd: "Alpha original.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        let sid = try await doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: pid, span: nil, body: "s",
            suggestedText: "REPLACED.", authorName: "D")
        try await doc.withdrawReviewerAnnotation(id: sid, authorName: "D")
        try await doc.reopenAnnotation(id: sid)

        try await doc.acceptAnnotation(id: sid)
        XCTAssertEqual(doc.paragraph(id: pid), "REPLACED.")
        XCTAssertEqual(status(doc, sid), .accepted)
    }
}
