import Foundation
import MaughamCore

/// `move_research_item(project_id, research_ids, target | target_group_id |
/// target_document_id)` — move research items (including whole groups)
/// between shared research, a research group, and a collection piece's
/// research folder. Exactly one target must be given; unknown ids fail
/// loudly. Cross-scope moves never touch explicit links — association is
/// containment-based: a manual link goes dormant while contained and
/// resurfaces on move-out; a containment-only association severs on move-out
/// (see the Phase 4 comment in ProjectStore+ResearchMove.swift). Wraps
/// `ProjectStore.moveResearchItems`.
public enum MoveResearchItemTool: MCPTool {
    public static let method = "move_research_item"
    public static let description =
        "Move research items between shared research, a research group, and " +
        "a collection piece's research folder. research_ids accepts a batch. " +
        "Give exactly one of: target=\"shared\", target_group_id, or " +
        "target_document_id (a loose piece). Whole groups move with their contents. " +
        "Where a note is, is whose it is: into a group a chapter holds makes it that " +
        "chapter's; to shared research or a whole-book group makes it whole-book, its own " +
        "links to chapters removed (`left` names them). Each moved item's `home` says which."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"research_ids":{"type":"array","items":{"type":"string"}},"target":{"type":"string","enum":["shared"]},"target_group_id":{"type":"string"},"target_document_id":{"type":"string"}},"required":["project_id","research_ids"]}"#

    public struct Params: Codable {
        public let project_id: String
        public let research_ids: [String]
        public let target: String?
        public let target_group_id: String?
        public let target_document_id: String?
    }
    public struct MovedItem: Codable, Equatable {
        public let id: String
        public let path: String?
        /// Whose it is now, in words: "whole-book", or "Chapter One's"
        /// (closing round A) — so a move out of a chapter is never unknowing.
        public let home: String
        /// The chapters a move to the book took it from (its links removed),
        /// by title; absent when none.
        public let left: [String]?
    }
    public struct Result: Codable, Equatable {
        public let moved: [MovedItem]
    }

    /// "whole-book", or "“Chapter One”’s" / "“One” and “Two”’s".
    static func home(of id: String, in homes: ResearchHomes) -> String {
        let pieces = homes.homes(of: id).map { "\u{201C}\(homes.pieceTitles[$0] ?? $0)\u{201D}" }
        guard !pieces.isEmpty else { return "whole-book" }
        let named = pieces.count == 1 ? pieces[0]
            : pieces.dropLast().joined(separator: ", ") + " and " + pieces.last!
        return named + "\u{2019}s"
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let store = entry.store

        var targets: [ResearchMoveTarget] = []
        if let t = params.target {
            guard t == "shared" else {
                throw MCPError.invalidArgument("target must be \"shared\"")
            }
            targets.append(.sharedRoot)
        }
        if let gid = params.target_group_id { targets.append(.group(gid)) }
        if let did = params.target_document_id { targets.append(.piece(did)) }
        guard targets.count == 1 else {
            throw MCPError.invalidArgument(
                "Give exactly one of target=\"shared\", target_group_id, target_document_id (got \(targets.count))")
        }
        guard !params.research_ids.isEmpty else {
            throw MCPError.invalidArgument("research_ids must not be empty")
        }

        // **Where a note is, is whose it is** (closing round A2): to the book,
        // its own links go — the tree's rule, said in the answer.
        let before = ResearchHomes.derive(structure: store.manifest.structure,
                                          research: store.manifest.research,
                                          projectType: store.manifest.type)
        let unlinks = HeldResearchAct.unlinks(params.research_ids, to: targets[0], homes: before)
        try await store.moveResearchItems(ids: params.research_ids, to: targets[0])
        for (id, pieces) in unlinks.sorted(by: { $0.key < $1.key }) {
            try await store.relinkResearch(ids: [id], from: pieces, to: nil)
        }

        let homes = ResearchHomes.derive(structure: store.manifest.structure,
                                         research: store.manifest.research,
                                         projectType: store.manifest.type)
        let moved = params.research_ids.map { id in
            MovedItem(id: id,
                      path: TreeWalk.find(id: id, in: store.manifest.research)?.path,
                      home: Self.home(of: id, in: homes),
                      left: unlinks[id].map { $0.map { before.pieceTitles[$0] ?? $0 } })
        }
        return try JSONEncoder().encode(Result(moved: moved))
    }
}
