import Foundation

public enum InitializePublishTemplateTool: MCPTool {

    public static let method = "initialize_publish_template"

    public static let description =
    "Initialize the per-project publishing template. Copies the bundled barebones starter into .maugham/publish/. Refuses if already initialized unless force=true. Call this before any other publish_* tool on a project that predates the publishing feature."

    public static let inputSchemaJSON = """
    {
      "type": "object",
      "properties": {
        "project_id": {"type": "string", "description": "Project ID from list_projects"},
        "force": {"type": "boolean", "description": "Overwrite if already initialized", "default": false}
      },
      "required": ["project_id"]
    }
    """

    struct Params: Codable {
        let projectID: String
        let force: Bool?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case force
        }
    }

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        guard let json = paramsJSON else {
            throw MCPError.invalidArgument("missing params")
        }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let entry = registry.lookup(id: params.projectID) else {
            throw MCPError.invalidArgument("unknown project_id")
        }
        do {
            try PublishStarter.install(
                into: entry.url, force: params.force ?? false)
        } catch PublishStarter.Error.alreadyInitialized {
            throw MCPError.invalidArgument(
                "publish template already initialized — pass force=true to overwrite")
        }
        let response: [String: Any] = [
            "status": "initialized",
            "publish_dir": ".maugham/publish"
        ]
        return try JSONSerialization.data(
            withJSONObject: response, options: [.sortedKeys])
    }
}
