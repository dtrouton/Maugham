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
        "Move research items between the whole book's research (target=\"shared\": " +
        "the binder's Research section), a research group, and a Collection piece's " +
        "research folder (target_document_id; outside a Collection, give a note to a piece with " +
        "link_research instead). research_ids accepts a batch. " +
        "Give exactly one of: target=\"shared\", target_group_id, or " +
        "target_document_id (a loose piece). Whole groups move with their contents. " +
        "Where a note is, is whose it is: into a group a piece holds makes it that " +
        "piece's; to the whole book's research or a whole-book group makes it whole-book, its own " +
        "links to pieces removed. `left` names every piece an item left, " +
        "`home` whose it is now."
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
        /// The chapters the move took it from — by its own link or through
        /// the group it stood in — by title; absent when none.
        public let left: [String]?
    }
    public struct Result: Codable, Equatable {
        public let moved: [MovedItem]
        /// Titles of the moved notes whose picture links could not be
        /// rewritten to their new folder (#148 D2); absent when none.
        public var asset_refs_left_in: [String]? = nil
        /// The sentence the writer is told about them; absent when none.
        public var notice: String? = nil
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

        // **The tree's one oracle** (closing round A3): the move's plan says
        // what it does — to the book the rows' own links go — and what it
        // takes from each chapter; the move and its link edits are one save,
        // and the answer names every chapter each item left (`left`), even
        // one in read-through (the assistant's writes ask it nothing, ADR 0039).
        let before = ResearchHomes.derive(structure: store.manifest.structure,
                                          research: store.manifest.research,
                                          projectType: store.manifest.type)
        let plan = ResearchMovePlan.make(ids: params.research_ids, target: targets[0], linkTo: nil,
                                         explicitUnlinks: nil,
                                         // It lifts nothing: the plan is the move made (A4).
                                         liftsHeld: false, homes: before,
                                         structure: store.manifest.structure,
                                         research: store.manifest.research,
                                         projectType: store.manifest.type)
        // The move stands; what it left is said in the result (RULING-52).
        let outcome = try await store.moveResearchItems(ids: params.research_ids, to: targets[0],
                                                        relinking: plan.linkEdit)

        let homes = ResearchHomes.derive(structure: store.manifest.structure,
                                         research: store.manifest.research,
                                         projectType: store.manifest.type)
        let moved = params.research_ids.map { id in
            MovedItem(id: id,
                      path: TreeWalk.find(id: id, in: store.manifest.research)?.path,
                      home: Self.home(of: id, in: homes),
                      left: plan.losses[id].map { $0.map { before.pieceTitles[$0] ?? $0 } })
        }
        return try JSONEncoder().encode(Result(
            moved: moved,
            asset_refs_left_in: outcome.assetRefsLeftIn.isEmpty ? nil : outcome.assetRefsLeftIn,
            notice: outcome.sentence))
    }
}
