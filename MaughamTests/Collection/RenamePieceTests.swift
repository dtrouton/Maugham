import XCTest
@testable import Maugham

@MainActor
final class RenamePieceTests: XCTestCase {
    private func makeCollection() async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "T", in: tmp)
        let store = try await ProjectStore.load(from: url)
        return (url, store)
    }

    func test_renamePiece_loose_renamesFolderAndDoc() async throws {
        let (url, store) = try await makeCollection()
        let piece = try await store.addLoosePiece(title: "Lighthouse", mode: .prose)

        try await store.renamePiece(pieceId: piece.id, newTitle: "The Beacon")

        guard let updated = store.manifest.structure.first(where: { $0.id == piece.id }) else {
            XCTFail("piece gone"); return
        }
        XCTAssertEqual(updated.title, "The Beacon")
        XCTAssertTrue(updated.path?.contains("the-beacon") == true,
            "folder slug should reflect new title; got: \(updated.path ?? "nil")")
        XCTAssertTrue(updated.path?.hasSuffix("the-beacon.md") == true,
            "main doc should rename to new slug; got: \(updated.path ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(updated.path!).path),
            "renamed doc should exist on disk")
    }

    func test_renamePiece_rewritesPerPieceResearchPaths() async throws {
        let (url, store) = try await makeCollection()
        let piece = try await store.addLoosePiece(title: "Lighthouse", mode: .prose)
        let note = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Sarah Notes")
        XCTAssertTrue(note.path?.contains("lighthouse") == true)
        XCTAssertTrue(note.path?.contains("/research/") == true)

        try await store.renamePiece(pieceId: piece.id, newTitle: "The Beacon")

        guard let updatedNote = store.manifest.research.first(where: { $0.id == note.id }) else {
            XCTFail("note gone"); return
        }
        XCTAssertTrue(updatedNote.path?.contains("the-beacon") == true,
            "research path should reflect new piece folder; got: \(updatedNote.path ?? "nil")")
        XCTAssertTrue(updatedNote.path?.contains("/research/") == true,
            "research path should still contain /research/; got: \(updatedNote.path ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(updatedNote.path!).path))
    }

    func test_renamePiece_reference_keepsLinkFile() async throws {
        let (collection, store) = try await makeCollection()
        let tmp = collection.deletingLastPathComponent()
        let target = try await ProjectFactory.createShortStoryProject(
            named: "Other Project", in: tmp)
        let piece = try await store.addProjectReference(targetURL: target)
        // After T5, the title comes from the target's manifest ("Other Project")

        try await store.renamePiece(pieceId: piece.id, newTitle: "My Linked Story")

        guard let updated = store.manifest.structure.first(where: { $0.id == piece.id }) else {
            XCTFail("piece gone"); return
        }
        XCTAssertEqual(updated.title, "My Linked Story")
        XCTAssertTrue(updated.path?.contains("my-linked-story") == true,
            "reference folder should rename to slug of new title")
        XCTAssertTrue(updated.path?.hasSuffix(".maugham-link.json") == true,
            "reference path still points at link file; got: \(updated.path ?? "nil")")
        // Link file still exists on disk at the new location
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: collection.appendingPathComponent(updated.path!).path))
    }
}
