import XCTest
import MaughamCore
@testable import Maugham

/// ADR 0018 / Task 7: project-open word counts must derive from the op log,
/// NEVER the on-disk `.md`. A stale `.md` with a different word count must
/// not affect the cached total; only op-log content drives what is recorded.
@MainActor
final class WordCountOpLogSourceTests: XCTestCase {

    func test_populateWordCountCache_readsOpLog_notStaleMd() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordCountOpLog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/ch1.md"
        let docId   = "doc-wc-adr0018"
        let docURL  = tmp.appendingPathComponent(docPath)

        // --- seed op log ---------------------------------------------------
        // 1. Write exactly 3 words so Bootstrap mines them into the op log.
        let opLogText = "alpha beta gamma"   // 3 words
        try opLogText.write(to: docURL, atomically: true, encoding: .utf8)

        // 2. Write the manifest.
        let item = StructureItem(
            id: docId, title: "Ch1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        // 3. Bootstrap: Document.load → Bootstrap.run → seeds op log with
        //    the 3-word paragraph and writes back an anchored .md.
        _ = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        // --- corrupt the .md -----------------------------------------------
        // Overwrite with 7 words. If populateWordCountCache reads .md it will
        // record 7; if it reads the op log it will record 3.
        let staleMd = "one two three four five six seven"   // 7 words
        try staleMd.write(to: docURL, atomically: true, encoding: .utf8)

        // --- load project (kicks off async word-count population) ------------
        let store = try await ProjectStore.load(from: tmp)
        // F5: population is now off the blocking load path — await it before
        // asserting on the recorded count.
        await store.wordCountPopulationTask?.value

        let recorded = store.cachedWordCount(for: docId)
        XCTAssertNotNil(recorded, "populateWordCountCache must record a count for the document")
        XCTAssertEqual(
            recorded, 3,
            "word count must be 3 (op-log content), not 7 (stale .md count). "
            + "populateWordCountCache must read the op log, not the .md file.")
    }
}
