import Foundation
import AppKit

/// `read_document(project_id, document_id, max_dimension?, quality?, region?)` —
/// returns text + metadata for manuscript / text-research docs; returns a
/// downscaled JPEG inside an MCP content envelope for image research items.
/// Image params are ignored for non-image targets.
public enum ReadDocumentTool: MCPTool {
    public struct Region: Codable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let max_dimension: Int?
        public let quality: Int?
        public let region: Region?
    }
    public struct DocumentContent: Codable, Equatable {
        public let id: String
        public let title: String
        public let path: String
        public let mode: String    // "prose" / "screenplay" / "fountain"
        public let text: String
        public let word_count: Int
        public let character_count: Int
        public let tags: [String]?
        public let links: [String]?
    }
    public static let method = "read_document"
    public static let description = """
        Return text + metadata for a manuscript or text-research document. \
        For an image research item (kind=image), returns a downscaled JPEG \
        (default 2048 px longest edge, quality 85). Use `region` to crop \
        into a sub-area at higher effective resolution — useful for \
        hard-to-read handwriting or marginalia. `region` coordinates are \
        normalized 0–1 with top-left origin.
        """
    public static let inputSchemaJSON = #"""
        {"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"max_dimension":{"type":"integer","description":"Longest-edge cap for image research items (256–4096, default 2048). Ignored for text documents."},"quality":{"type":"integer","description":"JPEG quality 10–100 for image research items (default 85). Ignored for text documents."},"region":{"type":"object","description":"Optional crop for image research items, normalized 0–1, top-left origin. e.g. {x:0.3,y:0.5,width:0.2,height:0.1} = 20% × 10% slice 30% from the left, 50% down. Ignored for text documents.","properties":{"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"}},"required":["x","y","width","height"]}},"required":["project_id","document_id"]}
        """#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id and document_id required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let store = entry.store

        // Manuscript document path
        if let item = Self.findItem(id: params.document_id, in: store.manifest.structure),
           item.type == .document,
           let path = item.path {
            return try await emitManuscriptDoc(item: item, path: path, store: store, projectURL: entry.url)
        }

        // Research item path
        if let item = Self.findResearchItem(id: params.document_id, in: store.manifest.research) {
            return try emitResearchItem(item: item, projectURL: entry.url, params: params)
        }

        throw MCPError.invalidArgument("document not found: \(params.document_id)")
    }

    @MainActor
    private static func emitManuscriptDoc(
        item: StructureItem, path: String, store: ProjectStore, projectURL: URL
    ) async throws -> Data {
        // Return the anchored (materialized) form so Claude can target
        // paragraphs by `<!-- ¶id -->` markers. If the doc is open in the
        // editor, materialize from its in-memory state — that's fresher than
        // disk (autosave is debounced at 750ms). Otherwise read the .md
        // verbatim, which already contains the anchors from Bootstrap.
        let text: String
        if let ds = store.documentStore, let doc = ds.document(for: path) {
            text = doc.materialize()
        } else {
            let abs = projectURL.appendingPathComponent(path)
            text = (try? String(contentsOf: abs, encoding: .utf8)) ?? ""
        }
        let mode = Self.modeFor(path: path, projectType: store.manifest.type)
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let chars = text.count
        let content = DocumentContent(
            id: item.id,
            title: item.title,
            path: path,
            mode: mode,
            text: text,
            word_count: words,
            character_count: chars,
            tags: item.tags,
            links: item.links)
        return try JSONEncoder().encode(content)
    }

    private static func emitResearchItem(
        item: ResearchItem, projectURL: URL, params: Params
    ) throws -> Data {
        guard item.type == .asset else {
            throw MCPError.invalidArgument(
                "Research item '\(item.title)' is a group, not a readable document")
        }
        switch item.kind {
        case .document:
            guard let path = item.path else {
                throw MCPError.invalidArgument(
                    "Research item '\(item.title)' has no on-disk path")
            }
            let abs = projectURL.appendingPathComponent(path)
            let text = (try? String(contentsOf: abs, encoding: .utf8)) ?? ""
            let words = text.split { $0.isWhitespace || $0.isNewline }.count
            let chars = text.count
            let content = DocumentContent(
                id: item.id,
                title: item.title,
                path: path,
                mode: "prose",
                text: text,
                word_count: words,
                character_count: chars,
                tags: item.tags,
                links: item.links)
            return try JSONEncoder().encode(content)
        case .image:
            return try emitImageResearchItem(
                item: item, projectURL: projectURL, params: params)
        case .pdf:
            throw MCPError.invalidArgument(
                "Research item '\(item.title)' is a PDF, not a readable text document. Use list_research for metadata.")
        case .audio:
            throw MCPError.invalidArgument(
                "Research item '\(item.title)' is an audio file, not a readable text document. Use list_research for metadata.")
        case .link:
            throw MCPError.invalidArgument(
                "Research item '\(item.title)' is a web link (\(item.url ?? "no url")). Use list_research for the URL.")
        case .none:
            throw MCPError.invalidArgument(
                "Research item '\(item.title)' has no kind set")
        }
    }

    /// Sanity cap on the on-disk source before NSImage opens it. Phone photos
    /// top out around 10–15 MB; 50 MB is well above any reasonable research
    /// input and prevents loading absurd files into memory.
    private static let maxSourceImageBytes = 50 * 1024 * 1024
    /// Default longest-edge cap if the caller doesn't override. 2048 px at
    /// JPEG q=85 produces ~400–700 KB for a full-page handwritten photo —
    /// the sweet spot for readability under MCP's ~720 KB raw-bytes budget.
    static let defaultMaxDimension: Int = 2048
    /// Default JPEG quality. 85 keeps handwriting legible without bloat.
    static let defaultJPEGQuality: Int = 85
    /// Raw-bytes budget for the JPEG payload. Base64 inflates ~33% and the
    /// JSON envelope adds a few hundred bytes; 720 KB leaves headroom under
    /// MCP's 1 MB result cap.
    private static let jpegByteBudget = 720_000
    /// Allowed range for the caller-supplied max_dimension.
    private static let dimensionFloor = 256
    private static let dimensionCeiling = 4096
    /// Step-down sequence for auto-fallback when the encoded JPEG exceeds
    /// jpegByteBudget. Each retry reduces longest-edge by roughly 25%.
    private static let fallbackSteps: [Double] = [1.0, 0.75, 0.5625, 0.4218]

    /// Emit an image research item as an MCP `tools/call` content envelope.
    /// Pipeline:
    ///   1. Open via NSImage.
    ///   2. If `region` provided, crop in source-pixel coords (top-left origin,
    ///      so y=0 is the top of the page) to a sub-rect at native resolution.
    ///   3. Scale the (cropped) image so longest edge ≤ max_dimension. Never
    ///      upscale — if the source/crop is already smaller, we keep its
    ///      native pixels.
    ///   4. JPEG-encode at `quality`. If the encoded size exceeds the byte
    ///      budget, step max_dimension down ~25% and retry up to 3 times.
    ///   5. If a fallback happened, prepend a `text` content block with a
    ///      one-line note so the agent knows the effective resolution.
    ///
    /// Errors out clearly if the image can't be decoded, the region is
    /// invalid, or no fallback step fits.
    private static func emitImageResearchItem(
        item: ResearchItem, projectURL: URL, params: Params
    ) throws -> Data {
        guard let path = item.path else {
            throw MCPError.invalidArgument(
                "Research item '\(item.title)' has no on-disk path")
        }
        let abs = projectURL.appendingPathComponent(path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: abs.path)
        if let size = attrs?[.size] as? NSNumber,
           size.intValue > maxSourceImageBytes {
            let mb = Double(size.intValue) / (1024 * 1024)
            throw MCPError.invalidArgument(String(
                format: "Image '%@' is %.1f MB on disk; refusing to load. Maugham resizes for MCP delivery but won't open a source over 50 MB.",
                item.title, mb))
        }

        let requestedMax = clampDimension(params.max_dimension ?? defaultMaxDimension)
        let quality = clampQuality(params.quality ?? defaultJPEGQuality)
        if let region = params.region { try validateRegion(region) }

        let rendered = try renderImageWithBudget(
            at: abs, region: params.region,
            requestedMax: requestedMax, quality: quality)

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

    private static func clampDimension(_ d: Int) -> Int {
        return min(dimensionCeiling, max(dimensionFloor, d))
    }
    private static func clampQuality(_ q: Int) -> Int {
        return min(100, max(10, q))
    }
    private static func validateRegion(_ r: Region) throws {
        let inUnit = { (v: Double) in v >= 0 && v <= 1 }
        guard inUnit(r.x), inUnit(r.y),
              r.width > 0, r.height > 0,
              r.x + r.width <= 1.0 + 1e-9,
              r.y + r.height <= 1.0 + 1e-9 else {
            throw MCPError.invalidArgument(
                "region must satisfy 0≤x,y; 0<width,height; x+width≤1; y+height≤1 (got x=\(r.x), y=\(r.y), width=\(r.width), height=\(r.height))")
        }
    }

    private struct RenderResult {
        let jpeg: Data
        let effectiveMax: Int
        let fallbackUsed: Bool
    }

    private static func renderImageWithBudget(
        at url: URL, region: Region?, requestedMax: Int, quality: Int
    ) throws -> RenderResult {
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
                return RenderResult(
                    jpeg: jpeg,
                    effectiveMax: maxDim,
                    fallbackUsed: step != 1.0)
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

    private static func findResearchItem(
        id: String, in items: [ResearchItem]
    ) -> ResearchItem? {
        for item in items {
            if item.id == id { return item }
            if let kids = item.children, let n = findResearchItem(id: id, in: kids) { return n }
        }
        return nil
    }

    private static func findItem(id: String, in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let kids = item.children, let f = findItem(id: id, in: kids) { return f }
        }
        return nil
    }

    private static func modeFor(path: String, projectType: ProjectType) -> String {
        if path.hasSuffix(".fountain") { return "fountain" }
        if projectType == .screenplay { return "screenplay" }
        return "prose"
    }
}

/// `search_text(project_id, query, options?)` — reuses ProjectSearchEngine.
public enum SearchTextTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let query: String
        public let case_sensitive: Bool?
        public let whole_word: Bool?
    }
    public struct Match: Codable, Equatable {
        public let document_id: String
        public let document_title: String
        public let line: Int
        public let preview: String
    }
    public static let method = "search_text"
    public static let description =
        "Search manuscript document text for matches. Manuscript-only — does " +
        "not scan [[wiki-link]] tokens, linked-research backrefs, or research " +
        "note bodies. Use find_references for those."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"query":{"type":"string"},"case_sensitive":{"type":"boolean"},"whole_word":{"type":"boolean"}},"required":["project_id","query"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id and query required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let opts = SearchOptions(
            caseSensitive: params.case_sensitive ?? false,
            wholeWord: params.whole_word ?? false)
        let engine = ProjectSearchEngine()
        let results = await engine.search(
            query: params.query, options: opts, in: entry.store)
        let allMatches = results.matches
        let manuscriptOnly = allMatches.filter { m in
            m.documentSource == .manuscript
        }
        let mapped = manuscriptOnly.map { m -> Match in
            // SearchMatch.documentPath is the engine's relative file path, not
            // the real StructureItem.id. Resolve to the actual id so that
            // search_text → read_document works correctly.
            let resolvedId = Self.findStructureItemId(
                path: m.documentPath, in: entry.store.manifest.structure)
                ?? m.documentPath  // fallback: orphan match, emit path for debug
            return Match(
                document_id: resolvedId,
                document_title: m.documentTitle,
                line: m.lineNumber,
                preview: m.linePreview)
        }
        return try JSONEncoder().encode(mapped)
    }

    private static func findStructureItemId(
        path: String, in items: [StructureItem]
    ) -> String? {
        for item in items {
            if item.path == path { return item.id }
            if let kids = item.children,
               let nested = findStructureItemId(path: path, in: kids) {
                return nested
            }
        }
        return nil
    }
}
