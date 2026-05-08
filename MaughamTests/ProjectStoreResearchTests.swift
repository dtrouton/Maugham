import XCTest
@testable import Maugham

@MainActor
final class ProjectStoreResearchTests: XCTestCase {
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
            named: "Research", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    func test_addResearchGroup_atRoot() async throws {
        let (_, store, ds) = try await makeNovel()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Locations", kind: nil)
        XCTAssertEqual(group.title, "Locations")
        XCTAssertEqual(group.type, .group)
        XCTAssertEqual(store.manifest.research.count, 1)
        XCTAssertEqual(store.manifest.research[0].id, group.id)
        await ds.close()
    }

    func test_addResearchAsset_underGroup_copiesIntoFolder() async throws {
        let (url, store, ds) = try await makeNovel()
        let externalImage = temp.url.appendingPathComponent("photo.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: externalImage)

        let group = try await store.addResearchItem(
            parentId: nil, title: "Locations", kind: nil)
        let asset = try await store.addResearchAsset(
            parentId: group.id, fromURL: externalImage)

        XCTAssertEqual(asset.kind, .image)
        XCTAssertEqual(asset.title, "photo")
        let onDisk = url.appendingPathComponent(asset.path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path))
        XCTAssertTrue(asset.path!.contains("research/locations/"))
        await ds.close()
    }

    func test_addResearchLink_storesURLNoFile() async throws {
        let (_, store, ds) = try await makeNovel()
        let link = try await store.addResearchLink(
            parentId: nil,
            title: "Reference",
            url: "https://en.wikipedia.org/wiki/Lighthouse")
        XCTAssertEqual(link.kind, .link)
        XCTAssertEqual(link.url, "https://en.wikipedia.org/wiki/Lighthouse")
        XCTAssertNil(link.path)
        await ds.close()
    }

    func test_addResearchAsset_unknownExtension_throws() async throws {
        let (_, store, ds) = try await makeNovel()
        let externalBin = temp.url.appendingPathComponent("strange.exe")
        try Data([0]).write(to: externalBin)
        do {
            _ = try await store.addResearchAsset(parentId: nil, fromURL: externalBin)
            XCTFail("expected throw")
        } catch ProjectStoreError.fileSystemError {
            // ok
        }
        await ds.close()
    }

