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

    /// Finding 1 (2026-07 sweep): `renameResearchPath`'s ref-rewrite now routes
    /// through the shared non-throwing `rewriteAssetRefsBestEffort` helper — the
    /// FS moves commit first, so a rewrite failure must never abort the rename.
    /// The helper's swallow behaviour is pinned directly by
    /// `ResearchMoveTests.test_rewriteAssetRefsBestEffort_swallowsWriteFailure`;
    /// this end-to-end test pins that the RENAME path actually uses the helper
    /// and rewrites refs to the *deduped* stem (the exact `newStem == dedupedSlug`
    /// wiring the happy-path test above doesn't exercise because it never dedups).
    func test_renamingNote_dedupsAgainstCollisionAndRewritesRefsToDedupedStem() async throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameAssetsDedup-\(UUID())")
        let research = project.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: research.appendingPathComponent("old-name_assets"),
            withIntermediateDirectories: true)
        try Data().write(to: research.appendingPathComponent("old-name_assets/image-1.png"))
        try """
        # Old Name

        ![](./old-name_assets/image-1.png)
        """.write(to: research.appendingPathComponent("old-name.md"),
                  atomically: true, encoding: .utf8)

        // Pre-existing collision at the target slug forces dedup → new-name-2.
        try "occupied".write(
            to: research.appendingPathComponent("new-name.md"),
            atomically: true, encoding: .utf8)

        let note = ResearchItem(
            id: "note-1", title: "Old Name",
            type: .asset, kind: .document, path: "research/old-name.md")
        let occupant = ResearchItem(
            id: "note-2", title: "New Name",
            type: .asset, kind: .document, path: "research/new-name.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [note, occupant])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: project.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: project)
        try await store.updateResearchItem(id: "note-1", title: "New Name")

        // Renamed to the deduped stem, with its assets folder alongside.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: research.appendingPathComponent("old-name_assets").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: research.appendingPathComponent("new-name-2_assets/image-1.png").path))
        // Ref rewritten to the DEDUPED stem, not the raw slug.
        let updated = try String(
            contentsOf: research.appendingPathComponent("new-name-2.md"), encoding: .utf8)
        XCTAssertTrue(updated.contains("./new-name-2_assets/image-1.png"))
        XCTAssertFalse(updated.contains("./old-name_assets"))
    }

    /// W2's last sibling (#31): the note leaf and its `<stem>_assets` folder
    /// dedup JOINTLY. An orphaned `<target-slug>_assets/` at the destination —
    /// no `.md` beside it, so the leaf-only dedup sees a free slug — used to let
    /// the note's move commit and then throw on the assets move, leaving the
    /// manifest pointing at the old path while the disk held the new one.
    func test_renamingNote_dedupsJointlyAgainstAnOrphanedAssetsFolder() async throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameAssetsOrphan-\(UUID())")
        let research = project.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: research.appendingPathComponent("old-name_assets"),
            withIntermediateDirectories: true)
        try Data().write(to: research.appendingPathComponent("old-name_assets/image-1.png"))
        try """
        # Old Name

        ![](./old-name_assets/image-1.png)
        """.write(to: research.appendingPathComponent("old-name.md"),
                  atomically: true, encoding: .utf8)

        // The orphan: an assets folder at the target slug with NO note beside
        // it. The leaf `new-name.md` is free; `new-name_assets` is not.
        try FileManager.default.createDirectory(
            at: research.appendingPathComponent("new-name_assets"),
            withIntermediateDirectories: true)
        try Data().write(to: research.appendingPathComponent("new-name_assets/stray.png"))

        let note = ResearchItem(
            id: "note-1", title: "Old Name",
            type: .asset, kind: .document, path: "research/old-name.md")
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

        // Both halves land at the SAME jointly-vacant deduped stem.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: research.appendingPathComponent("new-name-2.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: research.appendingPathComponent("new-name-2_assets/image-1.png").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: research.appendingPathComponent("old-name.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: research.appendingPathComponent("old-name_assets").path))

        // The orphan is untouched — nothing was moved into or over it.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: research.appendingPathComponent("new-name_assets/stray.png").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: research.appendingPathComponent("new-name_assets/image-1.png").path))

        // Manifest matches disk.
        XCTAssertEqual(store.manifest.research.first?.path, "research/new-name-2.md")

        // Refs follow the deduped stem.
        let updated = try String(
            contentsOf: research.appendingPathComponent("new-name-2.md"), encoding: .utf8)
        XCTAssertTrue(updated.contains("./new-name-2_assets/image-1.png"))
    }
}
