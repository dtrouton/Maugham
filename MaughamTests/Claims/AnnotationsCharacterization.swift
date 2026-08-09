import XCTest
import MaughamCore
@testable import Maugham

/// CHARACTERISATION of `Maugham/OpLog/Document+Annotations.swift` and its
/// immediate MaughamCore collaborators `AnnotationDeriver` / `AnnotationInverse`.
///
/// Every assertion here was written from OBSERVED probe output
/// (`experiment/app-layer-tests/AnnotationsProbe{,2,3,4,5}.swift`), never from
/// what the code looked like it should do. Five claims came out opposite to the
/// reading — most importantly M5-AN-005 (a paragraph edit does NOT refresh the
/// stale flag) and M5-AN-049 (a lost span anchor replaces the WHOLE paragraph).
///
/// Pinned against HEAD `e5a93f0f`. A failure means the behaviour CHANGED, not
/// that it is wrong — several claims pinned here are defects, pinned as such.
///
/// Claim ids `M5-AN-nnn` correspond to `experiment/reconciliation/Annotations.claims.json`.
@MainActor
final class AnnotationsCharacterization: XCTestCase {

    // MARK: - Harness

    private struct Harness { let doc: Document; let pid: String; let url: URL }

    private func makeHarness(_ initialMd: String = "One.") async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnChar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let relativePath = "manuscript/c1.md"
        try initialMd.write(to: tmp.appendingPathComponent(relativePath),
                            atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "Chapter 1", type: .document,
                                 path: relativePath)
        let manifest = ProjectManifest(type: .novel, title: "Ann Char", author: "A",
                                       created: Date(), modified: Date(),
                                       structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let ds = try await DocumentStore.open(url: tmp)
        let doc = try await Document.load(url: tmp.appendingPathComponent(relativePath),
                                          device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: relativePath)
        let pid = try await doc.opLog().first { $0.kind == .bootstrap }!.changes.first!.paragraphId
        return Harness(doc: doc, pid: pid, url: tmp)
    }

    /// The unfiltered projection. `annotations()` alone defaults to `.open` only
    /// (M5-AN-002), which would hide most of what these tests inspect.
    private func all(_ doc: Document) -> [Annotation] {
        doc.annotations(filter: AnnotationFilter(statuses: nil))
    }
    private func one(_ doc: Document, _ id: String) -> Annotation? {
        all(doc).first { $0.id == id }
    }
    private func status(_ doc: Document, _ id: String) -> AnnotationStatus? {
        one(doc, id)?.status
    }
    private func opCount(_ doc: Document) -> Int { doc.opLogSnapshot.count }

    /// A synthetic op, for the pure-`AnnotationDeriver` claims.
    private func op(_ id: String, _ kind: OpKind, src: String? = nil, body: String? = nil,
                    pid: String? = nil, prior: String? = nil, next: String? = nil) -> Op {
        Op(opId: id, docId: "d", at: Date(timeIntervalSince1970: 0), device: "x", session: "s",
           kind: kind,
           changes: pid.map { [.init(paragraphId: $0, prior: prior, next: next ?? "")] } ?? [],
           sequence: nil,
           provenance: Op.Provenance(sessionId: "s", annotationBody: body, sourceAnnotationId: src))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Claims/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
    }

    // MARK: - The op-kind census

    /// M5-AN-001 — eleven of `OpKind`'s cases are annotation ops. The
    /// membership decides which merged ops flip `_hasAnyAnnotationOps`, the
    /// sticky flag that lets the typing hot path skip annotation work.
    func test_annotationOpKindsAreExactlyTheElevenAnnotationCases() {
        let annotationKinds = OpKind.allCases.filter { Document.isAnnotationOpKind($0) }
        XCTAssertEqual(Set(annotationKinds.map(\.rawValue)), [
            "claude_comment", "claude_suggestion", "claude_query", "claude_craft_note",
            "claude_accept", "claude_reject", "claude_archive", "claude_accept_revert",
            "annotation_edit", "annotation_withdraw", "annotation_reopen",
        ])
        for k in [OpKind.typingBurst, .bootstrap, .checkpoint, .checkpointRestore,
                  .externalEdit, .taskCreate, .taskArchive, .unknown] {
            XCTAssertFalse(Document.isAnnotationOpKind(k), "\(k) is not an annotation op")
        }
    }

    // MARK: - Reading the projection

    /// M5-AN-002 — `AnnotationFilter()`'s default `statuses` is `[.open]`, so an
    /// argument-free `annotations()` hides every resolved annotation.
    /// M5-AN-003 — kinds / statuses / paragraphId compose as AND.
    func test_theDefaultFilterShowsOnlyOpenAnnotations() async throws {
        let h = try await makeHarness()
        XCTAssertEqual(AnnotationFilter().statuses, [.open])
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        _ = try await h.doc.addAnnotation(kind: .craftNote, paragraphId: nil, body: "n")
        XCTAssertEqual(h.doc.annotations().count, 2)
        try await h.doc.archiveAnnotation(id: cid)
        XCTAssertEqual(h.doc.annotations().count, 1, "the archived comment is filtered out")
        XCTAssertEqual(all(h.doc).count, 2, "…but it is still in the projection")

        XCTAssertEqual(
            h.doc.annotations(filter: AnnotationFilter(kinds: [.craftNote], statuses: nil)).count, 1)
        XCTAssertEqual(
            h.doc.annotations(filter: AnnotationFilter(statuses: nil, paragraphId: h.pid)).count, 1,
            "the craft note has no paragraph id, so a paragraph filter excludes it")
        XCTAssertEqual(
            h.doc.annotations(filter: AnnotationFilter(
                kinds: [.craftNote], statuses: nil, paragraphId: h.pid)).count, 0,
            "the filters are ANDed")
    }

