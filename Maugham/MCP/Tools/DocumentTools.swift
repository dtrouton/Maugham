import Foundation
import MaughamCore
import AppKit

/// `read_document(project_id, document_id, max_dimension?, quality?, region?)` —
/// returns text + metadata for manuscript / text-research docs; returns a
/// downscaled JPEG inside an MCP content envelope for image research items.
/// Image params are ignored for non-image targets.
public enum ReadDocumentTool: MCPTool {
    /// Normalized 0–1 crop region with top-left origin. Aliases the shared
    /// `ImageResponseBuilder.Region` so external Codable shape (the MCP
    /// surface) stays identical while implementation lives in one place.
    public typealias Region = ImageResponseBuilder.Region
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
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let store = entry.store

        // Manuscript document path
        if let item = TreeWalk.find(id: params.document_id, in: store.manifest.structure),
           item.type == .document,
           let path = item.path {
            return try await emitManuscriptDoc(item: item, path: path, store: store, projectURL: entry.url)
        }

        // Research item path
        if let item = TreeWalk.find(id: params.document_id, in: store.manifest.research) {
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
        // disk (autosave is debounced at 750ms). Otherwise derive from the
        // op log (ADR 0018): the .md can lag the op log, causing
        // read_document and add_comment to disagree on paragraph ids.
        let text: String
        if let ds = store.documentStore, let doc = ds.document(for: path) {
            text = doc.materialize()
        } else {
            text = DerivedManuscript.materialize(forDocId: item.id, in: projectURL)
        }
        let mode = Self.modeFor(path: path, projectType: store.manifest.type)
        // `text` is the ANCHORED body (so Claude can target `<!-- ¶id -->`
        // paragraphs), but word_count must count the DISPLAY form — anchor
        // comment tokens (`<!--`, `¶id`, `-->`) are not words and would inflate
        // the count by ~3 per paragraph.
        let displayForm = MarkdownDisplayFilter.stripAnchors(text)
        let words = displayForm.split { $0.isWhitespace || $0.isNewline }.count
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
        return try MCPResponseBudget.enforce(
            try JSONEncoder().encode(content),
            hint: "This document is too large to return in one MCP response. "
                + "Use search_text to locate the passage you need, or split the "
                + "manuscript into per-chapter documents in the binder and read one.")
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
            let text = (try? String(contentsOf: abs, encoding: .utf8)) ?? "" // adr-0018-ok: research-item document read, not manuscript
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
            return try MCPResponseBudget.enforce(
                try JSONEncoder().encode(content),
                hint: "This research document is too large to return in one MCP "
                    + "response. Open the file directly on disk at \(path).")
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

    /// Emit an image research item as an MCP `tools/call` content envelope.
    /// Delegates the JPEG-transcoding pipeline (decode → optional region
    /// crop → scale → JPEG → budget-fallback retry → envelope) to the
    /// shared `ImageResponseBuilder`. See that type for the algorithm.
    private static func emitImageResearchItem(
        item: ResearchItem, projectURL: URL, params: Params
    ) throws -> Data {
        guard let path = item.path else {
            throw MCPError.invalidArgument(
                "Research item '\(item.title)' has no on-disk path")
        }
        let abs = projectURL.appendingPathComponent(path)
        // Pre-check the on-disk size so the error names the research item
        // rather than the bare filename. Builder re-checks defensively.
        let attrs = try? FileManager.default.attributesOfItem(atPath: abs.path)
        if let size = attrs?[.size] as? NSNumber,
           size.intValue > ImageResponseBuilder.maxSourceImageBytes {
            let mb = Double(size.intValue) / (1024 * 1024)
            throw MCPError.invalidArgument(String(
                format: "Image '%@' is %.1f MB on disk; refusing to load. Maugham resizes for MCP delivery but won't open a source over 50 MB.",
                item.title, mb))
        }
        return try ImageResponseBuilder.encodeEnvelope(
            at: abs,
            region: params.region,
            maxDimension: params.max_dimension,
            quality: params.quality)
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
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
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
            let resolvedId = TreeWalk.first(
                in: entry.store.manifest.structure) { $0.path == m.documentPath }?.id
                ?? m.documentPath  // fallback: orphan match, emit path for debug
            return Match(
                document_id: resolvedId,
                document_title: m.documentTitle,
                line: m.lineNumber,
                preview: m.linePreview)
        }
        return try JSONEncoder().encode(mapped)
    }
}
