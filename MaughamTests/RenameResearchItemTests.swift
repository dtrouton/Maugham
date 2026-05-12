import XCTest
@testable import Maugham

@MainActor
final class RenameResearchItemTests: XCTestCase {
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
            named: "RenameTest", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    func test_renamingNote_renamesFileOnDisk() async throws {
        let (project, store, ds) = try await makeNovel()
        let note = try await store.addResearchTextNote(parentId: nil)
        let originalPath = project.appendingPathComponent("research/untitled-note.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalPath.path))

        try await store.updateResearchItem(id: note.id, title: "Sarah")

        // Old file gone, new file in place
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalPath.path))
        let newPath = project.appendingPathComponent("research/sarah.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPath.path))

        // Manifest path updated
        let updated = store.manifest.research.first(where: { $0.id == note.id })
        XCTAssertEqual(updated?.path, "research/sarah.md")
        XCTAssertEqual(updated?.title, "Sarah")
        await ds.close()
    }

    func test_renamingNote_preservesContent() async throws {
        let (project, store, ds) = try await makeNovel()
        let note = try await store.addResearchTextNote(parentId: nil)
        // Write content to the note
        let path = project.appendingPathComponent(note.path!)
        try "Some content\nLine 2".write(to: path, atomically: true, encoding: .utf8)

        try await store.updateResearchItem(id: note.id, title: "Sarah")

        let newPath = project.appendingPathComponent("research/sarah.md")
        let content = try String(contentsOf: newPath, encoding: .utf8)
        XCTAssertEqual(content, "Some content\nLine 2")
        await ds.close()
    }

    func test_renamingGroup_renamesFolderOnDisk() async throws {
        let (project, store, ds) = try await makeNovel()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Untitled Group", kind: nil)
        // Add a child note inside the group to verify recursive path update
        let child = try await store.addResearchTextNote(parentId: group.id)
        XCTAssertTrue(child.path?.contains("untitled-group/") ?? false)

        try await store.updateResearchItem(id: group.id, title: "Characters")

        // Folder renamed
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("research/untitled-group").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("research/characters").path))

        // Child path updated in manifest
        let updatedGroup = store.manifest.research
            .first(where: { $0.id == group.id })
        let updatedChild = updatedGroup?.children?.first
        XCTAssertEqual(updatedChild?.path, "research/characters/untitled-note.md")
        await ds.close()
    }

    func test_renamingNote_dedupsAgainstExistingFile() async throws {
        let (project, store, ds) = try await makeNovel()
        // Create two notes
        let a = try await store.addResearchTextNote(parentId: nil, title: "Note A")
        let b = try await store.addResearchTextNote(parentId: nil, title: "Note B")
        _ = a

        // Try to rename b → "Note A" (collision with a's file)
        try await store.updateResearchItem(id: b.id, title: "Note A")

        // b should get a dedup slug (note-a-2.md)
        let bAfter = store.manifest.research.first(where: { $0.id == b.id })
        XCTAssertEqual(bAfter?.title, "Note A")
        XCTAssertEqual(bAfter?.path, "research/note-a-2.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("research/note-a-2.md").path))
        await ds.close()
    }
}
