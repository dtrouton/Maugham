import Foundation
import MaughamCore

/// `move_research_item(project_id, research_ids, target | target_group_id |
/// target_document_id)` — move research items (including whole groups)
/// between shared research, a research group, and a collection piece's
/// research folder. Exactly one target must be given; unknown ids fail
/// loudly. Cross-scope moves clean up explicit links (into a piece: the
/// now-redundant link is dropped; out of a piece: an explicit link is added
/// so the association survives). Wraps `ProjectStore.moveResearchItems`.
public enum MoveResearchItemTool: MCPTool {
    public static let method = "move_research_item"
    public static let description =
        "Move research items between shared research, a research group, and " +
        "a collection piece's research folder. research_ids accepts a batch. " +
        "Give exactly one of: target=\"shared\", target_group_id, or " +
        "target_document_id (a loose piece). Whole groups move with their contents."
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
    }
    public struct Result: Codable, Equatable {
        public let moved: [MovedItem]
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

        try await store.moveResearchItems(ids: params.research_ids, to: targets[0])

        let moved = params.research_ids.map { id in
            MovedItem(id: id,
                      path: TreeWalk.find(id: id, in: store.manifest.research)?.path)
        }
        return try JSONEncoder().encode(Result(moved: moved))
    }
}
