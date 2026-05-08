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
}
