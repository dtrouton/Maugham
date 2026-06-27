import XCTest
import MaughamCore
@testable import Maugham

/// End-to-end integration test: Claude adds a suggestion via MCP, the annotation
/// appears on the Document, the user accepts it, the manuscript text updates, and
/// list_annotations (via MCP) reports accepted state.
///
/// Harness pattern copied from MaughamTests/MCP/Tools/AnnotationCreationToolsTests.swift.
@MainActor
final class AnnotationFlowTests: XCTestCase {

    // MARK: - Test harness

    private struct Harness {
        let projectURL: URL
        let projectId: String
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let registry: ProjectRegistry
        let doc: Document
        let docPath: String
    }

    private func makeHarness(initialMd: String = "She was angry.") async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AFT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId = "doc-flow-test"
        try initialMd.write(
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

    // MARK: - End-to-end flow

    func test_end_to_end_addSuggestion_userAccepts_listShowsAccepted() async throws {
        let h = try await makeHarness(initialMd: "She was angry.")

        // Obtain the real paragraph id from the bootstrap op.
        let pid = try await h.doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId

        // 1. Claude adds a suggestion via MCP (add_suggested_change).
        let mcpAddParams: [String: Any] = [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "paragraph_id": pid,
            "body": "show, don't tell",
            "suggested_text": "Her jaw clenched."
        ]
        let addData = try JSONSerialization.data(withJSONObject: mcpAddParams)
        let addResultData = try await AddSuggestedChangeTool.handle(
            paramsJSON: addData, registry: h.registry)
        let addResult = try JSONDecoder().decode(
            AddSuggestedChangeTool.Result.self, from: addResultData)
        let annotationId = addResult.annotation_id
        XCTAssertFalse(annotationId.isEmpty)

        // 2. Annotation appears in Document.annotations with open status.
        let openList = h.doc.annotations()
        XCTAssertEqual(openList.count, 1)
        XCTAssertEqual(openList[0].id, annotationId)
        XCTAssertEqual(openList[0].kind, .suggestedChange)
        XCTAssertEqual(openList[0].status, .open)

        // 3. User accepts via Document.acceptAnnotation.
        try await h.doc.acceptAnnotation(id: annotationId)

        // 4. Manuscript reflects the accepted suggestion.
        XCTAssertEqual(h.doc.displayText, "Her jaw clenched.")

        // 5. list_annotations (via MCP) shows accepted state.
        let listParams: [String: Any] = [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "statuses": ["accepted"]
        ]
        let listData = try JSONSerialization.data(withJSONObject: listParams)
        let listResultData = try await ListAnnotationsTool.handle(
            paramsJSON: listData, registry: h.registry)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let listResult = try dec.decode(
            [ListAnnotationsTool.Item].self, from: listResultData)
        XCTAssertEqual(listResult.count, 1)
        XCTAssertEqual(listResult[0].id, annotationId)
        XCTAssertEqual(listResult[0].status, "accepted")

        await h.documentStore.close()
    }

    /// Span-anchored (sub-paragraph) suggestion: accepting must replace ONLY the
    /// anchored span, not the whole paragraph. Regression for the bug where the
    /// suggested-change op's `next` was the bare suggested text, so accept set the
    /// entire paragraph to the one suggested word. (Paragraph-level suggestions —
    /// no span, MCP/Claude — still replace the whole paragraph; see the
    /// end-to-end test above.)
    func test_spanSuggestion_acceptReplacesOnlyTheSpan() async throws {
        let h = try await makeHarness(initialMd: "She was very angry.")
        let pid = try await h.doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId

        // Author a human span suggestion over "very angry" (chars 8..<18) → "furious".
        let span = SpanAnchorResolver.capture(
            in: "She was very angry.", range: 8..<18)
        let annId = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: pid, span: span,
            body: "tighten", suggestedText: "furious", authorName: "R")

        // The DISPLAYED suggestion stays the bare replacement (so the review card
        // shows `→ furious`, not the whole resulting paragraph — the splice is
        // deferred to accept).
        XCTAssertEqual(h.doc.annotations().first?.suggestedText, "furious",
            "the op stores the bare suggested text for display; the splice is at accept")

        try await h.doc.acceptAnnotation(id: annId)

        XCTAssertEqual(h.doc.displayText, "She was furious.",
            "accepting a span suggestion must splice ONLY the span, not replace "
            + "the whole paragraph with the bare suggested text")

        await h.documentStore.close()
    }
}
