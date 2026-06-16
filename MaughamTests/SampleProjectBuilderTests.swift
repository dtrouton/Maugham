import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class SampleProjectBuilderTests: XCTestCase {
    /// Repo seed dir, injected so the test doesn't depend on the app bundle.
    private func seedRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // MaughamTests/
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Maugham/Resources/Samples")
    }

    private func tempParent() throws -> URL {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("samples-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
        return parent
    }

    func test_buildsNovelSampleThatLoadsWithAnchors() async throws {
        let parent = try tempParent()

        let url = try await SampleProjectBuilder.build(
            .novel, seedsRoot: seedRoot(), destinationParent: parent)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(ProjectManifest.fileName).path))

        // Open through the standard load path so Bootstrap mints the inline
        // ¶id anchors and writes the anchored .md back to disk. Document.load's
        // real signature is (url:device:session:presenter:); it resolves the
        // doc-id + projectURL by walking up to project.maugham.json.
        let firstDoc = url.appendingPathComponent("manuscript/01-welcome.md")
        _ = try await Document.load(
            url: firstDoc, device: "test-device", session: "test-session",
            presenter: nil)

        // `displayText` deliberately strips anchors for editor display, so we
        // assert against the on-disk .md, which Bootstrap re-materializes with
        // the inline <!-- ¶id --> comments.
        let onDisk = try String(contentsOf: firstDoc, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("<!-- ¶"),
            "Bootstrap should have minted inline anchors on load")
    }

    func test_buildsScreenplaySample() async throws {
        let parent = try tempParent()
        let url = try await SampleProjectBuilder.build(
            .screenplay, seedsRoot: seedRoot(), destinationParent: parent)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("manuscript/01-welcome.fountain").path))
    }

    func test_dedupesDestinationName() async throws {
        let parent = try tempParent()
        let first = try await SampleProjectBuilder.build(
            .novel, seedsRoot: seedRoot(), destinationParent: parent)
        let second = try await SampleProjectBuilder.build(
            .novel, seedsRoot: seedRoot(), destinationParent: parent)
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
    }
}
