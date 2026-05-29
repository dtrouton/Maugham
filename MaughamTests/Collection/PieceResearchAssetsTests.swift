import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class PieceResearchAssetsTests: XCTestCase {
    private func makeCollectionWithPiece() async throws -> (URL, ProjectStore, StructureItem) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRA-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "T", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        return (url, store, piece)
    }

    func test_addPieceResearchAsset_importsFileIntoPieceResearch() async throws {
        let (url, store, piece) = try await makeCollectionWithPiece()
        let tmpSrc = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-asset-\(UUID()).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: tmpSrc)
        defer { try? FileManager.default.removeItem(at: tmpSrc) }

        let asset = try await store.addPieceResearchAsset(
            pieceId: piece.id, fromURL: tmpSrc)
        XCTAssertTrue(asset.path?.hasPrefix("pieces/01-story-a/research/") == true,
            "expected piece research path; got: \(asset.path ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(asset.path!).path))
        XCTAssertEqual(asset.kind, .image)
    }

    func test_addPieceResearchLink_landsInPieceResearch() async throws {
        let (_, store, piece) = try await makeCollectionWithPiece()
        let link = try await store.addPieceResearchLink(
            pieceId: piece.id, title: "Maugham Wiki",
            url: "https://en.wikipedia.org/wiki/W._Somerset_Maugham")
        XCTAssertEqual(link.kind, .link)
        XCTAssertEqual(link.title, "Maugham Wiki")
        XCTAssertEqual(link.url, "https://en.wikipedia.org/wiki/W._Somerset_Maugham")
        XCTAssertTrue(link.path?.hasPrefix("pieces/01-story-a/research/") == true,
            "expected piece research path; got: \(link.path ?? "nil")")
    }

    func test_importPieceResearchFiles_bulkImports() async throws {
        let (_, store, piece) = try await makeCollectionWithPiece()
        let tmp = FileManager.default.temporaryDirectory
        let a = tmp.appendingPathComponent("a-\(UUID()).txt")
        let b = tmp.appendingPathComponent("b-\(UUID()).txt")
        try "alpha".write(to: a, atomically: true, encoding: .utf8)
        try "beta".write(to: b, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        let imported = try await store.importPieceResearchFiles(
            pieceId: piece.id, urls: [a, b])
        XCTAssertEqual(imported.count, 2)
        for item in imported {
            XCTAssertTrue(item.path?.hasPrefix("pieces/01-story-a/research/") == true,
                "got: \(item.path ?? "nil")")
        }
    }
}
