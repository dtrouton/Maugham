import XCTest
import MaughamCore
@testable import Maugham

/// Regression: `read_document` on a CLOSED doc must derive its text from the
/// op log, not the on-disk `.md` (which can be stale). ADR 0018.
///
/// Before the fix: the closed-doc branch read the `.md` verbatim — a stale
/// file made read_document and add_comment disagree on paragraph ids, causing
/// `paragraph_not_found` errors.
@MainActor
final class ReadDocumentOpLogSourceTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let projectURL: URL
        let projectId: String
        let docId: String
        let docURL: URL
        let registry: ProjectRegistry
        let documentStore: DocumentStore
    }

    private func makeHarness(initialMd: String) async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RDOLS-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId = "doc-rdols-test"
        let docURL = tmp.appendingPathComponent(docPath)
        try initialMd.write(to: docURL, atomically: true, encoding: .utf8)

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

        // Load the Document so Bootstrap runs and the op log is populated.
        // Crucially: do NOT register it with DocumentStore — that keeps it
        // "closed" so emitManuscriptDoc's closed-doc branch is exercised.
        _ = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        let reg = ProjectRegistry()
        reg.register(url: tmp, store: pStore)
        let projectId = ProjectIdentifier.id(for: tmp)

        return Harness(
            projectURL: tmp,
            projectId: projectId,
            docId: docId,
            docURL: docURL,
            registry: reg,
            documentStore: ds)
    }

    // MARK: - Tests

    /// read_document on a CLOSED doc must reflect the op log, not a stale `.md`.
    func test_readDocument_closedDoc_usesOpLogNotStaleMd() async throws {
        let h = try await makeHarness(initialMd: "Real op-log text.")
        defer { Task { await h.documentStore.close() } }

        // Corrupt the on-disk .md so it disagrees with the op log.
        try "STALE WRONG CONTENT".write(to: h.docURL, atomically: true, encoding: .utf8)

        let paramsData = try JSONSerialization.data(withJSONObject: [
            "project_id": h.projectId,
            "document_id": h.docId])
        let result = try await ReadDocumentTool.handle(
            paramsJSON: paramsData, registry: h.registry)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result) as? [String: Any])
        let text = try XCTUnwrap(obj["text"] as? String)

        XCTAssertTrue(text.contains("Real op-log text."),
            "read_document must derive from the op log, not the stale .md; got: \(text.prefix(200))")
        XCTAssertFalse(text.contains("STALE WRONG CONTENT"),
            "read_document must not return the stale .md content; got: \(text.prefix(200))")
    }
}
