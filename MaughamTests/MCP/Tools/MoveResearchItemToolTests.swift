import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class MoveResearchItemToolTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeRegistry() async throws
        -> (ProjectRegistry, ProjectStore, DocumentStore, StructureItem, String) {
        let url = try await ProjectFactory.createCollectionProject(
            named: "MCPMove", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        let registry = ProjectRegistry()
        registry.register(url: url, store: store)
        let projectId = ProjectIdentifier.id(for: url)
        return (registry, store, ds, piece, projectId)
    }

    private func params(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }

    func test_moveToPiece_movesFile() async throws {
        let (registry, store, ds, piece, projectId) = try await makeRegistry()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")

        _ = try await MoveResearchItemTool.handle(
            paramsJSON: params([
                "project_id": projectId,
                "research_ids": [note.id],
                "target_document_id": piece.id]),
            registry: registry)

        let moved = TreeWalk.find(id: note.id, in: store.manifest.research)
        XCTAssertTrue(moved?.path?.hasPrefix("pieces/") == true)
        await ds.close()
    }

    func test_moveToShared() async throws {
        let (registry, store, ds, piece, projectId) = try await makeRegistry()
        let note = try await store.createResearchNote(
            scope: .document(piece.id), title: "Out")

        _ = try await MoveResearchItemTool.handle(
            paramsJSON: params([
                "project_id": projectId,
                "research_ids": [note.id],
                "target": "shared"]),
            registry: registry)

        XCTAssertEqual(
            TreeWalk.find(id: note.id, in: store.manifest.research)?.path,
            "research/out.md")
        await ds.close()
    }

    func test_multipleTargets_failsLoudly() async throws {
        let (registry, store, ds, piece, projectId) = try await makeRegistry()
        let note = try await store.addResearchTextNote(parentId: nil, title: "X")

        await XCTAssertThrowsErrorAsync(
            _ = try await MoveResearchItemTool.handle(
                paramsJSON: params([
                    "project_id": projectId,
                    "research_ids": [note.id],
                    "target": "shared",
                    "target_document_id": piece.id]),
                registry: registry))
        await ds.close()
    }

    func test_noTarget_failsLoudly() async throws {
        let (registry, store, ds, _, projectId) = try await makeRegistry()
        let note = try await store.addResearchTextNote(parentId: nil, title: "X")

        await XCTAssertThrowsErrorAsync(
            _ = try await MoveResearchItemTool.handle(
                paramsJSON: params([
                    "project_id": projectId,
                    "research_ids": [note.id]]),
                registry: registry))
        await ds.close()
    }

    func test_unknownResearchId_failsLoudly() async throws {
        let (registry, _, ds, piece, projectId) = try await makeRegistry()
        await XCTAssertThrowsErrorAsync(
            _ = try await MoveResearchItemTool.handle(
                paramsJSON: params([
                    "project_id": projectId,
                    "research_ids": ["res-nope"],
                    "target_document_id": piece.id]),
                registry: registry))
        await ds.close()
    }
}
