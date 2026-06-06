import XCTest
import MaughamCore
@testable import Maugham

/// Integration coverage for Task 2.2: Find-Replace must route manuscript
/// edits THROUGH the op log (the source of truth), not raw-write the `.md`.
///
/// Before this fix `replaceMatch`/`replaceAll` spliced bytes straight into
/// the `.md` and `.write(to:atomically:)`, bypassing the op log entirely
/// (so the change was invisible to ops and clobbered on re-render) AND
/// racing the 750ms autosave on any open document. These tests pin the
/// contract: closed docs go through `Document.load` -> `setFullText` ->
/// persist; open docs apply via the live `Document`; the `.md` and op log
/// never diverge.
@MainActor
final class FindReplaceOpLogTests: XCTestCase {

    /// Build a temp Novel project with a single manuscript doc.
    /// The `.md` is written WITHOUT inline ¶id anchors; `Document.load`
    /// bootstraps it (minting anchors) the first time it's loaded.
    private func makeProject(
        body: String, slug: String = "c1"
    ) throws -> (project: URL, docPath: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindReplaceOpLog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/\(slug).md"
        try body.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-\(slug)", title: slug, type: .document,
                path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    /// replaceAll on a CLOSED document (no DocumentStore registry entry)
    /// must persist via the op log: a fresh `Document.load` after the
    /// replacement sees the new text, and the op log carries a typing_burst
    /// op (proving it went through ops, not a raw byte-splice).
    func test_replaceAll_closedDoc_goesThroughOpLog_and_survivesReload() async throws {
        let (project, docPath) = try makeProject(
            body: "The cat sat.\n\nThe cat ran.\n")
        let store = try await ProjectStore.load(from: project)
        XCTAssertNil(store.documentStore,
            "Precondition: doc is closed (no DocumentStore registry).")

        await store.performSearch(query: "cat", options: SearchOptions())
        // performSearch debounces 300ms + runs async; wait for it to land.
        try await pollUntil { store.currentSearch?.matchCount == 2 }
        let results = try XCTUnwrap(store.currentSearch)
        XCTAssertEqual(results.matchCount, 2)

        try await store.replaceAll(in: results, with: "dog")

        // The op log must now carry a typing_burst op for this doc.
        let docId = try resolveDocId(
            for: project.appendingPathComponent(docPath))
        let opStore = OpLogStore(projectURL: project)
        let ops = try await opStore.load(docId: docId)
        XCTAssertTrue(ops.contains { $0.kind == .typingBurst },
            "replaceAll must append a typing_burst op (went through the op log).")

        // A FRESH load must reflect the replacement in display form.
        let reloaded = try await Document.load(
            url: project.appendingPathComponent(docPath),
            device: "verify", session: "verify", presenter: nil)
        XCTAssertTrue(reloaded.displayText.contains("dog"),
            "Reloaded displayText should contain the replacement.")
        XCTAssertFalse(reloaded.displayText.contains("cat"),
            "Reloaded displayText should no longer contain the original.")
    }

    /// replaceMatch on an OPEN document (in the DocumentStore registry) must
    /// mutate the live Document so the editor reflects it immediately, and
    /// (after flushBurstNow) the op log carries the change.
    func test_replaceMatch_openDoc_reflectsImmediately_andRecordsOp() async throws {
        let (project, docPath) = try makeProject(
            body: "The cat sat.\n\nThe cat ran.\n")
        let store = try await ProjectStore.load(from: project)

        // Open the doc through the DocumentStore so it's in the registry.
        let ds = try await DocumentStore.open(url: project)
        store.documentStore = ds
        let doc = try await Document.load(
            url: project.appendingPathComponent(docPath),
            device: "editor", session: "editor",
            presenter: ds.presenter)
        ds.register(document: doc, for: docPath)
        let docId = doc.docId

        await store.performSearch(query: "cat", options: SearchOptions())
        try await pollUntil { store.currentSearch?.matchCount == 2 }
        let results = try XCTUnwrap(store.currentSearch)
        XCTAssertEqual(results.matchCount, 2)

        // Replace the FIRST occurrence only.
        let first = results.matches
            .filter { $0.documentPath == docPath }
            .min { $0.charRangeInDocument.location < $1.charRangeInDocument.location }!
        try await store.replaceMatch(first, with: "dog")

        // The LIVE document reflects the replacement immediately.
        XCTAssertTrue(doc.displayText.contains("dog"),
            "Open doc should reflect the replacement immediately.")
        // Only the first "cat" replaced — one "cat" remains.
        let catCount = doc.displayText.components(separatedBy: "cat").count - 1
        XCTAssertEqual(catCount, 1,
            "Exactly one occurrence should have been replaced.")

        // After flushing the burst, the op log carries the change.
        try await doc.flushBurstNow()
        let opStore = OpLogStore(projectURL: project)
        let ops = try await opStore.load(docId: docId)
        XCTAssertTrue(ops.contains { $0.kind == .typingBurst },
            "replaceMatch on an open doc must record a typing_burst op.")

        await doc.close()
        ds.unregister(path: docPath)
        await ds.close()
    }

    /// Poll a predicate up to ~3s, yielding between checks. Used because
    /// `performSearch` debounces + runs on a detached Task.
    private func pollUntil(
        _ predicate: () -> Bool,
        timeout: TimeInterval = 3.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("pollUntil timed out")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
