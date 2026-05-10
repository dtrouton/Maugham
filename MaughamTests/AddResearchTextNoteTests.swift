import XCTest
@testable import Maugham

@MainActor
final class AddResearchTextNoteTests: XCTestCase {
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
            named: "TestNote", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    func test_addNote_atRoot_writesFileAndManifestEntry() async throws {
        let (url, store, ds) = try await makeNovel()
        let note = try await store.addResearchTextNote(parentId: nil)

        XCTAssertEqual(note.kind, .document)
        XCTAssertEqual(note.type, .asset)
        XCTAssertEqual(note.title, "Untitled Note")
        XCTAssertTrue(note.path?.hasSuffix(".md") ?? false)

        let fileURL = url.appendingPathComponent(note.path ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(contents, "")
        await ds.close()
    }

    func test_addNote_titleCollision_dedupesNumerically() async throws {
        let (_, store, ds) = try await makeNovel()
        let first = try await store.addResearchTextNote(parentId: nil)
        let second = try await store.addResearchTextNote(parentId: nil)
        XCTAssertEqual(first.title, "Untitled Note")
        XCTAssertEqual(second.title, "Untitled Note 2")
        XCTAssertNotEqual(first.path, second.path)
        await ds.close()
    }

    func test_addNote_intoGroup_createsInsideGroupFolder() async throws {
        let (_, store, ds) = try await makeNovel()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Characters", kind: nil)
        let note = try await store.addResearchTextNote(parentId: group.id)
        XCTAssertTrue(note.path?.contains("characters/") ?? false,
                      "expected note inside characters group; got \(note.path ?? "<nil>")")
        await ds.close()
    }
}
