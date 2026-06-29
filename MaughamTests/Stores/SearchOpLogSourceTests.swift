import XCTest
import MaughamCore
@testable import Maugham

/// ADR 0018 / Task 4: cross-document manuscript search must derive content
/// from the op log, NEVER the on-disk `.md`. A stale `.md` that diverges from
/// the op log must be invisible to search; only the op-log content is found.
@MainActor
final class SearchOpLogSourceTests: XCTestCase {

    func test_manuscriptSearch_readsOpLog_notStaleMd() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchOpLog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId   = "doc-sol-adr0018"
        let docURL  = tmp.appendingPathComponent(docPath)

        // A token that lives in the op log (written at bootstrap time).
        let opLogToken = "XOPLGTKN42"
        // A token written ONLY to the stale .md — must never surface in search.
        let staleToken = "STALE_XYZ99"

        // --- seed op log -----------------------------------------------
        // 1. Write the initial content so Bootstrap can mine it into ops.
        try opLogToken.write(to: docURL, atomically: true, encoding: .utf8)

        // 2. Write the manifest so resolveDocId returns `docId`.
        let item = StructureItem(
            id: docId, title: "C1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        // 3. Bootstrap: Document.load triggers Bootstrap.run → seeds the op log
        //    with opLogToken and writes the anchored .md back to disk.
        _ = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        // --- corrupt the .md -------------------------------------------
        // Overwrite the on-disk .md with stale content.  The op log is now
        // the ONLY correct source — the .md disagrees.
        try staleToken.write(to: docURL, atomically: true, encoding: .utf8)

        // --- search ----------------------------------------------------
        let store  = try await ProjectStore.load(from: tmp)
        let engine = ProjectSearchEngine()

        let opLogHits = await engine.search(
            query: opLogToken, options: SearchOptions(), in: store)
        let staleHits = await engine.search(
            query: staleToken, options: SearchOptions(), in: store)

        XCTAssertFalse(opLogHits.matches.isEmpty,
            "search must find '\(opLogToken)' from the op log (source of truth)")
        XCTAssertTrue(staleHits.matches.isEmpty,
            "search must NOT find '\(staleToken)' — it only exists in the stale .md")
    }
}
