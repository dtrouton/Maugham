import XCTest
@testable import Maugham

@MainActor
final class TrashIntegrationTests: XCTestCase {
    private func makeProjectWithChapter() async throws -> (URL, ProjectStore, StructureItem) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashIntegration-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "Chapter X".write(
            to: tmp.appendingPathComponent("manuscript/chapter-x.md"),
            atomically: true, encoding: .utf8)

        let chapter = StructureItem(
            id: "ch-x", title: "Chapter X", type: .document,
            path: "manuscript/chapter-x.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: tmp)
        return (tmp, store, chapter)
    }

    func test_deleteStructureItem_routesToTrash() async throws {
        let (project, store, chapter) = try await makeProjectWithChapter()
        try await store.deleteStructureItem(id: chapter.id)

        XCTAssertEqual(store.manifest.structure.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("manuscript/chapter-x.md").path))
        XCTAssertEqual(store.trashEntries.count, 1)
        XCTAssertEqual(store.trashEntries[0].displayTitle, "Chapter X")
    }

    func test_restoreLastDeleted_bringsBackToOriginalPosition() async throws {
        let (project, store, chapter) = try await makeProjectWithChapter()
        try await store.deleteStructureItem(id: chapter.id)
        try await store.restoreLastDeleted()

        XCTAssertEqual(store.manifest.structure.count, 1)
        XCTAssertEqual(store.manifest.structure[0].id, chapter.id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("manuscript/chapter-x.md").path))
        XCTAssertEqual(store.trashEntries.count, 0)
    }

    func test_restoreLastDeleted_whenNothingTrashed_noOps() async throws {
        let (_, store, _) = try await makeProjectWithChapter()
        // Don't delete anything
        try await store.restoreLastDeleted()  // Should not throw
        XCTAssertEqual(store.manifest.structure.count, 1)
    }
}
