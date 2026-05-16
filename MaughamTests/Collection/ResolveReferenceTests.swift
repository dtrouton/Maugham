import XCTest
@testable import Maugham

@MainActor
final class ResolveReferenceTests: XCTestCase {
    func test_resolveReference_bookmarkResolves_returnsURL() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collection = try await ProjectFactory.createCollectionProject(
            named: "C", in: tmp)
        let target = try await ProjectFactory.createShortStoryProject(
            named: "T", in: tmp)
        let store = try await ProjectStore.load(from: collection)
        let piece = try await store.addProjectReference(targetURL: target)

        let resolution = store.resolveReference(piece)
        switch resolution {
        case .resolved(let url):
            XCTAssertEqual(url.standardized.path, target.standardized.path)
        case .resolvedViaPathFallback, .unresolved:
            XCTFail("expected .resolved, got: \(resolution)")
        }
    }

    func test_resolveReference_bookmarkFails_pathSucceeds_resolvesViaFallback() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RR-fb-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collection = try await ProjectFactory.createCollectionProject(
            named: "C", in: tmp)
        let target = try await ProjectFactory.createShortStoryProject(
            named: "T", in: tmp)
        let store = try await ProjectStore.load(from: collection)
        var piece = try await store.addProjectReference(targetURL: target)

        // Corrupt the bookmark to force fallback
        piece.linkedProjectBookmark = Data([0xFF])

        let resolution = store.resolveReference(piece)
        switch resolution {
        case .resolvedViaPathFallback(let url):
            XCTAssertEqual(url.standardized.path, target.standardized.path)
        case .resolved, .unresolved:
            XCTFail("expected fallback, got: \(resolution)")
        }
    }

    func test_resolveReference_bothFail_returnsUnresolved() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RR-un-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collection = try await ProjectFactory.createCollectionProject(
            named: "C", in: tmp)
        let store = try await ProjectStore.load(from: collection)

        let piece = StructureItem(
            id: "doc-x",
            title: "Gone",
            type: .document,
            pieceKind: .reference,
            linkedProjectPath: "/nope/does/not/exist",
            linkedProjectBookmark: Data([0xFF]))

        let resolution = store.resolveReference(piece)
        switch resolution {
        case .unresolved:
            break  // ok
        case .resolved, .resolvedViaPathFallback:
            XCTFail("expected unresolved, got: \(resolution)")
        }
    }
}
