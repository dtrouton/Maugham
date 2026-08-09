import XCTest
import MaughamCore
@testable import Maugham

/// ADR 0018 open-doc rule (finding F6): building the publish AST for an OPEN,
/// actively-edited doc must read the live `Document`'s in-memory state — the op
/// log lags an open doc by the burst window (30s idle / 90s cap) because the
/// 750ms autosave writes the `.md` + pending mirror but appends NO ops. A
/// persisted PDF/EPUB must not silently omit the newest text. Closed docs still
/// derive from the op log (see `PublishOpLogSourceTests`).
@MainActor
final class ProjectStoreASTSourceFreshnessTests: XCTestCase {

    func test_openDoc_unflushedEdit_appearsInAST() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASTFresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId = "doc-astfresh"
        let docURL = tmp.appendingPathComponent(docPath)
        try "Original body text.".write(to: docURL, atomically: true, encoding: .utf8)

        let item = StructureItem(id: docId, title: "Ch 1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds
        defer { Task { await ds.close() } }

        // Open the doc (Bootstrap seeds the op log with the original) and
        // register it so the source treats it as live.
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: docPath)

        // Mutate WITHOUT flushing the burst — no ops reach `.maugham/ops/`.
        doc.setFullText("Freshly typed sentence not yet flushed.")

        let source = ProjectStoreASTSource(projectStore: store)
        let pieces = try source.orderedPieces()
        let piece = try XCTUnwrap(pieces.first { $0.pieceID == docId })

        XCTAssertTrue(
            piece.displayText.contains("Freshly typed sentence not yet flushed."),
            "AST for an open doc must reflect the unflushed live edit; got: \(piece.displayText)")
        XCTAssertFalse(
            piece.displayText.contains("Original body text."),
            "stale op-log content must not appear for an open doc; got: \(piece.displayText)")
    }
}
