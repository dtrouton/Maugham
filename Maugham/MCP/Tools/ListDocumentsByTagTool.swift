import Foundation
import MaughamCore

/// `list_documents_by_tag(project_id, tag)` — flat list of manuscript documents
/// whose tags include `tag` (case-insensitive). Returns id/title/path/tags.
public enum ListDocumentsByTagTool: MCPTool {
    public static let method = "list_documents_by_tag"
    public static let description =
        "List manuscript documents whose tags include the given tag " +
        "(case-insensitive). Returns id, title, path, tags."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"tag":{"type":"string"}},"required":["project_id","tag"]}"#

    public struct Params: Codable {
        public let project_id: String
        public let tag: String
    }
    public struct Doc: Codable, Equatable {
        public let id: String
        public let title: String
        public let path: String?
        public let tags: [String]?
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id and tag required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let target = params.tag.lowercased()
        let docs = Self.flatDocs(entry.store.manifest.structure).compactMap { item -> Doc? in
            guard let tags = item.tags,
                  tags.contains(where: { $0.lowercased() == target }) else { return nil }
            return Doc(id: item.id, title: item.title, path: item.path, tags: item.tags)
        }
        return try JSONEncoder().encode(docs)
    }

    private static func flatDocs(_ items: [StructureItem]) -> [StructureItem] {
        var out: [StructureItem] = []
        for item in items {
            if item.type == .document { out.append(item) }
            if let kids = item.children { out.append(contentsOf: flatDocs(kids)) }
        }
        return out
    }
}
