import XCTest
import MaughamCore
@testable import Maugham

/// TDD tests for finding 1.8 (trash restore structural corruption).
/// These tests are RED until ProjectStore+Trash.swift is fixed to honor
/// originalParentId / originalIndex and validate descendant paths.
@MainActor
final class TrashRestoreNestingTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() {
        super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    // MARK: - Test 1: nested item restores to its original parent at originalIndex

    /// Trash an item that is NESTED (under a parent group, at a specific index,
    /// with siblings). Restore it. Assert it returns to its originalParentId at
    /// originalIndex (clamped), NOT root.
    func test_restore_nestedItem_returnsToOriginalParentAtOriginalIndex() async throws {
        let url = try await makeProjectWithNestedStructure()
        let store = try await ProjectStore.load(from: url)

        // Structure after load:
        // root:
        //   grp-act1 (Act One, group)
        //     doc-ch1 (Chapter 1, index 0)
        //     doc-ch2 (Chapter 2, index 1)  ← we will trash this
        //     doc-ch3 (Chapter 3, index 2)
        //   doc-epilogue (Epilogue, root index 1)

        let actOne = store.manifest.structure.first(where: { $0.title == "Act One" })!
        let chapter2 = actOne.children!.first(where: { $0.title == "Chapter 2" })!

        // Confirm starting position: index 1 under grp-act1
        let childrenBefore = actOne.children!
        XCTAssertEqual(childrenBefore.firstIndex(where: { $0.id == chapter2.id }), 1,
                       "Chapter 2 should be at index 1 before delete")

        // Trash Chapter 2
        try await store.deleteStructureItem(id: chapter2.id)

        // Verify it's gone from the structure
        let actOneAfterDelete = store.manifest.structure
            .first(where: { $0.id == actOne.id })!
        XCTAssertNil(actOneAfterDelete.children?.first(where: { $0.id == chapter2.id }),
                     "Chapter 2 should be removed from Act One's children after trash")
        XCTAssertEqual(store.manifest.structure.count, 2,  // Act One + Epilogue at root
                       "Root should still have 2 items (Act One + Epilogue)")

        // Restore
        try await store.restoreLastDeletion()

        // ASSERT: Chapter 2 must be back under Act One (not appended to root)
        let actOneAfterRestore = store.manifest.structure
            .first(where: { $0.id == actOne.id })
        XCTAssertNotNil(actOneAfterRestore,
                        "Act One should still be in structure after restore")

        let restoredChildren = actOneAfterRestore?.children ?? []
        let restoredCh2 = restoredChildren.first(where: { $0.id == chapter2.id })
        XCTAssertNotNil(restoredCh2,
                        "Chapter 2 must be restored under Act One, not at root (finding 1.8)")

        // Root should NOT have gained Chapter 2
        let rootHasCh2 = store.manifest.structure.contains(where: { $0.id == chapter2.id })
        XCTAssertFalse(rootHasCh2,
                       "Chapter 2 must NOT be appended to root on restore (finding 1.8)")

        // Index must be at originalIndex (1), clamped to actual sibling count
        let restoredIndex = restoredChildren.firstIndex(where: { $0.id == chapter2.id })
        XCTAssertEqual(restoredIndex, 1,
                       "Chapter 2 must restore at index 1 (originalIndex), not appended (finding 1.8)")
    }

    // MARK: - Test 2: restored subtree drops descendants whose files no longer exist

