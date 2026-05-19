// MaughamTests/OpLog/DocumentAnnotationCacheTests.swift
import XCTest
@testable import Maugham

@MainActor
final class DocumentAnnotationCacheTests: XCTestCase {

    private func makeProject(initialMd: String = "") throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CACHE-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document,
                path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    func test_initially_no_annotations() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        XCTAssertEqual(doc.annotations(), [])
    }

    func test_annotationsVersion_startsAtZero() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        XCTAssertEqual(doc.annotationsVersion, 0)
    }

    func test_addComment_appendsClaudeCommentOp() async throws {
        let (project, path) = try makeProject(initialMd: "First paragraph.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        // Find a paragraph id from the bootstrap op.
        let log = try await doc.opLog()
        guard let bootstrap = log.first(where: { $0.kind == .bootstrap }),
              let pid = bootstrap.changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }

        let id = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "consider showing")

        let newLog = try await doc.opLog()
        let creation = newLog.first { $0.opId == id }
        XCTAssertNotNil(creation)
        XCTAssertEqual(creation?.kind, .claudeComment)
        XCTAssertEqual(creation?.changes.first?.paragraphId, pid)
        XCTAssertEqual(creation?.provenance?.annotationBody, "consider showing")
    }

    func test_addSuggestedChange_includesPriorAndSuggested() async throws {
        let (project, path) = try makeProject(initialMd: "She was angry.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let log = try await doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }

        let id = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "telling not showing",
            suggestedText: "Her jaw clenched.")

        let newLog = try await doc.opLog()
        let creation = newLog.first { $0.opId == id }
        XCTAssertEqual(creation?.kind, .claudeSuggestion)
        let change = creation?.changes.first
        XCTAssertEqual(change?.paragraphId, pid)
        XCTAssertEqual(change?.prior, "She was angry.")
        XCTAssertEqual(change?.next, "Her jaw clenched.")
    }

    func test_acceptSuggestedChange_appliesChangeToDocument() async throws {
        let (project, path) = try makeProject(initialMd: "She was angry.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let log = try await doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }

        let id = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "tighter", suggestedText: "Her jaw clenched.")
        try await doc.acceptAnnotation(id: id)

        XCTAssertEqual(doc.displayText, "Her jaw clenched.")
        let anns = doc.annotations(filter: .init(statuses: nil))
        XCTAssertEqual(anns.first(where: { $0.id == id })?.status, .accepted)
    }

    func test_acceptComment_doesNotChangeDisplayText() async throws {
        let (project, path) = try makeProject(initialMd: "Original prose.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let log = try await doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }
        let before = doc.displayText

        let id = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "noted")
        try await doc.acceptAnnotation(id: id)

        XCTAssertEqual(doc.displayText, before)
    }

    func test_acceptQuery_capturesUserResponse() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let log = try await doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }

        let id = try await doc.addAnnotation(
            kind: .query, paragraphId: pid, body: "ambiguous?")
        try await doc.acceptAnnotation(id: id, userResponse: "yes, intended")

        let anns = doc.annotations(filter: .init(statuses: nil))
        let a = anns.first { $0.id == id }
        XCTAssertEqual(a?.status, .accepted)
        XCTAssertEqual(a?.userResponse, "yes, intended")
    }

    func test_addCraftNote_hasNoParagraphAnchor() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let id = try await doc.addAnnotation(
            kind: .craftNote, paragraphId: nil,
            body: "Lisa avoids contractions with her father.")
        let log = try await doc.opLog()
        let creation = log.first { $0.opId == id }
        XCTAssertEqual(creation?.kind, .claudeCraftNote)
        XCTAssertTrue(creation?.changes.isEmpty ?? false)
    }

    func test_rejectWithUserResponse_capturesReasoning() async throws {
        let (project, path) = try makeProject(initialMd: "She was angry.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let log = try await doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }

        let id = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "rewrite", suggestedText: "Her jaw clenched.")
        try await doc.rejectAnnotation(
            id: id, userResponse: "original lands harder")

        let anns = doc.annotations(filter: .init(statuses: nil))
        let a = anns.first { $0.id == id }
        XCTAssertEqual(a?.status, .rejected)
        XCTAssertEqual(a?.userResponse, "original lands harder")
        // Manuscript should be untouched by reject.
        XCTAssertEqual(doc.displayText, "She was angry.")
    }

    func test_archive_leavesAnnotationInHistoryButOutOfDefaultView() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let log = try await doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }

        let id = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "x")
        try await doc.archiveAnnotation(id: id)

        // Default (open only) — empty.
        XCTAssertTrue(doc.annotations().isEmpty)
        // All statuses → archived.
        let all = doc.annotations(filter: .init(statuses: nil))
        XCTAssertEqual(all.first(where: { $0.id == id })?.status, .archived)
    }

    func test_annotation_isMarkedStaleWhenParagraphChanges() async throws {
        // Use a longer initial text so the bigram matcher has enough overlap to
        // reuse the same paragraph ID after the edit (threshold ≥ 0.6).
        let (project, path) = try makeProject(
            initialMd: "She was angry and shaking with fury.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let log = try await doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }

        let id = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "tighter", suggestedText: "Her jaw clenched.")

        // Not stale immediately after creation.
        XCTAssertFalse(doc.annotations()
            .first(where: { $0.id == id })?.isStale ?? true,
            "annotation should be non-stale immediately after creation")

        // User edits the paragraph directly via setFullText; text is different
        // enough to mark the annotation stale but similar enough (~0.7+ bigram
        // overlap) that restoreComments maps it to the same paragraph ID.
        doc.setFullText("She was furious and shaking, her voice breaking.")

        // Annotation maintenance is deferred from per-keystroke paths to
        // flushBurstNow to keep the editor's hot path off the observable-
        // write loop. Trigger a flush so staleness recomputes.
        try await doc.flushBurstNow()

        // Cache must now reflect the staleness.
        let anns = doc.annotations()
        XCTAssertTrue(anns.first(where: { $0.id == id })?.isStale ?? false,
            "annotation should be flagged stale after paragraph edit via setFullText")
    }

    func test_paragraphDeletion_autoArchivesAnnotations() async throws {
        let (project, path) = try makeProject(
            initialMd: "First paragraph.\n\nSecond paragraph.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let log = try await doc.opLog()
        guard let bootstrap = log.first(where: { $0.kind == .bootstrap })
        else { return XCTFail("no bootstrap op") }
        let pids = bootstrap.changes.map(\.paragraphId)
        guard pids.count >= 2 else { return XCTFail("expected 2 paragraphs") }
        let p1 = pids[0]

        let id = try await doc.addAnnotation(
            kind: .comment, paragraphId: p1, body: "on first")
        XCTAssertEqual(doc.annotations().count, 1)

        doc.deleteParagraph(id: p1)
        // Annotation maintenance is deferred to flushBurstNow (keeps the
        // editor hot path free of observable-write churn).
        try await doc.flushBurstNow()

        // After deletion, the annotation should be archived.
        XCTAssertTrue(doc.annotations().isEmpty,
            "open-default view should not include archived annotations")
        let all = doc.annotations(filter: .init(statuses: nil))
        let a = all.first { $0.id == id }
        XCTAssertEqual(a?.status, .archived)

        // The archive op should carry the synthesisSource flag.
        let newLog = try await doc.opLog()
        let archiveOp = newLog.first {
            $0.kind == .claudeArchive
                && $0.provenance?.sourceAnnotationId == id
        }
        XCTAssertEqual(
            archiveOp?.provenance?.synthesisSource, "paragraph_deleted")
    }

    func test_setFullText_dropsParagraph_autoArchivesAnnotations() async throws {
        // Use longer text so RenderFilter.restoreComments preserves the
        // remaining paragraph's ID via bigram-similarity matching above the
        // 0.6 threshold — same trick as the T11 stale test.
        let initial = """
        First paragraph with enough text to survive bigram matching.

        Second paragraph that will be deleted in this test entirely.
        """
        let (project, path) = try makeProject(initialMd: initial)
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let log = try await doc.opLog()
        let pids = log.first(where: { $0.kind == .bootstrap })!
            .changes.map(\.paragraphId)
        guard pids.count >= 2 else { return XCTFail("expected 2 paragraphs") }
        let p2 = pids[1]

        let id = try await doc.addAnnotation(
            kind: .comment, paragraphId: p2, body: "on second")

        // Edit removing the second paragraph entirely.
        doc.setFullText("First paragraph with enough text to survive bigram matching.")
        // Annotation maintenance is deferred to flushBurstNow.
        try await doc.flushBurstNow()

        let a = doc.annotations(filter: .init(statuses: nil))
            .first { $0.id == id }
        XCTAssertEqual(a?.status, .archived,
            "annotation on deleted paragraph should be auto-archived")
    }
}