    func test_moveResearchItem_siblingReorder_isManifestOnly() async throws {
        let (url, store, ds) = try await makeNovel()
        let g1 = try await store.addResearchItem(parentId: nil, title: "First", kind: nil)
        let g2 = try await store.addResearchItem(parentId: nil, title: "Second", kind: nil)
        let g1PathBefore = g1.path!
        let g2PathBefore = g2.path!

        try await store.moveResearchItem(id: g2.id, toParentId: nil, atIndex: 0)

        XCTAssertEqual(store.manifest.research[0].id, g2.id)
        XCTAssertEqual(store.manifest.research[1].id, g1.id)
        // Paths unchanged on disk.
        XCTAssertEqual(store.manifest.research[0].path, g2PathBefore)
        XCTAssertEqual(store.manifest.research[1].path, g1PathBefore)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(g2PathBefore).path))
        await ds.close()
    }

    func test_moveResearchItem_crossGroup_movesFile() async throws {
        let (url, store, ds) = try await makeNovel()
        let target = try await store.addResearchItem(
            parentId: nil, title: "Locations", kind: nil)
        let source = try await store.addResearchItem(
            parentId: nil, title: "Characters", kind: nil)
        let externalImage = temp.url.appendingPathComponent("face.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: externalImage)
        let asset = try await store.addResearchAsset(
            parentId: source.id, fromURL: externalImage)

        try await store.moveResearchItem(
            id: asset.id, toParentId: target.id, atIndex: 0)

        let updatedTarget = store.manifest.research
            .first(where: { $0.id == target.id })!
        XCTAssertEqual(updatedTarget.children?.first?.id, asset.id)
        let movedPath = updatedTarget.children!.first!.path!
        XCTAssertTrue(movedPath.contains("research/locations/"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(movedPath).path))
        await ds.close()
    }

    func test_moveResearchItem_groupIntoOwnDescendant_throws() async throws {
        let (_, store, ds) = try await makeNovel()
        let outer = try await store.addResearchItem(
            parentId: nil, title: "Outer", kind: nil)
        let inner = try await store.addResearchItem(
            parentId: outer.id, title: "Inner", kind: nil)
        do {
            try await store.moveResearchItem(
                id: outer.id, toParentId: inner.id, atIndex: 0)
            XCTFail("expected throw")
        } catch ProjectStoreError.cycle {}
        await ds.close()
    }

    func test_duplicateResearchAsset_copiesFile() async throws {
        let (url, store, ds) = try await makeNovel()
        let externalImage = temp.url.appendingPathComponent("photo.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: externalImage)
        let original = try await store.addResearchAsset(
            parentId: nil, fromURL: externalImage)

        let copy = try await store.duplicateResearchItem(id: original.id)

        XCTAssertEqual(copy.title, "Copy of photo")
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(copy.path!).path))
        await ds.close()
    }

    func test_duplicateResearchLink_copiesURL() async throws {
        let (_, store, ds) = try await makeNovel()
        let link = try await store.addResearchLink(
            parentId: nil, title: "Reference", url: "https://example.com")
        let copy = try await store.duplicateResearchItem(id: link.id)
        XCTAssertEqual(copy.url, "https://example.com")
        XCTAssertEqual(copy.title, "Copy of Reference")
        await ds.close()
    }

    func test_deleteResearchAsset_removesFromManifestAndDisk() async throws {
        let (url, store, ds) = try await makeNovel()
        let externalImage = temp.url.appendingPathComponent("photo.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: externalImage)
        let asset = try await store.addResearchAsset(
            parentId: nil, fromURL: externalImage)
        let onDisk = url.appendingPathComponent(asset.path!)

        try await store.deleteResearchItem(id: asset.id)

        XCTAssertFalse(store.manifest.research.contains(where: { $0.id == asset.id }))
        // Trashed (not hard-deleted) — file no longer at original path.
        XCTAssertFalse(FileManager.default.fileExists(atPath: onDisk.path))
        await ds.close()
    }

    func test_updateResearchItem_writesFields() async throws {
        let (_, store, ds) = try await makeNovel()
        let link = try await store.addResearchLink(
            parentId: nil, title: "Original", url: "https://example.com")

        try await store.updateResearchItem(
            id: link.id,
            title: "Renamed",
            caption: "A useful reference",
            tags: ["history", "novel"],
            url: "https://example.org")

        let updated = store.manifest.research
            .first(where: { $0.id == link.id })!
        XCTAssertEqual(updated.title, "Renamed")
        XCTAssertEqual(updated.caption, "A useful reference")
        XCTAssertEqual(updated.tags, ["history", "novel"])
        XCTAssertEqual(updated.url, "https://example.org")
        await ds.close()
    }

    func test_importResearchFiles_multipleFiles_atRoot() async throws {
        let (_, store, ds) = try await makeNovel()
        let f1 = temp.url.appendingPathComponent("a.jpg")
        let f2 = temp.url.appendingPathComponent("b.pdf")
        try Data([0xFF, 0xD8, 0xFF]).write(to: f1)
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: f2)

        let imported = try await store.importResearchFiles(
            [f1, f2], toParentId: nil)

        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(store.manifest.research.count, 2)
        XCTAssertEqual(imported[0].kind, .image)
        XCTAssertEqual(imported[1].kind, .pdf)
        await ds.close()
    }

    func test_importResearchFiles_folder_importsRecursively() async throws {
        let (_, store, ds) = try await makeNovel()
        let extDir = temp.url.appendingPathComponent("photos")
        try FileManager.default.createDirectory(
            at: extDir, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(
            to: extDir.appendingPathComponent("one.jpg"))
        try Data([0xFF, 0xD8, 0xFF]).write(
            to: extDir.appendingPathComponent("two.jpg"))

        let imported = try await store.importResearchFiles(
            [extDir], toParentId: nil)

        XCTAssertEqual(imported.count, 1)
        let group = imported[0]
        XCTAssertEqual(group.type, .group)
        XCTAssertEqual(group.children?.count, 2)
        await ds.close()
    }

    func test_importResearchFiles_skipsUnknownExtensions() async throws {
        let (_, store, ds) = try await makeNovel()
        let f1 = temp.url.appendingPathComponent("a.jpg")
        let f2 = temp.url.appendingPathComponent("b.exe")
        try Data([0xFF, 0xD8, 0xFF]).write(to: f1)
        try Data([0]).write(to: f2)

        let imported = try await store.importResearchFiles(
            [f1, f2], toParentId: nil)

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].kind, .image)
        await ds.close()
    }
}
