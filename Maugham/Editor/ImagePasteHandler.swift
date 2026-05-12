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

        // Dedupe on rare same-second paste
        var filename = "image-\(timestamp).png"
        var counter = 2
        while FileManager.default.fileExists(
            atPath: assetsDir.appendingPathComponent(filename).path) {
            filename = "image-\(timestamp)-\(counter).png"
            counter += 1
        }
        let fileURL = assetsDir.appendingPathComponent(filename)

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ImagePasteError.encodingFailed
        }
        try pngData.write(to: fileURL, options: .atomic)

        return "![](./\(assetsDirName)/\(filename))"
    }

    public enum ImagePasteError: Error {
        case encodingFailed
    }
}
