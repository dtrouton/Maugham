import Foundation

public enum GetPublishConfigTool: MCPTool {
    public static let method = "get_publish_config"
    public static let description =
    "Return the project's current PublishConfig as JSON. Response includes a `source` discriminator: \"persisted\" means the config was read from .maugham/publish/config.json; \"defaults\" means the file doesn't exist yet and the returned shape is the bundled default — a preview of what initialize_publish_template will write. Tools that need to know whether a project is configured should branch on `source`. Per-piece `sections.<docId>.include` (default true) controls whether that piece ships in the compiled edition: set it false to omit a piece from compile/republish output and from the translation coverage gate, letting a subset (e.g. one volume) ship as a first-class Publication."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}
    """
    struct Params: Codable {
        let projectID: String
        enum CodingKeys: String, CodingKey { case projectID = "project_id" }
    }
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.projectID, in: registry)
        let cfgStore = PublishConfigStore(projectURL: entry.url)
        let persisted = try await cfgStore.load()
        let cfg = persisted ?? PublishConfig()
        let source = persisted == nil ? "defaults" : "persisted"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cfgData = try encoder.encode(cfg)
        let cfgObj = try JSONSerialization.jsonObject(with: cfgData)
        return try JSONSerialization.data(
            withJSONObject: [
                "config": cfgObj,
                "source": source
            ],
            options: [.sortedKeys])
    }
}

public enum SetPublishConfigTool: MCPTool {
    public static let method = "set_publish_config"
    public static let description =
    "Apply a JSON Merge Patch (RFC 7396) to the project's PublishConfig. null values delete keys, objects merge recursively, all else replaces. Validates the merged result; if errors exist, returns them and does NOT persist. To ship a subset edition, patch `sections.<docId>.include` to false for each piece to omit — excluded pieces are dropped from compile/republish output and from the translation coverage gate (default true, so an absent flag keeps a piece included)."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{
       "project_id":{"type":"string"},
       "patch":{"type":"object"}
     },"required":["project_id","patch"]}
    """
    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else { throw MCPError.invalidArgument("missing params") }
        let outer = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        guard let projectID = outer?["project_id"] as? String else {
            throw MCPError.invalidArgument("project_id required")
        }
        guard let patchObj = outer?["patch"] else {
            throw MCPError.invalidArgument("patch required")
        }
        let entry = try resolveProject(projectID, in: registry)
        let patchData = try JSONSerialization.data(withJSONObject: patchObj, options: [])
        let cfgStore = PublishConfigStore(projectURL: entry.url)
        let result = try await cfgStore.applyPatch(patchData)

        // Warn about section keys that don't match any piece in the project.
        let validIDs = Set(ProjectStore.collectDocuments(in: entry.store.manifest.structure).map(\.id))
        let unknownKeys = result.config.sections.keys.filter { !validIDs.contains($0) }.sorted()
        let warnings: [String] = unknownKeys.map {
            "section key '\($0)' matches no piece in this project; call get_outline for valid piece ids"
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cfgData = try encoder.encode(result.config)
        let cfgObj = try JSONSerialization.jsonObject(with: cfgData)
        let errs = result.errors.map { ["field": $0.field, "message": $0.message] }
        return try JSONSerialization.data(withJSONObject: [
            "config": cfgObj,
            "errors": errs,
            "warnings": warnings
        ], options: [.sortedKeys])
    }
}
