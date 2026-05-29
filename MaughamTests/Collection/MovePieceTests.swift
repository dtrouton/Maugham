import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class MovePieceTests: XCTestCase {
    private func makeCollectionWithPieces() async throws -> (URL, ProjectStore, [StructureItem]) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MV-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "T", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let p1 = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        let p2 = try await store.addLoosePiece(title: "Beta", mode: .prose)
        let p3 = try await store.addLoosePiece(title: "Gamma", mode: .prose)
        return (url, store, [p1, p2, p3])
    }

    func test_movePiece_reordersArray() async throws {
        let (_, store, pieces) = try await makeCollectionWithPieces()
        // Move Gamma to position 0
        try await store.movePiece(pieceId: pieces[2].id, toIndex: 0)
        let orderedIds = store.manifest.structure.map(\.id)
        XCTAssertEqual(orderedIds, [pieces[2].id, pieces[0].id, pieces[1].id])
    }

    func test_movePiece_renumbersFoldersOnDisk() async throws {
        let (url, store, pieces) = try await makeCollectionWithPieces()
        try await store.movePiece(pieceId: pieces[2].id, toIndex: 0)
        // After move: Gamma should be 01-, Alpha 02-, Beta 03-
        let gammaPath = store.manifest.structure[0].path!
        let alphaPath = store.manifest.structure[1].path!
        let betaPath = store.manifest.structure[2].path!
        XCTAssertTrue(gammaPath.contains("/01-"), "got: \(gammaPath)")
        XCTAssertTrue(alphaPath.contains("/02-"), "got: \(alphaPath)")
        XCTAssertTrue(betaPath.contains("/03-"), "got: \(betaPath)")
        // Verify files actually exist on disk
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(gammaPath).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(alphaPath).path))
    }

    func test_movePiece_rewritesPerPieceResearchPaths() async throws {
        let (url, store, pieces) = try await makeCollectionWithPieces()
        // Add a research note to Alpha (currently at index 0)
        let note = try await store.addPieceResearchNote(
            pieceId: pieces[0].id, title: "Alpha Notes")
        // Move Alpha to position 2 (it becomes 03-alpha)
        try await store.movePiece(pieceId: pieces[0].id, toIndex: 2)
        guard let updatedNote = store.manifest.research.first(where: { $0.id == note.id }) else {
            XCTFail("note missing"); return
        }
        XCTAssertTrue(updatedNote.path?.contains("/03-alpha/research/") == true,
            "research path should reflect new folder; got: \(updatedNote.path ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(updatedNote.path!).path))
    }
}
