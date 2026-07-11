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

    func test_addThenOpen_sequence_returnsResearchItemIdForNavigation() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "IntentNav", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        // The affordance's behavior: create-if-absent, then navigate by item id.
        let item = try await store.createCraftIntent(forPieceId: nil)
        XCTAssertNotNil(TreeWalk.find(id: item.id, in: store.manifest.research))
        await ds.close()
    }

    // MARK: - Role-first identity (rename survival + lazy healing)

    func test_craftIntent_survivesRename_andStampsOnCreate() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "IntentRename", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds

        let item = try await store.createCraftIntent(forPieceId: nil)
        XCTAssertEqual(item.role, .craftIntent)            // stamped at creation
        // Rename the doc away from craft-intent.md — the filename fallback
        // no longer matches, so only the role can find it.
        try await store.updateResearchItem(id: item.id, title: "What this story needs")
        XCTAssertEqual(store.craftIntentItem(forPieceId: nil)?.id, item.id)
        await ds.close()
    }

    func test_legacyCraftIntent_getsLazilyStamped() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "IntentLegacy", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds

        // Simulate a v0.19.0 project: doc exists at the legacy path, no role.
        let legacy = try await store.addResearchTextNote(
            parentId: nil, title: ProjectStore.craftIntentTitle)
        XCTAssertNil(legacy.role)
        XCTAssertEqual(legacy.path, "research/craft-intent.md")
        let found = store.craftIntentItem(forPieceId: nil)
        XCTAssertEqual(found?.id, legacy.id)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            TreeWalk.find(id: legacy.id, in: store.manifest.research)?.role, .craftIntent)
        await ds.close()
    }
}
