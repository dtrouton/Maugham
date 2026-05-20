import Foundation

/// MCP `tools/list` handler. Returns the catalog of available tools with
/// JSON-Schema-shaped `inputSchema` for each. Claude Desktop consumes this
/// to know which tools to expose and how to render arguments.
///
/// The catalog is derived from `MCPToolCatalog.all` — the single source of
/// truth for both tool registration and tool advertisement. To add a tool,
/// implement `MCPTool` on it and add the type to `MCPToolCatalog.all`. Do
/// not list tools here.
public enum MCPToolsListHandler {
    public static let method = "tools/list"

    public static func handle(paramsJSON: Data?) async throws -> Data {
        var tools: [AnyJSON] = []
        for tool in MCPToolCatalog.all {
            let schemaAny = try JSONDecoder().decode(
                AnyJSON.self, from: Data(tool.inputSchemaJSON.utf8))
            tools.append(.object([
                "name": .string(tool.method),
                "description": .string(tool.description),
                "inputSchema": schemaAny
            ]))
        }
        let result = AnyJSON.object(["tools": .array(tools)])
        return try JSONEncoder().encode(result)
    }
}
