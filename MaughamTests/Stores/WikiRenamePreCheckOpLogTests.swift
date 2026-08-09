import XCTest
import MaughamCore
@testable import Maugham

/// ADR 0018 / Task 8: the wiki-rename pre-check must derive manuscript content
/// from the op log, NEVER the on-disk `.md`.
///
/// A doc whose op log contains `[[OldTitle]]` but whose stale `.md` does not
/// must NOT be skipped by the pre-check — the rename must propagate to it.
/// This test fails when the pre-check reads `String(contentsOf: docURL)` and
/// passes once the pre-check reads `DerivedManuscript.materialize(forDocId:in:)`.
@MainActor
final class WikiRenamePreCheckOpLogTests: XCTestCase {

    func test_preCheck_readsOpLog_notStaleMd_renamePropagatesToStaleDoc() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("WikiPreCheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let aPath = "manuscript/01-a.md"
        let bPath = "manuscript/01-b.md"
        let aURL  = tmp.appendingPathComponent(aPath)
        let bURL  = tmp.appendingPathComponent(bPath)

        // Write initial content for both docs.
        try "The protagonist.\n"
            .write(to: aURL, atomically: true, encoding: .utf8)
        try "See [[Alpha]] for the backstory.\n"
            .write(to: bURL, atomically: true, encoding: .utf8)

        // Write manifest so resolveDocId returns the correct IDs.
        let structure: [StructureItem] = [
            StructureItem(id: "a", title: "Alpha", type: .document, path: aPath),
            StructureItem(id: "b", title: "Beta",  type: .document, path: bPath),
        ]
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: structure, research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        // Bootstrap doc B via Document.load → seeds the op log with
        // "See [[Alpha]] for the backstory." and writes the anchored .md
        // back to disk.
        let seedB = try await Document.load(
            url: bURL, device: "seed", session: "seed", presenter: nil)
        await seedB.close()

        // Stale the .md: preserve the paragraph anchor IDs (so Document.load
        // won't re-bootstrap when it later loads B for the rename mutation)
        // but remove [[Alpha]] from the visible text.
        let anchoredMd = (try? String(contentsOf: bURL, encoding: .utf8)) ?? ""
        let staleMd = anchoredMd.replacingOccurrences(
            of: "[[Alpha]]", with: "the protagonist")
        try staleMd.write(to: bURL, atomically: true, encoding: .utf8)

        // Pre-condition: stale .md really has no [[Alpha]].
        let onDisk = (try? String(contentsOf: bURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(onDisk.contains("[[Alpha]]"),
            "Stale .md must not contain [[Alpha]] — test setup error")

        // Pre-condition: op log still has [[Alpha]] (the source of truth).
        let opLogBody = try DerivedManuscript.materialize(forDocId: "b", in: tmp)
        XCTAssertTrue(opLogBody.contains("[[Alpha]]"),
            "Op log must contain [[Alpha]] before the rename — test setup error")

        // --- Run the rename ---
        let store = try await ProjectStore.load(from: tmp)
        let ds    = try await DocumentStore.open(url: tmp)
        store.documentStore = ds
        // Doc B is NOT registered in the DocumentStore → closed-doc pre-check path.

        try await store.renameStructureItem(id: "a", newTitle: "Omega")

        // --- Assert: rename propagated through the op log ---
        // When the pre-check reads the stale .md it finds no [[Alpha]] and
        // incorrectly skips B, leaving [[Alpha]] untouched (FAIL before fix).
        // When the pre-check reads the op log it finds [[Alpha]] and correctly
        // proceeds, so the result must contain [[Omega]] (PASS after fix).
        let result = try DerivedManuscript.materialize(forDocId: "b", in: tmp)
        XCTAssertTrue(
            result.contains("[[Omega]]"),
            "Wiki-rename must not skip B because its stale .md lacks [[Alpha]]; " +
            "the op-log pre-check must find [[Alpha]] and propagate the rename.")
        XCTAssertFalse(
            result.contains("[[Alpha]]"),
            "[[Alpha]] must be gone from doc B after the rename.")
    }
}
