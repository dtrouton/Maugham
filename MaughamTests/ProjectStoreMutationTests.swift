import XCTest
@testable import Maugham

@MainActor
final class ProjectStoreMutationTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() {
        super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    // MARK: - addStructureItem

    func test_addDocument_atRoot_appendsAndCreatesFile() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let initialCount = store.manifest.structure.count

        let item = try await store.addStructureItem(
            parentId: nil,
            title: "Chapter 2",
            kind: .document(extension: "md"))

        XCTAssertEqual(store.manifest.structure.count, initialCount + 1)
        XCTAssertEqual(item.title, "Chapter 2")
        XCTAssertEqual(item.type, .document)
        let path = item.path ?? ""
        XCTAssertTrue(path.hasPrefix("manuscript/"))
        let fullURL = url.appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fullURL.path))
    }

    func test_addGroup_atRoot_createsFolder() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)

        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)

        XCTAssertEqual(group.type, .group)
        XCTAssertEqual(group.children?.count, 0)
        let path = group.path ?? ""
        let fullURL = url.appendingPathComponent(path)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fullURL.path,
                                                      isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func test_addDocument_underGroup_nestsCorrectly() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)

        let scene = try await store.addStructureItem(
            parentId: group.id,
            title: "Opening Scene",
            kind: .document(extension: "md"))

        // Group's children should contain the new scene
        let updatedGroup = store.manifest.structure
            .first(where: { $0.id == group.id })
        XCTAssertEqual(updatedGroup?.children?.count, 1)
        XCTAssertEqual(updatedGroup?.children?.first?.id, scene.id)

        // Scene's path should be under the group's folder
        let scenePath = scene.path ?? ""
        XCTAssertTrue(scenePath.contains("/01-act-one/"),
                      "scene path \(scenePath) should contain /01-act-one/")
    }

    func test_addStructureItem_withInvalidParentId_throws() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)

        do {
            _ = try await store.addStructureItem(
                parentId: "does-not-exist",
                title: "X",
                kind: .document(extension: "md"))
            XCTFail("expected throw")
        } catch ProjectStoreError.parentNotFound(let id) {
            XCTAssertEqual(id, "does-not-exist")
        }
    }

    func test_addStructureItem_persistsAcrossReload() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        _ = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2",
            kind: .document(extension: "md"))

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertTrue(reloaded.manifest.structure
            .contains { $0.title == "Chapter 2" })
    }

    // MARK: - renameStructureItem

    func test_renameDocument_movesFileAndUpdatesManifest() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let item = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2",
            kind: .document(extension: "md"))
        let oldPath = item.path!
        let oldFullURL = url.appendingPathComponent(oldPath)

        try await store.renameStructureItem(id: item.id, newTitle: "The Funeral")

        // Manifest title updated
        let updated = store.manifest.structure
            .first(where: { $0.id == item.id })!
        XCTAssertEqual(updated.title, "The Funeral")

        // Path's slug updated, NN preserved
        let newPath = updated.path!
        XCTAssertTrue(newPath.contains("the-funeral"),
                      "newPath \(newPath) should contain 'the-funeral'")
        XCTAssertTrue(newPath.hasPrefix("manuscript/01-"),
                      "newPath \(newPath) should preserve NN prefix '01-'")

        // File at old path gone, new path exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFullURL.path))
        let newFullURL = url.appendingPathComponent(newPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFullURL.path))
    }

    func test_renameGroup_movesFolderAndKeepsChildren() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)
        let scene = try await store.addStructureItem(
            parentId: group.id, title: "Opening",
            kind: .document(extension: "md"))

        try await store.renameStructureItem(id: group.id, newTitle: "Prologue")

        // Group folder moved; NN prefix preserved.
        let renamedGroup = store.manifest.structure
            .first(where: { $0.id == group.id })!
        XCTAssertEqual(renamedGroup.title, "Prologue")
        XCTAssertTrue(renamedGroup.path!.contains("01-prologue"),
                      "group path \(renamedGroup.path!) should contain '01-prologue' (NN preserved)")
        XCTAssertFalse(renamedGroup.path!.contains("act-one"),
                       "group path \(renamedGroup.path!) should not still contain old slug")

        // Scene's path updated to follow group's new path.
        let updatedScene = renamedGroup.children!
            .first(where: { $0.id == scene.id })!
        XCTAssertTrue(updatedScene.path!.contains("/01-prologue/"),
                      "scene path \(updatedScene.path!) should contain new group folder '01-prologue'")

        // Scene file still exists at the new path
        let sceneURL = url.appendingPathComponent(updatedScene.path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sceneURL.path))
    }

    func test_rename_withInvalidId_throws() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)

        do {
            try await store.renameStructureItem(
                id: "nope", newTitle: "X")
            XCTFail("expected throw")
        } catch ProjectStoreError.structureMissing {
            // ok
        }
    }
}
