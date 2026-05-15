import Foundation

/// `list_projects` — currently-open projects.
public enum ListProjectsTool {
    public struct Project: Codable, Equatable {
        public let id: String
        public let title: String
        public let type: String   // raw value of ProjectType
        public let path: String
    }
    public static let method = "list_projects"

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let list = registry.list()
        let mapped = list.map { entry in
            Project(
                id: entry.id,
                title: entry.store.manifest.title,
                type: entry.store.manifest.type.rawValue,
                path: entry.url.path)
        }
        return try JSONEncoder().encode(mapped)
    }
}

/// `get_metadata(project_id)` — project-level info.
public enum GetMetadataTool {
    public struct Params: Codable {
        public let project_id: String
    }
    public struct Metadata: Codable, Equatable {
        public let title: String
        public let type: String
        public let author: String?
        public let created: Date
        public let modified: Date
        public let total_word_target: Int?
        public let page_target: Int?
        public let tags_in_use: [String]
        public let research_count: Int
    }
    public static let method = "get_metadata"

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON else {
            throw MCPError.invalidArgument("project_id required")
        }
        let params: Params
        do { params = try JSONDecoder().decode(Params.self, from: data) }
        catch { throw MCPError.invalidArgument("project_id required") }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let m = entry.store.manifest
        let tags = Self.collectTags(in: m.structure)
        let researchCount = Self.countResearch(m.research)
        let meta = Metadata(
            title: m.title,
            type: m.type.rawValue,
            author: m.author,
            created: m.created,
            modified: m.modified,
            total_word_target: m.targets?.totalWords,
            page_target: m.targets?.pageTarget,
            tags_in_use: tags,
            research_count: researchCount)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(meta)
    }

    private static func collectTags(in items: [StructureItem]) -> [String] {
        var seen = Set<String>()
        func walk(_ list: [StructureItem]) {
            for item in list {
                if let tags = item.tags { for t in tags { seen.insert(t) } }
                if let kids = item.children { walk(kids) }
            }
        }
        walk(items)
        return seen.sorted()
    }

    private static func countResearch(_ items: [ResearchItem]) -> Int {
        var count = 0
        func walk(_ list: [ResearchItem]) {
            for item in list {
                if item.type == .asset { count += 1 }
                if let kids = item.children { walk(kids) }
            }
        }
        walk(items)
        return count
    }
}

/// `get_outline(project_id)` — hierarchical manifest.structure with metadata.
public enum GetOutlineTool {
    public struct Params: Codable { public let project_id: String }
    public struct Outline: Codable, Equatable {
        public let nodes: [Node]
    }
    public struct Node: Codable, Equatable {
        public let id: String
        public let title: String
        public let type: String     // "document" or "group"
        public let status: String?
        public let synopsis: String?
        public let word_count: Int?
        public let word_target: Int?
        public let children: [Node]?
    }
    public static let method = "get_outline"

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
        let nodes = Self.toNodes(store.manifest.structure, store: store)
        return try JSONEncoder().encode(Outline(nodes: nodes))
    }

    @MainActor
    private static func toNodes(_ items: [StructureItem], store: ProjectStore) -> [Node] {
        items.map { item in
            let childNodes = item.children.map { toNodes($0, store: store) }
            return Node(
                id: item.id,
                title: item.title,
                type: item.type == .document ? "document" : "group",
                status: item.status,
                synopsis: item.synopsis,
                word_count: item.type == .document ? store.cachedWordCount(for: item.id) : nil,
                word_target: item.wordTarget,
                children: childNodes)
        }
    }
}
