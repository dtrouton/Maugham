import XCTest
import MaughamCore
@testable import Maugham

/// F5 perf guards, asserted by DERIVE COUNT (cache hits), never wall-clock —
/// so CI can't flake. Exercises the real adopters (`ProjectStore.load`
/// word-count population + `ProjectSearchEngine`) against the per-project
/// `derivedCache`.
@MainActor
final class DerivedCachePerfGuardTests: XCTestCase {

    /// Write `<docId>.jsonl` under `root`, appending so a second call grows the
    /// file (mutating the cache token). Ops carry `text` as a single paragraph.
    @discardableResult
    private func appendOp(
        root: URL, docId: String, opId: String, paraId: String, text: String
    ) throws {
        let opsDir = root.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(at: opsDir, withIntermediateDirectories: true)
        let op = Op(
            opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
            device: "d", session: "s", kind: .typingBurst,
            changes: [Op.ParagraphChange(paragraphId: paraId, prior: nil, next: text)],
            sequence: [paraId], provenance: nil)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        let line = String(data: try enc.encode(op), encoding: .utf8)! + "\n"
        let fileURL = opsDir.appendingPathComponent("\(docId).jsonl")
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try handle.close()
        } else {
            try line.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// (c) project-open + first search ≤ 1 derive per doc; (a) second identical
    /// search performs 0 derives.
    func test_openThenSearch_oneDerivePerDoc_andSecondSearchZero() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DerivedPerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try appendOp(root: root, docId: "doc-a", opId: "01a", paraId: "aaaa", text: "Alpha content here.")
        try appendOp(root: root, docId: "doc-b", opId: "01b", paraId: "bbbb", text: "Beta content here.")
        let items = [
            StructureItem(id: "doc-a", title: "A", type: .document, path: "a.md"),
            StructureItem(id: "doc-b", title: "B", type: .document, path: "b.md"),
        ]
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: items, research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: root.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: root)
        await store.wordCountPopulationTask?.value
        // Word-count population derived each of the 2 docs exactly once.
        XCTAssertEqual(store.derivedCache.deriveCount, 2,
            "project-open word counts should derive each doc once (≤1 per doc)")

        let engine = ProjectSearchEngine()
        _ = await engine.search(query: "content", options: SearchOptions(), in: store)
        XCTAssertEqual(store.derivedCache.deriveCount, 2,
            "first search reuses the warm cache — no additional derives")

        _ = await engine.search(query: "content", options: SearchOptions(), in: store)
        XCTAssertEqual(store.derivedCache.deriveCount, 2,
            "second identical search performs 0 derives")
    }

    /// (b) editing one doc invalidates only that doc.
    func test_editingOneDoc_invalidatesOnlyThatDoc() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DerivedPerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try appendOp(root: root, docId: "doc-a", opId: "01a", paraId: "aaaa", text: "Alpha content here.")
        try appendOp(root: root, docId: "doc-b", opId: "01b", paraId: "bbbb", text: "Beta content here.")
        let items = [
            StructureItem(id: "doc-a", title: "A", type: .document, path: "a.md"),
            StructureItem(id: "doc-b", title: "B", type: .document, path: "b.md"),
        ]
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: items, research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: root.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: root)
        await store.wordCountPopulationTask?.value
        XCTAssertEqual(store.derivedCache.deriveCount, 2)

        // Grow ONLY doc-a's op log on disk (append a second op).
        try appendOp(root: root, docId: "doc-a", opId: "01a2", paraId: "cccc", text: "Alpha grows.")

        let engine = ProjectSearchEngine()
        _ = await engine.search(query: "content", options: SearchOptions(), in: store)
        XCTAssertEqual(store.derivedCache.deriveCount, 3,
            "only doc-a's token changed → exactly one re-derive; doc-b stays cached")
    }
}
