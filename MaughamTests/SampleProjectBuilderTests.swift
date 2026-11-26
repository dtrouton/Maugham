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
        let parent = TestTemp.root
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

    /// **The sample novel is a walk through the window** (shell p5 Task 9):
    /// its second chapter's fold holds a note of its own and a link to the
    /// third, so clicking it opens a fold with something to pull up; the
    /// Research section keeps a whole-book note; every path the manifest
    /// names is in the seed.
    func test_theSampleNovelsFoldsAndResearchAreWhoseTheSampleSays() throws {
        let seed = seedRoot().appendingPathComponent("novel")
        let data = try Data(contentsOf: seed.appendingPathComponent(ProjectManifest.fileName))
        let manifest = try ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: data)
        let chapters = manifest.structure
        XCTAssertEqual(chapters.map(\.title), ["Welcome", "Try It", "Going Further"])
        let tryIt = try XCTUnwrap(chapters.first { $0.title == "Try It" })
        let goingFurther = try XCTUnwrap(chapters.first { $0.title == "Going Further" })
        XCTAssertEqual(tryIt.links, [goingFurther.id], "Try It's fold links to Going Further")
        let homes = ResearchHomes.derive(structure: manifest.structure, research: manifest.research,
                                         projectType: manifest.type)
        let notes = TreeWalk.collect(in: manifest.research, where: { $0.type == .asset })
        XCTAssertEqual(notes.count, 2)
        let chaptersNote = try XCTUnwrap(notes.first { tryIt.linkedResearchIds?.contains($0.id) == true })
        XCTAssertEqual(homes.homes(of: chaptersNote.id), [tryIt.id], "the chapter's note is Try It's")
        let bookNote = try XCTUnwrap(notes.first { $0.id != chaptersNote.id })
        XCTAssertEqual(homes.homes(of: bookNote.id), [], "the other note is the whole book's")
        XCTAssertTrue(homes.wholeBook.contains { $0.id == bookNote.id }, "in the Research section")
        for path in chapters.compactMap(\.path) + notes.compactMap(\.path) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: seed.appendingPathComponent(path).path), path)
        }
    }
}
