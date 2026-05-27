import Foundation
import AppKit

/// Shared image → JPEG-in-MCP-envelope pipeline.
///
/// Used by `ReadDocumentTool` (for image research items) and
/// `ReadPublishImageTool` (for images under `.maugham/publish/`).
///
/// Region coordinates are **normalized 0–1 with top-left origin**; the
/// renderer flips y internally for NSImage's bottom-up space.
///
/// Caps payload under MCP's 1 MB transport budget by stepping the
/// longest-edge dimension down ~25% per retry until the JPEG fits or the
/// floor is reached.
public enum ImageResponseBuilder {

    /// Normalized 0–1 crop region. `width` and `height` are extents from
    /// `(x, y)`. The renderer ensures `x + width ≤ 1` and `y + height ≤ 1`.
    public struct Region: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Default longest-edge cap if the caller doesn't override. 2048 px at
    /// JPEG q=85 produces ~400–700 KB for a full-page handwritten photo —
    /// the sweet spot for readability under MCP's ~720 KB raw-bytes budget.
    public static let defaultMaxDimension: Int = 2048
    /// Default JPEG quality. 85 keeps handwriting legible without bloat.
    public static let defaultJPEGQuality: Int = 85
    /// Allowed range for the caller-supplied max_dimension.
    public static let dimensionFloor = 256
    public static let dimensionCeiling = 4096
    /// Sanity cap on the on-disk source before NSImage opens it. Phone photos
    /// top out around 10–15 MB; 50 MB is well above any reasonable input
    /// and prevents loading absurd files into memory.
    public static let maxSourceImageBytes = 50 * 1024 * 1024

    /// Raw-bytes budget for the JPEG payload. Base64 inflates ~33% and the
    /// JSON envelope adds a few hundred bytes; 720 KB leaves headroom under
    /// MCP's 1 MB result cap.
    private static let jpegByteBudget = 720_000
    /// Step-down sequence for auto-fallback when the encoded JPEG exceeds
    /// jpegByteBudget. Each retry reduces longest-edge by roughly 25%.
    private static let fallbackSteps: [Double] = [1.0, 0.75, 0.5625, 0.4218]

    public struct Rendered {
        public let jpeg: Data
        public let effectiveMax: Int
        public let fallbackUsed: Bool
        public let requestedMax: Int
    }

    // MARK: - Public API

    /// Render the image at `url` to JPEG with the requested cap, quality,
    /// and optional crop. Throws `MCPError.invalidArgument` on decode
    /// failure, oversize source, invalid region, or budget-impossible
    /// configurations.
    public static func render(
        at url: URL, region: Region?, requestedMax: Int, quality: Int
    ) throws -> Rendered {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? NSNumber,
           size.intValue > maxSourceImageBytes {
            let mb = Double(size.intValue) / (1024 * 1024)
            throw MCPError.invalidArgument(String(
                format: "Image at '%@' is %.1f MB on disk; refusing to load. Maugham resizes for MCP delivery but won't open a source over 50 MB.",
                url.lastPathComponent, mb))
        }
        if let region { try validateRegion(region) }
        let clampedMax = clampDimension(requestedMax)
        let clampedQuality = clampQuality(quality)
        return try renderImageWithBudget(
            at: url, region: region,
            requestedMax: clampedMax, quality: clampedQuality)
    }

    /// Convenience: render and return an MCP `content` envelope ready to
    /// JSONEncode. Prepends a one-line text block when the budget
    /// fallback fires so the agent knows the effective resolution.
    public static func encodeEnvelope(
        at url: URL, region: Region?, maxDimension: Int?, quality: Int?
    ) throws -> Data {
        let requestedMax = clampDimension(maxDimension ?? defaultMaxDimension)
        let clampedQuality = clampQuality(quality ?? defaultJPEGQuality)
        let rendered = try render(
            at: url, region: region,
            requestedMax: requestedMax, quality: clampedQuality)

        let imageBlock: AnyJSON = .object([
            "type": .string("image"),
            "data": .string(rendered.jpeg.base64EncodedString()),
            "mimeType": .string("image/jpeg")
        ])
        var blocks: [AnyJSON] = []
        if rendered.fallbackUsed {
            let note = "Requested \(requestedMax)px exceeded the 1 MB transport cap; returning at \(rendered.effectiveMax)px instead."
            blocks.append(.object([
                "type": .string("text"),
                "text": .string(note)
            ]))
        }
        blocks.append(imageBlock)
        let envelope = AnyJSON.object(["content": .array(blocks)])
        return try JSONEncoder().encode(envelope)
    }

