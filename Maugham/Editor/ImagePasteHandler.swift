import Foundation
import AppKit

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
    @discardableResult
    public static func saveAndReferenceFile(
        from sourceURL: URL,
        forNoteAt notePath: String,
        in projectURL: URL
    ) throws -> String {
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let dest = try destination(forNoteAt: notePath, in: projectURL, ext: ext)
        try FileManager.default.copyItem(at: sourceURL, to: dest.fileURL)
        return "![](./\(dest.assetsDirName)/\(dest.filename))"
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

    public enum ImagePasteError: Error {
        case encodingFailed
    }
}
