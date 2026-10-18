import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ProjectStoreASTSourceTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = TestTemp.root
            .appendingPathComponent("PSASTSrcTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testShortStory_yieldsOnePieceWithFileContent() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Tale", in: tmp)
        // Seed by loading the store and bootstrapping the op log through Document.load.
        let store = try await ProjectStore.load(from: url)
        let path = store.manifest.structure.first?.path ?? ""
        XCTAssertFalse(path.isEmpty, "short story should have a path")
        let docURL = url.appendingPathComponent(path)
        try "Once upon a time.".write(to: docURL, atomically: true, encoding: .utf8)
        _ = try await Document.load(
            url: docURL, device: "test", session: "test", presenter: nil)

        let src = ProjectStoreASTSource(projectStore: store)
        let pieces = try src.orderedPieces()

        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces.first?.mode, .prose)
        // After Bootstrap the op-log render includes ¶id anchors; use contains.
        XCTAssertTrue(
            pieces.first?.displayText.contains("Once upon a time.") ?? false,
            "displayText should contain the seeded prose")
    }

    func testScreenplay_picksFountainMode() async throws {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "Movie", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let path = store.manifest.structure.first?.path ?? ""
        XCTAssertTrue(path.hasSuffix(".fountain"), "expected .fountain path, got \(path)")
        let docURL = url.appendingPathComponent(path)
        try "INT. ROOM - DAY\n\nA character.".write(
            to: docURL, atomically: true, encoding: .utf8)
        _ = try await Document.load(
            url: docURL, device: "test", session: "test", presenter: nil)

        let src = ProjectStoreASTSource(projectStore: store)
        let pieces = try src.orderedPieces()

        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces.first?.mode, .fountain)
        XCTAssertTrue(pieces.first?.displayText.contains("INT. ROOM") ?? false)
    }

    /// A hand-imported `scene.FOUNTAIN` is built as Fountain: the mode is
    /// `ProjectAST.Mode(DocumentFormat.ofManuscript(path:))`, whose extension
    /// match is case-insensitive.
    func testUppercaseFOUNTAINPiece_picksFountainMode() async throws {
        let docPath = "scene.FOUNTAIN"
        try "INT. ROOM - DAY\n\nA character.".write(
            to: tmp.appendingPathComponent(docPath), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-up", title: "Scene", type: .document, path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        _ = try await Document.load(
            url: tmp.appendingPathComponent(docPath),
            device: "test", session: "test", presenter: nil)

        let pieces = try ProjectStoreASTSource(projectStore: store).orderedPieces()

        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces.first?.mode, .fountain)
        XCTAssertTrue(pieces.first?.displayText.contains("INT. ROOM") ?? false)
    }

    func testEmptyStructure_yieldsNoPieces() async throws {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Empty", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let src = ProjectStoreASTSource(projectStore: store)
        XCTAssertTrue(try src.orderedPieces().isEmpty)
    }
}