    public static func clampDimension(_ d: Int) -> Int {
        return min(dimensionCeiling, max(dimensionFloor, d))
    }

    public static func clampQuality(_ q: Int) -> Int {
        return min(100, max(10, q))
    }

    public static func validateRegion(_ r: Region) throws {
        let inUnit = { (v: Double) in v >= 0 && v <= 1 }
        guard inUnit(r.x), inUnit(r.y),
              r.width > 0, r.height > 0,
              r.x + r.width <= 1.0 + 1e-9,
              r.y + r.height <= 1.0 + 1e-9 else {
            throw MCPError.invalidArgument(
                "region must satisfy 0≤x,y; 0<width,height; x+width≤1; y+height≤1 (got x=\(r.x), y=\(r.y), width=\(r.width), height=\(r.height))")
        }
    }

    // MARK: - Internal rendering

    private static func renderImageWithBudget(
        at url: URL, region: Region?, requestedMax: Int, quality: Int
    ) throws -> Rendered {
        guard let source = NSImage(contentsOf: url) else {
            throw MCPError.invalidArgument(
                "Could not decode image at '\(url.path)' as a recognized format")
        }
        let sourceSize = source.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            throw MCPError.invalidArgument("image has zero dimensions")
        }
        // Source rect: full image or the requested crop. NSImage uses
        // bottom-up coordinates, so we flip the region's y to convert from
        // the agent's top-left-origin convention.
        let sourceRect: NSRect
        if let r = region {
            let sx = r.x * sourceSize.width
            let sy = (1.0 - r.y - r.height) * sourceSize.height
            let sw = r.width * sourceSize.width
            let sh = r.height * sourceSize.height
            sourceRect = NSRect(x: sx, y: sy, width: sw, height: sh)
        } else {
            sourceRect = NSRect(origin: .zero, size: sourceSize)
        }

        for step in fallbackSteps {
            let maxDim = max(dimensionFloor, Int(Double(requestedMax) * step))
            guard let jpeg = renderJPEG(
                source: source, sourceRect: sourceRect,
                maxDimension: maxDim, quality: quality) else { continue }
            if jpeg.count <= jpegByteBudget || maxDim <= dimensionFloor {
                return Rendered(
                    jpeg: jpeg,
                    effectiveMax: maxDim,
                    fallbackUsed: step != 1.0,
                    requestedMax: requestedMax)
            }
        }
        throw MCPError.invalidArgument(
            "Could not fit image under the 1 MB transport cap even at \(dimensionFloor)px. Try a tighter region.")
    }

    /// Draw `sourceRect` of `source` into a bitmap whose longest edge equals
    /// `maxDimension` (preserving aspect ratio), then JPEG-encode at the
    /// given quality. Never upscales — if the source rect is smaller than
    /// the cap in both dimensions, the bitmap matches the source rect.
    private static func renderJPEG(
        source: NSImage, sourceRect: NSRect, maxDimension: Int, quality: Int
    ) -> Data? {
        let scale = min(1.0, Double(maxDimension) / Double(max(sourceRect.width, sourceRect.height)))
        let targetW = max(1, Int((sourceRect.width * scale).rounded()))
        let targetH = max(1, Int((sourceRect.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetW,
            pixelsHigh: targetH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: targetW, height: targetH)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
            from: sourceRect,
            operation: .copy, fraction: 1.0)
        return rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: CGFloat(quality) / 100.0])
    }
}
