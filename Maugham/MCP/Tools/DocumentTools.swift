import Foundation

/// `read_document(project_id, document_id)` — current text + metadata.
public enum ReadDocumentTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
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
            return try emitResearchItem(item: item, projectURL: entry.url)
        }

        throw MCPError.invalidArgument("document not found: \(params.document_id)")
    }

    @MainActor
    private static func emitManuscriptDoc(
        item: StructureItem, path: String, store: ProjectStore, projectURL: URL
    ) async throws -> Data {
        // Live in-memory text if this doc is the one currently open in the editor.
        let text: String
        if let ds = store.documentStore, ds.openDocumentPath == path {
            text = ds.currentDocumentText
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
        item: ResearchItem, projectURL: URL
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
            throw MCPError.invalidArgument(
                "Research item '\(item.title)' is an image, not a readable text document. Use list_research for metadata.")
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
public enum SearchTextTool {
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
