import XCTest
import MaughamCore
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

    func test_promotedProject_carriedResearch_isDerivedForItsDocument() async throws {
        // Collection with a piece that owns one research note.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("promote-derive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "C", in: parent)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        let note = try await store.addPieceResearchNote(pieceId: piece.id, title: "Carried")

        let dest = parent.appendingPathComponent("StoryA")
        _ = try await store.promotePieceToProject(pieceId: piece.id, destination: dest)

        // The promoted single-doc project derives the carried research for its
        // document with no re-linking (spec §6: promotion follow-through).
        let promoted = try await ProjectStore.load(from: dest)
        let docId = try XCTUnwrap(
            TreeWalk.collect(in: promoted.manifest.structure,
                             where: { $0.type == .document }).first?.id)
        let derived = promoted.derivedResearchItems(forDocumentId: docId)
        XCTAssertTrue(derived.contains { $0.title == note.title },
                      "carried research must appear derived; got: \(derived.map(\.title))")
        XCTAssertTrue(derived.allSatisfy { $0.path?.hasPrefix("research/") == true },
                      "carried paths must be rewritten to research/…")
    }
}
