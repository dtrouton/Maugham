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
}
