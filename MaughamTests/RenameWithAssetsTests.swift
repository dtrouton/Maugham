import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class RenameWithAssetsTests: XCTestCase {
    func test_renamingNote_alsoRenamesAssetsFolderAndUpdatesRefs() async throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameAssets-\(UUID())")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("research"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("research/old-name_assets"),
            withIntermediateDirectories: true)
        try Data().write(
            to: project.appendingPathComponent("research/old-name_assets/image-1.png"))
        let noteContent = """
        # Old Name

        ![](./old-name_assets/image-1.png)

        Some prose.
        """
        try noteContent.write(
            to: project.appendingPathComponent("research/old-name.md"),
            atomically: true, encoding: .utf8)

        let note = ResearchItem(
            id: "note-1",
            title: "Old Name",
            type: .asset,
            kind: .document,
            path: "research/old-name.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [note])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: project.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: project)
        try await store.updateResearchItem(id: "note-1", title: "New Name")

        // Old folder gone
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("research/old-name_assets").path))
        // New folder exists with the image
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("research/new-name_assets/image-1.png").path))
        // Note content updated
        let updated = try String(
            contentsOf: project.appendingPathComponent("research/new-name.md"),
            encoding: .utf8)
        XCTAssertTrue(updated.contains("./new-name_assets/image-1.png"))
        XCTAssertFalse(updated.contains("./old-name_assets"))
    }
}
