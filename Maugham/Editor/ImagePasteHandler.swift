import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Saves a pasted NSImage as a PNG file sibling to a research note and
/// returns the Markdown reference to insert at the cursor.
public enum ImagePasteHandler {

    /// Persist `image` to a `<note-slug>_assets/` folder next to the note,
    /// using a timestamp-based filename. Returns a Markdown image ref
    /// `![](./<note-slug>_assets/image-YYYYMMDD-HHMMSS.png)` for insertion.
    @discardableResult
    public static func saveAndReference(
        image: NSImage,
        forNoteAt notePath: String,
        in projectURL: URL
    ) throws -> String {
        let dest = try destination(forNoteAt: notePath, in: projectURL, ext: "png")
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ImagePasteError.encodingFailed
        }
        try pngData.write(to: dest.fileURL, options: .atomic)
        return "![](./\(dest.assetsDirName)/\(dest.filename))"
    }

    /// File-URL twin of `saveAndReference`: copy an existing image (dragged or
    /// picked) into the note's `<slug>_assets/` folder, preserving its extension,
    /// under the same timestamp-naming/dedupe scheme. Returns the Markdown ref.
    ///
    /// **The one entry point an arbitrary file can reach, so it is the one that
    /// validates** (M1A Task 12). `saveAndReference(image:)` takes an `NSImage`
    /// and re-encodes it, so there is nothing there to check; this one used to
    /// take `sourceURL.pathExtension` as given and check nothing at all, and
    /// every caller inherited that. What a `.txt` bought, on the surface that
    /// had a check: a file copied into the well, a card drawing the photograph
    /// glyph, and a decode that can only fail — which `CanvasThumbnails`
    /// memoises with no `invalidate`, so it is one permanently dead cache entry
    /// per mistake.
    ///
    /// Throws `.notAnImage` **before anything is copied**, naming the file: a
    /// writer who dragged four things in needs to know which one did not arrive.
    @discardableResult
    public static func saveAndReferenceFile(
        from sourceURL: URL,
        forNoteAt notePath: String,
        in projectURL: URL
    ) throws -> String {
        guard isIngestableImage(sourceURL) else {
            throw ImagePasteError.notAnImage(filename: sourceURL.lastPathComponent)
        }
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let dest = try destination(forNoteAt: notePath, in: projectURL, ext: ext)
        try FileManager.default.copyItem(at: sourceURL, to: dest.fileURL)
        return "![](./\(dest.assetsDirName)/\(dest.filename))"
    }

    // MARK: - What a well will take

    /// Whether this file is one a `<slug>_assets/` well will take.
    ///
    /// **Moved here from `CanvasExternalDrop`, not copied.** It was scoped to
    /// the canvas on the stated grounds that widening a shared saver was not one
    /// task's decision to make; M1A Task 12 made visual language a well of its own
    /// and took that decision, so there is one spelling and every well gets it.
    ///
    /// **The comment it arrived with was wrong about macOS, and the shape below
    /// is what the measurements support** (2026-08-01, macOS 26.5; every case is
    /// pinned by `ImagePasteHandlerTests.test_whatTheSaverWillAndWillNotTakeIntoAWell`).
    /// It claimed to read *"the file's real type first, its extension second: a
    /// file with no extension still has a type on disk"*. Neither half holds:
    /// `URLResourceValues.contentType` is derived from the NAME, so a text file
    /// called `liar.png` reports `public.png`, and a real PNG with no extension
    /// at all reports `public.data` — the extensionless drag the ordering was
    /// written to serve was the one case it refused.
    ///
    /// So: the questions below, in order, any yes being enough.
    ///
    /// 1. **Does the type the OS gives this name conform to `.image`?** This is
    ///    what keeps `.svg` acceptable — no `CGImageSource` decodes one and
    ///    `NSImage` displays it, so a decoder must never be a veto here.
    /// 2. **Does the extension alone claim one?** For a URL whose file is not
    ///    present, which is a drag whose file has not materialised yet.
    /// 3. **Only when the OS had no opinion at all** — an extensionless file
    ///    reports `public.data` — can an image decoder read the header? Gated,
    ///    rather than asked of everything, because ImageIO reads a PDF's first
    ///    page happily and a PDF is not something these wells hold.
    ///
    /// It is deliberately a WIDENING of the canvas check it replaces: nothing
    /// that reached a well before is refused now, so no working drop on any of
    /// the surfaces already using this saver can become a silent refusal. What
    /// it stops is the file that answers no to every one of them.
    public static func isIngestableImage(_ url: URL) -> Bool {
        let declared = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if declared?.conforms(to: .image) == true { return true }
        if UTType(filenameExtension: url.pathExtension.lowercased())?
            .conforms(to: .image) == true { return true }
        guard declared == nil || declared == .data || declared == .item else { return false }
        return imageDecoderReadsAHeader(at: url)
    }

    /// Whether ImageIO can make sense of this file's header. Reads the header
    /// only — `CGImageSourceCreateWithURL` is incremental, so this does not pull
    /// a large photograph into memory to answer a yes/no question.
    private static func imageDecoderReadsAHeader(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }

    /// Resolve the `<slug>_assets/` folder next to `notePath`, create it, and mint
    /// a deduped timestamp filename with the given extension. Single home for the
    /// naming/dedupe logic shared by the NSImage and file-URL entry points.
    private static func destination(
        forNoteAt notePath: String, in projectURL: URL, ext: String
    ) throws -> (assetsDir: URL, assetsDirName: String, fileURL: URL, filename: String) {
        let noteURL = projectURL.appendingPathComponent(notePath)
        let noteSlug = noteURL.deletingPathExtension().lastPathComponent
        let assetsDirName = "\(noteSlug)_assets"
        let assetsDir = noteURL
            .deletingLastPathComponent()
            .appendingPathComponent(assetsDirName)

        try FileManager.default.createDirectory(
            at: assetsDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        let timestamp = formatter.string(from: Date())

        // Dedupe on rare same-second write
        var filename = "image-\(timestamp).\(ext)"
        var counter = 2
        while FileManager.default.fileExists(
            atPath: assetsDir.appendingPathComponent(filename).path) {
            filename = "image-\(timestamp)-\(counter).\(ext)"
            counter += 1
        }
        return (assetsDir, assetsDirName, assetsDir.appendingPathComponent(filename), filename)
    }

    /// **Two failures with different owners, and the surfaces tell them apart.**
    /// `encodingFailed` is ours — a picture the writer handed us that we could
    /// not re-encode — and there is nothing they can do about it. `notAnImage`
    /// is theirs, and is the only one worth a sentence naming their file. A
    /// surface that showed both would blame a writer for our bug.
    public enum ImagePasteError: Error, LocalizedError {
        case encodingFailed
        case notAnImage(filename: String)

        public var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "That picture could not be added."
            case .notAnImage(let filename):
                return "“\(filename)” isn’t a picture, so it wasn’t added."
            }
        }
    }

    /// **One sentence for a writer whose picture did not land, shared by every
    /// surface that takes one.** A drop that silently does nothing is
    /// indistinguishable from a broken surface — the defect the palette well
    /// shipped behind a `try?` — so every failure says something.
    ///
    /// It names the writer's file only when the writer's file is what is wrong.
    /// Anything else is ours, and `error.localizedDescription` on an arbitrary
    /// error is *"The operation couldn't be completed"*, which tells them
    /// nothing and reads like a crash.
    public static func failureMessage(for error: Error) -> String {
        (error as? ImagePasteError)?.errorDescription ?? "That picture could not be added."
    }
}
