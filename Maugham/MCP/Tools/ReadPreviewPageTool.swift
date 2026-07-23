import Foundation
import PDFKit
import AppKit

// MARK: - read_preview_page

/// F3: rasterize a page of the *latest* preview PDF, closing the visual loop
/// for `preview_compile`. Previews are throwaway (no Publication record, no
/// version bump), so they can't be addressed the way `read_publication_page`
/// addresses a `Publication` by id/version. Instead this tool resolves the
/// newest `.pdf` by modification time in the deterministic preview directory
/// (`.maugham/publish/build/preview/`, written by `PreviewCompiler`). That
/// directory is intentionally last-write-wins: whatever `preview_compile` (or
/// a language-edition preview, F2) rendered most recently is what this reads.
public enum ReadPreviewPageTool: MCPTool {
    public static let method = "read_preview_page"
    public static let description =
    "Rasterize one page of the LATEST preview PDF as a JPEG, closing the visual loop for preview_compile. There is no id/version to address — this always reads whichever preview was rendered most recently (newest .pdf by modification time in the project's preview build directory), including a language-edition preview (F2). Run preview_compile first; this fails with 'No preview output — run preview_compile first' when no preview exists. If the most recent preview is an EPUB it errors (only PDF previews can be rasterized). The response carries preview_filename + preview_mtime (ISO8601) so staleness is self-evident. Optional max_dimension/quality/region (region is normalized 0–1, top-left origin). Returns the same image-response envelope as read_document. Pages are 1-indexed."
    public static let inputSchemaJSON = #"""
    {"type":"object","properties":{"project_id":{"type":"string"},"page_number":{"type":"integer"},"max_dimension":{"type":"integer","description":"Longest-edge cap (256–4096, default 2048)."},"quality":{"type":"integer","description":"JPEG quality 10–100 (default 85)."},"region":{"type":"object","description":"Optional crop, normalized 0–1, top-left origin.","properties":{"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"}},"required":["x","y","width","height"]}},"required":["project_id","page_number"]}
    """#

    struct Params: Codable {
        let projectID: String
        let pageNumber: Int
        let maxDimension: Int?
        let quality: Int?
        let region: ImageResponseBuilder.Region?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case pageNumber = "page_number"
            case maxDimension = "max_dimension"
            case quality, region
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.projectID, in: registry)
        let projectURL = entry.url

        let previewDir = projectURL.appendingPathComponent(
            PreviewCompiler.previewSubpath, isDirectory: true)
        let fm = FileManager.default

        // Gather PDF and EPUB previews with their mtimes. We consider both so
        // "the latest preview" is honest: a newer EPUB after an older PDF must
        // error (staleness would be silent otherwise), not fall back to the
        // stale PDF.
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let contents = (try? fm.contentsOfDirectory(
            at: previewDir, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []
        let previews: [(url: URL, mtime: Date, ext: String)] = contents.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard ext == "pdf" || ext == "epub" else { return nil }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return (url, mtime, ext)
        }

        guard let newest = previews.max(by: { $0.mtime < $1.mtime }) else {
            throw MCPError.invalidArgument(
                "No preview output — run preview_compile first")
        }
        guard newest.ext == "pdf" else {
            throw MCPError.invalidArgument(
                "the latest preview '\(newest.url.lastPathComponent)' is an EPUB; only PDF previews can be rasterized — run preview_compile with format \"pdf\"")
        }

        guard let pdf = PDFDocument(url: newest.url) else {
            throw MCPError.internalError(
                "could not open preview PDF at \(newest.url.path)")
        }
        let zeroBased = params.pageNumber - 1
        guard zeroBased >= 0, zeroBased < pdf.pageCount,
              let page = pdf.page(at: zeroBased) else {
            throw MCPError.invalidArgument(
                "page out of range: \(params.pageNumber) (preview has \(pdf.pageCount) pages)")
        }

        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw MCPError.internalError("page has zero dimensions")
        }
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(bounds)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()

        let envelope = try ImageResponseBuilder.encodeEnvelope(
            nsImage: image,
            region: params.region,
            maxDimension: params.maxDimension,
            quality: params.quality)

        // Fold the resolved preview identity (filename + mtime) into the
        // envelope as sibling keys. `MCPToolsCallHandler` passes any object
        // carrying a top-level `content` array through verbatim, so these
        // extra fields survive to the caller and make staleness self-evident.
        return injectResolution(
            into: envelope,
            filename: newest.url.lastPathComponent,
            mtime: newest.mtime)
    }

    /// Add `preview_filename` and `preview_mtime` (ISO8601) as siblings of the
    /// image envelope's `content` array. Falls back to the untouched envelope
    /// if the shape is unexpectedly not a JSON object.
    private static func injectResolution(
        into envelope: Data, filename: String, mtime: Date
    ) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        guard var obj = (try? JSONSerialization.jsonObject(with: envelope))
                as? [String: Any] else { return envelope }
        obj["preview_filename"] = filename
        obj["preview_mtime"] = iso.string(from: mtime)
        return (try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys])) ?? envelope
    }
}
