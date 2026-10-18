import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class AddLoosePieceTests: XCTestCase {
    private func makeCollection() async throws -> (URL, ProjectStore) {
        let tmp = TestTemp.root
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
            title: "The Lighthouse Keeper", format: .markdown)

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
            title: "The Visit", format: .fountain)
        XCTAssertTrue(piece.path?.hasSuffix(".fountain") == true)
        XCTAssertEqual(piece.pieceKind, .loose)
    }

    func test_addLoosePiece_dedupsSlugCollision() async throws {
        let (_, store) = try await makeCollection()
        _ = try await store.addLoosePiece(title: "Story", format: .markdown)
        let piece2 = try await store.addLoosePiece(title: "Story", format: .markdown)
        XCTAssertTrue(piece2.path?.contains("story-2") == true,
            "second 'Story' should dedup to story-2; got: \(piece2.path ?? "nil")")
    }

    func test_addLoosePiece_assignsContiguousNumericPrefix() async throws {
        let (url, store) = try await makeCollection()
        let p1 = try await store.addLoosePiece(title: "A", format: .markdown)
        let p2 = try await store.addLoosePiece(title: "B", format: .markdown)

        // Folder names start with 01-, 02-
        let p1Folder = url.appendingPathComponent(
            p1.path!).deletingLastPathComponent().lastPathComponent
        let p2Folder = url.appendingPathComponent(
            p2.path!).deletingLastPathComponent().lastPathComponent
        XCTAssertTrue(p1Folder.hasPrefix("01-"), "got: \(p1Folder)")
        XCTAssertTrue(p2Folder.hasPrefix("02-"), "got: \(p2Folder)")
    }
    /// **The slug dedup strips every `.md`, then every `.fountain`, anywhere
    /// in a piece doc's basename — not only the suffix** (plan 7 Task 4).
    /// Pinned as-is: a "fixed" strip (`deletingPathExtension`) would yield a
    /// different slug and so a different dedup. `story.md-x.md` strips to
    /// `story-x`, so a new "Story X" collides and becomes `story-x-2`.
    func test_slugDedup_stripsAFormatExtensionMidName() async throws {
        let (_, store) = try await makeCollection()
        let first = try await store.addLoosePiece(title: "Seed", format: .markdown)
        let index = try XCTUnwrap(store.manifest.structure.firstIndex { $0.id == first.id })
        store.manifest.structure[index].path = "pieces/01-seed/story.md-x.md"

        let piece = try await store.addLoosePiece(title: "Story X", format: .markdown)
        XCTAssertEqual((piece.path! as NSString).lastPathComponent, "story-x-2.md")
    }

    /// **The strip runs in `DocumentFormat.allCases` order, `.md` first** —
    /// and the order is observable: `story.fo.mduntain` loses `.md` to become
    /// `story.fountain`, which then loses `.fountain` to become `story`. In
    /// the other order it would stay `story.fountain` and never collide.
    func test_slugDedup_stripsInDeclarationOrder_markdownFirst() async throws {
        XCTAssertEqual(DocumentFormat.allCases, [.markdown, .fountain])
        let (_, store) = try await makeCollection()
        let first = try await store.addLoosePiece(title: "Seed", format: .markdown)
        let index = try XCTUnwrap(store.manifest.structure.firstIndex { $0.id == first.id })
        store.manifest.structure[index].path = "pieces/01-seed/story.fo.mduntain"

        let piece = try await store.addLoosePiece(title: "Story", format: .markdown)
        XCTAssertEqual((piece.path! as NSString).lastPathComponent, "story-2.md")
    }
}
