import XCTest
import MaughamCore
@testable import Maugham

/// Test harness pattern:
///  1. Create a project on disk manually (manifest + one .md file).
///  2. Load ProjectStore via ProjectStore.load(from:).
///  3. Open DocumentStore.open(url:) and wire as store.documentStore.
///  4. Load Document.load(url:...) for the manuscript file.
///  5. Register the Document with the DocumentStore so document(forDocId:) works.
///  6. Register the ProjectStore in a ProjectRegistry.
///
/// Document.load resolves the docId from the manifest StructureItem.id, so
/// doc.docId matches the id used in the registry lookup chain.
@MainActor
final class AnnotationCreationToolsTests: XCTestCase {

    private struct Harness {
        let projectURL: URL
        let projectId: String
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let registry: ProjectRegistry
        let doc: Document
        let docPath: String
    }

    private func makeHarness() async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId = "doc-ann-test"
        try "First paragraph.".write(
            to: tmp.appendingPathComponent(docPath),
            atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: docId, title: "Chapter 1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let pStore = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        pStore.documentStore = ds

        let docURL = tmp.appendingPathComponent(docPath)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: docPath)

        let reg = ProjectRegistry()
        reg.register(url: tmp, store: pStore)
        let projectId = ProjectIdentifier.id(for: tmp)

        return Harness(
            projectURL: tmp,
            projectId: projectId,
            projectStore: pStore,
            documentStore: ds,
            registry: reg,
            doc: doc,
            docPath: docPath)
    }

    // MARK: - add_comment

    func test_addComment_appendsClaudeCommentOp() async throws {
        let h = try await makeHarness()

        // Obtain a real paragraph id from the bootstrap op.
        let log = try await h.doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }

        let params: [String: Any] = [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "paragraph_id": pid,
            "body": "consider showing not telling"
        ]
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let resultData = try await AddCommentTool.handle(
            paramsJSON: paramsData, registry: h.registry)
        let result = try JSONDecoder().decode(
            AddCommentTool.Result.self, from: resultData)
        XCTAssertFalse(result.annotation_id.isEmpty)

        let newLog = try await h.doc.opLog()
        let creation = newLog.first { $0.opId == result.annotation_id }
        XCTAssertNotNil(creation, "op not found in log")
        XCTAssertEqual(creation?.kind, .claudeComment)
        XCTAssertEqual(creation?.provenance?.annotationBody,
                       "consider showing not telling")

        await h.documentStore.close()
    }

    // MARK: - add_suggested_change

    func test_addSuggestedChange_capturesPriorAndSuggested() async throws {
        let h = try await makeHarness()

        let log = try await h.doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }

        let params: [String: Any] = [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "paragraph_id": pid,
            "body": "telling not showing",
            "suggested_text": "Her jaw clenched."
        ]
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let resultData = try await AddSuggestedChangeTool.handle(
            paramsJSON: paramsData, registry: h.registry)
        let result = try JSONDecoder().decode(
            AddSuggestedChangeTool.Result.self, from: resultData)
        XCTAssertFalse(result.annotation_id.isEmpty)

        let newLog = try await h.doc.opLog()
        let creation = newLog.first { $0.opId == result.annotation_id }
        XCTAssertNotNil(creation, "op not found in log")
        XCTAssertEqual(creation?.kind, .claudeSuggestion)
        let change = creation?.changes.first
        XCTAssertEqual(change?.paragraphId, pid)
        XCTAssertEqual(change?.prior, "First paragraph.")
        XCTAssertEqual(change?.next, "Her jaw clenched.")

        await h.documentStore.close()
    }

    // MARK: - quote span + provenance

    func test_addComment_withQuote_capturesSpanAndStampsClaude() async throws {
        let h = try await makeHarness()

        let log = try await h.doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }

        let quote = "First"
        let params: [String: Any] = [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "paragraph_id": pid,
            "body": "anchor on the first word",
            "quote": quote
        ]
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let resultData = try await AddCommentTool.handle(
            paramsJSON: paramsData, registry: h.registry)
        let result = try JSONDecoder().decode(
            AddCommentTool.Result.self, from: resultData)

        let ann = h.doc.annotations().first { $0.id == result.annotation_id }
        XCTAssertNotNil(ann, "derived annotation not found")
        XCTAssertEqual(ann?.author?.sourceKind, .claude)
        XCTAssertEqual(ann?.span?.quote, quote)

        await h.documentStore.close()
    }

    func test_addComment_withMissingQuote_returnsSpanNotFound() async throws {
        let h = try await makeHarness()

        let log = try await h.doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }

        let params: [String: Any] = [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "paragraph_id": pid,
            "body": "this quote isn't there",
            "quote": "nonexistent phrase that does not appear"
        ]
        let paramsData = try JSONSerialization.data(withJSONObject: params)

        do {
            _ = try await AddCommentTool.handle(
                paramsJSON: paramsData, registry: h.registry)
            XCTFail("expected span_not_found")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "span_not_found")
        }

        await h.documentStore.close()
    }

    func test_addComment_noQuote_stampsClaudeProvenance() async throws {
        let h = try await makeHarness()

        let log = try await h.doc.opLog()
        guard let pid = log.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId
        else { return XCTFail("no bootstrap paragraph") }

        let params: [String: Any] = [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "paragraph_id": pid,
            "body": "whole-paragraph comment"
        ]
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let resultData = try await AddCommentTool.handle(
            paramsJSON: paramsData, registry: h.registry)
        let result = try JSONDecoder().decode(
            AddCommentTool.Result.self, from: resultData)

        let ann = h.doc.annotations().first { $0.id == result.annotation_id }
        XCTAssertNotNil(ann, "derived annotation not found")
        XCTAssertEqual(ann?.author?.sourceKind, .claude)
        XCTAssertNil(ann?.span)

        await h.documentStore.close()
    }

    // MARK: - add_craft_note

    func test_addCraftNote_acceptsNoParagraphId() async throws {
        let h = try await makeHarness()

        let params: [String: Any] = [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "body": "Lisa avoids contractions when speaking to her father."
        ]
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let resultData = try await AddCraftNoteTool.handle(
            paramsJSON: paramsData, registry: h.registry)
        let result = try JSONDecoder().decode(
            AddCraftNoteTool.Result.self, from: resultData)
        XCTAssertFalse(result.annotation_id.isEmpty)

        let newLog = try await h.doc.opLog()
        let creation = newLog.first { $0.opId == result.annotation_id }
        XCTAssertNotNil(creation, "op not found in log")
        XCTAssertEqual(creation?.kind, .claudeCraftNote)
        XCTAssertTrue(creation?.changes.isEmpty ?? false,
                      "craft note should have no paragraph changes")
        XCTAssertEqual(creation?.provenance?.annotationBody,
                       "Lisa avoids contractions when speaking to her father.")

        await h.documentStore.close()
    }
}
