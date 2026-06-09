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
