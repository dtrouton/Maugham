import Foundation
import MaughamCore

/// list_palette_cards — summaries of the project's sensory-palette cards.
/// Full note text and images come from `read_palette_card` (a sibling tool
/// in this file); this one stays cheap for a project-wide overview.
public enum ListPaletteCardsTool: MCPTool {
    public static let method = "list_palette_cards"
    public static let description =
        "List the project's sensory-palette cards (subject-keyed reference material: "
        + "locations, characters, motifs — each with swatches, sensory notes, images). "
        + "Use read_palette_card for a card's full notes and images."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    public struct Params: Codable { public let project_id: String }
    public struct CardSummary: Codable, Equatable {
        public let id: String
        public let title: String
        public let kind: String
        public let swatches: [String]
        public let note_count: Int
        public let image_paths: [String]
    }
    public struct Result: Codable, Equatable { public let cards: [CardSummary] }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let cards = entry.store.loadPaletteCards().map { card in
            CardSummary(
                id: card.researchItemId, title: card.title, kind: card.kind.rawValue,
                swatches: card.swatches, note_count: card.notes.count,
                image_paths: card.imagePaths)
        }
        return try JSONEncoder().encode(Result(cards: cards))
    }
}

/// read_palette_card — a card's full markdown plus its images.
/// Without `image`: text + per-image thumbnails (512px). With `image`: that one
/// image full-quality with crop-on-demand (same semantics as read_document).
public enum ReadPaletteCardTool: MCPTool {
    public static let method = "read_palette_card"
    public static let description =
        "Read one sensory-palette card: its full markdown (kind, swatches, sensory "
        + "notes) plus thumbnails of its images. Pass image (a path from the card's "
        + "image_paths) for one full-quality image, with optional region/max_dimension/"
        + "quality crop-on-demand like read_document."
    public static let inputSchemaJSON = #"""
    {"type":"object","properties":{
      "project_id":{"type":"string"},
      "card_id":{"type":"string"},
      "image":{"type":"string","description":"A path from the card's image_paths. When set, returns that one image full-quality with crop-on-demand (region/max_dimension/quality) like read_document."},
      "max_dimension":{"type":"integer","description":"Longest-edge cap for the single-image path (256–4096, default 2048). Ignored without image."},
      "quality":{"type":"integer","description":"JPEG quality 10–100 for the single-image path (default 85). Ignored without image."},
      "region":{"type":"object","description":"Optional crop for the single-image path, normalized 0–1, top-left origin. Ignored without image.","properties":{"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"}},"required":["x","y","width","height"]}
    },"required":["project_id","card_id"]}
    """#

    public struct Params: Codable {
        public let project_id: String
        public let card_id: String
        public let image: String?
        public let max_dimension: Int?
        public let quality: Int?
        public let region: ImageResponseBuilder.Region?
    }

    private static let thumbnailMax = 512
    private static let maxThumbnails = 6
    /// Combined raw-JPEG byte ceiling across all overview thumbnails. Mirrors
    /// `ImageResponseBuilder`'s per-image 720 KB budget; base64 inflates ~33%
    /// (≈960 KB) which, with the text block, stays under MCP's 1 MB cap.
    private static let combinedThumbnailByteBudget = 720_000

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        guard let card = entry.store.loadPaletteCards()
            .first(where: { $0.researchItemId == params.card_id }) else {
            throw MCPError.invalidArgument(
                "unknown card_id \(params.card_id) — call list_palette_cards for valid ids")
        }
        guard let item = entry.store.paletteCardItems()
            .first(where: { $0.id == params.card_id }), let rel = item.path else {
            throw MCPError.internalError("palette card \(params.card_id) has no path")
        }

        // Single-image full-quality path — identical semantics to read_document.
        if let imagePath = params.image {
            guard card.imagePaths.contains(imagePath) else {
                throw MCPError.invalidArgument(
                    "image \(imagePath) is not on card \(params.card_id); its images are: "
                    + card.imagePaths.joined(separator: ", "))
            }
            return try ImageResponseBuilder.encodeEnvelope(
                at: entry.url.appendingPathComponent(imagePath),
                region: params.region,
                maxDimension: params.max_dimension,
                quality: params.quality)
        }

        // Overview path: text block (full markdown) + thumbnails.
        let markdown = (try? String(
            contentsOf: entry.url.appendingPathComponent(rel),
            encoding: .utf8)) ?? "" // adr-0018-ok: palette card read, not manuscript

        // Thumbnails are budgeted TWICE: by count (`maxThumbnails`) and by a
        // running RAW-JPEG byte total. The per-image budget inside
        // `ImageResponseBuilder` never fires at 512px (a 512px JPEG tops out
        // ~262 KB, under its 720 KB floor), so six detailed photos would
        // otherwise combine past the 1 MB transport cap (tripwire 10 / ADR
        // 0004) once base64-inflated. The combined ceiling mirrors that
        // per-image budget and leaves base64 + text headroom under 1 MB.
        var imageBlocks: [AnyJSON] = []
        var omitted: [String] = []
        var runningBytes = 0
        for (index, path) in card.imagePaths.enumerated() {
            if imageBlocks.count >= maxThumbnails {
                omitted.append(path)
                continue
            }
            let url = entry.url.appendingPathComponent(path)
            // A thumbnail render failure skips that image; it never fails the
            // call and (unlike a budget omission) isn't listed — the caller can
            // still reach it by path via the `image` parameter.
            guard let rendered = try? ImageResponseBuilder.render(
                at: url, region: nil, requestedMax: thumbnailMax,
                quality: ImageResponseBuilder.defaultJPEGQuality) else { continue }
            // Always allow the first thumbnail (a lone 512px JPEG can't breach
            // the cap); stop once the next would push the combined raw total
            // over the ceiling, and list it plus every remaining image.
            if !imageBlocks.isEmpty,
               runningBytes + rendered.jpeg.count > combinedThumbnailByteBudget {
                omitted.append(contentsOf: card.imagePaths[index...])
                break
            }
            runningBytes += rendered.jpeg.count
            imageBlocks.append(.object([
                "type": .string("image"),
                "data": .string(rendered.jpeg.base64EncodedString()),
                "mimeType": .string("image/jpeg")
            ]))
        }

        var text = markdown
        if !omitted.isEmpty {
            text += "\n\n[\(omitted.count) more image(s) not thumbnailed: "
                + omitted.joined(separator: ", ")
                + " — fetch each via the image parameter.]"
        }
        // Images are already budgeted above; the card's markdown text is the
        // one unbounded part, and this envelope bypasses the central backstop in
        // MCPToolsCallHandler (it returns a `content` array directly), so guard
        // the text explicitly.
        try MCPResponseBudget.enforce(
            Data(text.utf8),
            hint: "This palette card's notes are too large to return in one MCP "
                + "response. Open the card's markdown directly on disk at \(rel).")
        var blocks: [AnyJSON] = [.object(["type": .string("text"), "text": .string(text)])]
        blocks.append(contentsOf: imageBlocks)
        return try JSONEncoder().encode(AnyJSON.object(["content": .array(blocks)]))
    }
}