    /// Trash a SUBTREE (group with children), hard-delete one child's file from disk,
    /// restore the group. Assert no dangling binder row points at a non-existent path.
    func test_restore_subtreeWithMissingDescendant_dropsDanglingRow() async throws {
        let url = try await makeProjectWithNestedStructure()
        let store = try await ProjectStore.load(from: url)

        let actOne = store.manifest.structure.first(where: { $0.title == "Act One" })!
        let ch1 = actOne.children!.first(where: { $0.title == "Chapter 1" })!

        // Trash Act One (the whole group with its 3 children)
        try await store.deleteStructureItem(id: actOne.id)
        XCTAssertNil(store.manifest.structure.first(where: { $0.id == actOne.id }),
                     "Act One should be gone from structure")

        // Now simulate a hard-delete of Chapter 1's file inside the trash folder.
        // Find the trashed group folder and remove Chapter 1's file from it.
        let trashEntry = store.trashEntries.first!
        let trashRoot = url.appendingPathComponent(".trash")
        let entryFolder = trashRoot.appendingPathComponent(trashEntry.id)

        // The trashed group folder is the non-meta.json item inside entryFolder
        let entryContents = try FileManager.default.contentsOfDirectory(
            at: entryFolder, includingPropertiesForKeys: nil, options: [])
        let groupFolder = entryContents.first(where: { $0.lastPathComponent != "meta.json" })!

        // Find Chapter 1's file inside the group folder
        let ch1Filename = (ch1.path! as NSString).lastPathComponent
        let ch1FileInTrash = groupFolder.appendingPathComponent(ch1Filename)
        // Chapter 1 is at e.g. "manuscript/01-act-one/01-chapter-1.md" → leaf is "01-chapter-1.md"
        // In the trash the group folder contains the whole subtree flattened at its original
        // relative position, so find any .md file that matches.
        // The TrashStore restores the group folder as a directory; children are inside it.
        let groupContents = (try? FileManager.default.contentsOfDirectory(
            at: groupFolder, includingPropertiesForKeys: nil, options: [])) ?? []
        let ch1InTrash = groupContents.first(where: { $0.lastPathComponent == ch1Filename })
            ?? groupFolder.appendingPathComponent(ch1Filename)
        // Hard-delete Chapter 1's file from the trash copy
        try? FileManager.default.removeItem(at: ch1InTrash)

        // Restore Act One
        try await store.restoreTrashEntry(id: trashEntry.id)

        // ASSERT: Act One is back
        let restoredActOne = store.manifest.structure.first(where: { $0.id == actOne.id })
        XCTAssertNotNil(restoredActOne, "Act One must be restored")

        // ASSERT: No binder row points at a path that doesn't exist on disk.
        // The policy is: drop descendants whose paths no longer exist on disk.
        let allItems = collectAllItems(restoredActOne!)
        for item in allItems {
            if let path = item.path, !path.isEmpty {
                let fullURL = url.appendingPathComponent(path)
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: fullURL.path),
                    "Restored item '\(item.title)' has a dangling path '\(path)' — " +
                    "binder row points at non-existent file (finding 1.8)")
            }
        }
    }

    // MARK: - Test 3: original-parent-deleted fallback

    /// Trash a child, then trash its parent, then restore the child.
    /// The original parent no longer exists in the structure → graceful fallback
    /// to root. No crash, no dangling row.
    func test_restore_whenOriginalParentDeleted_fallsBackToRoot() async throws {
        let url = try await makeProjectWithNestedStructure()
        let store = try await ProjectStore.load(from: url)

        let actOne = store.manifest.structure.first(where: { $0.title == "Act One" })!
        let ch1 = actOne.children!.first(where: { $0.title == "Chapter 1" })!

        // Step 1: Trash Chapter 1 (child)
        try await store.deleteStructureItem(id: ch1.id)
        let ch1TrashId = store.trashEntries.first(where: {
            $0.displayTitle == "Chapter 1"
        })!.id

        // Step 2: Trash Act One (the original parent)
        try await store.deleteStructureItem(id: actOne.id)

        // Confirm neither is in structure
        XCTAssertNil(store.manifest.structure.first(where: { $0.id == ch1.id }))
        XCTAssertNil(store.manifest.structure.first(where: { $0.id == actOne.id }))

        // Step 3: Restore Chapter 1 — its original parent (Act One) is gone
        // Expect: graceful fallback to root, no crash
        try await store.restoreTrashEntry(id: ch1TrashId)

        // Chapter 1 must appear somewhere in the structure (not thrown away)
        let allStructureItems = collectAllStructureItems(store.manifest.structure)
        let restoredCh1 = allStructureItems.first(where: { $0.id == ch1.id })
        XCTAssertNotNil(restoredCh1,
                        "Chapter 1 must appear in structure after restore even when its " +
                        "original parent was deleted (finding 1.8 fallback)")

        // File must be back on disk
        let ch1Path = restoredCh1?.path ?? ch1.path!
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent(ch1Path).path),
            "Chapter 1's file must exist on disk after restore")
    }

    // MARK: - Helpers

    /// Build a project with this structure:
    ///   root:
    ///     Act One (group)
    ///       Chapter 1 (doc)
    ///       Chapter 2 (doc)
    ///       Chapter 3 (doc)
    ///     Epilogue (doc, root level)
    private func makeProjectWithNestedStructure() async throws -> URL {
        let fm = FileManager.default
        let projectURL = temp.url.appendingPathComponent("NestProject")
        try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let manuscriptURL = projectURL.appendingPathComponent("manuscript")
        try fm.createDirectory(at: manuscriptURL, withIntermediateDirectories: true)

        // Create the Act One group folder
        let actOneDir = manuscriptURL.appendingPathComponent("01-act-one")
        try fm.createDirectory(at: actOneDir, withIntermediateDirectories: true)

        // Create chapter files inside Act One
        try "Chapter 1 content".write(
            to: actOneDir.appendingPathComponent("01-chapter-1.md"),
            atomically: true, encoding: .utf8)
        try "Chapter 2 content".write(
            to: actOneDir.appendingPathComponent("02-chapter-2.md"),
            atomically: true, encoding: .utf8)
        try "Chapter 3 content".write(
            to: actOneDir.appendingPathComponent("03-chapter-3.md"),
            atomically: true, encoding: .utf8)

        // Epilogue at root level
        try "Epilogue content".write(
            to: manuscriptURL.appendingPathComponent("02-epilogue.md"),
            atomically: true, encoding: .utf8)

        let actOne = StructureItem(
            id: "grp-act1",
            title: "Act One",
            type: .group,
            path: "manuscript/01-act-one",
            children: [
                StructureItem(
                    id: "doc-ch1",
                    title: "Chapter 1",
                    type: .document,
                    path: "manuscript/01-act-one/01-chapter-1.md"),
                StructureItem(
                    id: "doc-ch2",
                    title: "Chapter 2",
                    type: .document,
                    path: "manuscript/01-act-one/02-chapter-2.md"),
                StructureItem(
                    id: "doc-ch3",
                    title: "Chapter 3",
                    type: .document,
                    path: "manuscript/01-act-one/03-chapter-3.md"),
            ])

        let epilogue = StructureItem(
            id: "doc-epilogue",
            title: "Epilogue",
            type: .document,
            path: "manuscript/02-epilogue.md")

        let manifest = ProjectManifest(
            type: .novel,
            title: "NestProject",
            author: "Tester",
            created: Date(),
            modified: Date(),
            structure: [actOne, epilogue],
            research: [])

        try ProjectManifest.makeEncoder().encode(manifest).write(
            to: projectURL.appendingPathComponent(ProjectManifest.fileName))

        return projectURL
    }

    /// Collect all StructureItems (self + descendants) from an item.
    private func collectAllItems(_ item: StructureItem) -> [StructureItem] {
        var result = [item]
        for child in item.children ?? [] {
            result.append(contentsOf: collectAllItems(child))
        }
        return result
    }

    /// Collect all StructureItems recursively from a flat root array.
    private func collectAllStructureItems(_ items: [StructureItem]) -> [StructureItem] {
        var result: [StructureItem] = []
        for item in items {
            result.append(item)
            result.append(contentsOf: collectAllItems(item).dropFirst())
        }
        return result
    }
}
