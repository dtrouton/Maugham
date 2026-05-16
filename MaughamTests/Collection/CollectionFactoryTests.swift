import XCTest
@testable import Maugham

@MainActor
final class CollectionFactoryTests: XCTestCase {
    func test_createCollectionProject_createsPiecesDirectory() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CF-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = try await ProjectFactory.createCollectionProject(
            named: "Anthology", in: tmp)
        let pieces = url.appendingPathComponent("pieces")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pieces.path),
            "Collection project should create pieces/ directory")

        // Also still creates research/ and notes/
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("notes").path))
    }

    func test_createCollectionProject_manifestStructureEmpty() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CF2-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = try await ProjectFactory.createCollectionProject(
            named: "Anthology", in: tmp)
        let store = try await ProjectStore.load(from: url)
        XCTAssertEqual(store.manifest.type, .collection)
        XCTAssertEqual(store.manifest.structure.count, 0)
        XCTAssertEqual(store.manifest.research.count, 0)
    }
}
