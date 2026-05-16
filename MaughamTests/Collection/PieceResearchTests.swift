import XCTest
@testable import Maugham

@MainActor
final class PieceResearchTests: XCTestCase {
    private func makeCollectionWithPiece() async throws -> (URL, ProjectStore, StructureItem) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "T", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        return (url, store, piece)
    }

    func test_addPieceResearchNote_landsInPieceFolder() async throws {
        let (url, store, piece) = try await makeCollectionWithPiece()
        let note = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Sarah Notes")
        XCTAssertTrue(note.path?.hasPrefix("pieces/01-story-a/research/") == true,
            "expected pieces/01-story-a/research/; got: \(note.path ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(note.path!).path))
    }

    func test_addPieceResearchNote_unknownPiece_throws() async throws {
        let (_, store, _) = try await makeCollectionWithPiece()
        do {
            _ = try await store.addPieceResearchNote(
                pieceId: "doc-nope", title: "x")
            XCTFail("expected throw")
        } catch {
            // ok
        }
    }
}
