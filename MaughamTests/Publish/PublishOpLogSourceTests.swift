import XCTest
import MaughamCore
@testable import Maugham

/// ADR 0018: `ProjectStoreASTSource` must derive manuscript content from the op
/// log, not the raw `.md` file. If the `.md` is stale (overwritten externally),
/// the publish pipeline must still see the op-log truth.
@MainActor
final class PublishOpLogSourceTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishOpLogSource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_publishASTSource_usesOpLogNotStaleMd() async throws {
        // 1. Create a short story project (single document, known manifest id).
        let projectURL = try await ProjectFactory.createShortStoryProject(
            named: "OpLogTest", in: tmp)

        // 2. Write the canonical content to the doc's .md so Bootstrap has
        //    something meaningful to read and record into the op log.
        let storyURL = projectURL.appendingPathComponent("story.md")
        try "Chapter body.".write(to: storyURL, atomically: true, encoding: .utf8)

        // 3. Load via Document.load — this runs Bootstrap.run which writes the
        //    paragraph content into .maugham/ops/manuscript.<slug>.jsonl.
        _ = try await Document.load(
            url: storyURL, device: "oplogtest", session: "oplogtest", presenter: nil)

        // 4. Overwrite the .md with stale content so that any code reading the
        //    file directly would return "STALE", not "Chapter body.".
        try "STALE".write(to: storyURL, atomically: true, encoding: .utf8)

        // 5. Build the AST source from the project store (the same entry point
        //    the publish pipeline uses).
        let store = try await ProjectStore.load(from: projectURL)
        let src = ProjectStoreASTSource(projectStore: store)
        let pieces = src.orderedPieces()

        // 6. Assert the piece text derives from the op log ("Chapter body."),
        //    not from the stale .md ("STALE").
        XCTAssertEqual(pieces.count, 1, "expected exactly one piece")
        let displayText = pieces.first?.displayText ?? ""
        XCTAssertTrue(
            displayText.contains("Chapter body."),
            "piece should contain op-log content; got: \(displayText.prefix(200))")
        XCTAssertFalse(
            displayText.contains("STALE"),
            "piece must NOT read the stale .md; got: \(displayText.prefix(200))")
    }
}
