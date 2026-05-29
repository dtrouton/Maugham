import Foundation
import MaughamCore

/// `list_projects` — currently-open projects.
public enum ListProjectsTool: MCPTool {
    public struct Project: Codable, Equatable {
        public let id: String
        public let title: String
        public let type: String   // raw value of ProjectType
        public let path: String
    }
    public static let method = "list_projects"
    public static let description = "List currently-open Maugham projects."
    public static let inputSchemaJSON = #"{"type":"object","properties":{}}"#

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
public enum GetMetadataTool: MCPTool {
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
    public static let description =
        "Return project-level metadata: title, type, author, dates, targets, tags, research count."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

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
public enum GetOutlineTool: MCPTool {
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
        public let modified: Date?  // filesystem mtime for document nodes; max descendant mtime for groups
        public let children: [Node]?

        enum CodingKeys: String, CodingKey {
            case id, title, type, status, synopsis, word_count, word_target, modified, children
        }

        public init(id: String, title: String, type: String,
                    status: String?, synopsis: String?,
                    word_count: Int?, word_target: Int?,
                    modified: Date?, children: [Node]?) {
            self.id = id
            self.title = title
            self.type = type
            self.status = status
            self.synopsis = synopsis
            self.word_count = word_count
            self.word_target = word_target
            self.modified = modified
            self.children = children
        }

        // Default-synthesized decoder is fine (Optionals decode as nil when absent).

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(type, forKey: .type)
            // Optionals encoded explicitly so nil emits as JSON null rather
            // than omitting the key (uniform schema across nodes).
            try c.encode(status, forKey: .status)
            try c.encode(synopsis, forKey: .synopsis)
            try c.encode(word_count, forKey: .word_count)
            try c.encode(word_target, forKey: .word_target)
            try c.encode(modified, forKey: .modified)
            // children: only emit when present; a missing key naturally signals
            // "leaf document, no children".
            try c.encodeIfPresent(children, forKey: .children)
        }
    }
    public static let method = "get_outline"
    public static let description =
        "Return the hierarchical manuscript structure with status, synopsis, and word counts."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Outline(nodes: nodes))
    }

    @MainActor
    private static func toNodes(_ items: [StructureItem], store: ProjectStore) -> [Node] {
        items.map { item in
            let isDoc = (item.type == .document)
            let childNodes = item.children.map { toNodes($0, store: store) }
            let modified: Date? = isDoc
                ? Self.modifiedDate(for: item, store: store)
                : Self.maxDescendantModified(in: item.children ?? [], store: store)
            return Node(
                id: item.id,
                title: item.title,
                type: isDoc ? "document" : "group",
                status: item.status,
                synopsis: item.synopsis,
                word_count: isDoc ? store.cachedWordCount(for: item.id) : nil,
                word_target: item.wordTarget,
                modified: modified,
                children: childNodes)
        }
    }

    private static func modifiedDate(for item: StructureItem, store: ProjectStore) -> Date? {
        guard let path = item.path else { return nil }
        let url = store.url.appendingPathComponent(path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    /// Max document mtime among all descendants. Returns nil if there are no
    /// document descendants (empty group).
    private static func maxDescendantModified(
        in items: [StructureItem], store: ProjectStore
    ) -> Date? {
        var best: Date? = nil
        for item in items {
            if item.type == .document, let d = modifiedDate(for: item, store: store) {
                if let b = best { best = max(b, d) } else { best = d }
            }
            if let kids = item.children,
               let nested = maxDescendantModified(in: kids, store: store) {
                best = best.map { max($0, nested) } ?? nested
            }
        }
        return best
    }
}
