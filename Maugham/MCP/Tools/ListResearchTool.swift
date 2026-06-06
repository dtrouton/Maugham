import Foundation
import MaughamCore

/// `list_research(project_id)` — hierarchical research tree. Mirrors the
/// shape of get_outline but for `manifest.research`. Lets Claude discover
/// research items by enumeration instead of guessing internal ids.
public enum ListResearchTool: MCPTool {
    public static let method = "list_research"
    public static let description =
        "List the project's research tree hierarchically. Each item has id, " +
        "title, type (group/asset), kind, path. Use this to discover research " +
        "items before calling find_references or read_document."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    public struct Params: Codable {
        public let project_id: String
    }
    public struct ResearchTree: Codable, Equatable {
        public let items: [Item]
    }
    public struct Item: Codable, Equatable {
        public let id: String
        public let title: String
        public let type: String    // "group" or "asset"
        public let kind: String?   // "document"/"image"/"pdf"/"audio"/"link"; nil for groups
        public let path: String?
        public let url: String?
        public let children: [Item]?
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let items = Self.toItems(entry.store.manifest.research)
        return try JSONEncoder().encode(ResearchTree(items: items))
    }

    private static func toItems(_ list: [ResearchItem]) -> [Item] {
        list.map { r in
            Item(
                id: r.id,
                title: r.title,
                type: r.type == .group ? "group" : "asset",
                kind: r.kind.map(Self.kindString),
                path: r.path,
                url: r.url,
                children: r.children.map { toItems($0) })
        }
    }

    private static func kindString(_ kind: ResearchItem.AssetKind) -> String {
        switch kind {
        case .document: return "document"
        case .image:    return "image"
        case .pdf:      return "pdf"
        case .audio:    return "audio"
        case .link:     return "link"
        }
    }
}
