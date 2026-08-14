import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ProjectStoreInspectorTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeNovel() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Inspector", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    func test_updateInspector_setsTags() async throws {
        let (_, store, ds) = try await makeNovel()
        let id = store.manifest.structure[0].id
        try await store.updateInspector(id: id, tags: ["margaret", "lighthouse"])
        let updated = store.manifest.structure[0]
        XCTAssertEqual(updated.tags, ["margaret", "lighthouse"])
        await ds.close()
    }

    func test_updateInspector_setsWordTarget() async throws {
        let (_, store, ds) = try await makeNovel()
        let id = store.manifest.structure[0].id
        try await store.updateInspector(id: id, wordTarget: 5000)
        XCTAssertEqual(store.manifest.structure[0].wordTarget, 5000)
        // Setting 0 clears.
        try await store.updateInspector(id: id, wordTarget: 0)
        XCTAssertNil(store.manifest.structure[0].wordTarget)
        await ds.close()
    }

    func test_updateInspector_setsLinks() async throws {
        let (_, store, ds) = try await makeNovel()
        let chapter1 = store.manifest.structure[0]
        let chapter2 = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2",
            kind: .document(extension: "md"))
        try await store.updateInspector(id: chapter1.id, links: [chapter2.id])
        XCTAssertEqual(store.manifest.structure[0].links, [chapter2.id])
        await ds.close()
    }

    // MARK: - setPassState (M3 P1 Task 4)

    /// The verb's happy path, asserted through a **manifest round-trip** rather
    /// than off the in-memory manifest: `PassState` hand-writes its `Codable`
    /// conformance, and an in-memory-only assertion would pass just as happily
    /// against a verb that never saved.
    func test_setPassState_persistsThroughAManifestRoundTrip() async throws {
        let (url, store, ds) = try await makeNovel()
        let id = store.manifest.structure[0].id

        try await store.setPassState(id: id, passId: "structural", .done)
        try await store.setPassState(id: id, passId: "line", .inProgress)

        let reloaded = try await ProjectStore.load(from: url)
        let item = try XCTUnwrap(reloaded.manifest.structure.first { $0.id == id })
        XCTAssertEqual(item.passStates?["structural"], .done)
        XCTAssertEqual(item.passStates?["line"], .inProgress)
        await ds.close()
    }

    /// `nil` REMOVES the key — it is the ladder's "Untouched" row, and an
    /// absent key is what `ReviewStatus.derived` reads as untouched. Storing a
    /// fourth "notStarted" state instead would make `PassState` grow a case the
    /// type deliberately does not have.
    func test_setPassState_nilRemovesTheKeyAndLeavesTheRest() async throws {
        let (_, store, ds) = try await makeNovel()
        let id = store.manifest.structure[0].id
        try await store.setPassState(id: id, passId: "structural", .done)
        try await store.setPassState(id: id, passId: "line", .skipped)

        try await store.setPassState(id: id, passId: "structural", nil)

        let item = try XCTUnwrap(store.manifest.structure.first { $0.id == id })
        XCTAssertNil(item.passStates?["structural"])
        XCTAssertEqual(item.passStates?["line"], .skipped,
                       "clearing one pass must not disturb another")
        await ds.close()
    }

    /// An EMPTIED map becomes `nil`, not `[:]`. Both read as untouched, so this
    /// is invisible on screen — and that is exactly why it needs a test: an
    /// empty dictionary is a `"passStates": {}` object written into every
    /// manifest a writer ever cleared a pass in, and (per `StructureItem`'s
    /// optional-on-purpose doc) absence is the encoding that costs nothing.
    func test_setPassState_clearingTheLastPassLeavesNilNotAnEmptyMap() async throws {
        let (url, store, ds) = try await makeNovel()
        let id = store.manifest.structure[0].id
        try await store.setPassState(id: id, passId: "structural", .done)
        try await store.setPassState(id: id, passId: "structural", nil)

        XCTAssertNil(store.manifest.structure.first { $0.id == id }?.passStates)

        let onDisk = try String(
            contentsOf: url.appendingPathComponent(ProjectManifest.fileName),
            encoding: .utf8)
        XCTAssertFalse(onDisk.contains("passStates"),
                       "an emptied map was encoded rather than dropped")
        await ds.close()
    }

    /// A newer build's state round-trips verbatim through this verb too: the
    /// ladder offers the three known states, and setting one must not be a
    /// route by which `.unknown`'s payload is rewritten to something this build
    /// invented (`PassState`'s lossless contract).
    func test_setPassState_preservesAnUnknownStateOnAnotherPass() async throws {
        let (url, store, ds) = try await makeNovel()
        let id = store.manifest.structure[0].id
        try await store.setPassState(
            id: id, passId: "sensitivity", .unknown("awaiting_reader"))
        try await store.setPassState(id: id, passId: "structural", .done)

        let reloaded = try await ProjectStore.load(from: url)
        let item = try XCTUnwrap(reloaded.manifest.structure.first { $0.id == id })
        XCTAssertEqual(item.passStates?["sensitivity"], .unknown("awaiting_reader"))
        await ds.close()
    }

    /// Same guard-find beat as `updateInspector`: an id naming nothing throws
    /// rather than silently minting a row of states against nobody.
    func test_setPassState_invalidId_throws() async throws {
        let (_, store, ds) = try await makeNovel()
        do {
            try await store.setPassState(id: "nope", passId: "structural", .done)
            XCTFail("expected throw")
        } catch ProjectStoreError.structureMissing {
            // ok
        }
        await ds.close()
    }

    /// The fourth beat. `modified` is what the shelf sorts on and what the
    /// manifest-echo guard compares, so a verb that mutated structure without
    /// moving it would write a manifest the store's own conflict detection
    /// reads as somebody else's.
    func test_setPassState_movesTheProjectsModifiedStamp() async throws {
        let (_, store, ds) = try await makeNovel()
        let id = store.manifest.structure[0].id
        // `modified` round-trips through whole-second ISO8601, so the test has
        // to cross a second boundary before it can observe a change at all.
        let before = store.manifest.modified
        try await Task.sleep(for: .milliseconds(1100))
        try await store.setPassState(id: id, passId: "structural", .done)
        XCTAssertGreaterThan(store.manifest.modified, before)
        await ds.close()
    }

    func test_resolveDocumentId_byTitleCaseInsensitive() async throws {
        let (_, store, ds) = try await makeNovel()
        let chapter1 = store.manifest.structure[0]
        XCTAssertEqual(
            store.resolveDocumentId(forTitle: "chapter 1"),
            chapter1.id)
        XCTAssertEqual(
            store.resolveDocumentId(forTitle: "  Chapter 1  "),
            chapter1.id)
        XCTAssertNil(store.resolveDocumentId(forTitle: "nonsense"))
        await ds.close()
    }

    func test_projectWordCount_sumsLoadedDocuments() async throws {
        let (url, store, ds) = try await makeNovel()
        // Seed Chapter 1 with text via direct file write + record cache.
        let chapter1 = store.manifest.structure[0]
        try "one two three four five".write(
            to: url.appendingPathComponent(chapter1.path!),
            atomically: true, encoding: .utf8)
        store.recordWordCount(forDocumentId: chapter1.id, wordCount: 5)
        XCTAssertEqual(store.projectWordCount, 5)
        await ds.close()
    }

    func test_renameStructureItem_propagatesWikiLinkReferences() async throws {
        let (url, store, ds) = try await makeNovel()
        let chapter1 = store.manifest.structure[0]
        let chapter2 = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2",
            kind: .document(extension: "md"))
        // Seed chapter 2 with a body that references chapter 1 by title.
        let chapter2Body = "Margaret revisits [[Chapter 1]] and reflects."
        try chapter2Body.write(
            to: url.appendingPathComponent(chapter2.path!),
            atomically: true, encoding: .utf8)

        try await store.renameStructureItem(
            id: chapter1.id, newTitle: "The Opening")

        // Re-read chapter 2's body after rename: the wiki link should now
        // reference the new title. The rewrite is now op-routed (M1.2 —
        // Document.load → setFullText → close), so the on-disk `.md` is
        // materialized WITH `¶id` anchors; strip them to compare the body.
        let updated = try String(
            contentsOf: url.appendingPathComponent(
                store.manifest.structure[1].path!),
            encoding: .utf8)
        let body = MarkdownDisplayFilter.stripAnchors(updated)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            body,
            "Margaret revisits [[The Opening]] and reflects.")
        await ds.close()
    }
}
