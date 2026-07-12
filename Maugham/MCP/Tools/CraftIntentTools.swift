import Foundation

/// read_craft_intent — the writer's optional statement of what a piece needs
/// sensorially. ABSENCE IS VALID: returns {exists: false}, never an error.
public enum ReadCraftIntentTool: MCPTool {
    public static let method = "read_craft_intent"
    public static let description =
        "Read the writer's craft-intent doc — an optional freeform statement of what "
        + "the story (or a collection piece) needs, e.g. sensory groundedness goals. "
        + "Returns exists:false when the writer has not declared one; that is a valid, "
        + "deliberate state — do not invent a standard on their behalf. Pass item_id "
        + "for a collection loose piece; omit for project scope."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"item_id":{"type":"string"}},"required":["project_id"]}"#

    public struct Params: Codable {
        public let project_id: String
        public let item_id: String?
    }
    public struct Result: Codable, Equatable {
        public let exists: Bool
        public let markdown: String?
        public let path: String?
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        guard let item = entry.store.craftIntentItem(forPieceId: params.item_id),
              let rel = item.path else {
            return try JSONEncoder().encode(Result(exists: false, markdown: nil, path: nil))
        }
        let url = entry.url.appendingPathComponent(rel)
        let markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? "" // adr-0018-ok: craft-intent note read, not manuscript
        return try MCPResponseBudget.enforce(
            try JSONEncoder().encode(Result(exists: true, markdown: markdown, path: rel)),
            hint: "The craft-intent doc is too large to return in one MCP response. "
                + "Open it directly on disk at \(rel).")
    }
}
