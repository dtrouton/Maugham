import XCTest
@testable import Maugham

@MainActor
final class AddLoosePieceTests: XCTestCase {
    private func makeCollection() async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ALP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "Test", in: tmp)
        let store = try await ProjectStore.load(from: url)
        return (url, store)
    }

    func test_addLoosePiece_prose_createsFolderDocAndResearch() async throws {
        let (url, store) = try await makeCollection()
        let piece = try await store.addLoosePiece(
            title: "The Lighthouse Keeper", mode: .prose)

        XCTAssertEqual(piece.pieceKind, .loose)
        XCTAssertEqual(piece.type, .document)
        XCTAssertTrue(piece.path?.hasSuffix(".md") == true)

        let pieceFolder = url.appendingPathComponent(
            piece.path!).deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pieceFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pieceFolder.appendingPathComponent("research").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(piece.path!).path))

        XCTAssertEqual(store.manifest.structure.count, 1)
        XCTAssertEqual(store.manifest.structure[0].id, piece.id)
    }

    func test_addLoosePiece_screenplay_createsFountain() async throws {
        let (_, store) = try await makeCollection()
        let piece = try await store.addLoosePiece(
            title: "The Visit", mode: .screenplay)
        XCTAssertTrue(piece.path?.hasSuffix(".fountain") == true)
        XCTAssertEqual(piece.pieceKind, .loose)
    }

    func test_addLoosePiece_dedupsSlugCollision() async throws {
        let (_, store) = try await makeCollection()
        _ = try await store.addLoosePiece(title: "Story", mode: .prose)
        let piece2 = try await store.addLoosePiece(title: "Story", mode: .prose)
        XCTAssertTrue(piece2.path?.contains("story-2") == true,
            "second 'Story' should dedup to story-2; got: \(piece2.path ?? "nil")")
    }

    func test_addLoosePiece_assignsContiguousNumericPrefix() async throws {
        let (url, store) = try await makeCollection()
        let p1 = try await store.addLoosePiece(title: "A", mode: .prose)
        let p2 = try await store.addLoosePiece(title: "B", mode: .prose)

        // Folder names start with 01-, 02-
        let p1Folder = url.appendingPathComponent(
            p1.path!).deletingLastPathComponent().lastPathComponent
        let p2Folder = url.appendingPathComponent(
            p2.path!).deletingLastPathComponent().lastPathComponent
        XCTAssertTrue(p1Folder.hasPrefix("01-"), "got: \(p1Folder)")
        XCTAssertTrue(p2Folder.hasPrefix("02-"), "got: \(p2Folder)")
    }
}
