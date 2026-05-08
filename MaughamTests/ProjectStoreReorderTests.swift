import XCTest
@testable import Maugham

@MainActor
final class ProjectStoreReorderTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    /// Helper: create a Novel with N chapters at root. Novel comes with
    /// Chapter 1; additional chapters appended via addStructureItem.
    private func makeNovel(chapters: Int) async throws
        -> (URL, ProjectStore, DocumentStore)
    {
        let url = try await ProjectFactory.createNovelProject(
            named: "Reorder", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        if chapters >= 2 {
            for i in 2...chapters {
                _ = try await store.addStructureItem(
                    parentId: nil,
                    title: "Chapter \(i)",
                    kind: .document(extension: "md"))
            }
        }
        return (url, store, ds)
    }

    func test_moveSiblings_swapAdjacent() async throws {
        let (url, store, ds) = try await makeNovel(chapters: 3)
        let chapterIds = store.manifest.structure.map(\.id)

        // Move chapter 1 to position 1 (between chapter 1 and 2 -> swap with 2)
        try await store.moveStructureItem(
            id: chapterIds[0], toParentId: nil, atIndex: 1)

        let newOrder = store.manifest.structure.map(\.id)
        XCTAssertEqual(newOrder, [chapterIds[1], chapterIds[0], chapterIds[2]])

        XCTAssertTrue(store.manifest.structure[0].path?.contains("/01-") ?? false)
        XCTAssertTrue(store.manifest.structure[1].path?.contains("/02-") ?? false)
        XCTAssertTrue(store.manifest.structure[2].path?.contains("/03-") ?? false)

        for item in store.manifest.structure {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: url.appendingPathComponent(item.path!).path))
        }
        await ds.close()
    }

    func test_moveDocument_intoGroup() async throws {
        let (url, store, ds) = try await makeNovel(chapters: 2)
        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)
        let chapter1Id = store.manifest.structure[0].id

        try await store.moveStructureItem(
            id: chapter1Id, toParentId: group.id, atIndex: 0)

        XCTAssertFalse(store.manifest.structure
            .contains { $0.id == chapter1Id })
        let updatedGroup = store.manifest.structure
            .first(where: { $0.id == group.id })!
        XCTAssertEqual(updatedGroup.children?.first?.id, chapter1Id)
        let movedItem = updatedGroup.children!.first!
        XCTAssertTrue(movedItem.path!.contains("act-one/"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(movedItem.path!).path))
        await ds.close()
    }

    func test_moveGroup_intoAnotherGroup() async throws {
        let (url, store, ds) = try await makeNovel(chapters: 1)
        let act1 = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)
        let act2 = try await store.addStructureItem(
            parentId: nil, title: "Act Two", kind: .group)
        let chapInAct2 = try await store.addStructureItem(
            parentId: act2.id, title: "Inner",
            kind: .document(extension: "md"))

        try await store.moveStructureItem(
            id: act2.id, toParentId: act1.id, atIndex: 0)

        let updatedAct1 = store.manifest.structure
            .first(where: { $0.id == act1.id })!
        let movedAct2 = updatedAct1.children?.first(where: { $0.id == act2.id })
        XCTAssertNotNil(movedAct2)
        XCTAssertTrue(movedAct2!.path!.contains("act-one"))
        let updatedChap = movedAct2!.children!
            .first(where: { $0.id == chapInAct2.id })!
        XCTAssertTrue(updatedChap.path!.contains("act-one"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(updatedChap.path!).path))
        await ds.close()
    }

    func test_moveItemIntoOwnDescendant_throws() async throws {
        let (url, store, ds) = try await makeNovel(chapters: 1)
        _ = url
        let outerGroup = try await store.addStructureItem(
            parentId: nil, title: "Outer", kind: .group)
        let innerGroup = try await store.addStructureItem(
            parentId: outerGroup.id, title: "Inner", kind: .group)

        do {
            try await store.moveStructureItem(
                id: outerGroup.id, toParentId: innerGroup.id, atIndex: 0)
            XCTFail("expected throw")
        } catch ProjectStoreError.cycle {
            // ok
        }
        await ds.close()
    }

    func test_moveSameParent_atSameIndex_isNoOp() async throws {
        let (url, store, ds) = try await makeNovel(chapters: 3)
        _ = url
        let manifestBefore = store.manifest

        try await store.moveStructureItem(
            id: store.manifest.structure[0].id,
            toParentId: nil, atIndex: 0)

        XCTAssertEqual(
            store.manifest.structure.map(\.id),
            manifestBefore.structure.map(\.id))
        await ds.close()
    }
}
