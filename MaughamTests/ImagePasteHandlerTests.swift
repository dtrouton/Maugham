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

    // MARK: - The file-URL twin validates (M1A Task 12)

    private func writeFile(named name: String, bytes: Data, in project: URL) throws -> URL {
        let url = project.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func pngData() throws -> Data {
        let image = makeImage()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// **A file that is not a picture never reaches the well.**
    ///
    /// `saveAndReferenceFile` took `sourceURL.pathExtension` as given and
    /// validated nothing, so every caller that could be handed an arbitrary file
    /// copied it in and returned a Markdown ref to it: on the canvas that is an
    /// owned node drawing the photograph glyph over a decode that can only fail,
    /// and `CanvasThumbnails` memoises the failure with no `invalidate`, so it is
    /// one permanently dead cache entry per mistake. Falsified by removing the
    /// guard — the `.txt` lands in the well.
    ///
    /// **Control, in the same test:** a real PNG through the same call still
    /// lands. Without it a guard that refused everything would pass here.
    func test_theSaverRefusesAFileThatIsNotAnImage() throws {
        let project = try makeProject()
        try Data().write(to: project.appendingPathComponent("research/sarah.md"))
        let notes = try writeFile(
            named: "notes.txt", bytes: Data("not a picture".utf8), in: project)
        let assets = project.appendingPathComponent("research/sarah_assets")

        XCTAssertThrowsError(
            try ImagePasteHandler.saveAndReferenceFile(
                from: notes, forNoteAt: "research/sarah.md", in: project)
        ) { error in
            guard case ImagePasteHandler.ImagePasteError.notAnImage(let filename) = error else {
                return XCTFail("expected .notAnImage, got \(error)")
            }
            XCTAssertEqual(filename, "notes.txt",
                           "the refusal NAMES the file — a writer who dragged four "
                           + "things in needs to know which one did not arrive")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.path),
                       "nothing was ingested, so the well was never even made")

        // Control.
        let picture = try writeFile(named: "real.png", bytes: try pngData(), in: project)
        let ref = try ImagePasteHandler.saveAndReferenceFile(
            from: picture, forNoteAt: "research/sarah.md", in: project)
        XCTAssertTrue(ref.contains("./sarah_assets/image-"), "got \(ref)")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: assets.path).count, 1)
    }

    /// **What the predicate takes and what it turns away, measured rather than
    /// reasoned about.**
    ///
    /// The comment this test replaces claimed the check read *"the file's real
    /// type first, its extension second: a file with no extension still has a
    /// type on disk"* — and both halves of that are false on macOS 26.5,
    /// measured 2026-08-01. `URLResourceValues.contentType` is derived from the
    /// NAME: a text file called `liar.png` reports `public.png`, and a real PNG
    /// with no extension at all reports `public.data`. The extensionless drag
    /// the ordering was written to serve was the one case it refused.
    ///
    /// So the decoder branch exists for exactly that case, and is reached only
    /// when the OS had no opinion — `doc.pdf` is why it is not reached
    /// otherwise: ImageIO reads a PDF's first page happily, and a PDF is not
    /// something these wells hold.
    ///
    /// Every row is a pin on the PREDICATE. The measurement that motivated it
    /// is in the doc comment on `isIngestableImage`; no row here re-measures
    /// it — each one holds under either hypothesis about how the OS derives
    /// `contentType`, which is what makes them a good pin on our code and no
    /// pin at all on the platform.
    func test_whatTheSaverWillAndWillNotTakeIntoAWell() throws {
        let project = try makeProject()
        let png = try pngData()

        XCTAssertTrue(
            ImagePasteHandler.isIngestableImage(
                try writeFile(named: "real.png", bytes: png, in: project)),
            "the ordinary case")
        XCTAssertTrue(
            ImagePasteHandler.isIngestableImage(
                try writeFile(named: "photograph", bytes: png, in: project)),
            "no extension, real PNG bytes: reports `public.data`, so only a "
            + "decoder can tell. This is the case the old comment named and the "
            + "old code refused.")
        XCTAssertTrue(
            ImagePasteHandler.isIngestableImage(
                project.appendingPathComponent("not-yet-there.png")),
            "a URL whose file is not present has no type to read; the extension "
            + "is all there is, and refusing here would decline a drag before "
            + "its file materialises")
        XCTAssertTrue(
            ImagePasteHandler.isIngestableImage(
                try writeFile(named: "liar.png", bytes: Data("nope".utf8), in: project)),
            "**accepted, deliberately.** The OS itself calls this a PNG. "
            + "Refusing it would also refuse `.svg`, which no CGImageSource "
            + "decodes and which NSImage displays — so the decoder is a "
            + "widening of this predicate and never a veto over it.")

        XCTAssertFalse(
            ImagePasteHandler.isIngestableImage(
                try writeFile(named: "notes.txt", bytes: Data("nope".utf8), in: project)),
            "the drop this whole task is about")
        XCTAssertFalse(
            ImagePasteHandler.isIngestableImage(
                try writeFile(named: "doc.pdf", bytes: try pdfData(), in: project)),
            "ImageIO reads a PDF's first page, so a bare decoder fallback would "
            + "take one. The decoder is asked ONLY when the type is `public.data`.")
        let folder = project.appendingPathComponent("afolder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(ImagePasteHandler.isIngestableImage(folder),
                       "a folder drag reports `public.folder`")
    }

    private func pdfData() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 10, height: 10)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
