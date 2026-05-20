import XCTest
@testable import Maugham

@MainActor
final class AnnotationReadToolsTests: XCTestCase {

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
            .appendingPathComponent("ART-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId = "doc-read-test"
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

    // MARK: - list_annotations

    func test_listAnnotations_filtersByKindAndStatus() async throws {
        let h = try await makeHarness()

        // Obtain a real paragraph id from the bootstrap op.
        let pid = try await h.doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId

        let commentId = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "comment")
        _ = try await h.doc.addAnnotation(
            kind: .craftNote, paragraphId: nil, body: "craft")
        try await h.doc.archiveAnnotation(id: commentId)

        // Default (open only) — should show only the craftNote.
        let allOpenData = try JSONSerialization.data(
            withJSONObject: [
                "project_id": h.projectId,
                "document_id": h.doc.docId
            ])
        let openResult = try await ListAnnotationsTool.handle(
            paramsJSON: allOpenData, registry: h.registry)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let openList = try dec.decode(
            [ListAnnotationsTool.Item].self, from: openResult)
        XCTAssertEqual(openList.count, 1)
        XCTAssertEqual(openList[0].kind, "craft_note")

        // Filter for archived.
        let archivedData = try JSONSerialization.data(
            withJSONObject: [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "statuses": ["archived"]
            ])
        let archivedResult = try await ListAnnotationsTool.handle(
            paramsJSON: archivedData, registry: h.registry)
        let archivedList = try dec.decode(
            [ListAnnotationsTool.Item].self, from: archivedResult)
        XCTAssertEqual(archivedList.count, 1)
        XCTAssertEqual(archivedList[0].kind, "comment")
        XCTAssertEqual(archivedList[0].status, "archived")

        await h.documentStore.close()
    }

    // MARK: - get_annotation

    func test_getAnnotation_returnsFullRecord() async throws {
        let h = try await makeHarness()

        let pid = try await h.doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId

        let id = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "specific text")

        let data = try JSONSerialization.data(
            withJSONObject: [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "annotation_id": id
            ])
        let resultData = try await GetAnnotationTool.handle(
            paramsJSON: data, registry: h.registry)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let result = try dec.decode(
            GetAnnotationTool.Result.self, from: resultData)
        XCTAssertEqual(result.id, id)
        XCTAssertEqual(result.body, "specific text")
        XCTAssertEqual(result.status, "open")
        XCTAssertFalse(result.history.isEmpty)  // at least the creation op

        await h.documentStore.close()
    }
}
