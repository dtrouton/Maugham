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
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
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
        for item in TreeWalk.collect(in: items, where: { _ in true }) {
            if let tags = item.tags { for t in tags { seen.insert(t) } }
        }
        return seen.sorted()
    }

    private static func countResearch(_ items: [ResearchItem]) -> Int {
        TreeWalk.collect(in: items, where: { $0.type == .asset }).count
    }
}

/// `get_outline(project_id)` — hierarchical manifest.structure with metadata.
public enum GetOutlineTool: MCPTool {
    public struct Params: Codable { public let project_id: String }
    public struct Outline: Codable, Equatable {
        public let nodes: [Node]
        /// The project's effective review passes in LADDER ORDER (M3 P3).
        /// Without it a reader has a `pass_states` map and no way to order it:
        /// a JSON object's key order is `Dictionary` iteration order, which is
        /// not the writer's ladder and is not even stable between two reads.
        /// Always the projection `ProjectManifest.effectiveReviewPasses` —
        /// never the raw stored array, which is empty until the writer
        /// customizes it and would report "this project has no passes" for
        /// every project that has simply never been customized.
        public let review_passes: [PassInfo]
    }
    /// The wire shape of one review pass. A local type rather than
    /// `MaughamCore.ReviewPass` on purpose: this is a published wire contract
    /// and must not move because a model type grew a field.
    public struct PassInfo: Codable, Equatable {
        public let id: String
        public let name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }
    public struct Node: Codable, Equatable {
        public let id: String
        public let title: String
        public let type: String     // "document" or "group"
        /// **The RAW legacy `StructureItem.status` string, kept for
        /// compatibility only.** The disagreement window M3 P1's whole-branch
        /// review opened (seam 1) is CLOSED as of P3: `review_status` beside
        /// it is the projection every in-app surface draws, and that is the
        /// truth. Nothing writes this field — not the app, not any MCP tool —
        /// so what it carries is a project's pre-M3 string (or null), i.e.
        /// history rather than state. It stays on the wire because removing a
        /// shipped field is a breaking change this milestone does not make;
        /// read `review_status`.
        public let status: String?
        /// The one derived review status (M3 P3) — `ReviewStatus.derived` over
        /// this piece's `pass_states`, the project's `review_passes` and the
        /// legacy `status`. `"draft"` / `"revising"` / `"final"`. Null on a
        /// GROUP node: a group is not a piece and has nothing to be ruled on.
        public let review_status: String?
        /// This piece's per-pass states, keyed by `ReviewPass.id`. An absent
        /// KEY and an absent map both mean untouched, so a piece the writer
        /// has never ruled on reports null. Null on a group node too.
        ///
        /// **A key that is NOT in `review_passes` is residue of a deleted
        /// pass, and that is by design**: deleting a pass removes it from the
        /// ladder and never rewrites every piece's state map, so the writer
        /// who restores it finds their rulings intact. `ReviewStatus.derived`
        /// walks the LADDER, so residue is inert — it is reported because the
        /// map is reported whole, not because anything reads it.
        public let pass_states: [String: PassState]?
        public let synopsis: String?
        public let word_count: Int?
        public let word_target: Int?
        public let modified: Date?  // filesystem mtime for document nodes; max descendant mtime for groups
        public let children: [Node]?

        enum CodingKeys: String, CodingKey {
            case id, title, type, status, review_status, pass_states
            case synopsis, word_count, word_target, modified, children
        }

        public init(id: String, title: String, type: String,
                    status: String?,
                    review_status: String?, pass_states: [String: PassState]?,
                    synopsis: String?,
                    word_count: Int?, word_target: Int?,
                    modified: Date?, children: [Node]?) {
            self.id = id
            self.title = title
            self.type = type
            self.status = status
            self.review_status = review_status
            self.pass_states = pass_states
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
            try c.encode(review_status, forKey: .review_status)
            try c.encode(pass_states, forKey: .pass_states)
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
        "Return the hierarchical manuscript structure with review status, " +
        "synopsis, and word counts. `review_status` (draft/revising/final) is " +
        "the derived truth for a piece; `pass_states` says where it stands on " +
        "each named review pass, keyed by the ids in the top-level " +
        "`review_passes` ladder (an absent key means untouched; a key NOT in " +
        "the ladder is residue of a pass the writer deleted — states outlive " +
        "their pass by design, and nothing derives from them). The legacy " +
        "`status` string is kept for compatibility only — nothing writes it."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let store = entry.store
        // The projection, never `manifest.reviewPasses` raw — an absent or
        // emptied stored list IS the presets, and is never written back.
        let passes = store.manifest.effectiveReviewPasses
        let nodes = Self.toNodes(store.manifest.structure, store: store, passes: passes)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Outline(
            nodes: nodes,
            review_passes: passes.map { PassInfo(id: $0.id, name: $0.name) }))
    }

    @MainActor
    private static func toNodes(
        _ items: [StructureItem], store: ProjectStore, passes: [ReviewPass]
    ) -> [Node] {
        items.map { item in
            let isDoc = (item.type == .document)
            let childNodes = item.children.map { toNodes($0, store: store, passes: passes) }
            let modified: Date? = isDoc
                ? Self.modifiedDate(for: item, store: store)
                : Self.maxDescendantModified(in: item.children ?? [], store: store)
            return Node(
                id: item.id,
                title: item.title,
                type: isDoc ? "document" : "group",
                status: item.status,
                // A group is not a piece: it is ruled on nowhere in the app,
                // so it reports null rather than a status derived from an
                // empty state map (which would read "draft" and be a claim).
                review_status: isDoc
                    ? ReviewStatus.derived(
                        passStates: item.passStates,
                        passes: passes,
                        legacyStatus: item.status).rawValue
                    : nil,
                pass_states: isDoc ? item.passStates : nil,
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
        TreeWalk.collect(in: items, where: { $0.type == .document })
            .compactMap { modifiedDate(for: $0, store: store) }
            .max()
    }
}
