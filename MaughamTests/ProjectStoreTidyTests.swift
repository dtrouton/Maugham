import XCTest
@testable import Maugham

@MainActor
final class ProjectStoreTidyTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeNovel(chapters: Int) async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Tidy", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        for i in 2...chapters {
            _ = try await store.addStructureItem(
                parentId: nil, title: "Chapter \(i)",
                kind: .document(extension: "md"))
        }
        return (url, store, ds)
    }

    func test_tidyAfterDelete_compactsContiguous() async throws {
        let (_, store, ds) = try await makeNovel(chapters: 5)
        try await store.deleteStructureItem(
            id: store.manifest.structure[1].id)  // ch2
        try await store.deleteStructureItem(
            id: store.manifest.structure[2].id)  // ch4 (now at index 2 after ch2 removed)

        let beforePaths = store.manifest.structure.compactMap(\.path)
        XCTAssertEqual(beforePaths.count, 3)

        try await store.tidyFilenames(parentId: nil)

        let afterPaths = store.manifest.structure.compactMap(\.path)
        XCTAssertTrue(afterPaths[0].contains("/01-"),
                      "got \(afterPaths[0])")
        XCTAssertTrue(afterPaths[1].contains("/02-"),
                      "got \(afterPaths[1])")
        XCTAssertTrue(afterPaths[2].contains("/03-"),
                      "got \(afterPaths[2])")
        await ds.close()
    }

    func test_tidy_isIdempotent() async throws {
        let (_, store, ds) = try await makeNovel(chapters: 3)
        try await store.tidyFilenames(parentId: nil)
        let firstPaths = store.manifest.structure.compactMap(\.path)
        try await store.tidyFilenames(parentId: nil)
        let secondPaths = store.manifest.structure.compactMap(\.path)
        XCTAssertEqual(firstPaths, secondPaths)
        await ds.close()
    }

    func test_tidyAllFilenames_walksTree() async throws {
        let (_, store, ds) = try await makeNovel(chapters: 3)
        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)
        let scene1 = try await store.addStructureItem(
            parentId: group.id, title: "Scene 1",
            kind: .document(extension: "md"))
        _ = try await store.addStructureItem(
            parentId: group.id, title: "Scene 2",
            kind: .document(extension: "md"))
        try await store.deleteStructureItem(id: scene1.id)

        try await store.tidyAllFilenames()

        let updatedGroup = store.manifest.structure
            .first(where: { $0.id == group.id })!
        let remainingScene = updatedGroup.children!.first!
        XCTAssertTrue(remainingScene.path!.contains("/01-"))
        await ds.close()
    }

    func test_tidy_preservesSlugs() async throws {
        let (_, store, ds) = try await makeNovel(chapters: 3)
        let ch2 = store.manifest.structure[1]
        try await store.renameStructureItem(
            id: ch2.id, newTitle: "The Funeral")
        try await store.deleteStructureItem(
            id: store.manifest.structure[0].id)

        try await store.tidyFilenames(parentId: nil)

        let top = store.manifest.structure[0]
        XCTAssertTrue(top.path!.contains("the-funeral"),
                      "got \(top.path!)")
        XCTAssertTrue(top.path!.contains("/01-"))
        await ds.close()
    }
}
