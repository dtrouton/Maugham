import Foundation
import MaughamCore

/// `list_all_links(project_id)` — full reference graph. Returns every edge
/// from a manuscript document to (a) a linked research item, (b) a wiki-link
/// target that resolves to another doc or research item, or (c) an unresolved
/// wiki target (text mentions [[X]] but no item with title X exists).
public enum ListAllLinksTool: MCPTool {
    public static let method = "list_all_links"
    public static let description =
        "Return the full reference graph as edges: every manuscript document's " +
        "linked-research and [[wiki-link]] targets, plus collection pieces' " +
        "own (folder-scoped) research. Each edge has from_id/from_title, " +
        "to_id (null for unresolved wiki targets) / to_title, and kind " +
        "('linked_research' / 'piece_research' / 'wiki' / 'wiki_unresolved')."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    public struct Params: Codable {
        public let project_id: String
    }
    public struct Edge: Codable, Equatable {
        public let from_id: String
        public let from_title: String
        public let to_id: String?       // nil when target is wiki_unresolved
        public let to_title: String     // for resolved: target's title; for unresolved: literal [[X]] content
        public let kind: String         // "linked_research" | "piece_research" | "wiki" | "wiki_unresolved"
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let store = entry.store

        let docs = TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document })
        // title → (id, title) lookup for wiki resolution. Manuscript docs and
        // research assets compete on title; if both exist with the same title
        // the document wins (caller should be using unique titles).
        var titleIndex: [String: (id: String, title: String)] = [:]
        // Index every research item (groups + assets) so linked groups
        // resolve their title instead of falling back to the raw id.
        let allResearch = TreeWalk.collect(in: store.manifest.research, where: { _ in true })
        for r in allResearch {
            titleIndex[r.title.lowercased()] = (r.id, r.title)
        }
        for d in docs {
            titleIndex[d.title.lowercased()] = (d.id, d.title)
        }
        let researchById: [String: ResearchItem] =
            Dictionary(uniqueKeysWithValues: allResearch.map { ($0.id, $0) })

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

        // Containment edges — a collection loose piece owns research by path
        // prefix (the strongest association; spec 2026-07-07 ends MCP's
        // blindness to it). Uses the same derivation as the panes.
        for piece in store.manifest.structure where piece.pieceKind == .loose {
            for r in store.derivedResearchItems(forDocumentId: piece.id) {
                edges.append(Edge(
                    from_id: piece.id,
                    from_title: piece.title,
                    to_id: r.id,
                    to_title: r.title,
                    kind: "piece_research"))
            }
        }

        // Wiki edges — ADR 0018: an OPEN doc's live `Document` is freshest (the
        // op log lags an actively-edited doc by the burst window, 30s/90s);
        // closed docs derive from the op log. Never read the `.md` directly.
        for doc in docs {
            let text: String
            if let ds = store.documentStore, let path = doc.path,
               let live = ds.document(for: path) {
                text = live.materialize()
            } else {
                text = store.derivedCache.materialize(forDocId: doc.id, in: entry.url)
            }
            guard !text.isEmpty else { continue }
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
