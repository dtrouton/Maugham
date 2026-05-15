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
        guard let item = Self.findItem(id: params.document_id, in: store.manifest.structure),
              item.type == .document,
              let path = item.path else {
            throw MCPError.invalidArgument("document not found: \(params.document_id)")
        }

        // Live in-memory text if this doc is the one currently open in the editor.
        let text: String
        if let ds = store.documentStore, ds.openDocumentPath == path {
            text = ds.currentDocumentText
        } else {
            let abs = entry.url.appendingPathComponent(path)
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
