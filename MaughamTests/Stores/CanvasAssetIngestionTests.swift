import XCTest
import AppKit
@testable import Maugham
import MaughamCore

/// Coverage for the canvas's asset well (`Maugham/Stores/ProjectStore+CanvasAssets.swift`):
/// the one pair that gives a captured or dropped photograph a home the writer
/// cannot tidy away.
///
/// **What every test here is really guarding is the returned string.** It goes
/// straight into `CanvasItemReference.owned(path:)`, which requires a
/// PROJECT-RELATIVE path. An absolute path, a `file://` URL or a Markdown ref
/// each renders nothing on the canvas, keys the thumbnail cache on a string
/// that differs between Macs, and breaks the moment the project is moved or
/// synced — and all three are what the saver's own return value looks like one
/// resolution step earlier, so this is a near miss rather than a far-fetched
/// one.
@MainActor
final class CanvasAssetIngestionTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    // MARK: - The NSImage arm

    func test_ingestingAnImage_landsUnderCanvasAssetsAndReturnsAProjectRelativePath() async throws {
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "CanvasIngestImage", in: temp.url)
        let store = try await ProjectStore.load(from: projectURL)

        let path = try await store.ingestCanvasAsset(image: makeImage())

        // Project-relative, in every spelling the failure could take.
        XCTAssertFalse((path as NSString).isAbsolutePath, "returned an absolute path: \(path)")
        XCTAssertFalse(path.hasPrefix("file://"), "returned a file URL: \(path)")
        XCTAssertFalse(path.hasPrefix("./"), "returned a leading-./ path: \(path)")
        XCTAssertFalse(path.contains("!["), "returned a Markdown ref: \(path)")
        XCTAssertFalse(path.contains(temp.url.path), "leaked this Mac's path: \(path)")

        // …and it is the well the canvas owns, at the project ROOT.
        XCTAssertTrue(path.hasPrefix("canvas_assets/"), "landed outside the well: \(path)")
        XCTAssertTrue(path.hasSuffix(".png"))

        // Resolving it against the project URL finds the file that was written.
        let resolved = projectURL.appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
        XCTAssertNotNil(NSImage(contentsOf: resolved), "the bytes on disk are not an image")

        // Content, not derived state: deleting `.maugham/` must not cost the
        // photographs, so the well cannot be inside it.
        XCTAssertFalse(path.hasPrefix(".maugham/"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent(".maugham/canvas_assets").path))
    }

    // MARK: - The file-URL arm

    func test_ingestingAFileURL_preservesTheSourceExtensionAndTheBytes() async throws {
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "CanvasIngestFile", in: temp.url)
        let store = try await ProjectStore.load(from: projectURL)
        let source = try writeSourceFile(named: "seaside.jpg")

        let path = try await store.ingestCanvasAsset(fileURL: source)

        XCTAssertTrue(path.hasPrefix("canvas_assets/"), "landed outside the well: \(path)")
        XCTAssertTrue(path.hasSuffix(".jpg"), "lost the source extension: \(path)")
        XCTAssertFalse((path as NSString).isAbsolutePath, "returned an absolute path: \(path)")
        XCTAssertFalse(path.hasPrefix("./"), "returned a leading-./ path: \(path)")
        XCTAssertFalse(path.contains("!["), "returned a Markdown ref: \(path)")

        let resolved = projectURL.appendingPathComponent(path)
        XCTAssertEqual(
            try Data(contentsOf: resolved), try Data(contentsOf: source),
            "the copy is not the file that was dropped")

        // A copy, not a move: the drop source is the writer's own file (a photo
        // in their Pictures folder), and ingesting it must not take it away.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: - Dedupe

    /// The dedupe is the saver's — a same-second second write becomes
    /// `image-<ts>-2.<ext>`. This asserts we did not defeat it by, say,
    /// deriving the returned name from the source filename instead of from
    /// what the saver actually wrote.
    func test_twoIngestionsOfOneFile_produceTwoDistinctPathsAndTwoFiles() async throws {
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "CanvasIngestTwice", in: temp.url)
        let store = try await ProjectStore.load(from: projectURL)
        let source = try writeSourceFile(named: "seaside.jpg")

        let first = try await store.ingestCanvasAsset(fileURL: source)
        let second = try await store.ingestCanvasAsset(fileURL: source)

        XCTAssertNotEqual(first, second, "the second ingestion reported the first one's path")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent(first).path),
            "the first ingestion's file was overwritten")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent(second).path))
        XCTAssertEqual(try wellContents(of: projectURL).count, 2)
    }

    // MARK: - Control

    /// The control for every "it landed in `canvas_assets/`" assertion above: a
    /// project that has ingested nothing has no well at all. The pair creates
    /// it; nothing else in the project does, so a passing assertion upstream
    /// cannot be an accident of project scaffolding.
    func test_aProjectThatHasIngestedNothingHasNoWell() async throws {
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "CanvasIngestControl", in: temp.url)
        let store = try await ProjectStore.load(from: projectURL)
        let well = projectURL.appendingPathComponent("canvas_assets")

        XCTAssertFalse(FileManager.default.fileExists(atPath: well.path),
            "something other than the ingestion pair created canvas_assets/")

        _ = try await store.ingestCanvasAsset(image: makeImage())

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: well.path, isDirectory: &isDirectory),
            "the pair did not create the well")
        XCTAssertTrue(isDirectory.boolValue)
    }

    // MARK: - Helpers

    private func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemTeal.drawSwatch(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        image.unlockFocus()
        return image
    }

    /// A real image file OUTSIDE the project, standing in for a Finder drop.
    private func writeSourceFile(named name: String) throws -> URL {
        let sourceDir = temp.url.appendingPathComponent("Pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let url = sourceDir.appendingPathComponent(name)
        let tiff = try XCTUnwrap(makeImage().tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: url)
        return url
    }

    private func wellContents(of projectURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: projectURL.appendingPathComponent("canvas_assets").path)
    }
}
