import XCTest
@testable import Maugham

@MainActor
final class ProjectStoreDuplicateTests: XCTestCase {
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
            named: "Dupe", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    func test_duplicateDocument_createsCopyWithCopyOfPrefix() async throws {
        let (url, store, ds) = try await makeNovel()
        let chapter1 = store.manifest.structure[0]
        try "Hello world".write(
            to: url.appendingPathComponent(chapter1.path!),
            atomically: true, encoding: .utf8)

        let copy = try await store.duplicateStructureItem(id: chapter1.id)

        XCTAssertEqual(copy.title, "Copy of Chapter 1")
        XCTAssertNotEqual(copy.id, chapter1.id)
        XCTAssertEqual(copy.type, .document)

        let copyURL = url.appendingPathComponent(copy.path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
        let copyContent = try String(contentsOf: copyURL, encoding: .utf8)
        XCTAssertEqual(copyContent, "Hello world")

        XCTAssertEqual(store.manifest.structure.count, 2)
        XCTAssertEqual(store.manifest.structure[1].id, copy.id)
        await ds.close()
    }

    func test_duplicateDocument_filenameUsesNextNN() async throws {
        let (_, store, ds) = try await makeNovel()
        let chapter1 = store.manifest.structure[0]

        let copy = try await store.duplicateStructureItem(id: chapter1.id)

        XCTAssertTrue(copy.path!.hasPrefix("manuscript/02-"),
                      "expected NN '02-' prefix, got \(copy.path!)")
        await ds.close()
    }

    func test_duplicateGroup_recursivelyCopiesDescendants() async throws {
        let (url, store, ds) = try await makeNovel()
        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)
        let inner1 = try await store.addStructureItem(
            parentId: group.id, title: "Scene 1",
            kind: .document(extension: "md"))
        try "scene 1 text".write(
            to: url.appendingPathComponent(inner1.path!),
            atomically: true, encoding: .utf8)

        let copy = try await store.duplicateStructureItem(id: group.id)

        XCTAssertEqual(copy.title, "Copy of Act One")
        XCTAssertEqual(copy.type, .group)
        XCTAssertNotEqual(copy.id, group.id)
        XCTAssertEqual(copy.children?.count, 1)
        let copiedInner = copy.children!.first!
        XCTAssertNotEqual(copiedInner.id, inner1.id)
        XCTAssertEqual(copiedInner.title, "Scene 1")
        let copiedFileURL = url.appendingPathComponent(copiedInner.path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedFileURL.path))
        let copiedContent = try String(contentsOf: copiedFileURL, encoding: .utf8)
        XCTAssertEqual(copiedContent, "scene 1 text")
        await ds.close()
    }

    func test_duplicate_invalidId_throws() async throws {
        let (_, store, ds) = try await makeNovel()
        do {
            _ = try await store.duplicateStructureItem(id: "nope")
            XCTFail("expected throw")
        } catch ProjectStoreError.structureMissing {}
        await ds.close()
    }
}
