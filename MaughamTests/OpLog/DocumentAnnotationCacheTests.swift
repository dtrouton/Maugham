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
}
