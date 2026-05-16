import Foundation

/// `list_all_links(project_id)` — full reference graph. Returns every edge
/// from a manuscript document to (a) a linked research item, (b) a wiki-link
/// target that resolves to another doc or research item, or (c) an unresolved
/// wiki target (text mentions [[X]] but no item with title X exists).
public enum ListAllLinksTool {
    public static let method = "list_all_links"

    public struct Params: Codable {
        public let project_id: String
    }
    public struct Edge: Codable, Equatable {
        public let from_id: String
        public let from_title: String
        public let to_id: String?       // nil when target is wiki_unresolved
        public let to_title: String     // for resolved: target's title; for unresolved: literal [[X]] content
        public let kind: String         // "linked_research" | "wiki" | "wiki_unresolved"
    }

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

        let docs = Self.flatDocs(store.manifest.structure)
        // title → (id, title) lookup for wiki resolution. Manuscript docs and
        // research assets compete on title; if both exist with the same title
        // the document wins (caller should be using unique titles).
        var titleIndex: [String: (id: String, title: String)] = [:]
        for r in Self.flatResearchAssets(store.manifest.research) {
            titleIndex[r.title.lowercased()] = (r.id, r.title)
        }
        for d in docs {
            titleIndex[d.title.lowercased()] = (d.id, d.title)
        }
        let researchById: [String: ResearchItem] =
            Dictionary(uniqueKeysWithValues:
                Self.flatResearchAssets(store.manifest.research).map { ($0.id, $0) })

        var edges: [Edge] = []

        // Linked-research edges
        for doc in docs {
            for rid in store.linkedResearchIds(forDocumentId: doc.id) {
                let title = researchById[rid]?.title ?? rid
                edges.append(Edge(
                    from_id: doc.id,
                    from_title: doc.title,
                    to_id: rid,
                    to_title: title,
                    kind: "linked_research"))
            }
        }

        // Wiki edges
        for doc in docs {
            guard let path = doc.path else { continue }
            let abs = entry.url.appendingPathComponent(path)
            guard let text = try? String(contentsOf: abs, encoding: .utf8) else { continue }
            for token in Self.wikiTokens(in: text) {
                if let hit = titleIndex[token.lowercased()] {
                    edges.append(Edge(
                        from_id: doc.id,
                        from_title: doc.title,
                        to_id: hit.id,
                        to_title: hit.title,
                        kind: "wiki"))
                } else {
                    edges.append(Edge(
                        from_id: doc.id,
                        from_title: doc.title,
                        to_id: nil,
                        to_title: token,
                        kind: "wiki_unresolved"))
                }
            }
        }
        return try JSONEncoder().encode(edges)
    }

    private static func flatDocs(_ items: [StructureItem]) -> [StructureItem] {
        var out: [StructureItem] = []
        for item in items {
            if item.type == .document { out.append(item) }
            if let kids = item.children { out.append(contentsOf: flatDocs(kids)) }
        }
        return out
    }

    private static func flatResearchAssets(_ items: [ResearchItem]) -> [ResearchItem] {
        var out: [ResearchItem] = []
        for item in items {
            if item.type == .asset { out.append(item) }
            if let kids = item.children { out.append(contentsOf: flatResearchAssets(kids)) }
        }
        return out
    }

    /// Extract `[[X]]` tokens from text. Returns the X strings (no brackets,
    /// trimmed). Duplicates removed but order preserved by first appearance.
    private static func wikiTokens(in text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        guard let regex = try? NSRegularExpression(
            pattern: #"\[\[([^\]]+)\]\]"#) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let body = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty, seen.insert(body).inserted {
                out.append(body)
            }
        }
        return out
    }
}
