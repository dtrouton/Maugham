import XCTest
import AppKit
@testable import Maugham

@MainActor
final class ImagePasteHandlerTests: XCTestCase {
    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImagePaste-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        return tmp
    }

    private func makeImage(size: NSSize = NSSize(width: 10, height: 10)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    func test_save_writesPNGToAssetsFolder() throws {
        let project = try makeProject()
        try Data().write(to: project.appendingPathComponent("research/sarah.md"))

        let ref = try ImagePasteHandler.saveAndReference(
            image: makeImage(),
            forNoteAt: "research/sarah.md",
            in: project)

        // Assets folder created
        let assets = project.appendingPathComponent("research/sarah_assets")
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.path))

        // One image file inside
        let contents = try FileManager.default.contentsOfDirectory(atPath: assets.path)
        XCTAssertEqual(contents.count, 1)
        let imageFile = contents[0]
        XCTAssertTrue(imageFile.hasSuffix(".png"))

        // Markdown ref shape
        XCTAssertTrue(ref.hasPrefix("![]("))
        XCTAssertTrue(ref.contains("./sarah_assets/image-"))
        XCTAssertTrue(ref.hasSuffix(".png)"))
    }

    func test_save_intoExistingAssetsFolder_addsSecondImage() throws {
        let project = try makeProject()
        try Data().write(to: project.appendingPathComponent("research/sarah.md"))
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("research/sarah_assets"),
            withIntermediateDirectories: true)
        try Data().write(to:
            project.appendingPathComponent("research/sarah_assets/pre-existing.png"))

        _ = try ImagePasteHandler.saveAndReference(
            image: makeImage(),
            forNoteAt: "research/sarah.md",
            in: project)

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: project.appendingPathComponent("research/sarah_assets").path)
        XCTAssertEqual(contents.count, 2,
                       "expected pre-existing + new image; got \(contents)")
    }
}
