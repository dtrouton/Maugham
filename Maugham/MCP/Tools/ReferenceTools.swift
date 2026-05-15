import Foundation

/// `list_scenes(project_id)` — screenplay-only. Parses on demand.
public enum ListScenesTool {
    public struct Params: Codable { public let project_id: String }
    public struct Scene: Codable, Equatable {
        public let id: String
        public let heading: String
        public let page_start: Double
        public let page_length: Double
        public let document_id: String
    }
    public static let method = "list_scenes"

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let store = entry.store
        guard store.manifest.type == .screenplay else {
            return try JSONEncoder().encode([Scene]())
        }
        // Find the screenplay document — typically the first .document item.
        guard let item = Self.firstDocument(in: store.manifest.structure),
              let path = item.path else {
            return try JSONEncoder().encode([Scene]())
        }
        // Read text — live if open, else disk.
        let text: String
        if let ds = store.documentStore, ds.openDocumentPath == path {
            text = ds.currentDocumentText
        } else {
            let abs = entry.url.appendingPathComponent(path)
            text = (try? String(contentsOf: abs, encoding: .utf8)) ?? ""
        }
        let script = FountainTokenizer().parse(text)
        let headings = script.lines.filter { $0.element == .sceneHeading }
        let starts = headings.map { Double(script.pageNumber(at: $0)) }
        let totalPages = script.estimatedPageCount

        var scenes: [Scene] = []
        for (idx, line) in headings.enumerated() {
            let start = starts[idx]
            let end = (idx + 1 < starts.count) ? starts[idx + 1] : totalPages
            let length = max(0, end - start)
            scenes.append(Scene(
                id: "scene-\(line.range.location)",
                heading: line.content,
                page_start: start,
                page_length: length,
                document_id: item.id))
        }
        return try JSONEncoder().encode(scenes)
    }

    private static func firstDocument(in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.type == .document { return item }
            if let kids = item.children, let n = firstDocument(in: kids) { return n }
        }
        return nil
    }
}
