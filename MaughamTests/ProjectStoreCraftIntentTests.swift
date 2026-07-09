import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class ProjectStoreCraftIntentTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_projectScope_absentByDefault_thenCreated() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "IntentTest", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds

        XCTAssertNil(store.craftIntentItem(forPieceId: nil))   // absence is valid

        let item = try await store.createCraftIntent(forPieceId: nil)
        XCTAssertEqual(item.title, ProjectStore.craftIntentTitle)
        XCTAssertEqual(item.path, "research/craft-intent.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/craft-intent.md").path))
        XCTAssertEqual(store.craftIntentItem(forPieceId: nil)?.id, item.id)

        let again = try await store.createCraftIntent(forPieceId: nil)
        XCTAssertEqual(again.id, item.id)   // idempotent
        await ds.close()
    }

    func test_collectionLoosePiece_getsItsOwnIntent() async throws {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Coll", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story One", mode: .prose)

        XCTAssertNil(store.craftIntentItem(forPieceId: piece.id))
        let item = try await store.createCraftIntent(forPieceId: piece.id)
        XCTAssertTrue(item.path?.hasSuffix("/research/craft-intent.md") ?? false)
        XCTAssertTrue(item.path?.hasPrefix("pieces/") ?? false)
        XCTAssertEqual(store.craftIntentItem(forPieceId: piece.id)?.id, item.id)
        // Project-scope lookup must NOT see the piece's intent doc.
        XCTAssertNil(store.craftIntentItem(forPieceId: nil))
        await ds.close()
    }

    func test_unknownPieceId_lookupAndCreate() async throws {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Coll2", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds

        XCTAssertNil(store.craftIntentItem(forPieceId: "doc-nope"))
        do {
            _ = try await store.createCraftIntent(forPieceId: "doc-nope")
            XCTFail("expected createCraftIntent to throw for unknown piece")
        } catch {
            // expected — unknown piece must not silently create project-scope content
        }
        await ds.close()
    }
}
