import Foundation

/// MCP tool: `list_maugham_tools`
///
/// Returns the complete, flat, unranked catalog of every tool this Maugham
/// server exposes, along with server build identity. Use this to
/// authoritatively verify which tools are present and which build you are
/// connected to — unlike semantic tool search, it never omits tools.
public enum ListMaughamToolsTool: MCPTool {
    public static let method = "list_maugham_tools"
    public static let description =
        "Flat, complete, UNRANKED list of every tool this Maugham server exposes, each with its description, plus server build identity (variant, version, tool_count). Call this to authoritatively verify which tools are available and which build you are connected to — unlike semantic tool search, it never omits tools. Optional name_contains is a plain (non-semantic) case-insensitive substring filter on tool names."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"name_contains":{"type":"string","description":"Optional case-insensitive plain substring filter on tool names. Omit to list all. NOT semantic."}}}
    """

    struct Params: Codable {
        let nameContains: String?
        enum CodingKeys: String, CodingKey { case nameContains = "name_contains" }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let filter = paramsJSON
            .flatMap { try? JSONDecoder().decode(Params.self, from: $0) }?
            .nameContains?
            .lowercased()

        let all = MCPToolCatalog.all
        var tools: [[String: Any]] = all.map { ["name": $0.method, "description": $0.description] }
        if let f = filter, !f.isEmpty {
            tools = tools.filter { (($0["name"] as? String) ?? "").lowercased().contains(f) }
        }
        tools.sort { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") }

        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let buildVariantString = BuildVariant.current == .dev ? "dev" : "stable"
        let server: [String: Any] = [
            "name": BuildVariant.current.mcpServerKey,
            "build_variant": buildVariantString,
            "version": version,
            "tool_count": all.count
        ]
        return try JSONSerialization.data(withJSONObject: [
            "server": server,
            "tools": tools,
            "returned": tools.count
        ], options: [.sortedKeys])
    }
}
