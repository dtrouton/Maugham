import XCTest
@testable import Maugham

@MainActor
final class PromotePieceTests: XCTestCase {
    private func makeCollectionWithPiece(
        mode: PieceMode
    ) async throws -> (collection: URL, store: ProjectStore, piece: StructureItem) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collectionURL = try await ProjectFactory.createCollectionProject(
            named: "Anthology", in: tmp)
        let store = try await ProjectStore.load(from: collectionURL)
        let piece = try await store.addLoosePiece(title: "Story A", mode: mode)
        return (collectionURL, store, piece)
    }

    func test_promote_prose_createsShortStoryProject() async throws {
        let (collection, store, piece) = try await makeCollectionWithPiece(mode: .prose)
        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted Story A")

        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination)

        // New project exists with .shortStory type
        let newStore = try await ProjectStore.load(from: newProjectURL)
        XCTAssertEqual(newStore.manifest.type, .shortStory)
        XCTAssertEqual(newStore.manifest.title, "Story A")

        // Collection's piece is now a reference
        guard let converted = store.manifest.structure.first(where: { $0.id == piece.id }) else {
            XCTFail("piece not found in Collection after promote"); return
        }
        XCTAssertEqual(converted.pieceKind, .reference)
        XCTAssertNotNil(converted.linkedProjectBookmark)
    }

    func test_promote_screenplay_createsScreenplayProject() async throws {
        let (collection, store, piece) = try await makeCollectionWithPiece(mode: .screenplay)
        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted Screenplay")

        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination)

        let newStore = try await ProjectStore.load(from: newProjectURL)
        XCTAssertEqual(newStore.manifest.type, .screenplay)
    }

    func test_promote_referenceFails() async throws {
        let (collection, store, _) = try await makeCollectionWithPiece(mode: .prose)
        // Make a reference to test against
        let tmp = collection.deletingLastPathComponent()
        let other = try await ProjectFactory.createShortStoryProject(
            named: "Other", in: tmp)
        let refPiece = try await store.addProjectReference(targetURL: other)

        let dest = tmp.appendingPathComponent("Promoted")
        do {
            _ = try await store.promotePieceToProject(
                pieceId: refPiece.id, destination: dest)
            XCTFail("expected throw — can't promote a reference")
        } catch {
            // ok
        }
    }
}