    /// M5-AN-004 — newest first by `createdAt`, ties broken by DESCENDING op id.
    func test_theProjectionIsNewestFirst() async throws {
        let h = try await makeHarness()
        _ = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "first")
        _ = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "second")
        XCTAssertEqual(all(h.doc).map(\.body), ["second", "first"])
    }

    /// M5-AN-005 — the annotations cache is rebuilt lazily and NOTHING on the
    /// text-edit path invalidates it: neither `setParagraph` nor `setFullText`.
    /// Once the cache is warm (which a rendered AnnotationsPane guarantees), the
    /// `isStale` flag keeps reporting the pre-edit answer until the next burst
    /// flush or the next annotation op. This is the claim that came out opposite
    /// to the reading, and it is what disarms M5-AN-050's gate.
    func test_theStaleFlagDoesNotFollowAParagraphEditUntilTheNextBurst() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        XCTAssertFalse(one(h.doc, cid)!.isStale, "warms the cache, as a rendered pane does")

        h.doc.setParagraph(id: h.pid, text: "Alpha changed.")
        XCTAssertEqual(h.doc.paragraphs[h.pid], "Alpha changed.", "the text really did change")
        XCTAssertFalse(one(h.doc, cid)!.isStale,
                       "…and the annotation still reports itself fresh")

        h.doc.invalidateAnnotationsCache()
        XCTAssertTrue(one(h.doc, cid)!.isStale, "the answer was there all along, uncomputed")

        // The burst boundary is what refreshes it in production.
        h.doc.setParagraph(id: h.pid, text: "Alpha again.")
        try await h.doc.flushBurstNow()
        XCTAssertTrue(one(h.doc, cid)!.isStale)
    }

    /// M5-AN-051 — `_hasAnyAnnotationOps` is re-derived from the MERGED log, so
    /// a peer's annotation op on a doc that had none flips the flag on.
    func test_theStickyAnnotationFlagIsRebuiltFromAMergedLog() async throws {
        let h = try await makeHarness("Beta.")
        XCTAssertFalse(h.doc._hasAnyAnnotationOps)
        let peer = Op(opId: ULID.generate(), docId: h.doc.docId, at: Date(), device: "peer",
                      session: "p", kind: .claudeComment,
                      changes: [.init(paragraphId: h.pid, prior: "Beta.", next: "")],
                      sequence: nil,
                      provenance: Op.Provenance(sessionId: "p", annotationBody: "peer note"))
        try await OpLogStore(projectURL: h.url).append(peer)
        try await h.doc.handleExternalLogChange()
        XCTAssertTrue(h.doc._hasAnyAnnotationOps)
        XCTAssertEqual(all(h.doc).map(\.body), ["peer note"])
    }

    // MARK: - Creating an annotation

    /// M5-AN-006 — the three paragraph-scoped kinds refuse a nil or unknown
    /// anchor AT THE ENTRY POINT with a structured `paragraph_not_found` error
    /// naming the id and the document's current paragraph count.
    func test_paragraphScopedKindsRefuseAnUnknownAnchorAtTheEntryPoint() async throws {
        let h = try await makeHarness()
        for kind in [AnnotationKind.comment, .query, .suggestedChange] {
            for pid in [nil, "zzzz"] as [String?] {
                do {
                    _ = try await h.doc.addAnnotation(
                        kind: kind, paragraphId: pid, body: "x", suggestedText: "s")
                    XCTFail("\(kind) with paragraphId \(pid ?? "nil") should refuse")
                } catch MCPError.toolError(let payload) {
                    XCTAssertEqual(payload.error, "paragraph_not_found")
                    XCTAssertTrue(payload.message.contains(pid ?? "<nil>"),
                                  "the refusal names the id: \(payload.message)")
                    XCTAssertEqual(payload.fields["current_paragraph_count"], .int(1))
                }
            }
        }
        XCTAssertEqual(all(h.doc).count, 0, "nothing was persisted")
    }

    /// M5-AN-007 — a craft note bypasses the anchor check entirely, and a
    /// paragraph id supplied alongside one is SILENTLY DISCARDED: the op carries
    /// no changes and the projection reports `paragraphId == nil`.
    func test_aCraftNoteBypassesTheAnchorCheckAndDiscardsASuppliedParagraphId() async throws {
        let h = try await makeHarness()
        let withNil = try await h.doc.addAnnotation(kind: .craftNote, paragraphId: nil, body: "a")
        let withPid = try await h.doc.addAnnotation(kind: .craftNote, paragraphId: h.pid, body: "b")
        let withJunk = try await h.doc.addAnnotation(kind: .craftNote, paragraphId: "zzzz", body: "c")
        for id in [withNil, withPid, withJunk] {
            XCTAssertNil(one(h.doc, id)?.paragraphId)
            XCTAssertEqual(h.doc.opLogSnapshot.first { $0.opId == id }?.changes.count, 0)
        }
    }

    /// M5-AN-008 — a comment / query stores `prior` = the paragraph's text at
    /// creation and `next` = "". The `prior` is the staleness datum.
    /// M5-AN-009 — a suggestion stores the BARE replacement in `next`; the
    /// splice into the span happens at accept, not here.
    /// M5-AN-011 — an empty body is accepted and derives as "".
    func test_creationOpPayloadsByKind() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        let cChange = h.doc.opLogSnapshot.first { $0.opId == cid }!.changes.first!
        XCTAssertEqual(cChange.prior, "Alpha.")
        XCTAssertEqual(cChange.next, "")
        XCTAssertEqual(one(h.doc, cid)?.priorText, "Alpha.")

        let sid = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, body: "s", suggestedText: "Beta.")
        let sChange = h.doc.opLogSnapshot.first { $0.opId == sid }!.changes.first!
        XCTAssertEqual(sChange.prior, "Alpha.")
        XCTAssertEqual(sChange.next, "Beta.", "the BARE replacement, not the spliced result")
        XCTAssertEqual(one(h.doc, sid)?.suggestedText, "Beta.")

        let empty = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "")
        XCTAssertEqual(one(h.doc, empty)?.body, "")
    }

    /// M5-AN-010 — a suggestion created with NO replacement text is accepted at
    /// the entry point, derives `suggestedText == ""`, and accepting it empties
    /// the paragraph. Both entry points behave identically.
    func test_aSuggestionWithNoReplacementTextEmptiesTheParagraphOnAccept() async throws {
        let h = try await makeHarness("Alpha.")
        let sid = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, body: "cut this", suggestedText: nil)
        XCTAssertEqual(one(h.doc, sid)?.suggestedText, "")
        try await h.doc.acceptAnnotation(id: sid)
        XCTAssertEqual(h.doc.paragraphs[h.pid], "", "the writer's sentence is gone")
        XCTAssertEqual(h.doc.sequence.count, 1, "the paragraph itself survives, empty")

        let h2 = try await makeHarness("Beta.")
        let rid = try await h2.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h2.pid, span: nil, body: "cut",
            suggestedText: nil, authorName: "D")
        try await h2.doc.acceptAnnotation(id: rid)
        XCTAssertEqual(h2.doc.paragraphs[h2.pid], "")
    }

    /// M5-AN-012 — `addReviewerAnnotation` stamps `.human` + display name +
    /// collaborator id; a plain `addAnnotation` with no author derives nil.
    func test_authorProvenance() async throws {
        let h = try await makeHarness("Alpha.")
        let rid = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: nil, body: "b",
            authorName: "Denver", authorId: "d1")
        let author = try XCTUnwrap(one(h.doc, rid)?.author)
        XCTAssertEqual(author.sourceKind, .human)
        XCTAssertEqual(author.displayName, "Denver")
        XCTAssertEqual(author.collaboratorId, "d1")

        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "b2")
        XCTAssertNil(one(h.doc, cid)?.author)
    }

    /// M5-AN-013 — a span whose quote is not in the paragraph is ACCEPTED at the
    /// entry point; the annotation is born `isStale`, with `resolvedSpanRange` nil.
    func test_anUnresolvableSpanIsAcceptedAndBornStale() async throws {
        let h = try await makeHarness("The quick brown fox.")
        let good = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid,
            span: SpanAnchor(quote: "quick", prefix: "The ", suffix: " brown", posHint: 4),
            body: "b", authorName: "D")
        XCTAssertEqual(one(h.doc, good)?.resolvedSpanRange, 4..<9)
        XCTAssertFalse(one(h.doc, good)!.isStale)

        let bad = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid,
            span: SpanAnchor(quote: "elephant", prefix: "", suffix: "", posHint: 0),
            body: "b3", authorName: "D")
        XCTAssertNil(one(h.doc, bad)?.resolvedSpanRange)
        XCTAssertTrue(one(h.doc, bad)!.isStale, "born stale, not refused")
    }

    /// M5-AN-014 — the `language` tag is decoded off `toolArgs` for `.query`
    /// ONLY; malformed JSON yields nil rather than throwing.
    func test_theLanguageTagIsQueryOnly() async throws {
        let h = try await makeHarness("Alpha.")
        let q = try await h.doc.addAnnotation(
            kind: .query, paragraphId: h.pid, body: "q", toolArgs: #"{"language":"fr"}"#)
        XCTAssertEqual(one(h.doc, q)?.language, "fr")
        let c = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "c", toolArgs: #"{"language":"fr"}"#)
        XCTAssertNil(one(h.doc, c)?.language)
        let bad = try await h.doc.addAnnotation(
            kind: .query, paragraphId: h.pid, body: "q2", toolArgs: "not json")
        XCTAssertNil(one(h.doc, bad)?.language)
    }

    // MARK: - Editing

    /// M5-AN-015 — an edit replaces the body; the latest edit by opId wins; the
    /// creation op is never mutated.
    /// M5-AN-016 — `newSuggestedText: nil` leaves the original replacement
    /// intact; a value replaces it.
    func test_editReplacesTheBodyAndOptionallyTheReplacement() async throws {
        let h = try await makeHarness("Alpha.")
        let sid = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, span: nil, body: "one",
            suggestedText: "Beta.", authorName: "D")
        try await h.doc.editReviewerAnnotation(
            id: sid, newBody: "two", newSuggestedText: nil, authorName: "D")
        XCTAssertEqual(one(h.doc, sid)?.body, "two")
        XCTAssertEqual(one(h.doc, sid)?.suggestedText, "Beta.", "left intact")

        try await h.doc.editReviewerAnnotation(
            id: sid, newBody: "three", newSuggestedText: "Gamma.", authorName: "D")
        XCTAssertEqual(one(h.doc, sid)?.body, "three")
        XCTAssertEqual(one(h.doc, sid)?.suggestedText, "Gamma.")

        let creation = h.doc.opLogSnapshot.first { $0.opId == sid }!
        XCTAssertEqual(creation.provenance?.annotationBody, "one", "append-only: never mutated")
        XCTAssertEqual(creation.changes.first?.next, "Beta.")
    }

    /// M5-AN-017 — an edit naming an id that is not a creation op still appends
    /// an `annotationEdit` op; no projection reads it.
    /// M5-AN-018 — there is no status guard: an archived (or withdrawn)
    /// annotation can be edited, and its status is untouched.
    func test_editHasNoTargetAndNoStatusGuard() async throws {
        let h = try await makeHarness("Alpha.")
        let before = opCount(h.doc)
        try await h.doc.editReviewerAnnotation(
            id: "NOPE", newBody: "ghost", newSuggestedText: nil, authorName: "D")
        XCTAssertEqual(opCount(h.doc) - before, 1, "a no-effect op is still written")
        XCTAssertEqual(all(h.doc).count, 0)

        let cid = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: nil, body: "c", authorName: "D")
        try await h.doc.archiveAnnotation(id: cid)
        try await h.doc.editReviewerAnnotation(
            id: cid, newBody: "edited while archived", newSuggestedText: nil, authorName: "D")
        XCTAssertEqual(one(h.doc, cid)?.body, "edited while archived")
        XCTAssertEqual(status(h.doc, cid), .archived)

        // …and while WITHDRAWN, where nothing is visible to edit at all.
        try await h.doc.withdrawReviewerAnnotation(id: cid, authorName: "D")
        try await h.doc.editReviewerAnnotation(
            id: cid, newBody: "edited while withdrawn", newSuggestedText: nil, authorName: "D")
        XCTAssertNil(one(h.doc, cid))
        try await h.doc.reopenAnnotation(id: cid)
        XCTAssertEqual(one(h.doc, cid)?.body, "edited while withdrawn",
                       "the invisible edit was real and surfaces on reopen")
    }

    /// M5-AN-019 — the ⌘Z of an edit is DRIFT-GUARDED: the compensating edit is
    /// appended only while the annotation still shows the body this action
    /// wrote. If anything changed it since, the undo declines silently — the
    /// menu item still reads "Undo Edit Annotation" and nothing happens.
    func test_theEditUndoDeclinesSilentlyWhenTheAnnotationDrifted() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: nil, body: "original", authorName: "D")
        let um = UndoManager()
        try await h.doc.editReviewerAnnotation(
            id: cid, newBody: "first edit", newSuggestedText: nil,
            authorName: "D", undoManager: um)
        XCTAssertTrue(um.canUndo)

        // Something else moves the annotation on (a second Mac's merge, in
        // production; a second unregistered edit here).
        try await h.doc.editReviewerAnnotation(
            id: cid, newBody: "moved on", newSuggestedText: nil, authorName: "D")

        let before = opCount(h.doc)
        um.undo()
        await h.doc.awaitPendingUndoWork()
        XCTAssertEqual(opCount(h.doc), before, "no compensating edit was appended")
        XCTAssertEqual(one(h.doc, cid)?.body, "moved on", "and nothing was clobbered")

        // The control: an undrifted undo does revert.
        let h2 = try await makeHarness("Alpha.")
        let c2 = try await h2.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h2.pid, span: nil, body: "original", authorName: "D")
        let um2 = UndoManager()
        try await h2.doc.editReviewerAnnotation(
            id: c2, newBody: "first edit", newSuggestedText: nil,
            authorName: "D", undoManager: um2)
        um2.undo()
        await h2.doc.awaitPendingUndoWork()
        XCTAssertEqual(one(h2.doc, c2)?.body, "original")
    }

    // MARK: - Withdrawing

    /// M5-AN-020 — withdraw drops the annotation from the projection ENTIRELY,
    /// at every status, while the op stays in the log.
    /// M5-AN-021 — withdrawing an accepted suggestion leaves the applied
    /// manuscript text in place.
    /// M5-AN-022 — withdraw / reopen resolve latest-by-opId.
    /// M5-AN-023 — withdrawing an unknown id appends a no-effect op.
    func test_withdrawDropsTheAnnotationFromEveryStatus() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: nil, body: "c", authorName: "D")
        try await h.doc.withdrawReviewerAnnotation(id: cid, authorName: "D")
        XCTAssertNil(one(h.doc, cid))
        XCTAssertTrue(h.doc.opLogSnapshot.contains { $0.kind == .annotationWithdraw })

        try await h.doc.reopenAnnotation(id: cid)
        XCTAssertEqual(status(h.doc, cid), .open)
        try await h.doc.withdrawReviewerAnnotation(id: cid, authorName: "D")
        XCTAssertNil(one(h.doc, cid), "a later withdraw re-drops it")

        let sid = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, span: nil, body: "s",
            suggestedText: "Beta.", authorName: "D")
        try await h.doc.acceptAnnotation(id: sid)
        XCTAssertEqual(h.doc.paragraphs[h.pid], "Beta.")
        try await h.doc.withdrawReviewerAnnotation(id: sid, authorName: "D")
        XCTAssertNil(one(h.doc, sid))
        XCTAssertEqual(h.doc.paragraphs[h.pid], "Beta.", "the applied text stays")

        let before = opCount(h.doc)
        try await h.doc.withdrawReviewerAnnotation(id: "NOPE", authorName: "D")
        XCTAssertEqual(opCount(h.doc) - before, 1)
    }

    // MARK: - Accepting

    /// M5-AN-024 — accept of an id that is not an annotation CREATION op (an
    /// unknown id, a bootstrap op, a lifecycle op) is a silent no-op that
    /// appends nothing and says nothing.
    func test_acceptIgnoresAnIdItCannotResolveToACreationOp() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        try await h.doc.acceptAnnotation(id: cid)
        let bootstrapId = h.doc.opLogSnapshot.first { $0.kind == .bootstrap }!.opId
        let acceptId = h.doc.opLogSnapshot.first { $0.kind == .claudeAccept }!.opId
        for id in ["NOPE", bootstrapId, acceptId] {
            let before = opCount(h.doc)
            try await h.doc.acceptAnnotation(id: id)
            XCTAssertEqual(opCount(h.doc), before, "accept(\(id)) appended nothing")
        }
    }

    /// M5-AN-025 — accepting a comment, query or craft note sets `.accepted`
    /// and changes no manuscript text.
    func test_acceptingANonSuggestionChangesNoText() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        let qid = try await h.doc.addAnnotation(kind: .query, paragraphId: h.pid, body: "q")
        let nid = try await h.doc.addAnnotation(kind: .craftNote, paragraphId: nil, body: "n")
        for id in [cid, qid, nid] {
            try await h.doc.acceptAnnotation(id: id, userResponse: "ok")
            XCTAssertEqual(status(h.doc, id), .accepted)
            XCTAssertEqual(one(h.doc, id)?.userResponse, "ok")
        }
        XCTAssertEqual(h.doc.paragraphs[h.pid], "Alpha.")
    }

    /// M5-AN-026 — a span-anchored suggestion splices ONLY the span; a
    /// paragraph-level one replaces the whole paragraph.
    func test_aSpanSuggestionSplicesOnlyItsSpan() async throws {
        let h = try await makeHarness("The quick brown fox.")
        let sid = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pid,
            span: SpanAnchor(quote: "quick", prefix: "The ", suffix: " brown", posHint: 4),
            body: "s", suggestedText: "slow", authorName: "D")
        try await h.doc.acceptAnnotation(id: sid)
        XCTAssertEqual(h.doc.paragraphs[h.pid], "The slow brown fox.")

        let h2 = try await makeHarness("The quick brown fox.")
        let pid2 = try await h2.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h2.pid, body: "s", suggestedText: "A dog.")
        try await h2.doc.acceptAnnotation(id: pid2)
        XCTAssertEqual(h2.doc.paragraphs[h2.pid], "A dog.")
    }

    /// M5-AN-049 — A SPAN WHOSE QUOTE IS NO LONGER IN THE PARAGRAPH IS STILL
    /// APPLIED, and it replaces the WHOLE paragraph with the span-sized
    /// replacement. The writer's rewritten sentence becomes one word.
    /// M5-AN-049 (fixed under RULING-5, 2026-08-09) — a span-anchored
    /// suggestion whose quoted phrase is NO LONGER in the paragraph is REFUSED:
    /// the accept throws, the paragraph is untouched, the annotation stays
    /// open, and no accept op is appended. Maugham never guesses where an
    /// AI-authored change belongs. (This test pinned the whole-paragraph
    /// data loss until the fix.)
    func test_aLostSpanAnchorRefusesTheAccept() async throws {
        let h = try await makeHarness("She was very angry about the whole business.")
        let span = SpanAnchor(quote: "very angry", prefix: "She was ",
                              suffix: " about the", posHint: 8)
        let sid = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, span: span, body: "tighter",
            suggestedText: "furious", authorName: "D")

        h.doc.setParagraph(id: h.pid, text: "She was livid about the whole business.")
        h.doc.invalidateAnnotationsCache()
        let ann = one(h.doc, sid)!
        XCTAssertNil(ann.resolvedSpanRange, "the quoted phrase is gone")

        let opsBefore = try await h.doc.opLog().count
        do {
            try await h.doc.acceptAnnotation(id: sid)
            XCTFail("a lost anchor must refuse, not apply")
        } catch let error as AnnotationAcceptError {
            XCTAssertEqual(error, .suggestionAnchorLost)
        }

        XCTAssertEqual(h.doc.paragraphs[h.pid], "She was livid about the whole business.",
                       "the writer's sentence is untouched")
        XCTAssertEqual(one(h.doc, sid)?.status, .open,
                       "the suggestion stays open — the writer may ask again")
        let opsAfter = try await h.doc.opLog().count
        XCTAssertEqual(opsAfter, opsBefore, "no accept op was appended")
    }

    /// M5-AN-050 (fixed under RULING-5, 2026-08-09) — the staleness CACHE still
    /// lags a typing edit until the next burst flush (M5-AN-005's mechanism,
    /// unchanged — the pane's badge can read fresh for up to 30s), but the lag
    /// can no longer cost prose: the accept itself re-resolves the span against
    /// the CURRENT text and refuses when the anchor is gone, whatever the cache
    /// says. Lower layer protects; the upper layer's gate is advisory.
    func test_theStaleCacheLagCannotCostProseAnymore() async throws {
        let h = try await makeHarness("She was very angry about the whole business.")
        let sid = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pid,
            span: SpanAnchor(quote: "very angry", prefix: "She was ",
                             suffix: " about the", posHint: 8),
            body: "t", suggestedText: "furious", authorName: "D")
        XCTAssertFalse(one(h.doc, sid)!.isStale, "the pane renders and warms the cache")

        h.doc.setFullText("She was livid about the whole business.\n")
        XCTAssertEqual(h.doc.paragraphs[h.pid], "She was livid about the whole business.")
        XCTAssertFalse(one(h.doc, sid)!.isStale,
                       "the cache still lags — M5-AN-005's mechanism is unchanged")

        do {
            try await h.doc.acceptAnnotation(id: sid)
            XCTFail("the lagging cache must not let the accept through")
        } catch let error as AnnotationAcceptError {
            XCTAssertEqual(error, .suggestionAnchorLost)
        }
        XCTAssertEqual(h.doc.paragraphs[h.pid], "She was livid about the whole business.")
    }

    /// M5-AN-027 — accept has NO status guard. An already-rejected or archived
    /// annotation flips to `.accepted`; a second accept appends again and its
    /// `userResponse` supersedes the first.
    func test_acceptHasNoStatusGuard() async throws {
        let h = try await makeHarness("Alpha.")
        let rid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "r")
        try await h.doc.rejectAnnotation(id: rid, userResponse: "no")
        XCTAssertEqual(status(h.doc, rid), .rejected)
        try await h.doc.acceptAnnotation(id: rid)
        XCTAssertEqual(status(h.doc, rid), .accepted)

        let aid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "a")
        try await h.doc.archiveAnnotation(id: aid)
        try await h.doc.acceptAnnotation(id: aid, userResponse: "first")
        XCTAssertEqual(status(h.doc, aid), .accepted)
        try await h.doc.acceptAnnotation(id: aid, userResponse: "second")
        XCTAssertEqual(one(h.doc, aid)?.userResponse, "second")
    }

    /// M5-AN-028 — accepting a WITHDRAWN suggestion still rewrites the
    /// manuscript. The creation op is in the mirror, so accept proceeds; the
    /// annotation stays absent from the projection, so nothing on any surface
    /// records that the paragraph was changed by a suggestion.
    func test_acceptingAWithdrawnSuggestionStillRewritesTheManuscript() async throws {
        let h = try await makeHarness("Alpha.")
        let sid = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, span: nil, body: "s",
            suggestedText: "REPLACED.", authorName: "D")
        try await h.doc.withdrawReviewerAnnotation(id: sid, authorName: "D")
        XCTAssertNil(one(h.doc, sid))

        try await h.doc.acceptAnnotation(id: sid)
        XCTAssertEqual(h.doc.paragraphs[h.pid], "REPLACED.")
        XCTAssertNil(one(h.doc, sid), "still invisible — no row offers a Revert")
    }

    // MARK: - Drift and revert

    /// M5-AN-029 — `acceptedTextDrifted` is false with no accept, no change or
    /// no live paragraph; true once the paragraph differs from the accept's `next`.
    func test_acceptedTextDrifted() async throws {
        let h = try await makeHarness("Alpha.")
        XCTAssertFalse(h.doc.acceptedTextDrifted(annotationId: "NOPE"))
        let sid = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, body: "s", suggestedText: "Beta.")
        XCTAssertFalse(h.doc.acceptedTextDrifted(annotationId: sid), "not accepted yet")
        try await h.doc.acceptAnnotation(id: sid)
        XCTAssertFalse(h.doc.acceptedTextDrifted(annotationId: sid))
        h.doc.setParagraph(id: h.pid, text: "Gamma.")
        XCTAssertTrue(h.doc.acceptedTextDrifted(annotationId: sid))
    }

    /// M5-AN-030 — revert loud-no-ops (logs, does not throw, appends nothing)
    /// on a non-suggestion, on a suggestion that is not `.accepted`, and on an
    /// accepted suggestion whose paragraph no longer exists.
    func test_revertLoudNoOpsRatherThanRefusing() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        var before = opCount(h.doc)
        try await h.doc.revertAcceptedAnnotation(id: cid)
        XCTAssertEqual(opCount(h.doc), before, "not a suggestion")

        let sid = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, body: "s", suggestedText: "Beta.")
        before = opCount(h.doc)
        try await h.doc.revertAcceptedAnnotation(id: sid)
        XCTAssertEqual(opCount(h.doc), before, "not accepted")

        // Accepted, then the paragraph is deleted out from under it.
        let h2 = try await makeHarness("One.")
        h2.doc.setFullText("One.\n\nTwo.\n"); try await h2.doc.flushBurstNow()
        let pid2 = h2.doc.opLogSnapshot.last { $0.kind == .typingBurst }!
            .changes.first { ($0.next ?? "").contains("Two") }!.paragraphId
        let s2 = try await h2.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid2, body: "s", suggestedText: "Two!")
        try await h2.doc.acceptAnnotation(id: s2)
        XCTAssertEqual(status(h2.doc, s2), .accepted)
        h2.doc.setFullText("One.\n"); try await h2.doc.flushBurstNow()
        XCTAssertFalse(h2.doc.sequence.contains(pid2), "the paragraph is gone")
        XCTAssertEqual(status(h2.doc, s2), .accepted, "…and the accepted row survives it")
        before = opCount(h2.doc)
        try await h2.doc.revertAcceptedAnnotation(id: s2)
        XCTAssertEqual(opCount(h2.doc), before,
                       "Revert on that row does nothing and says nothing")
    }

    /// M5-AN-031 — a revert restores the PRE-accept text over whatever the
    /// paragraph now holds, returns the annotation to `.open`, and drops the
    /// `userResponse` recorded at accept.
    func test_revertRestoresThePreAcceptTextAndReopens() async throws {
        let h = try await makeHarness("Alpha.")
        let sid = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, body: "s", suggestedText: "Beta.")
        try await h.doc.acceptAnnotation(id: sid, userResponse: "yes")
        h.doc.setParagraph(id: h.pid, text: "Gamma — an edit made since the accept.")
        try await h.doc.revertAcceptedAnnotation(id: sid)
        XCTAssertEqual(h.doc.paragraphs[h.pid], "Alpha.", "the intervening edit is clobbered")
        XCTAssertEqual(status(h.doc, sid), .open)
        XCTAssertNil(one(h.doc, sid)?.userResponse)
    }

    // MARK: - Reject / archive / the lifecycle tail

    /// M5-AN-032 — `appendLifecycleOp` is completely unguarded: reject and
    /// archive append for an unknown id, for a bootstrap op id, and for an
    /// already-resolved annotation, in any order.
    /// M5-AN-033 — the deriver ignores a lifecycle op with no
    /// `sourceAnnotationId`, and an edit whose source names no creation op.
    func test_rejectAndArchiveAreUnguarded() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        try await h.doc.archiveAnnotation(id: cid)
        var before = opCount(h.doc)
        try await h.doc.archiveAnnotation(id: cid)
        XCTAssertEqual(opCount(h.doc) - before, 1, "a duplicate archive is written")
        XCTAssertEqual(status(h.doc, cid), .archived)
        try await h.doc.rejectAnnotation(id: cid)
        XCTAssertEqual(status(h.doc, cid), .rejected, "archived → rejected, no guard")

        let bootstrapId = h.doc.opLogSnapshot.first { $0.kind == .bootstrap }!.opId
        for junk in ["NOPE", bootstrapId] {
            before = opCount(h.doc)
            try await h.doc.archiveAnnotation(id: junk)
            XCTAssertEqual(opCount(h.doc) - before, 1, "a meaningless lifecycle op is written")
        }
        XCTAssertEqual(all(h.doc).count, 1, "…and the projection ignores every one of them")

        // Pure-deriver half.
        let creation = op("A", .claudeComment, body: "orig", pid: "aaaa", prior: "P")
        let unsourced = AnnotationDeriver.derive(
            ops: [creation, op("B", .claudeArchive)], paragraphs: ["aaaa": "P"])
        XCTAssertEqual(unsourced.first?.status, .open)
        let orphanEdit = AnnotationDeriver.derive(
            ops: [creation, op("B", .annotationEdit, src: "NOPE", body: "ghost")],
            paragraphs: ["aaaa": "P"])
        XCTAssertEqual(orphanEdit.first?.body, "orig")
    }

    // MARK: - Reopening

    /// M5-AN-034 — `reopenAnnotation` acts only from `.rejected`, `.archived`
    /// and withdrawn. `.open` and `.accepted` are logged no-ops — which is why
    /// `AnnotationInverse`'s `.noInverse` decline is unreachable from here.
    func test_reopenActsOnlyFromRejectedArchivedOrWithdrawn() async throws {
        let h = try await makeHarness("Alpha.")
        let openId = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "o")
        var before = opCount(h.doc)
        try await h.doc.reopenAnnotation(id: openId)
        XCTAssertEqual(opCount(h.doc), before, "already open")

        let accId = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, body: "s", suggestedText: "Beta.")
        try await h.doc.acceptAnnotation(id: accId)
        before = opCount(h.doc)
        try await h.doc.reopenAnnotation(id: accId)
        XCTAssertEqual(opCount(h.doc), before, "accepted has no reopen inverse")
        XCTAssertEqual(status(h.doc, accId), .accepted)

        for kind in ["reject", "archive"] {
            let id = try await h.doc.addAnnotation(
                kind: .comment, paragraphId: h.pid, body: kind)
            if kind == "reject" { try await h.doc.rejectAnnotation(id: id) }
            else { try await h.doc.archiveAnnotation(id: id) }
            before = opCount(h.doc)
            try await h.doc.reopenAnnotation(id: id)
            XCTAssertEqual(opCount(h.doc) - before, 1)
            XCTAssertEqual(status(h.doc, id), .open)
        }
    }

    /// M5-AN-035 — reopen appends nothing for an unknown id, for an id that is
    /// not withdrawn, or on a closed (husked) Document.
    func test_reopenDeclinesOnAnUnknownIdAndOnAClosedDocument() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        try await h.doc.archiveAnnotation(id: cid)
        var before = opCount(h.doc)
        try await h.doc.reopenAnnotation(id: "NOPE")
        XCTAssertEqual(opCount(h.doc), before)

        await h.doc.close()
        XCTAssertTrue(h.doc.isClosed)
        before = opCount(h.doc)
        try await h.doc.reopenAnnotation(id: cid)
        XCTAssertEqual(opCount(h.doc), before, "the husk refuses")
    }

    /// M5-AN-036 — `annotationReopen` is ONE op kind serving TWO inverses, and
    /// the deriver reads it as both. A reopen issued to undo a withdrawal also
    /// cancels an earlier archive or reject, so ⌘Z on a withdraw over-restores:
    /// the annotation comes back OPEN, not archived.
    func test_oneReopenCancelsBothAWithdrawalAndAnEarlierResolution() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: nil, body: "c", authorName: "D")
        try await h.doc.archiveAnnotation(id: cid)
        XCTAssertEqual(status(h.doc, cid), .archived)
        try await h.doc.withdrawReviewerAnnotation(id: cid, authorName: "D")
        try await h.doc.reopenAnnotation(id: cid)          // the ⌘Z of the withdraw
        XCTAssertEqual(status(h.doc, cid), .open,
                       "the archive the writer never undid is gone too")

        // Same shape with a reject.
        let rid = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: nil, body: "r", authorName: "D")
        try await h.doc.withdrawReviewerAnnotation(id: rid, authorName: "D")
        try await h.doc.rejectAnnotation(id: rid, userResponse: "no")
        try await h.doc.reopenAnnotation(id: rid)
        XCTAssertEqual(status(h.doc, rid), .open)
    }

    /// M5-AN-037 — a reopen clears the writer's recorded reply and the
    /// resolution timestamp from the projection. The words survive in the op
    /// log; no surface reads them back.
    func test_reopenClearsTheWritersRecordedReply() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        try await h.doc.rejectAnnotation(id: cid, userResponse: "not in this scene")
        XCTAssertEqual(one(h.doc, cid)?.userResponse, "not in this scene")
        XCTAssertNotNil(one(h.doc, cid)?.resolvedAt)

        try await h.doc.reopenAnnotation(id: cid)
        XCTAssertNil(one(h.doc, cid)?.userResponse)
        XCTAssertNil(one(h.doc, cid)?.resolvedAt)
        XCTAssertTrue(
            h.doc.opLogSnapshot.contains { $0.provenance?.userResponse == "not in this scene" },
            "still in the log, unread by any surface")
    }

    /// M5-AN-038 — reopens written by `reopenAnnotation` carry no
    /// `synthesisSource`; the rewind sweep's reopens are `.rewind`-stamped, and
    /// that stamp is the only thing distinguishing Maugham's from the writer's.
    func test_reopenOpsCarryNoSynthesisSource() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        try await h.doc.archiveAnnotation(id: cid)
        try await h.doc.reopenAnnotation(id: cid)
        let reopens = h.doc.opLogSnapshot.filter { $0.kind == .annotationReopen }
        XCTAssertEqual(reopens.count, 1)
        XCTAssertNil(reopens[0].provenance?.synthesisSource)
    }

    /// M5-AN-039 — `reopenAnnotation` still has NO non-undo production caller,
    /// and the annotations pane offers no Reopen affordance. RULING-29 requires
    /// both; this test is the register's marker for that fix.
    func test_reopenHasNoNonUndoProductionCaller() throws {
        var callers: [String] = []
        let fm = FileManager.default
        let appDir = repoRoot.appendingPathComponent("Maugham", isDirectory: true)
        let e = fm.enumerator(at: appDir, includingPropertiesForKeys: nil)!
        for case let url as URL in e where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("reopenAnnotation(id:") else { continue }
            callers.append(url.lastPathComponent)
        }
        XCTAssertEqual(Set(callers), [
            "Document+Annotations.swift",   // the definition
            "Document+RewindUndo.swift",    // undo of a rewind's auto-archive
            "Document+Tasks.swift",         // undo of a task-archive's auto-archive
        ], "a new caller means RULING-29 shipped — update this claim and its filing")

        let pane = try String(
            contentsOf: repoRoot.appendingPathComponent("Maugham/Views/AnnotationsPane.swift"),
            encoding: .utf8)
        XCTAssertFalse(pane.contains("onReopen"),
                       "the pane still has no Reopen action (RULING-29 gap)")
    }

    /// M5-AN-040 — `AnnotationInverse.reopenOp`'s full decision matrix: exactly
    /// three (undone kind, current status) pairs mint an op; accept declines
    /// with `.noInverse`; every other status mismatch declines `.stateDrifted`.
    func test_theReopenFactorysDecisionMatrix() {
        func outcome(_ k: OpKind, _ s: AnnotationStatus?) -> String {
            switch AnnotationInverse.reopenOp(
                undoing: k, annotationId: "x", currentStatus: s,
                docId: "d", device: "dev", session: "s") {
            case .op(let o): return "op(\(o.kind.rawValue))"
            case .declined(let d): return "declined(\(d))"
            }
        }
        let statuses: [AnnotationStatus?] = [nil, .open, .accepted, .rejected, .archived]
        for s in statuses {
            XCTAssertEqual(outcome(.claudeReject, s),
                           s == .rejected ? "op(annotation_reopen)" : "declined(stateDrifted)")
            XCTAssertEqual(outcome(.claudeArchive, s),
                           s == .archived ? "op(annotation_reopen)" : "declined(stateDrifted)")
            XCTAssertEqual(outcome(.annotationWithdraw, s),
                           s == nil ? "op(annotation_reopen)" : "declined(stateDrifted)")
            XCTAssertEqual(outcome(.claudeAccept, s),
                           "declined(noInverse(MaughamCore.OpKind.claudeAccept))",
                           "accept's inverse is claudeAcceptRevert, which also restores text")
            XCTAssertEqual(outcome(.claudeComment, s),
                           "declined(noInverse(MaughamCore.OpKind.claudeComment))")
        }
    }

    // MARK: - The orphan sweep

    /// M5-AN-041 — sweep eligibility is EXACTLY `status == .open && kind !=
    /// .craftNote && paragraphId ∈ reason.removed`. Accepted, rejected and
    /// archived annotations on a removed paragraph are left in place, anchored
    /// to a paragraph that no longer exists.
    /// M5-AN-043 — the craft-note carve-out is redundant by construction: a
    /// craft note's paragraphId is always nil, so the anchor test already
    /// excludes it.
    func test_theSweepArchivesOpenAnchoredAnnotationsOnly() async throws {
        let h = try await makeHarness("One.")
        h.doc.setFullText("One.\n\nTwo.\n"); try await h.doc.flushBurstNow()
        let pid2 = h.doc.opLogSnapshot.last { $0.kind == .typingBurst }!
            .changes.first { ($0.next ?? "").contains("Two") }!.paragraphId

        let openId = try await h.doc.addAnnotation(kind: .comment, paragraphId: pid2, body: "open")
        let accId = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid2, body: "acc", suggestedText: "Two!")
        try await h.doc.acceptAnnotation(id: accId)
        let rejId = try await h.doc.addAnnotation(kind: .comment, paragraphId: pid2, body: "rej")
        try await h.doc.rejectAnnotation(id: rejId)
        let arcId = try await h.doc.addAnnotation(kind: .comment, paragraphId: pid2, body: "arc")
        try await h.doc.archiveAnnotation(id: arcId)
        let craftId = try await h.doc.addAnnotation(kind: .craftNote, paragraphId: nil, body: "craft")
        let otherId = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "other paragraph")
        XCTAssertNil(one(h.doc, craftId)?.paragraphId, "a craft note never carries an anchor")

        await h.doc.sweepOrphanedAnnotations(
            reason: try XCTUnwrap(SweepReason.externalLog(removed: [pid2])))

        XCTAssertEqual(status(h.doc, openId), .archived, "the only one swept")
        XCTAssertEqual(status(h.doc, accId), .accepted)
        XCTAssertEqual(status(h.doc, rejId), .rejected)
        XCTAssertEqual(status(h.doc, arcId), .archived)
        XCTAssertEqual(status(h.doc, craftId), .open)
        XCTAssertEqual(status(h.doc, otherId), .open)
    }

    /// M5-AN-042 — the sweep trusts `reason.removed` and never consults
    /// `sequence`: a removed set naming a paragraph that is still present
    /// archives its open annotations anyway.
    func test_theSweepTrustsTheRemovedSetAndNeverChecksSequence() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        XCTAssertTrue(h.doc.sequence.contains(h.pid))
        await h.doc.sweepOrphanedAnnotations(
            reason: try XCTUnwrap(SweepReason.externalLog(removed: [h.pid])))
        XCTAssertEqual(status(h.doc, cid), .archived,
                       "archived on a paragraph that is still there")
    }

    /// M5-AN-044 — each synthesised archive carries `synthesisSource =
    /// reason.cause`, the forensic distinction between a typing deletion and a
    /// rewind.
    func test_theSweepStampsItsCauseOnEveryArchive() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        await h.doc.sweepOrphanedAnnotations(
            reason: try XCTUnwrap(SweepReason.rewind(removed: [h.pid])))
        let archive = h.doc.opLogSnapshot.last {
            $0.kind == .claudeArchive && $0.provenance?.sourceAnnotationId == cid }
        XCTAssertEqual(archive?.provenance?.synthesisSource, .rewind)

        let h2 = try await makeHarness("Beta.")
        let c2 = try await h2.doc.addAnnotation(kind: .comment, paragraphId: h2.pid, body: "c")
        await h2.doc.sweepOrphanedAnnotations(
            reason: try XCTUnwrap(SweepReason.externalLog(removed: [h2.pid])))
        XCTAssertEqual(
            h2.doc.opLogSnapshot.last { $0.kind == .claudeArchive
                && $0.provenance?.sourceAnnotationId == c2 }?.provenance?.synthesisSource,
            .paragraphDeleted)
    }

    /// M5-AN-045 — `flagSweep` unions removed sets and inherits the LATER cause.
    func test_flagSweepUnionsAndTakesTheLaterCause() async throws {
        let h = try await makeHarness("Alpha.")
        h.doc.flagSweep(try XCTUnwrap(SweepReason.externalLog(removed: ["aaaa"])))
        h.doc.flagSweep(try XCTUnwrap(SweepReason.rewind(removed: ["bbbb"])))
        XCTAssertEqual(h.doc._pendingSweep?.removed, ["aaaa", "bbbb"])
        XCTAssertEqual(h.doc._pendingSweep?.cause, .rewind)
    }

    // MARK: - The op-log mirror

    /// M5-AN-046 — every annotation append pushes onto `_opLogMirror` without
    /// re-sorting. `handleExternalLogChange` REPLACES the mirror with a sorted
    /// merge, so the mirror is opId-ordered right up until the first local
    /// append after a merge that brought in a peer op with a higher ULID —
    /// after which it is not.
    /// M5-AN-047 — the annotation projection is unharmed (it compares opIds
    /// rather than trusting order), but `currentFoldBasis` and
    /// `Deriver.derive(ops:upTo:)` — which trusts caller order by design —
    /// return a state the document never held.
    func test_theMirrorIsNotReSortedOnAppend() async throws {
        let h = try await makeHarness("One.")
        func isSorted(_ ops: [Op]) -> Bool {
            zip(ops, ops.dropFirst()).allSatisfy { $0.opId < $1.opId }
        }
        XCTAssertTrue(isSorted(h.doc.opLogSnapshot))

        // A peer whose clock is ahead: a max-timestamp ULID sorts after anything
        // this process will mint.
        let futureId = "ZZZZZZZZZZ0000000000000000"
        let peer = Op(opId: futureId, docId: h.doc.docId, at: Date(), device: "peer",
                      session: "p", kind: .typingBurst,
                      changes: [.init(paragraphId: h.pid, prior: "One.", next: "PEER TEXT.")],
                      sequence: [h.pid], provenance: nil)
        try await OpLogStore(projectURL: h.url).append(peer)
        try await h.doc.handleExternalLogChange()
        XCTAssertTrue(isSorted(h.doc.opLogSnapshot), "the merge replaces the mirror, sorted")
        XCTAssertEqual(h.doc.paragraphs[h.pid], "PEER TEXT.")

        h.doc.setParagraph(id: h.pid, text: "LOCAL TEXT.")
        try await h.doc.flushBurstNow()
        let mirror = h.doc.opLogSnapshot
        XCTAssertFalse(isSorted(mirror), "one local append after the merge breaks the order")
        XCTAssertNotEqual(h.doc.currentFoldBasis, mirror.map(\.opId).max(),
                          "the 'last element is the newest' premise no longer holds")

        let tip = mirror.last!.opId
        XCTAssertEqual(
            Deriver.derive(ops: mirror, upTo: .atOp(opId: tip, at: Date())).paragraphs[h.pid],
            "PEER TEXT.",
            "a rewind to the writer's own newest moment shows the PEER's text")
        XCTAssertEqual(
            Deriver.derive(ops: mirror.sorted { $0.opId < $1.opId },
                           upTo: .atOp(opId: tip, at: Date())).paragraphs[h.pid],
            "LOCAL TEXT.",
            "…which is not what that moment held")

        // The annotation projection is unaffected: it compares opIds.
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "post")
        try await h.doc.archiveAnnotation(id: cid)
        XCTAssertEqual(status(h.doc, cid), .archived)
    }

    /// M5-AN-052 — `AnnotationDeriver.derive` is input-order-independent: it
    /// resolves latest-by-opId rather than by array position, so the unsorted
    /// mirror of M5-AN-046 cannot corrupt it.
    func test_theAnnotationDeriverIsInputOrderIndependent() {
        let creation = op("A", .claudeComment, body: "orig", pid: "aaaa", prior: "P")
        let paras = ["aaaa": "P"]
        let ops = [creation, op("B", .claudeArchive, src: "A"), op("C", .annotationReopen, src: "A")]
        XCTAssertEqual(AnnotationDeriver.derive(ops: ops, paragraphs: paras).first?.status, .open)
        XCTAssertEqual(
            AnnotationDeriver.derive(ops: ops.reversed(), paragraphs: paras).first?.status, .open)
        // A reopen that sorts BEFORE the archive loses, whatever the array order.
        let older = [creation, op("D", .claudeArchive, src: "A"), op("C", .annotationReopen, src: "A")]
        XCTAssertEqual(
            AnnotationDeriver.derive(ops: older, paragraphs: paras).first?.status, .archived)
        // Withdraw wins over an archive in either order (it is resolved separately).
        for pair in [[OpKind.annotationWithdraw, .claudeArchive], [.claudeArchive, .annotationWithdraw]] {
            let o = [creation, op("B", pair[0], src: "A"), op("C", pair[1], src: "A")]
            XCTAssertEqual(AnnotationDeriver.derive(ops: o, paragraphs: paras).count, 0)
        }
        // A paragraph absent from the map is stale; a craft note never is.
        XCTAssertTrue(AnnotationDeriver.derive(ops: [creation], paragraphs: [:]).first!.isStale)
        XCTAssertFalse(AnnotationDeriver.derive(
            ops: [op("A", .claudeCraftNote, body: "n")], paragraphs: [:]).first!.isStale)
    }

    // MARK: - The closed document

    /// M5-AN-048 — the husked-document guard is applied to `reopenAnnotation`
    /// and (by consequence of the emptied mirror) `acceptAnnotation`, but NOT to
    /// craft-note creation, archive, reject, withdraw or edit — all five append
    /// to disk and repopulate the husked mirror.
    func test_theClosedDocumentGuardCoversTwoOfSevenMutators() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        await h.doc.close()
        XCTAssertEqual(opCount(h.doc), 0, "husked")

        func appended(_ body: () async throws -> Void) async -> Int {
            let before = opCount(h.doc)
            do { try await body() } catch { return -1 }
            return opCount(h.doc) - before
        }
        // Declines.
        var n = await appended { try await h.doc.reopenAnnotation(id: cid) }
        XCTAssertEqual(n, 0, "reopen has the explicit isClosed guard")
        n = await appended { try await h.doc.acceptAnnotation(id: cid) }
        XCTAssertEqual(n, 0, "accept cannot find the creation op in the emptied mirror")
        n = await appended {
            _ = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "x") }
        XCTAssertEqual(n, -1, "the anchor check throws — sequence is empty")

        // Appends anyway.
        for (label, work) in [
            ("craft note", { _ = try await h.doc.addAnnotation(
                kind: .craftNote, paragraphId: nil, body: "x") }),
            ("archive", { try await h.doc.archiveAnnotation(id: cid) }),
            ("reject", { try await h.doc.rejectAnnotation(id: cid) }),
            ("withdraw", { try await h.doc.withdrawReviewerAnnotation(id: cid, authorName: "D") }),
            ("edit", { try await h.doc.editReviewerAnnotation(
                id: cid, newBody: "x", newSuggestedText: nil, authorName: "D") }),
        ] as [(String, () async throws -> Void)] {
            let count = await appended(work)
            XCTAssertEqual(count, 1, "\(label) appended to a closed document")
        }

        let onDisk = try await OpLogStore(projectURL: h.url).load(docId: h.doc.docId)
        XCTAssertTrue(onDisk.contains { $0.kind == .claudeCraftNote })
        XCTAssertTrue(onDisk.contains { $0.kind == .annotationWithdraw })
    }
}
