import XCTest
import MaughamCore
@testable import Maugham

/// ADR 0018 open-doc rule (finding F6): cross-document search must read an
/// OPEN doc's live `Document` state. The op log lags an actively-edited doc by
/// the burst window (30s/90s) — the 750ms autosave appends no ops — so a
/// search that always derives would miss the newest text. Closed docs still
/// derive from the op log (see `SearchOpLogSourceTests`).
@MainActor
final class SearchFreshnessTests: XCTestCase {

    func test_openDoc_unflushedEdit_isSearchable() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchFresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId = "doc-searchfresh"
        let docURL = tmp.appendingPathComponent(docPath)
        try "ORIGINALTOKEN baseline content.".write(
            to: docURL, atomically: true, encoding: .utf8)

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

        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: docPath)

        // Mutate WITHOUT flushing the burst — no ops reach `.maugham/ops/`.
        doc.setFullText("The unflushed FRESHTOKEN99 lives only in memory.")

        let engine = ProjectSearchEngine()
        let freshHits = await engine.search(
            query: "FRESHTOKEN99", options: SearchOptions(), in: store)
        XCTAssertFalse(freshHits.matches.isEmpty,
            "search must find the unflushed open-doc text via the live Document")

        let staleHits = await engine.search(
            query: "ORIGINALTOKEN", options: SearchOptions(), in: store)
        XCTAssertTrue(staleHits.matches.isEmpty,
            "the replaced original must no longer match once the doc is edited live")
    }
}
