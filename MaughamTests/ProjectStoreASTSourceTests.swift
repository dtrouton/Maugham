import XCTest
@testable import Maugham

@MainActor
final class ProjectStoreASTSourceTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PSASTSrcTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testShortStory_yieldsOnePieceWithFileContent() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Tale", in: tmp)
        // Seed by loading the store and writing through the manifested path.
        let store = try await ProjectStore.load(from: url)
        let path = store.manifest.structure.first?.path ?? ""
        XCTAssertFalse(path.isEmpty, "short story should have a path")
        try "Once upon a time.".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)

        let src = ProjectStoreASTSource(projectStore: store)
        let pieces = src.orderedPieces()

        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces.first?.mode, .prose)
        XCTAssertEqual(pieces.first?.displayText, "Once upon a time.")
    }

    func testScreenplay_picksFountainMode() async throws {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "Movie", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let path = store.manifest.structure.first?.path ?? ""
        XCTAssertTrue(path.hasSuffix(".fountain"), "expected .fountain path, got \(path)")
        try "INT. ROOM - DAY\n\nA character.".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)

        let src = ProjectStoreASTSource(projectStore: store)
        let pieces = src.orderedPieces()

        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces.first?.mode, .fountain)
        XCTAssertTrue(pieces.first?.displayText.contains("INT. ROOM") ?? false)
    }

    func testEmptyStructure_yieldsNoPieces() async throws {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Empty", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let src = ProjectStoreASTSource(projectStore: store)
        XCTAssertTrue(src.orderedPieces().isEmpty)
    }
}
